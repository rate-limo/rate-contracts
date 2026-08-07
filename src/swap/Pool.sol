// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {IPool} from "./interfaces/IPool.sol";
import {TransferHelper} from "./libraries/TransferHelper.sol";
import {Initializable} from "../security/Initializable.sol";
import {IMatchingEngine} from "../exchange/interfaces/IMatchingEngine.sol";
import {IOrderbook} from "../exchange/interfaces/IOrderbook.sol";

contract Pool is IPool, Initializable {
    uint256 public id;
    address public base;
    address public quote;
    address public orderbook;
    address public engine;
    address public positionManager;
    uint64 public decDiff;
    bool public baseBquote;

    uint256 public nextPositionId;
    mapping(uint256 => Position) public positions;
    // I2 fix (docs/swap/2026-07-17-i2-position-lifecycle-design.md): index of live
    // position ids so the swap-time scan is O(live positions), not O(every position ever
    // created). Invariant: positions[id].active == true <=> activeIds[idxInActive[id]] == id.
    // idxInActive is only meaningful while the position is active.
    uint256[] internal activeIds;
    mapping(uint256 => uint256) internal idxInActive;
    uint32 public constant MAX_POSITIONS_PER_SWAP = 20;
    uint32 public constant DENOM = 100000000;
    uint32 public constant TWAP_WINDOW = 600; // seconds

    // Minimum share of a tier's depth a fill must consume before it may move lmp,
    // DENOM-scaled. 0.0001% -- tuned against the suite: at 0.01% legitimate trades stopped
    // reporting (a 10e18 buy against 1000e18 of depth), at 0.0001% only rounding dust is
    // excluded. It converts a gas-cost price attack into a capital-cost one; it raises the
    // floor rather than removing the vector.
    uint256 internal constant MIN_REPORT_FRACTION = 100;

    // Settlement age weighting (see _ageMultiplier): a position earns nothing
    // before MATURITY (the JIT defense as a hard time gate, replacing the old
    // pure age-waterfall), weighs 1.0x its contribution at maturity, and ramps
    // linearly to 1.5x over LOYALTY_WINDOW -- early LPs earn more per dollar,
    // bounded so the head start stays contestable by size or a tighter quote.
    uint64 public constant MATURITY = 10 minutes;
    uint64 public constant LOYALTY_WINDOW = 30 days;
    uint32 public constant LOYALTY_BONUS = 50000000; // DENOM-scaled (+50%)

    // See `swap`'s own comment: exists purely to keep `swap`'s stack frame within EVM
    // limits by bundling its intermediate locals into one memory value.
    struct SwapContext {
        address inputToken;
        address outputToken;
        // Assembled positions in ascending (slippageLimit, positionId) order -- the
        // paper's ascending-s-then-earliest-position discipline. Positions with equal
        // slippageLimit form one "tier"; tiers are contiguous runs in these arrays.
        uint256[] positionIds;
        uint256[] contributions;
        uint32[] slippages;
        uint256 marketPrice; // TWAP reference this swap prices against
        uint256 totalAvailable;
        // Per-position amounts this swap actually consumed, aligned to positionIds.
        // Filled tier-by-tier during settlement; the taker-fee pool share is split by
        // these (what each position really supplied), not by assembled contributions.
        uint256[] usedAll;
        // One fill per tier: tier t spans positions [tierStart[t], tierStart[t+1]),
        // executes at tierBounds[t] = TWAP * (1 +/- s_t), and totals tierAmounts[t].
        uint256[] tierStart;
        uint256[] tierBounds;
        uint256[] tierAmounts;
    }

    // Bundles _assembleInRangePositions' scratch buffers into one memory value for the
    // same stack-depth reason as SwapContext above.
    struct AssemblyBuf {
        uint256[] idsBuf;
        uint256[] contribBuf;
        uint32[] slipBuf;
        uint256[] ids;
        bool[] used;
        uint32 count;
    }

    // Bundles the direct-fill loop's outputs into one memory value for the same
    // stack-depth reason as SwapContext above.
    struct DirectFill {
        uint256[] matched; // per-tier output-token amount consumed
        uint256[] spent; // per-tier input-token proceeds
        uint256 grossOut; // total output before the taker fee
        uint256 remainingIn; // unconsumed input after the last in-range tier
        // Bound of the last tier this swap actually took from -- the price the final
        // unit changed hands at, and so this swap's "last matched price". Tiers are
        // walked tightest-first, so it is also the WORST price touched, which is exactly
        // what MatchingLib does on the book (state.lmp = askHead per iteration). Zero
        // when nothing filled.
        uint256 lastBound;
    }

    modifier onlyPositionManager() {
        if (msg.sender != positionManager) {
            revert OnlyPositionManager(msg.sender, positionManager);
        }
        _;
    }

    // Swaps must enter through the router so that every fill reports a price (see
    // SwapRouter._reportSwap). While `swap` was open, trading the pool directly was a
    // way to move real size without moving lmp -- and it was the actors most worth
    // hearing from, arbitrageurs closing a gap, who had the most reason to use it.
    //
    // The router address is read from the engine rather than stored here: the engine
    // already holds it for its own `reportSwap` gate, so there is one source of truth
    // and no per-pool wiring step. Unset (address(0)) means no caller can pass, matching
    // PositionManager.onlyRouter's fail-closed default.
    modifier onlyRouter() {
        address router = IMatchingEngine(engine).swapRouter();
        if (msg.sender != router) {
            revert NotRouter(msg.sender, router);
        }
        _;
    }

    function initialize(
        uint256 id_,
        address base_,
        address quote_,
        address orderbook_,
        address engine_,
        address positionManager_
    ) external initializer {
        id = id_;
        base = base_;
        quote = quote_;
        orderbook = orderbook_;
        engine = engine_;
        positionManager = positionManager_;

        uint8 baseD = TransferHelper.decimals(base_);
        uint8 quoteD = TransferHelper.decimals(quote_);
        (uint8 diff, bool baseBquote_) = _absdiff(baseD, quoteD);
        decDiff = uint64(10 ** diff);
        baseBquote = baseBquote_;
    }

    function addLiquidity(
        uint256 minPrice,
        uint256 maxPrice,
        uint32 slippageLimit,
        uint256 baseAmount,
        uint256 quoteAmount,
        address payer
    ) external onlyPositionManager returns (uint256 positionId) {
        // A tolerance at or above 100% is meaningless economically and, worse, weaponizable:
        // if such a position were ever the widest tier assembled, the sell-side bound
        // TWAP * (DENOM - s) / DENOM would underflow and revert every base->quote swap in
        // its range. The eventual liquidity-scaled cap (paper §3.4) will tighten this
        // further; this guard only excludes the degenerate range.
        if (slippageLimit >= DENOM) revert InvalidSlippageLimit(slippageLimit);
        if (baseAmount > 0) {
            TransferHelper.safeTransferFrom(base, payer, address(this), baseAmount);
        }
        if (quoteAmount > 0) {
            TransferHelper.safeTransferFrom(quote, payer, address(this), quoteAmount);
        }

        positionId = ++nextPositionId;
        positions[positionId] = Position({
            minPrice: minPrice,
            maxPrice: maxPrice,
            slippageLimit: slippageLimit,
            createdAt: uint64(block.timestamp),
            baseAmount: baseAmount,
            quoteAmount: quoteAmount,
            feeOwedBase: 0,
            feeOwedQuote: 0,
            active: true
        });
        idxInActive[positionId] = activeIds.length;
        activeIds.push(positionId);

        emit LiquidityAdded(positionId, minPrice, maxPrice, slippageLimit, baseAmount, quoteAmount);
    }

    function removeLiquidity(uint256 positionId, uint256 baseAmount, uint256 quoteAmount, address recipient)
        external
        onlyPositionManager
    {
        Position storage p = positions[positionId];
        if (!p.active) revert PositionDoesNotExist(positionId);
        if (baseAmount > p.baseAmount) {
            revert InsufficientPositionBalance(positionId, baseAmount, p.baseAmount);
        }
        if (quoteAmount > p.quoteAmount) {
            revert InsufficientPositionBalance(positionId, quoteAmount, p.quoteAmount);
        }

        p.baseAmount -= baseAmount;
        p.quoteAmount -= quoteAmount;

        if (baseAmount > 0) TransferHelper.safeTransfer(base, recipient, baseAmount);
        if (quoteAmount > 0) TransferHelper.safeTransfer(quote, recipient, quoteAmount);

        emit LiquidityRemoved(positionId, baseAmount, quoteAmount);
        _deactivateIfDead(positionId);
    }

    function collect(uint256 positionId, address recipient)
        external
        onlyPositionManager
        returns (uint256 baseFee, uint256 quoteFee)
    {
        Position storage p = positions[positionId];
        if (!p.active) revert PositionDoesNotExist(positionId);

        baseFee = p.feeOwedBase;
        quoteFee = p.feeOwedQuote;
        p.feeOwedBase = 0;
        p.feeOwedQuote = 0;

        if (baseFee > 0) TransferHelper.safeTransfer(base, recipient, baseFee);
        if (quoteFee > 0) TransferHelper.safeTransfer(quote, recipient, quoteFee);

        emit FeeCollected(positionId, baseFee, quoteFee);
        _deactivateIfDead(positionId);
    }

    function creditFee(uint256[] calldata positionIds, uint256[] calldata shares, bool isBaseFee, uint256 totalFee)
        external
    {
        // Called by this same Pool contract internally from `swap` (Task 11) --
        // kept as a separate external-but-self-only-callable function so `swap`'s
        // fee-crediting logic is unit-testable in isolation from full swap execution.
        if (msg.sender != address(this)) revert OnlyPositionManager(msg.sender, address(this));
        uint256 sharesSum;
        for (uint256 i = 0; i < shares.length; i++) {
            sharesSum += shares[i];
        }
        for (uint256 i = 0; i < positionIds.length; i++) {
            uint256 owed = sharesSum == 0 ? 0 : (totalFee * shares[i]) / sharesSum;
            if (isBaseFee) {
                positions[positionIds[i]].feeOwedBase += owed;
            } else {
                positions[positionIds[i]].feeOwedQuote += owed;
            }
        }
    }

    function getPosition(uint256 positionId) external view returns (Position memory) {
        return positions[positionId];
    }

    function getBaseQuote() external view returns (address, address) {
        return (base, quote);
    }

    function swap(uint256 amountIn, bool quoteToBase, address recipient, bool restLeftoverOnFinalHop)
        external
        onlyRouter
        returns (uint256 amountOut, uint256 leftoverIn, uint256 matchedPrice)
    {
        // Locals bundled into a memory struct (rather than kept as individual stack
        // variables) purely so `swap`'s own stack frame stays within EVM limits -- this
        // file has no `viaIR` compilation available (see foundry.toml), and the number of
        // values that need to stay live across this function's full sequence of external
        // calls otherwise exceeds it. No logic change from an all-stack-locals version:
        // same values, same order, same computations, just addressed via `ctx.<field>`.
        SwapContext memory ctx;
        ctx.inputToken = quoteToBase ? quote : base;
        ctx.outputToken = quoteToBase ? base : quote;

        TransferHelper.safeTransferFrom(ctx.inputToken, msg.sender, address(this), amountIn);

        _prepareSwap(ctx, quoteToBase);

        // Direct settlement (the swapDirect design, adopted for gas): no orders are
        // placed, matched, or cancelled on the book -- the engine is consulted only for
        // the TWAP reference (via _prepareSwap), fee rates, and feeTo. Tiers fill
        // tightest-first at their own bounds by pure iteration order, which is the same
        // ascending-s discipline the old engine-routed path got from book price priority.
        // Consequences accepted with this design: a swap no longer crosses better-priced
        // third-party resting orders, and pool trades no longer write lmp/oracle
        // observations. Split across helpers purely for stack depth (this file has no
        // viaIR compilation available -- see foundry.toml).
        // matchedPrice is the price this swap actually traded at -- the bound of the last
        // tier that changed hands -- so `lmp` keeps meaning what its name says.
        (amountOut, leftoverIn, matchedPrice) =
            _executeDirect(ctx, quoteToBase, amountIn, recipient, restLeftoverOnFinalHop);

        emit Swap(recipient, quoteToBase, amountIn, amountOut, leftoverIn);
    }

    function _executeDirect(
        SwapContext memory ctx,
        bool quoteToBase,
        uint256 amountIn,
        address recipient,
        bool restLeftoverOnFinalHop
    ) internal returns (uint256 amountOut, uint256 leftoverIn, uint256 matchedPrice) {
        DirectFill memory df = _fillTiersDirect(ctx, quoteToBase, amountIn);
        matchedPrice = df.lastBound;

        ctx.usedAll = new uint256[](ctx.positionIds.length);
        _settleDirect(ctx, quoteToBase, df);

        amountOut = _payOut(ctx, quoteToBase, df.grossOut, recipient);
        leftoverIn = _disposeLeftover(ctx, quoteToBase, df.remainingIn, recipient, restLeftoverOnFinalHop);

        // I2 retirement sweep. MUST run after ALL crediting -- principal + maker rebate
        // (_settleDirect) and the taker-fee pool share (_payOut) -- for the same reason
        // documented on _deactivateIfDead: crediting a retired position strands funds
        // behind collect's PositionDoesNotExist gate.
        for (uint256 i = 0; i < ctx.positionIds.length; i++) {
            _deactivateIfDead(ctx.positionIds[i]);
        }
    }

    // Walks tiers tightest-first, taking each at ITS OWN bound until amountIn is
    // exhausted. `matched` is in output-token units (the LP-supplied side, same units as
    // tierAmounts); `spent` is the input-token proceeds that tier's positions earn.
    function _fillTiersDirect(SwapContext memory ctx, bool quoteToBase, uint256 amountIn)
        internal
        view
        returns (DirectFill memory df)
    {
        uint256 nTiers = ctx.tierBounds.length;
        df.matched = new uint256[](nTiers);
        df.spent = new uint256[](nTiers);
        df.remainingIn = amountIn;
        for (uint256 t = 0; t < nTiers; t++) {
            if (df.remainingIn == 0) break;
            // Input needed to take the whole tier at its bound. convert(_, _, isBid):
            // isBid=true converts base->quote; the input token is quote exactly when
            // quoteToBase, and tierAmounts are always the output (LP-supplied) side.
            uint256 tierIn = IOrderbook(orderbook).convert(ctx.tierBounds[t], ctx.tierAmounts[t], quoteToBase);
            if (tierIn == 0) continue;
            if (df.remainingIn >= tierIn) {
                df.matched[t] = ctx.tierAmounts[t];
                df.spent[t] = tierIn;
            } else {
                uint256 out = IOrderbook(orderbook).convert(ctx.tierBounds[t], df.remainingIn, !quoteToBase);
                // Input that buys nothing must not be consumed. `spent` used to be set to
                // the whole remainder even when convert() floored the output to zero, and
                // _settleDirect then skips the tier on matched == 0 -- so the tokens were
                // taken, credited to nobody, and left in the pool. `break` rather than
                // `continue` because tiers are walked worst-price-last: input that cannot
                // buy a single unit at this bound cannot at any wider one either. Leaving
                // it in remainingIn routes it to _disposeLeftover, which refunds it.
                if (out == 0) break;
                df.matched[t] = out;
                // Belt-and-braces rounding guard: floor division above can only round
                // DOWN, but never let a tier report more than it holds.
                if (df.matched[t] > ctx.tierAmounts[t]) df.matched[t] = ctx.tierAmounts[t];
                df.spent[t] = df.remainingIn;
            }
            df.grossOut += df.matched[t];
            df.remainingIn -= df.spent[t];
            // A fill earns the right to move the public reference only if it consumed a
            // non-trivial share of the tier. This gates the REPORT, never the price: the
            // swapper still trades at this bound either way, so `lmp` keeps meaning "a
            // price someone really paid" while rounding dust no longer sets the market.
            if (df.matched[t] * DENOM >= ctx.tierAmounts[t] * MIN_REPORT_FRACTION) {
                df.lastBound = ctx.tierBounds[t];
            }
        }
    }

    // Credits each tier's positions with its own bound-priced proceeds, IN FULL.
    //
    // There is deliberately no maker fee on this leg. A pool position cannot pass a
    // fee on the way a book maker can -- its execution price is TWAP * (1 +/- its own
    // slippageLimit), fixed before the swap arrives -- so a charge here comes straight
    // out of principal with no mechanism to recover it, and combined with the MATURITY
    // gate a small or short-lived position could net out negative. The swapper-side
    // taker fee in _payOut is the only fee this pool charges, and poolFeeShare of it is
    // what pays these positions (see _payOut).
    //
    // Conservation still holds and is tighter than before: the pool's measured
    // input-token balance delta now equals exactly what positions were credited, with
    // nothing split off to feeTo on this leg.
    function _settleDirect(SwapContext memory ctx, bool quoteToBase, DirectFill memory df) internal {
        for (uint256 t = 0; t < df.matched.length; t++) {
            if (df.matched[t] == 0) continue;
            _settleTierPositions(ctx, t, df.matched[t], df.spent[t], quoteToBase);
        }
    }

    // Charges the taker fee on the output side at the same rate the engine would have
    // (fee account = recipient, matching the old swapper-leg semantics), routes its
    // poolFeeShare to the contributing positions in proportion to what each actually
    // supplied (ctx.usedAll, filled during settlement), forwards the remainder to feeTo,
    // and pays the recipient.
    function _payOut(SwapContext memory ctx, bool quoteToBase, uint256 grossOut, address recipient)
        internal
        returns (uint256 amountOut)
    {
        uint256 takerFee = (grossOut * IMatchingEngine(engine).feeOf(base, quote, recipient, false)) / DENOM;
        uint256 poolShare = (takerFee * IMatchingEngine(engine).poolFeeShare()) / DENOM;
        if (poolShare > 0) {
            // isBaseFee: the OUTPUT token is base exactly when quoteToBase.
            this.creditFee(ctx.positionIds, ctx.usedAll, quoteToBase, poolShare);
        }
        if (takerFee - poolShare > 0) {
            TransferHelper.safeTransfer(ctx.outputToken, IMatchingEngine(engine).feeTo(), takerFee - poolShare);
        }
        amountOut = grossOut - takerFee;
        if (amountOut > 0) {
            TransferHelper.safeTransfer(ctx.outputToken, recipient, amountOut);
        }
    }

    // Disposes of unconsumed input. Default: refund to recipient (the router path's
    // contract -- it dispositions remainders itself per RemainderMode). Opt-in
    // (restLeftoverOnFinalHop = true): rest it on the book as RECIPIENT's own maker
    // order at the widest assembled tier's bound -- the worst price any pool position
    // agreed to, same price the old swapper leg used -- via the engine, which escrows
    // the tokens; the returned leftoverIn is 0 in that mode because nothing came back
    // to the recipient's wallet (documented behavior the suite asserts).
    function _disposeLeftover(
        SwapContext memory ctx,
        bool quoteToBase,
        uint256 remainingIn,
        address recipient,
        bool restLeftoverOnFinalHop
    ) internal returns (uint256 leftoverIn) {
        if (remainingIn == 0) return 0;
        if (!restLeftoverOnFinalHop) {
            TransferHelper.safeTransfer(ctx.inputToken, recipient, remainingIn);
            return remainingIn;
        }
        TransferHelper.safeApprove(ctx.inputToken, engine, remainingIn);
        uint256 bound = ctx.tierBounds[ctx.tierBounds.length - 1];
        if (quoteToBase) {
            IMatchingEngine(engine).limitBuy(base, quote, bound, remainingIn, true, MAX_POSITIONS_PER_SWAP, recipient);
        } else {
            IMatchingEngine(engine).limitSell(base, quote, bound, remainingIn, true, MAX_POSITIONS_PER_SWAP, recipient);
        }
        return 0;
    }

    // Split out from `swap` for the same stack-depth reason as `_placeTierLegs`/
    // `_settleTiers` below. MEV fix (docs/swap/design.md §4.5): every tier bound is derived
    // from a time-weighted average, not the instantaneous last-matched price -- lmp() can be
    // moved by a single trade in the same block/transaction sequence a swap lands in, and
    // bounding this trade's price *relative to* lmp() doesn't protect against that, since
    // the reference point itself is what's manipulated. Reverts (InsufficientHistory) if
    // this pool's pair was listed less than TWAP_WINDOW seconds ago -- a deliberate
    // fail-safe, not a bug.
    function _prepareSwap(SwapContext memory ctx, bool quoteToBase) internal view {
        (ctx.marketPrice,) = IOrderbook(orderbook).twap(TWAP_WINDOW);

        (ctx.positionIds, ctx.contributions, ctx.slippages, ctx.totalAvailable) =
            _assembleInRangePositions(ctx.marketPrice, quoteToBase);

        if (ctx.positionIds.length == 0) {
            revert NoLiquidityInRange(ctx.marketPrice);
        }

        _layoutTiers(ctx, quoteToBase);
    }

    // Groups the assembled positions -- already sorted ascending (slippageLimit, id) -- into
    // contiguous equal-slippage tiers and computes each tier's own execution bound
    // TWAP * (1 +/- s_tier). This is what makes a position's fill terms its OWN quoted
    // tolerance (paper §3.4) rather than the pool-wide minimum: each tier becomes a separate
    // maker order at its own price in _placeTierLegs.
    //
    // Tier sizing note (carried over from the single-leg version): do not try to precisely
    // cap a leg's size against a converted amountIn -- ExchangeOrderbook._decreaseOrder
    // auto-closes a maker order and hands the taker its ENTIRE remaining deposit whenever
    // the post-match leftover would be <= that pair's own per-match dust threshold. Every
    // leg is self-cancelled within this same transaction regardless of its size (see
    // _settleTiers below), and cancelOrder's return value -- not this initial sizing -- is
    // what actually determines each tier's matched amount either way.
    function _layoutTiers(SwapContext memory ctx, bool quoteToBase) internal pure {
        uint256 n = ctx.positionIds.length;
        uint256 nTiers = 1;
        for (uint256 i = 1; i < n; i++) {
            if (ctx.slippages[i] != ctx.slippages[i - 1]) nTiers++;
        }

        ctx.tierStart = new uint256[](nTiers + 1);
        ctx.tierBounds = new uint256[](nTiers);
        ctx.tierAmounts = new uint256[](nTiers);

        uint256 t = 0;
        for (uint256 i = 0; i < n; i++) {
            if (i > 0 && ctx.slippages[i] != ctx.slippages[i - 1]) {
                t++;
                ctx.tierStart[t] = i;
            }
            ctx.tierAmounts[t] += ctx.contributions[i];
        }
        ctx.tierStart[nTiers] = n;

        for (t = 0; t < nTiers; t++) {
            uint32 s = ctx.slippages[ctx.tierStart[t]];
            ctx.tierBounds[t] = quoteToBase
                ? (ctx.marketPrice * (uint256(DENOM) + s)) / DENOM
                : (ctx.marketPrice * (uint256(DENOM) - s)) / DENOM;
        }
    }

    // Age multiplier for settlement weights, DENOM-scaled: 0 before MATURITY
    // (a just-minted position earns nothing regardless of size -- the JIT
    // defense as a hard time gate), DENOM at maturity, ramping linearly to
    // DENOM + LOYALTY_BONUS over LOYALTY_WINDOW measured from creation.
    function _ageMultiplier(uint64 createdAt) internal view returns (uint256) {
        uint256 age = block.timestamp - createdAt;
        if (age < MATURITY) return 0;
        uint256 ramp =
            age >= LOYALTY_WINDOW ? LOYALTY_BONUS : (uint256(LOYALTY_BONUS) * age) / LOYALTY_WINDOW;
        return uint256(DENOM) + ramp;
    }

    // Allocates one tier's matched amount across its positions PRO-RATA BY
    // WEIGHT, where weight = contribution x _ageMultiplier(createdAt). Mature
    // positions therefore split flow by size (with a bounded early-LP bonus);
    // immature (pre-MATURITY) positions have zero weight and only receive what
    // overflows after every weighted member is full, in age order -- which is
    // exactly the old waterfall rule, so the paper's JIT defense (§4.6) holds:
    // a same-block mint takes nothing until everyone else is exhausted, and to
    // take flow early it must quote strictly tighter, handing the swapper a
    // better price. Principal is credited pro-rata to the amount each position
    // actually supplied. Fee income reaches these positions only through the
    // taker-fee share in _payOut -- there is no maker-fee rebate on this leg
    // because there is no maker fee (see _settleDirect).
    function _settleTierPositions(
        SwapContext memory ctx,
        uint256 t,
        uint256 matched,
        uint256 principalActual,
        bool quoteToBase
    ) internal {
        uint256 startI = ctx.tierStart[t];
        uint256 len = ctx.tierStart[t + 1] - startI;
        uint256[] memory tierIds = new uint256[](len);
        for (uint256 j = 0; j < len; j++) {
            tierIds[j] = ctx.positionIds[startI + j];
        }

        // Split out purely for stack depth (the standing pattern in this file).
        uint256[] memory used = _allocateTierFlow(ctx, startI, len, matched);

        // Record per-position consumption swap-wide: _payOut splits the taker fee's
        // poolFeeShare by these, so a position earns fee share only on what it supplied.
        for (uint256 j = 0; j < len; j++) {
            ctx.usedAll[startI + j] = used[j];
        }

        for (uint256 j = 0; j < len; j++) {
            uint256 u = used[j];
            if (u > 0) {
                uint256 credit = (principalActual * u) / matched;
                Position storage p = positions[tierIds[j]];
                if (quoteToBase) {
                    p.baseAmount -= u;
                    p.quoteAmount += credit;
                } else {
                    p.quoteAmount -= u;
                    p.baseAmount += credit;
                }
            }
        }
    }

    // Splits one tier's matched flow across members: weighted water-fill first
    // (pro-rata by contribution x age multiplier, capped at contribution, with
    // capped members' surplus re-splitting among the still-open), then a
    // residual sweep in age order -- rounding dust plus everything weighted
    // members couldn't hold, which is where immature (zero-weight) positions
    // earn, exactly on the old waterfall rule. The sweep also guarantees
    // sum(used) == matched, which the caller's inventory accounting depends on
    // (the book really consumed `matched`).
    function _allocateTierFlow(SwapContext memory ctx, uint256 startI, uint256 len, uint256 matched)
        internal
        view
        returns (uint256[] memory used)
    {
        used = new uint256[](len);
        uint256[] memory w = new uint256[](len);
        for (uint256 j = 0; j < len; j++) {
            w[j] = ctx.contributions[startI + j]
                * _ageMultiplier(positions[ctx.positionIds[startI + j]].createdAt);
        }

        uint256 remaining = matched;
        for (uint256 pass = 0; pass < len && remaining > 0; pass++) {
            uint256 wSum = 0;
            for (uint256 j = 0; j < len; j++) {
                if (w[j] > 0 && used[j] < ctx.contributions[startI + j]) wSum += w[j];
            }
            if (wSum == 0) break;
            uint256 allocated = 0;
            for (uint256 j = 0; j < len; j++) {
                if (w[j] == 0) continue;
                uint256 cap = ctx.contributions[startI + j] - used[j];
                if (cap == 0) continue;
                uint256 give = (remaining * w[j]) / wSum;
                if (give > cap) give = cap;
                used[j] += give;
                allocated += give;
            }
            if (allocated == 0) break;
            remaining -= allocated;
        }

        for (uint256 j = 0; j < len && remaining > 0; j++) {
            uint256 spare = ctx.contributions[startI + j] - used[j];
            uint256 give2 = spare < remaining ? spare : remaining;
            used[j] += give2;
            remaining -= give2;
        }
    }

    function _assembleInRangePositions(uint256 marketPrice, bool quoteToBase)
        internal
        view
        returns (
            uint256[] memory positionIds,
            uint256[] memory contributions,
            uint32[] memory slippages,
            uint256 totalAvailable
        )
    {
        AssemblyBuf memory buf;
        buf.idsBuf = new uint256[](MAX_POSITIONS_PER_SWAP);
        buf.contribBuf = new uint256[](MAX_POSITIONS_PER_SWAP);
        buf.slipBuf = new uint32[](MAX_POSITIONS_PER_SWAP);

        // I2 fix: iterate only live positions -- one up-front storage copy of the id
        // list (one SLOAD per element), then 20 selection passes over memory. Both the
        // scan and the scratch buffer are sized by the LIVE count; the old
        // `1..nextPositionId` loop and its `new bool[](nextPositionId + 1)` buffer each
        // grew forever with dead history.
        //
        // Selection is ascending (slippageLimit, positionId): tightest tolerance first,
        // ties broken by position AGE (lower id = older), regardless of the activeIds
        // permutation swap-and-pop leaves behind. The age tie-break is load-bearing for
        // the within-tier waterfall in _settleTierPositions -- it is what makes "a
        // same-tolerance JIT position takes nothing until every older position is
        // exhausted" true even among >MAX_POSITIONS_PER_SWAP in-range candidates.
        buf.ids = activeIds;
        buf.used = new bool[](buf.ids.length);

        for (uint32 pass = 0; pass < MAX_POSITIONS_PER_SWAP; pass++) {
            uint256 bestK = type(uint256).max;
            uint32 bestSlippage = type(uint32).max;

            for (uint256 k = 0; k < buf.ids.length; k++) {
                if (buf.used[k]) continue;
                Position storage p = positions[buf.ids[k]];
                if (!p.active) continue; // belt-and-braces; the activeIds invariant makes this redundant
                if (p.minPrice > marketPrice || p.maxPrice < marketPrice) continue;
                if ((quoteToBase ? p.baseAmount : p.quoteAmount) == 0) continue;
                if (
                    bestK == type(uint256).max || p.slippageLimit < bestSlippage
                        || (p.slippageLimit == bestSlippage && buf.ids[k] < buf.ids[bestK])
                ) {
                    bestSlippage = p.slippageLimit;
                    bestK = k;
                }
            }

            if (bestK == type(uint256).max) break;

            buf.used[bestK] = true;
            uint256 bestId = buf.ids[bestK];
            uint256 contribution = quoteToBase ? positions[bestId].baseAmount : positions[bestId].quoteAmount;
            buf.idsBuf[buf.count] = bestId;
            buf.contribBuf[buf.count] = contribution;
            buf.slipBuf[buf.count] = bestSlippage;
            totalAvailable += contribution;
            buf.count++;
        }

        positionIds = new uint256[](buf.count);
        contributions = new uint256[](buf.count);
        slippages = new uint32[](buf.count);
        for (uint32 i = 0; i < buf.count; i++) {
            positionIds[i] = buf.idsBuf[i];
            contributions[i] = buf.contribBuf[i];
            slippages[i] = buf.slipBuf[i];
        }
    }

    function activePositionsLength() external view returns (uint256) {
        return activeIds.length;
    }

    // Retire a position once it is economically dead: zero principal on both sides AND
    // zero fees owed. A drained position with pending fees stays active so collect keeps
    // working; it retires when collect zeroes the fees. Once retired, no code path can
    // credit an inactive position again (swap settlement only touches ids assembled from
    // the active set, and fee crediting runs before the retirement sweep in _settleLpLeg),
    // so retirement is permanent. The p.active guard makes this idempotent -- a reentrant
    // or repeated call is a no-op, never a double swap-and-pop.
    function _deactivateIfDead(uint256 positionId) internal {
        Position storage p = positions[positionId];
        if (
            p.active && p.baseAmount == 0 && p.quoteAmount == 0 && p.feeOwedBase == 0
                && p.feeOwedQuote == 0
        ) {
            p.active = false;
            uint256 idx = idxInActive[positionId];
            uint256 lastId = activeIds[activeIds.length - 1];
            // When retiring the last (or only) element, lastId == positionId and these
            // two writes are intentional self-assign no-ops -- correct because the
            // delete below runs after them. Do not "simplify" by branching on idx.
            activeIds[idx] = lastId;
            idxInActive[lastId] = idx;
            activeIds.pop();
            delete idxInActive[positionId];
            emit PositionDeactivated(positionId);
        }
    }

    function _absdiff(uint8 a, uint8 b) internal pure returns (uint8, bool) {
        return (a > b ? a - b : b - a, a > b);
    }
}
