/// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {TransferHelper} from "../../exchange/libraries/TransferHelper.sol";
import {ExchangeOrderbook} from "../../exchange/libraries/ExchangeOrderbook.sol";
import {IMatchingEngine} from "../../exchange/interfaces/IMatchingEngine.sol";
import {IOrderbook} from "../../exchange/interfaces/IOrderbook.sol";
import {IPoolFactory} from "../../swap/interfaces/IPoolFactory.sol";
import {IBandPool} from "../../swap/interfaces/IBandPool.sol";
import {IBandPositionManager} from "../../swap/interfaces/IBandPositionManager.sol";
import {AssetGenerator} from "../AssetGenerator.sol";
import {PoolBands} from "../../swap/PoolBands.sol";

/// The pool-creator surface of a band pool the launch needs while it holds it.
interface ILaunchPool {
    function bandCount() external view returns (uint256);
    function setBandOpen(uint8 index, bool open) external;
    function transferCreator(address to) external;
}

/**
 * @notice Holds one coin's launch proceeds until it graduates.
 * @dev The ladder's resting asks are placed with this contract as their owner, so every
 * fill pays its quote HERE rather than into the generator's balance, where several coins'
 * proceeds would be indistinguishable. The dev buy's quote lands here too. Only the
 * generator that deployed it can move anything out, and it does so once, at graduation.
 * It has no way to cancel an order, so before graduation nobody -- creator, generator or
 * admin -- can take back the ladder or the money it raised.
 */
contract LaunchEscrow {
    address internal immutable generator;

    error NotGenerator();

    constructor() {
        generator = msg.sender;
    }

    function sweep(address token, address to) external returns (uint256 amount) {
        if (msg.sender != generator) revert NotGenerator();
        amount = IERC20(token).balanceOf(address(this));
        if (amount > 0) TransferHelper.safeTransfer(token, to, amount);
    }
}

/**
 * @title AssetLaunchLib
 * @notice The heavy halves of `AssetGenerator.launch` and `graduate`, moved out for
 * EIP-170 headroom. Every function is `public`, so the generator reaches it by
 * DELEGATECALL: `address(this)`, `msg.sender` and `msg.value` are still the generator and
 * the caller. The generator keeps all storage; this takes values and returns them.
 *
 * ## The launch, in one place
 *
 * A coin opens at the quote's `startingMarketCap` and its supply is sold on the ORDER
 * BOOK, not into a pool:
 *
 *  - up to 10% to its creator, at the starting price (the dev buy);
 *  - 80% as five resting asks owned by the coin's `LaunchEscrow`, at market caps
 *    rising geometrically from `startingMarketCap` to `graduationMarketCap`;
 *  - the rest is held back in the escrow.
 *
 * An ask fills at its own price, so nobody can buy step 4's coins at step 0's price --
 * the property the band-seeded launch lacked (bands fill at the TWAP anchor with no price
 * impact inside a transaction). The pair's band pool exists from listing but every band
 * is CLOSED until graduation, and this contract holds its creator role.
 *
 * At graduation the escrow's quote (every ladder fill plus the dev buy) and its coins
 * (the held-back supply, plus any ladder remainder the book refunded) become one band
 * position the generator holds forever.
 */
library AssetLaunchLib {
    error InsufficientFee(uint256 sent, uint256 required);
    error FeeToNotSet();
    error RefundFailed();
    error DevBuyTooSmall(uint256 quoteIn, uint256 minimum);
    error DevBuyTooLarge(uint256 coinsOut, uint256 cap);
    error ListingPriceTooLow(uint256 price);
    error NoBandPool(address coin, address quote);
    error LadderNotFilled(uint256 step);
    error LadderNotPlaced();
    error LadderAlreadyPlaced();
    error InvalidFee(uint32 feeNum);
    error NotTheCreator(address caller);
    error CreatorFeeControlLocked(address coin);
    error NothingToRelease();
    error BandCallNotAllowed(bytes4 selector);
    error PairAlreadyListed(address base, address quote);
    error InvalidVolatility(uint16 volatilityBps);
    error FeeOutsidePairRange(uint32 feeNum, uint32 minFee, uint32 maxFee);
    error FeeAboveCreatorCap(uint32 feeNum, uint32 cap);

    event DevBuy(address indexed coin, address indexed creator, uint256 quoteIn, uint256 coinsOut);
    /// @notice Step `step` of `coin`'s ladder rests as ask `orderId`: `amount` at `price`.
    event LadderStep(address indexed coin, uint8 step, uint32 orderId, uint256 price, uint256 amount);

    uint256 private constant BPS = 10_000;
    uint256 private constant DENOM = 1e8;
    uint256 internal constant STEPS = 5;
    /// See the identically named constants on AssetGenerator, which publish these.
    uint16 internal constant MAX_DEV_BUY_BPS = 1_000;
    uint16 internal constant LADDER_BPS = 8_000;
    uint256 internal constant MIN_LISTING_PRICE = 100;
    uint64 internal constant VEST_DURATION = 365 days;

    /// @notice What a launch leaves for the generator to record.
    struct Ladder {
        address pair;
        address escrow;
        /// @dev The pair's limit BUY spread before the launch widened it; graduation restores it.
        uint32 restoreBuySpread;
        uint32[5] askIds;
    }

    /// @notice Everything a launch needs from the generator, bundled against "stack too deep".
    struct LaunchArgs {
        address engine;
        address coin;
        address quote;
        uint256 supply;
        uint256 devBuyQuote;
        uint256 launchFee;
        address feeTo;
        /// @dev Skip the ladder here; `placeDeferredLadder` places it in a second
        /// transaction. For chains whose per-transaction gas cap cannot hold a whole
        /// launch (Tempo: ~30M gas against a 30M cap, from 250k-gas storage slots).
        bool deferLadder;
    }

    /// @notice The generator's policy bounds, as a lister's pair must sit inside them.
    struct PairBounds {
        uint16 minSlippageBps;
        uint16 maxSlippageBps;
        uint32 minFee;
        uint32 maxFee;
        uint32 creatorCap;
    }

    /* --------------------------------- launch ---------------------------------- */

    /**
     * @notice Lists the pair at the starting price, sells the creator their dev buy,
     * places the five-step ladder, and closes the pool's bands. Charges nothing yet:
     * the fee is paid by `payFee`, after the generator has written every piece of state.
     */
    function settleListing(LaunchArgs memory a, AssetGenerator.QuoteOption memory option)
        public
        returns (Ladder memory l)
    {
        if (msg.value < a.launchFee) revert InsufficientFee(msg.value, a.launchFee);
        if (a.launchFee > 0 && a.feeTo == address(0)) revert FeeToNotSet();

        uint256[5] memory prices = ladderPrices(a.quote, a.supply, option.startingMarketCap, option.graduationMarketCap);
        if (prices[0] < MIN_LISTING_PRICE) revert ListingPriceTooLow(prices[0]);
        IMatchingEngine engine = IMatchingEngine(a.engine);
        // Pair creation is protocol-fee-free; `payment` is unused by the engine.
        l.pair = engine.addPair(a.coin, a.quote, prices[0], block.timestamp, a.coin, option.mode);
        l.escrow = address(new LaunchEscrow());

        _devBuy(a, option.minDevBuy, l, prices[0]);
        if (!a.deferLadder) _placeLadder(a, engine, l, prices);
        _setBandsOpen(_poolOf(a.engine, a.coin, a.quote), false);
    }

    /**
     * @notice Places a deferred launch's ladder: the second of a two-transaction launch.
     * @dev Same five asks, same prices and amounts as an inline launch, recomputed from
     * the coin's supply and the quote option. The generator has held the ladder and the
     * held-back supply since `launch`; `_placeLadder` moves both out, exactly as it does
     * inline. Until this runs the pair is listed with no ladder, so nothing can be
     * bought, and `requireFilled` refuses to arm graduation.
     *
     * Reads the quote option as it stands NOW: an admin who changes the caps between
     * the two transactions changes this ladder. Accepted for the chains that defer.
     */
    function placeDeferredLadder(
        address engine,
        address coin,
        address quote,
        Ladder memory l,
        AssetGenerator.QuoteOption memory option
    ) public returns (Ladder memory) {
        if (l.askIds[0] != 0) revert LadderAlreadyPlaced();
        uint256 supply = IERC20(coin).totalSupply();
        uint256[5] memory prices = ladderPrices(quote, supply, option.startingMarketCap, option.graduationMarketCap);
        LaunchArgs memory a;
        a.engine = engine;
        a.coin = coin;
        a.quote = quote;
        a.supply = supply;
        _placeLadder(a, IMatchingEngine(engine), l, prices);
        return l;
    }

    /// @notice Pays the launch fee and refunds the rest. The generator calls it LAST.
    function payFee(address feeTo, uint256 launchFee) public {
        if (launchFee > 0) TransferHelper.safeTransferETH(feeTo, launchFee);
        uint256 refund = msg.value - launchFee;
        if (refund > 0) {
            (bool ok,) = payable(msg.sender).call{value: refund}("");
            if (!ok) revert RefundFailed();
        }
    }

    /**
     * @notice The engine price, on its 1e8 scale, at which `supply` of an 18-decimal coin
     * is worth `marketCap` of `quote`, ROUNDED UP: a price that rounds down sells the
     * supply below the advertised market cap. The inverse of `Orderbook.convert`.
     */
    function listingPrice(address quote, uint256 supply, uint256 marketCap) public view returns (uint256) {
        uint8 d = IERC20Metadata(quote).decimals();
        if (d <= 18) return Math.ceilDiv(marketCap * 10 ** (18 - d) * DENOM, supply);
        return Math.ceilDiv(marketCap * DENOM, supply * 10 ** (d - 18));
    }

    /**
     * @notice The five ladder prices: market caps `start * r^i` with `r^4 = end / start`.
     * @dev Integer geometric means instead of a fractional power: step 2 is
     * `sqrt(start * end)`, steps 1 and 3 the means either side of it. Each `sqrt` floors,
     * which moves a step's market cap by under one quote base unit (1e-6 USDC), and each
     * price then rounds UP. Steps 0 and 4 are exactly `start` and `end`.
     */
    function ladderPrices(address quote, uint256 supply, uint256 start, uint256 end)
        public
        view
        returns (uint256[5] memory p)
    {
        uint256 mid = Math.sqrt(start * end);
        p[0] = listingPrice(quote, supply, start);
        p[1] = listingPrice(quote, supply, Math.sqrt(start * mid));
        p[2] = listingPrice(quote, supply, mid);
        p[3] = listingPrice(quote, supply, Math.sqrt(mid * end));
        p[4] = listingPrice(quote, supply, end);
    }

    /// The creator pays for their coins at the starting price, through the pair's own
    /// arithmetic so the amount matches what the book would quote. Their quote goes to the
    /// escrow: it is the first money raised and it seeds the pool at graduation.
    function _devBuy(LaunchArgs memory a, uint256 minDevBuy, Ladder memory l, uint256 price) private {
        if (a.devBuyQuote < minDevBuy) revert DevBuyTooSmall(a.devBuyQuote, minDevBuy);
        if (a.devBuyQuote == 0) return;
        TransferHelper.safeTransferFrom(a.quote, msg.sender, l.escrow, a.devBuyQuote);
        uint256 coinsOut = IOrderbook(l.pair).convert(price, a.devBuyQuote, false);
        uint256 cap = (a.supply * MAX_DEV_BUY_BPS) / BPS;
        if (coinsOut > cap) revert DevBuyTooLarge(coinsOut, cap);
        TransferHelper.safeTransfer(a.coin, msg.sender, coinsOut);
        emit DevBuy(a.coin, msg.sender, a.devBuyQuote, coinsOut);
    }

    /**
     * 80% of supply as five resting asks, 16% each (the last takes the rounding
     * remainder), owned by the escrow. What is left after the dev buy and the ladder --
     * at least 10% of supply -- is held back in the escrow for the pool.
     *
     * ## The spread
     *
     * A limit BUY may match no higher than `lmp * (1 + buy spread)`, and `lmp` sits at the
     * last step filled. The 3% default would strand the ladder at step 0, so the pair's
     * limit buy spread is widened to the largest step-to-step rise, rounded up -- about
     * 49.5% for a 5x ladder -- which lets one ordinary limit buy reach the next step and no
     * further. Graduation puts the previous value back.
     *
     * The SELL spread is left at the default on purpose. A limit sell may rest no lower
     * than `lmp * (1 - sell spread)`, so while the ladder is live anyone dumping -- the
     * creator's dev coins included -- can only sell within 3% of the last ladder price,
     * one order at a time, into whatever bids exist.
     *
     * Market orders keep the pair's slippage limit (100 bps), so a market buy cannot reach
     * the next step; the interface buys the ladder with limit orders.
     */
    function _placeLadder(LaunchArgs memory a, IMatchingEngine engine, Ladder memory l, uint256[5] memory prices)
        private
    {
        uint256 maxRise;
        for (uint256 i = 1; i < STEPS; i++) {
            uint256 rise = Math.ceilDiv((prices[i] - prices[i - 1]) * DENOM, prices[i - 1]);
            if (rise > maxRise) maxRise = rise;
        }
        l.restoreBuySpread = engine.getSpread(l.pair, true, false);
        if (maxRise > l.restoreBuySpread) {
            engine.setSpread(
                a.coin, a.quote, SafeCast.toUint32(maxRise), engine.getSpread(l.pair, false, false), false
            );
        }

        uint256 ladder = (a.supply * LADDER_BPS) / BPS;
        uint256 step = ladder / STEPS;
        TransferHelper.safeApprove(a.coin, address(engine), ladder);
        for (uint256 i = 0; i < STEPS; i++) {
            uint256 amount = i + 1 == STEPS ? ladder - step * (STEPS - 1) : step;
            l.askIds[i] = engine.limitSell(
                IMatchingEngine.LimitOrderInput({
                    base: a.coin,
                    quote: a.quote,
                    price: prices[i],
                    amount: amount,
                    isMaker: true,
                    n: 1,
                    recipient: l.escrow
                })
            ).id;
            emit LadderStep(a.coin, uint8(i), l.askIds[i], prices[i], amount);
        }
        TransferHelper.safeApprove(a.coin, address(engine), 0);
        // The held-back supply joins the proceeds in the escrow.
        TransferHelper.safeTransfer(a.coin, l.escrow, IERC20(a.coin).balanceOf(address(this)));
    }

    /* ------------------------------ trading config ----------------------------- */

    /// @notice Who is asking to change a launched coin's trading config.
    struct ConfigCaller {
        /// 2 = DEFAULT_ADMIN_ROLE, 1 = PAIR_CONFIG_ROLE, 0 = neither.
        uint8 role;
        address caller;
        address creator;
        bool creatorLocked;
        address coin;
        uint32 maxLaunchFee;
    }

    /**
     * @notice `AssetGenerator.setPairTradingConfig`'s checks, moved here unchanged so the
     * generator stays under EIP-170. Same errors, same order, same arguments: their
     * selectors are identical to the generator's own declarations.
     */
    function checkTradingConfig(
        PairBounds memory b,
        ConfigCaller memory c,
        uint16 slippageLimitBps,
        uint32 makerFee,
        uint32 takerFee
    ) public pure {
        if (slippageLimitBps < b.minSlippageBps || slippageLimitBps > b.maxSlippageBps) {
            revert InvalidVolatility(slippageLimitBps);
        }
        if (c.role > 0) {
            if (
                c.role == 1
                    && (makerFee < b.minFee || takerFee < b.minFee || makerFee > b.maxFee || takerFee > b.maxFee)
            ) {
                revert InvalidFee(makerFee < b.minFee || makerFee > b.maxFee ? makerFee : takerFee);
            }
            if (makerFee > c.maxLaunchFee || takerFee > c.maxLaunchFee) {
                revert InvalidFee(makerFee > takerFee ? makerFee : takerFee);
            }
        } else {
            if (c.caller != c.creator) revert NotTheCreator(c.caller);
            if (c.creatorLocked) revert CreatorFeeControlLocked(c.coin);
            uint32 cap = b.creatorCap;
            if (makerFee != 0 && (makerFee < b.minFee || makerFee > cap)) revert FeeAboveCreatorCap(makerFee, cap);
            if (takerFee < b.minFee || takerFee > cap) revert FeeAboveCreatorCap(takerFee, cap);
        }
    }

    /// @notice `AssetGenerator.setPairTakerFee`'s checks, moved here unchanged (EIP-170).
    function checkTakerFee(PairBounds memory b, ConfigCaller memory c, uint32 feeNum) public pure {
        if (c.role == 2) {
            if (feeNum > c.maxLaunchFee) revert InvalidFee(feeNum);
        } else if (c.role == 1) {
            if (feeNum < b.minFee || feeNum > b.maxFee) revert FeeOutsidePairRange(feeNum, b.minFee, b.maxFee);
        } else {
            if (c.caller != c.creator) revert NotTheCreator(c.caller);
            if (c.creatorLocked) revert CreatorFeeControlLocked(c.coin);
            if (feeNum < b.minFee || feeNum > b.maxFee) revert FeeOutsidePairRange(feeNum, b.minFee, b.maxFee);
            if (feeNum > b.creatorCap) revert FeeAboveCreatorCap(feeNum, b.creatorCap);
        }
    }

    /**
     * @notice `AssetGenerator.setExistingPairTradingConfig`'s checks after its role gate,
     * moved here unchanged (EIP-170). `listerPath` is the pair's lister acting without
     * the pair-config role, which caps them like a creator.
     */
    function checkExistingConfig(
        PairBounds memory b,
        bool listerPath,
        bool listerLocked,
        address pair,
        uint16 slippageLimitBps,
        uint32 makerFee,
        uint32 takerFee
    ) public pure {
        if (listerPath) {
            if (listerLocked) revert CreatorFeeControlLocked(pair);
            if (makerFee != 0) revert InvalidFee(makerFee);
            if (takerFee > b.creatorCap) revert FeeAboveCreatorCap(takerFee, b.creatorCap);
        }
        if (slippageLimitBps < b.minSlippageBps || slippageLimitBps > b.maxSlippageBps) {
            revert InvalidVolatility(slippageLimitBps);
        }
        // Makers are intentionally free. `minFee` guards the taker floor; applying it to
        // makers would make the documented 0 maker fee impossible on graduated markets.
        if (makerFee != 0 && (makerFee < b.minFee || makerFee > b.maxFee)) {
            revert FeeOutsidePairRange(makerFee, b.minFee, b.maxFee);
        }
        if (takerFee < b.minFee || takerFee > b.maxFee) revert FeeOutsidePairRange(takerFee, b.minFee, b.maxFee);
    }

    /// @notice `AssetGenerator.enabledQuoteTokens`, moved here unchanged (EIP-170).
    function enabledQuotes(
        address[] storage tokens,
        mapping(address => AssetGenerator.QuoteOption) storage options
    ) public view returns (address[] memory enabled) {
        uint256 total = tokens.length;
        // Explicitly zeroed rather than leaning on the default: slither flags the
        // implicit form, and the triage is cheaper than the annotation.
        uint256 count = 0;
        for (uint256 i; i < total; ++i) {
            if (options[tokens[i]].enabled) ++count;
        }
        enabled = new address[](count);
        uint256 j = 0;
        for (uint256 i; i < total; ++i) {
            address quote = tokens[i];
            if (options[quote].enabled) {
                enabled[j] = quote;
                ++j;
            }
        }
    }

    /// @notice `AssetGenerator.setQuoteOption`'s storage writes, moved here (EIP-170).
    function writeQuoteOption(
        mapping(address => AssetGenerator.QuoteOption) storage options,
        mapping(address => bool) storage known,
        address[] storage tokens,
        address quote,
        AssetGenerator.QuoteOption memory option
    ) public {
        if (!known[quote]) {
            known[quote] = true;
            tokens.push(quote);
        }
        options[quote] = option;
    }

    /* -------------------------------- graduation ------------------------------- */

    /**
     * @notice Reverts unless every ladder ask is gone from the book. Read from ORDER
     * STATE, never from pool reserves, so a deposit cannot fake it.
     * @dev An ask counts as filled once the slot no longer holds an escrow-owned
     * deposit: fully matched, or evicted as dust (the remainder then refunded to the
     * escrow, which graduation sweeps). The escrow cannot cancel, so nothing else
     * empties it.
     */
    function requireFilled(Ladder memory l) public view {
        // Order ids start at 1, so a zero id is a deferred ladder not yet placed. Without
        // this, an empty slot reads as a filled ask and graduation would arm on nothing.
        if (l.askIds[0] == 0) revert LadderNotPlaced();
        for (uint256 i = 0; i < STEPS; i++) {
            ExchangeOrderbook.Order memory o = IOrderbook(l.pair).getOrder(false, l.askIds[i]);
            if (o.owner == l.escrow && o.depositAmount > 0) revert LadderNotFilled(i);
        }
    }

    /**
     * @notice Moves everything the escrow holds into one band position the generator
     * owns, restores the pair's spread, opens the bands, and hands band configuration to
     * the coin's creator.
     * @return manager The position manager holding the position.
     * @return tokenId The position.
     * @return raised Quote seeded: every ladder fill plus the dev buy.
     * @return coins Coins seeded: the held-back supply plus any refunded ladder dust.
     */
    function seedPool(address engine, address coin, address quote, Ladder memory l, address creator)
        public
        returns (address manager, uint256 tokenId, uint256 raised, uint256 coins)
    {
        requireFilled(l);
        raised = LaunchEscrow(l.escrow).sweep(quote, address(this));
        coins = LaunchEscrow(l.escrow).sweep(coin, address(this));

        IMatchingEngine e = IMatchingEngine(engine);
        e.setSpread(coin, quote, l.restoreBuySpread, e.getSpread(l.pair, false, false), false);

        address pool = _poolOf(engine, coin, quote);
        _setBandsOpen(pool, true);
        manager = IPoolFactory(e.poolFactory()).positionManager();

        bool coinIsBase = IBandPool(pool).base() == coin;
        IBandPositionManager.MintParams memory p = _split(
            pool, ILaunchPool(pool).bandCount(), coinIsBase ? coins : raised, coinIsBase ? raised : coins
        );
        TransferHelper.safeApprove(coin, manager, coins);
        TransferHelper.safeApprove(quote, manager, raised);
        (tokenId,) = IBandPositionManager(manager).mint(p);
        TransferHelper.safeApprove(coin, manager, 0);
        TransferHelper.safeApprove(quote, manager, 0);

        ILaunchPool(pool).transferCreator(creator);
    }

    /**
     * @notice Withdraws the part of a vesting position that has vested since the last
     * release: linear over `VEST_DURATION` from graduation, measured against the ORIGINAL
     * position. Collects the position's fees first, since a withdrawal forfeits the
     * unvested part of fees pro rata and a collect does not.
     * @return vestedBps The vested share of the original position, to record as released.
     */
    function releaseVested(
        address manager,
        uint256 tokenId,
        uint64 graduatedAt,
        uint16 releasedBps,
        address recipient
    ) public returns (uint16 vestedBps) {
        uint256 elapsed = block.timestamp - graduatedAt;
        vestedBps = elapsed >= VEST_DURATION ? uint16(BPS) : uint16((elapsed * BPS) / VEST_DURATION);
        if (vestedBps <= releasedBps) revert NothingToRelease();
        // The position now holds (BPS - releasedBps) of the original; take the vested
        // increment as a share of THAT. The last release takes everything left.
        uint256 bps = vestedBps == BPS ? BPS : ((vestedBps - releasedBps) * BPS) / (BPS - releasedBps);
        IBandPositionManager(manager).collect(tokenId, recipient);
        IBandPositionManager(manager).decreaseLiquidity(tokenId, uint16(bps), 0, 0, recipient, block.timestamp);
    }

    /// @notice Validates and lists `listPair`'s market. The generator records the policy.
    function listPair(
        address engine,
        address base,
        address quote,
        uint256 price,
        uint16 slippageLimitBps,
        uint32 takerFee,
        PairBounds memory b
    ) public returns (address pair) {
        IMatchingEngine e = IMatchingEngine(engine);
        if (e.getPair(base, quote) != address(0) || e.getPair(quote, base) != address(0)) {
            revert PairAlreadyListed(base, quote);
        }
        if (price < MIN_LISTING_PRICE) revert ListingPriceTooLow(price);
        if (slippageLimitBps < b.minSlippageBps || slippageLimitBps > b.maxSlippageBps) {
            revert InvalidVolatility(slippageLimitBps);
        }
        if (takerFee < b.minFee || takerFee > b.maxFee) revert FeeOutsidePairRange(takerFee, b.minFee, b.maxFee);
        if (takerFee > b.creatorCap) revert FeeAboveCreatorCap(takerFee, b.creatorCap);
        pair = e.addPair(base, quote, price, block.timestamp, base, ExchangeOrderbook.MatchingMode.PriceTimePriority);
    }

    /// @notice Forwards a lister's band configuration to its pair's pool. Only the three
    /// configuration calls pass; `transferCreator` in particular never does.
    function bandCall(address engine, address base, address quote, bytes calldata data) public {
        bytes4 sel = bytes4(data);
        if (
            sel != PoolBands.configureBands.selector && sel != PoolBands.setBandFeeMultiplier.selector
                && sel != PoolBands.setBandOpen.selector
        ) revert BandCallNotAllowed(sel);
        (bool ok, bytes memory ret) = _poolOf(engine, base, quote).call(data);
        if (!ok) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }

    /* --------------------------------- helpers --------------------------------- */

    function _poolOf(address engine, address coin, address quote) private view returns (address pool) {
        address factory = IMatchingEngine(engine).poolFactory();
        if (factory != address(0)) {
            pool = IPoolFactory(factory).getPool(coin, quote);
            if (pool == address(0)) pool = IPoolFactory(factory).getPool(quote, coin);
        }
        if (pool == address(0)) revert NoBandPool(coin, quote);
    }

    /// Before graduation every band is closed: no third party can deposit, so the pool
    /// cannot undercut the ladder and its reserves can never be mistaken for demand.
    function _setBandsOpen(address pool, bool open) private {
        uint256 n = ILaunchPool(pool).bandCount();
        for (uint256 i = 0; i < n; i++) {
            ILaunchPool(pool).setBandOpen(uint8(i), open);
        }
    }

    function _split(address pool, uint256 n, uint256 baseTotal, uint256 quoteTotal)
        private
        view
        returns (IBandPositionManager.MintParams memory p)
    {
        p.pool = pool;
        p.bands = new uint8[](n);
        p.baseAmounts = new uint256[](n);
        p.quoteAmounts = new uint256[](n);
        p.minShares = new uint128[](n);
        p.recipient = address(this);
        p.deadline = block.timestamp;
        for (uint256 i = 0; i < n; i++) {
            p.bands[i] = uint8(i);
            // The last band takes the rounding remainder, so nothing is left behind.
            p.baseAmounts[i] = i + 1 == n ? baseTotal - (baseTotal / n) * (n - 1) : baseTotal / n;
            p.quoteAmounts[i] = i + 1 == n ? quoteTotal - (quoteTotal / n) * (n - 1) : quoteTotal / n;
        }
    }
}
