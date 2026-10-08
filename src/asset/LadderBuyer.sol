// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IMatchingEngine} from "../exchange/interfaces/IMatchingEngine.sol";
import {IOrderbook} from "../exchange/interfaces/IOrderbook.sol";
import {ExchangeOrderbook} from "../exchange/libraries/ExchangeOrderbook.sol";

interface IEngineNative {
    function WETH() external view returns (address);
    function nativeScale() external view returns (uint256);
}

interface IEngineMaxMatches {
    function maxMatches() external view returns (uint32);
}

interface IWrappedNative {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}

/**
 * @title LadderBuyer
 * @notice One "Buy" or "Sell" that walks several price levels in one transaction and
 * never leaves an order resting on the book. Buyers pay in the market's own quote token —
 * USDC, a tokenized stock, or the chain's gas coin through `buyWithNative`. Nothing is
 * converted: a coin's quote is chosen by its creator at launch and that is what it costs.
 *
 * @dev Why it exists. The engine caps how far a single order may match from the last
 * price (`lmp * (1 + limit spread)`). A launch ladder's steps are ~49.6% apart and the
 * ladder pair's buy spread is set to exactly that gap, so ONE order reaches at most the
 * next step. Each fill moves `lmp` to that step's price, so the next order reaches the
 * step after. This contract sends up to `MAX_STEPS` such orders back to back.
 *
 * ## Every order names the TRADER as `recipient`
 *
 * `OrderMatched.sender` — what the broker credits with the trade, its volume and its
 * POINTS — is the order's `recipient` (MatchingLib passes it to `Orderbook.execute`). An
 * order sent with `recipient = address(this)` would credit every trade to this contract.
 * So orders name the trader, and fills land in their wallet directly.
 *
 * That costs the ability to recycle an unfilled remainder: the engine refunds it to the
 * recipient (OrderPlacementLib.detMake), not here. So each order is SIZED to what the book
 * can fill right now — the levels this order can reach (up to `min(caller's limit,
 * lmp * (1 ± limit spread))`, the cap the engine computes from the same `lmp`, at most
 * `MATCHES_PER_ORDER` resting orders) — and the input this contract still holds funds the
 * next order. A level's cost is rounded UP by one unit, so an order never strands a
 * level's last unit; that unit reaches the recipient as dust. Output is measured as the
 * RECIPIENT's balance change.
 *
 * Because each order spends only what resting orders take, nothing reaches the band-pool
 * fallback. That is intended: a ladder coin's pool is closed until graduation. Ordinary
 * markets should use the router.
 *
 * ## The gas coin: `wrappedNative`, not the engine's WETH
 *
 * A launch quoted in the gas coin is quoted in `WrappedNative` (src/mock/WrappedNative.sol,
 * a plain 1:1 ERC-20) — NOT the engine's `WETH()`. On an unwrapping chain
 * (`nativeScale() == 0`, e.g. RISE) a pair touching the engine's WETH gets no band pool
 * (`addPair`: `nativeScale != 0 || (base != WETH && quote != WETH)`), its payouts arrive
 * as native coin (`Orderbook._pay` unwraps only `WETH()`), and a launch's escrow cannot
 * receive native coin — so graduation could never seed a pool. A separate wrapper is an
 * ordinary ERC-20 to the engine: it gets a pool, settles as an ERC-20, sits in an escrow. `buyWithNative` wraps `msg.value`, walks the
 * ladder, and returns what it did not spend as native coin. `sellForNative` sells for the
 * wrapper with the SELLER as the order's recipient (so the fill is credited to them),
 * then pulls exactly the proceeds back from them — they approve the wrapper to this
 * contract once — and unwraps them to native coin for `recipient`.
 *
 * `wrappedNative` is immutable and the only wrapper accepted, so an arbitrary contract
 * posing as a wrapper can never be called. It is zero on a chain whose gas coin is
 * already an ERC-20 (Arc: native IS USDC, the engine's `nativeScale() != 0`); there the
 * native paths revert `NoWrappedNative` and a buyer pays with `buy` in USDC, which draws
 * on the same balance.
 *
 * ## The ERC-20 paths refuse the engine's own WETH on an unwrapping chain
 *
 * Where `nativeScale() == 0`, a payout in the engine's WETH arrives as native coin, which
 * the ERC-20 paths do not forward, so such legs revert `NativeLegUnsupported`.
 *
 * ## What `refunded` does NOT include
 *
 * Input that went to the engine and was not spent is refunded by the ENGINE to the
 * order's recipient, never back here: each level's rounding unit (up to one unit per
 * level), the unspent part of a dust-clearing order, and — only if the book changes
 * between this contract's read and the engine's match within the same call, which a
 * single transaction cannot do — an unfilled remainder. So the recipient may receive a
 * few units of the INPUT token (the wrapper, for `buyWithNative`) besides the output;
 * `refunded`/`nativeRefunded` is only what this contract still held.
 *
 * `deadline` is a timestamp and must be in the future: `0` (or any past time) reverts
 * `DeadlinePassed`. There is no "no deadline" value.
 *
 * Holds nothing between calls, has no owner and no roles.
 */
contract LadderBuyer is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Orders sent per call. A launch ladder has 5 steps.
    uint256 public constant MAX_STEPS = 5;
    /// @notice Engine `n` per order, unless the engine's `maxMatches` is lower.
    uint32 private constant MATCHES_PER_ORDER = 20;
    /// @dev The engine's per-call dust-eviction cap (MatchingLib.MAX_DUST_EVICTIONS).
    uint256 private constant MAX_DUST_EVICTIONS = 8;
    /// @dev Dust-clearing orders per call, on top of `MAX_STEPS` filling orders.
    uint256 private constant MAX_EVICT_ORDERS = 3;
    /// @dev `expireOrder` calls per cleaning pass: bounds the gas a planted queue costs.
    uint256 private constant MAX_EXPIRIES = 20;
    /// @dev The engine's price scale (`MatchingEngine.DENOM`).
    uint256 private constant PRICE_DENOM = 1e8;

    IMatchingEngine public immutable engine;
    /// @notice The gas-coin wrapper launches are quoted in. Zero where the gas coin is
    /// already an ERC-20.
    address public immutable wrappedNative;

    error DeadlinePassed(uint256 deadline, uint256 nowTs);
    error InsufficientOutput(uint256 out, uint256 minOut);
    error ZeroAmount();
    error NativeLegUnsupported(address token);
    error InvalidRecipient(address recipient);
    error NoMarket(address base, address quote);
    error NoWrappedNative();
    error NotCanonicalWrapper(address wrapper);
    error UnexpectedNative(address from);
    error NativeTransferFailed();

    event LadderTrade(
        address indexed sender, address indexed base, address indexed quote, bool isBuy, uint256 amountIn,
        uint256 amountOut, uint256 refunded, uint256 orders
    );

    constructor(address engine_, address wrappedNative_) {
        engine = IMatchingEngine(engine_);
        // The engine's own WETH on an unwrapping chain gets no band pool and settles as
        // native coin: it can never be a launch quote, so it is never the wrapper here.
        if (wrappedNative_ != address(0)) {
            try IEngineNative(engine_).nativeScale() returns (uint256 scale) {
                if (scale == 0 && wrappedNative_ == IEngineNative(engine_).WETH()) {
                    revert NotCanonicalWrapper(wrappedNative_);
                }
            } catch {}
        }
        wrappedNative = wrappedNative_;
    }

    /// @dev Only the wrapper's `withdraw` pays native coin here.
    receive() external payable {
        if (msg.sender != wrappedNative || msg.sender == address(0)) revert UnexpectedNative(msg.sender);
    }

    /* --------------------------------- ERC-20 -------------------------------- */

    /// @notice Spend up to `quoteIn` of `quote` buying `base`, never above `maxPrice`.
    /// @return baseOut Base the engine paid `recipient`, net of the taker fee.
    /// @return refunded Quote returned to `msg.sender` (per-level dust goes to `recipient`).
    function buy(
        address base,
        address quote,
        uint256 quoteIn,
        uint256 maxPrice,
        uint256 minBaseOut,
        address recipient,
        uint256 deadline
    ) external nonReentrant returns (uint256 baseOut, uint256 refunded) {
        uint256 orders;
        (baseOut, refunded, orders) = _trade(base, quote, quoteIn, maxPrice, recipient, deadline, true);
        if (baseOut < minBaseOut) revert InsufficientOutput(baseOut, minBaseOut);
        if (refunded > 0) IERC20(quote).safeTransfer(msg.sender, refunded);
        emit LadderTrade(msg.sender, base, quote, true, quoteIn, baseOut, refunded, orders);
    }

    /// @notice Sell up to `baseIn` of `base` for `quote`, never below `minPrice`.
    /// @return quoteOut Quote the engine paid `recipient`, net of the taker fee.
    /// @return refunded Base returned to `msg.sender` (per-level dust goes to `recipient`).
    function sell(
        address base,
        address quote,
        uint256 baseIn,
        uint256 minPrice,
        uint256 minQuoteOut,
        address recipient,
        uint256 deadline
    ) external nonReentrant returns (uint256 quoteOut, uint256 refunded) {
        uint256 orders;
        (quoteOut, refunded, orders) = _trade(base, quote, baseIn, minPrice, recipient, deadline, false);
        if (quoteOut < minQuoteOut) revert InsufficientOutput(quoteOut, minQuoteOut);
        if (refunded > 0) IERC20(base).safeTransfer(msg.sender, refunded);
        emit LadderTrade(msg.sender, base, quote, false, baseIn, quoteOut, refunded, orders);
    }

    /* ------------------------------- gas coin -------------------------------- */

    /**
     * @notice Buy a coin quoted in the gas coin, paying `msg.value`: wrap it 1:1, walk
     * the ladder with `recipient` as the trader, return the rest as native coin.
     * @param wrapper Must be `wrappedNative` — the market's quote.
     * @return baseOut Base the engine paid `recipient`, net of the taker fee.
     * @return nativeRefunded Gas coin not spent, to `msg.sender`.
     */
    function buyWithNative(
        address base,
        address wrapper,
        uint256 maxPrice,
        uint256 minBaseOut,
        address recipient,
        uint256 deadline
    ) external payable nonReentrant returns (uint256 baseOut, uint256 nativeRefunded) {
        _checkDeadline(deadline);
        _requireWrapper(wrapper);
        if (msg.value == 0) revert ZeroAmount();
        _requireErc20Leg(base);
        // Snapshot before the wrapper arrives, so `remaining` counts only this payment.
        Trade memory t = _newTrade(base, wrapper, maxPrice, true, recipient);
        IWrappedNative(wrapper).deposit{value: msg.value}();
        uint256 orders;
        (baseOut, nativeRefunded, orders) = _run(t, msg.value);
        if (baseOut < minBaseOut) revert InsufficientOutput(baseOut, minBaseOut);
        if (nativeRefunded > 0) {
            IWrappedNative(wrapper).withdraw(nativeRefunded);
            _sendNative(msg.sender, nativeRefunded);
        }
        emit LadderTrade(msg.sender, base, wrapper, true, msg.value, baseOut, nativeRefunded, orders);
    }

    /**
     * @notice Sell a coin quoted in the gas coin and receive native coin. The orders name
     * `msg.sender` (the seller) as recipient, so every fill is credited to them; the
     * wrapper proceeds are then pulled back from them and unwrapped to `recipient`.
     * Needs a one-time `approve(wrappedNative → this)` from the seller.
     * @return nativeOut Native coin sent to `recipient`, net of the taker fee.
     * @return refunded Base returned to `msg.sender`.
     */
    function sellForNative(
        address base,
        address wrapper,
        uint256 baseIn,
        uint256 minPrice,
        uint256 minNativeOut,
        address recipient,
        uint256 deadline
    ) external nonReentrant returns (uint256 nativeOut, uint256 refunded) {
        _requireWrapper(wrapper);
        if (recipient == address(0) || recipient == address(this)) revert InvalidRecipient(recipient);
        uint256 orders;
        // The seller is the orders' recipient: they are the trader the broker credits.
        (nativeOut, refunded, orders) = _trade(base, wrapper, baseIn, minPrice, msg.sender, deadline, false);
        if (nativeOut < minNativeOut) revert InsufficientOutput(nativeOut, minNativeOut);
        if (refunded > 0) IERC20(base).safeTransfer(msg.sender, refunded);
        // Exactly the proceeds this call produced, measured at the seller.
        IERC20(wrapper).safeTransferFrom(msg.sender, address(this), nativeOut);
        IWrappedNative(wrapper).withdraw(nativeOut);
        _sendNative(recipient, nativeOut);
        emit LadderTrade(msg.sender, base, wrapper, false, baseIn, nativeOut, refunded, orders);
    }

    /* -------------------------------- internals ------------------------------ */

    /// @dev Everything one trade tracks, in memory: the legacy pipeline has no stack room
    /// for it as locals.
    struct Trade {
        address base;
        address quote;
        address pair;
        address recipient;
        IERC20 tokenIn;
        IERC20 tokenOut;
        uint256 price;
        uint256 inBefore;
        uint256 outBefore;
        uint256 remaining;
        bool isBuy;
    }

    /// @dev Pull `amountIn` of the input token, then trade what arrived (see `_run`).
    /// Rebasing tokens are unsupported: a balance that moves on its own is not something a
    /// balance delta can attribute.
    function _trade(
        address base,
        address quote,
        uint256 amountIn,
        uint256 price,
        address recipient,
        uint256 deadline,
        bool isBuy
    ) private returns (uint256 out, uint256 unspent, uint256 orders) {
        _checkDeadline(deadline);
        if (amountIn == 0) revert ZeroAmount();
        _requireErc20Leg(base);
        _requireErc20Leg(quote);
        Trade memory t = _newTrade(base, quote, price, isBuy, recipient);
        t.tokenIn.safeTransferFrom(msg.sender, address(this), amountIn);
        // What ARRIVED, not what was asked for: a fee-on-transfer token delivers less,
        // and refunding the nominal amount would pay out of whatever else is here.
        return _run(t, t.tokenIn.balanceOf(address(this)) - t.inBefore);
    }

    /// @dev Snapshot balances BEFORE the input arrives, so a donation sitting here is
    /// never counted as the caller's. `outBefore` is the RECIPIENT's balance: that is
    /// where the engine pays the output.
    function _newTrade(address base, address quote, uint256 price, bool isBuy, address recipient)
        private
        view
        returns (Trade memory t)
    {
        if (recipient == address(0) || recipient == address(this)) revert InvalidRecipient(recipient);
        t.base = base;
        t.quote = quote;
        t.pair = engine.getPair(base, quote);
        if (t.pair == address(0)) revert NoMarket(base, quote);
        t.price = price;
        t.isBuy = isBuy;
        t.recipient = recipient;
        t.tokenIn = IERC20(isBuy ? quote : base);
        t.tokenOut = IERC20(isBuy ? base : quote);
        t.inBefore = t.tokenIn.balanceOf(address(this));
        t.outBefore = t.tokenOut.balanceOf(recipient);
    }

    /**
     * @dev Each order spends exactly what the levels reachable this order can take,
     * paid to and credited to `t.recipient`. Stops when the input is spent, nothing is
     * reachable, or an order fills nothing.
     *
     * Before every order the reachable levels are cleaned of EXPIRED orders through the
     * engine's permissionless `expireOrder`. The engine evicts an unfillable order without
     * counting a match, and a level that yields no match ENDS its sweep (MatchingLib
     * `limitOrder`, i == prevI) and refunds the rest of the order to the recipient — so one
     * expired ask planted between ladder steps would stall every walk. A DUST order (its
     * amount converts to zero) cannot be expired; a level whose head is only dust is
     * cleared by a minimal order priced at it (`_evict`), whose unspent input reaches the
     * recipient — a few units, never the budget.
     * @return out The recipient's balance change in the output token.
     * @return unspent Input still held here, for the caller to return.
     */
    function _run(Trade memory t, uint256 amountIn)
        private
        returns (uint256 out, uint256 unspent, uint256 orders)
    {
        t.remaining = amountIn;
        uint32 n = _matchBudget();
        uint256 evictions;
        while (orders < MAX_STEPS && t.remaining > 0) {
            _expireReachable(t, n);
            (uint256 send, uint256 lastLevel, uint256 dustLevel) = _reachable(t, n);
            if (send == 0) {
                // Nothing fillable before a dust-only level: clear it and look again.
                if (dustLevel == 0 || evictions >= MAX_EVICT_ORDERS) break;
                ++evictions;
                if (!_evict(t, dustLevel, n, orders == 0 && evictions == 1)) break;
                continue;
            }
            if (send > t.remaining) send = t.remaining;
            ++orders;
            if (!_order(t, send, lastLevel, n, orders == 1 && evictions == 0)) break;
        }
        t.tokenIn.forceApprove(address(engine), 0);
        out = t.tokenOut.balanceOf(t.recipient) - t.outBefore;
        unspent = t.remaining;
    }

    /// @dev `min(MATCHES_PER_ORDER, engine.maxMatches())`. The engine REVERTS an order
    /// whose `n` exceeds its cap, so a lowered cap must lower this. The getter is not on
    /// every deployed engine (RISE's predates it), so its absence means the default.
    function _matchBudget() private view returns (uint32 n) {
        n = MATCHES_PER_ORDER;
        try IEngineMaxMatches(address(engine)).maxMatches() returns (uint32 cap) {
            if (cap != 0 && cap < n) n = cap;
        } catch {}
    }

    /// @dev The price the engine lets this order reach: `min(limit, lmp * (1 + buy
    /// spread))` for a buy, `max(limit, lmp * (1 - sell spread))` for a sell.
    function _cap(Trade memory t, IOrderbook book) private view returns (uint256 cap) {
        uint256 lmp = book.lmp();
        uint256 s = engine.getSpread(t.pair, t.isBuy, false);
        if (t.isBuy) {
            cap = lmp * (PRICE_DENOM + s) / PRICE_DENOM;
            if (t.price < cap) cap = t.price;
        } else {
            cap = s >= PRICE_DENOM ? 0 : lmp * (PRICE_DENOM - s) / PRICE_DENOM;
            if (t.price > cap) cap = t.price;
        }
    }

    /// @dev Expire every expired order in the reachable levels, up to `MAX_EXPIRIES` per
    /// call. Permissionless on the engine; the owner gets their deposit back.
    function _expireReachable(Trade memory t, uint32 n) private {
        IOrderbook book = IOrderbook(t.pair);
        uint256 cap = _cap(t, book);
        bool restingIsBid = !t.isBuy;
        uint256 price = t.isBuy ? book.askHead() : book.bidHead();
        uint256 seen;
        uint256 expired;
        while (price != 0 && seen < n && expired < MAX_EXPIRIES && (t.isBuy ? price <= cap : price >= cap)) {
            uint256 next = book.nextPrice(restingIsBid, price);
            uint32 id = book.orderHead(restingIsBid, price);
            while (id != 0 && seen < n && expired < MAX_EXPIRIES) {
                uint32 nextId = book.nextOrder(restingIsBid, price, id);
                ExchangeOrderbook.Order memory o = book.getOrder(restingIsBid, id);
                if (o.deadline != 0 && block.timestamp > o.deadline) {
                    engine.expireOrder(t.base, t.quote, restingIsBid, id);
                    ++expired;
                } else if (o.depositAmount != 0) {
                    ++seen;
                }
                id = nextId;
            }
            price = next;
        }
    }

    /**
     * @dev Input that clears every level this order can reach (`_cap`), up to `n`
     * fillable resting orders. Each level's cost is its fillable amount converted at its
     * price, plus one unit so integer rounding never strands the level's last unit.
     * Dust (converts to zero) costs nothing and is not counted against `n`: the engine
     * evicts it without a match. A level whose first `MAX_DUST_EVICTIONS` orders are all
     * dust would END the engine's sweep, so it is never included: sizing stops before it.
     * @return need Input that clears every included level.
     * @return lastLevel The furthest level included: the order is priced THERE, never at
     * the caller's limit, because the engine sizes an order by converting its input at its
     * own price and an open-ended limit converts to zero.
     * @return dustLevel The dust-only level sizing stopped at, or 0.
     */
    function _reachable(Trade memory t, uint32 n)
        private
        view
        returns (uint256 need, uint256 lastLevel, uint256 dustLevel)
    {
        IOrderbook book = IOrderbook(t.pair);
        uint256 cap = _cap(t, book);
        uint256 price = t.isBuy ? book.askHead() : book.bidHead();
        uint256 counted;
        while (price != 0 && counted < n && (t.isBuy ? price <= cap : price >= cap)) {
            uint256 level;
            (level, counted) = _levelAmount(t, book, price, n, counted);
            if (level == 0) return (need, lastLevel, price);
            // Asks rest base, bought with quote; bids rest quote, bought with base.
            need += book.convert(price, level, t.isBuy) + 1;
            lastLevel = price;
            price = book.nextPrice(!t.isBuy, price);
        }
    }

    /// @dev The fillable amount resting at `price`, counting fillable orders into
    /// `counted` up to `n`. Zero when the level is dust-only, or opens with
    /// `MAX_DUST_EVICTIONS` dust orders (where the engine's eviction cap ends its sweep).
    function _levelAmount(Trade memory t, IOrderbook book, uint256 price, uint32 n, uint256 counted)
        private
        view
        returns (uint256 level, uint256 countedAfter)
    {
        bool restingIsBid = !t.isBuy;
        uint256 dustRun;
        uint32 id = book.orderHead(restingIsBid, price);
        while (id != 0 && counted < n) {
            uint256 amount = book.getOrder(restingIsBid, id).depositAmount;
            id = book.nextOrder(restingIsBid, price, id);
            if (amount == 0) continue;
            // The engine's own test (Orderbook.fpop): the resting deposit converted into
            // the taker's asset. Asks rest base (-> quote, isBid true); bids rest quote.
            if (book.convert(price, amount, t.isBuy) == 0) {
                // Dust ahead of any fill: the engine evicts it free, up to its cap.
                if (level == 0 && ++dustRun >= MAX_DUST_EVICTIONS) break;
                continue;
            }
            ++counted;
            level += amount;
        }
        countedAfter = counted;
    }

    /// @dev A minimal taker order at a dust-only level: the engine evicts up to
    /// `MAX_DUST_EVICTIONS` dust orders there and ends the sweep; the unspent input (the
    /// smallest size the engine accepts) reaches the recipient. Returns whether the
    /// level changed, i.e. whether a further look can make progress.
    function _evict(Trade memory t, uint256 level, uint32 n, bool first) private returns (bool progressed) {
        IOrderbook book = IOrderbook(t.pair);
        uint32 headBefore = book.orderHead(!t.isBuy, level);
        // The engine refuses an order whose size converts to no more than one unit's worth;
        // the cost of one output unit plus one, or 2, clears that.
        uint256 amount = book.convert(level, 1, t.isBuy) + 1;
        if (amount < 2) amount = 2;
        if (amount > t.remaining) return false;
        _order(t, amount, level, n, first);
        progressed = book.orderHead(!t.isBuy, level) != headBefore;
    }

    /// @dev One taker order of `amount` at `price` to `t.recipient`. Returns whether it filled
    /// anything. The FIRST order's revert propagates (a missing pair or an order the
    /// engine refuses is the caller's answer); a later order's revert ends the walk,
    /// since by then it can only be a dust remainder the engine calls too small.
    function _order(Trade memory t, uint256 amount, uint256 price, uint32 n, bool first)
        private
        returns (bool filled)
    {
        uint256 outBeforeOrder = t.tokenOut.balanceOf(t.recipient);
        t.tokenIn.forceApprove(address(engine), amount);
        IMatchingEngine.LimitOrderInput memory input = IMatchingEngine.LimitOrderInput({
            base: t.base,
            quote: t.quote,
            price: price,
            amount: amount,
            isMaker: false,
            n: n,
            recipient: t.recipient
        });
        if (first) {
            if (t.isBuy) engine.limitBuy(input);
            else engine.limitSell(input);
        } else if (t.isBuy) {
            try engine.limitBuy(input) {} catch { return false; }
        } else {
            try engine.limitSell(input) {} catch { return false; }
        }
        t.remaining = t.tokenIn.balanceOf(address(this)) - t.inBefore;
        filled = t.tokenOut.balanceOf(t.recipient) != outBeforeOrder;
    }

    function _requireWrapper(address wrapper) private view {
        if (wrappedNative == address(0)) revert NoWrappedNative();
        if (wrapper != wrappedNative) revert NotCanonicalWrapper(wrapper);
    }

    function _sendNative(address to, uint256 amount) private {
        (bool ok,) = payable(to).call{value: amount}("");
        if (!ok) revert NativeTransferFailed();
    }

    function _checkDeadline(uint256 deadline) private view {
        if (block.timestamp > deadline) revert DeadlinePassed(deadline, block.timestamp);
    }

    /// @dev A leg in the ENGINE's WETH is only safe where it is the chain's own ERC-20
    /// (nonzero `nativeScale`), because then settlement never unwraps to native coin.
    function _requireErc20Leg(address token) private view {
        IEngineNative e = IEngineNative(address(engine));
        if (token == e.WETH() && e.nativeScale() == 0) revert NativeLegUnsupported(token);
    }
}
