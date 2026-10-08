// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {IMatchingEngine} from "../exchange/interfaces/IMatchingEngine.sol";
import {IOrderbook} from "../exchange/interfaces/IOrderbook.sol";
import {Oracle} from "../exchange/libraries/Oracle.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {PoolFeeMath} from "./libraries/PoolFeeMath.sol";
import {PoolPositions} from "./PoolPositions.sol";
import {TransferHelper} from "./libraries/TransferHelper.sol";
import {IBandPool} from "./interfaces/IBandPool.sol";

/**
 * The aggregated pool: liquidity as a per-band scalar, fees as a per-band accumulator,
 * and LP positions keyed by the position manager's token id -- one token holding any
 * subset of the ladder.
 *
 * ## `swap` reads and writes NO position
 *
 * Crediting a band is one write to its accumulator for any number of LPs inside it, so
 * swap gas is flat in LP count. GasBandScaling pins that.
 *
 * ## Bands are fractions of the pair's limit, and the limit is pushed on change
 *
 * `tolerance = spreadFrac × pairLimit(side) ÷ DENOM`, where the limit is the one the
 * engine applies to a market order on this pair: the creator's slippage cap if the pair
 * has one, capped by the engine's market spread for that side. `syncLimit` reads that
 * and stores the two limits, packed beside `engine` -- ONE slot, whatever the ladder's
 * length. The engine calls it from `_setSpread` and the generator from its pair-config
 * setters, in the same transaction as the change. A swap reads the limit once and
 * multiplies it by each band's fraction, which sits in the slot the walk loads anyway,
 * so pricing adds arithmetic and no storage read. Because `spreadFrac <= DENOM`, no
 * band can quote past the rail.
 *
 * Every rounding step goes the safe way: the tolerance rounds DOWN (inside the limit), a
 * buy bound rounds UP but never past the rail's own ceiling, a sell bound rounds DOWN, a
 * forfeit rounds UP, a payout rounds DOWN. A band whose tolerance rounds to zero, or
 * reaches 100% on the sell side, is idle for that fill rather than priced at the anchor
 * or at zero.
 */
contract BandPool is IBandPool, PoolPositions {
    using SafeCast for uint256;

    uint32 private constant TWAP_WINDOW = 300;
    uint16 private constant BPS = 10_000;
    /**
     * A fill must consume at least 1/1,000,000 of a band's payable side before it may
     * move `lmp`. It gates the REPORT, never the price: a dust swap still executes at the
     * band's bound, it just does not get to print.
     */
    uint256 private constant MIN_REPORT_DIVISOR = 1_000_000;
    /**
     * Gas held back so a halted band walk can still settle what it filled: one more band
     * plus the cold settlement tail, measured in v1 at ~45k + ~135k. Reserving too much
     * only ends the walk a band early; too little is the opaque out-of-gas revert this
     * exists to remove.
     */
    uint256 internal constant SWAP_GAS_RESERVE = 180_000;

    uint256 public id;
    /// The listing price, captured at creation: the anchor until the TWAP can answer.
    uint256 public seedPrice;
    /// Accrued, swept on demand. A token that refuses feeTo then fails only the sweep.
    uint256 public protocolFeesBase;
    uint256 public protocolFeesQuote;
    address public base;
    address public quote;
    address public orderbook;
    address public engine;
    /**
     * The pair limits last synced, per side, packed beside `engine` -- a slot every swap
     * already reads through `onlyRouter`, so the rail cap on a buy bound costs nothing.
     */
    uint32 public limitBuy;
    uint32 public limitSell;
    address public positionManager;
    bool private _initialized;
    /**
     * The orderbook's own decimal conversion, cached here at initialisation.
     *
     * `Orderbook.convert` is pure arithmetic over these two values, but they are
     * `private` there with no getter, so every band in a walk used to pay for TWO
     * external calls to do multiplication the pool already has the inputs for. They are
     * derived the same way the orderbook derives them, and `initialize` then asserts
     * both directions agree with the orderbook before the pool is usable -- a pool that
     * converts differently from the venue it settles against would mis-size every fill,
     * so this is checked once rather than trusted.
     */
    uint64 private decDiff;
    bool private baseBquote;

    error AlreadyInitialized();
    /// The cached decimal conversion disagrees with the orderbook's. Never expected; fatal if it happens.
    error ConvertMismatch(uint256 mine, uint256 theirs);
    error OnlyPositionManager(address caller, address expected);
    error NoLiquidity();
    error NotRouter(address caller, address router);
    error NoAnchorPrice();
    error SlippageExceeded(uint256 minAmountOut, uint256 amountOut);
    error SameBand(uint8 band);
    error BadBps(uint16 bps);
    error LengthMismatch();

    /// The pair's limit was re-read and stored; every band's tolerance follows from it.
    event PairLimitSynced(uint32 limitBuy, uint32 limitSell);

    /// The band walk stopped early to keep gas for settlement. The taker pays only for what filled.
    event SwapHaltedForGas(address indexed taker, uint256 remainingIn, uint256 bandsFilled);
    event ProtocolFeesSwept(address indexed feeTo, uint256 base, uint256 quote);

    /// The engine's router, or the engine itself (its fallback routes an order's remainder here).
    modifier onlyRouter() {
        address router = IMatchingEngine(engine).swapRouter();
        if (msg.sender != router && msg.sender != engine) revert NotRouter(msg.sender, router);
        _;
    }

    modifier onlyPositionManager() {
        if (msg.sender != positionManager) revert OnlyPositionManager(msg.sender, positionManager);
        _;
    }

    /// The two rates a swap reads once and every band then uses. One stack slot as a
    /// memory pointer; two separate uint256 params put `_walk` over solc's stack limit.
    struct FeeRates {
        uint256 engine;
        uint256 poolShare;
    }

    /// What one band gave up. Returned as a struct for the same stack reason as FeeRates:
    /// three named returns destructured in `_walk` put it over solc's limit.
    struct Fill {
        uint256 take;
        uint256 netOut;
        uint256 reportable;
    }

    struct InitParams {
        uint256 id;
        address base;
        address quote;
        address orderbook;
        address engine;
        address positionManager;
        address creator;
        uint64 maturity;
        uint32[] spreadFracs;
        uint32[] feeMultipliers;
    }

    function initialize(InitParams calldata p) external {
        if (_initialized) revert AlreadyInitialized();
        _initialized = true;
        id = p.id;
        base = p.base;
        quote = p.quote;
        orderbook = p.orderbook;
        engine = p.engine;
        positionManager = p.positionManager;
        seedPrice = IOrderbook(p.orderbook).lmp();

        /*
         * Recover the orderbook's own conversion by ASKING IT, rather than re-deriving it
         * from the tokens' decimals. Both would normally agree, but "normally" is not a
         * guarantee worth taking on a number that sizes every fill -- and re-deriving it
         * would also make the pool refuse any token whose `decimals()` reverts, which the
         * orderbook itself tolerates.
         *
         * At price 1e8 the bid direction reduces to `1e18 / decDiff` when the base has
         * more decimals and `1e18 * decDiff` when it has fewer, so one call names both
         * values exactly. They are powers of ten, so the divisions are exact.
         */
        uint256 probe = IOrderbook(p.orderbook).convert(1e8, 1e18, true);
        if (probe == 0) revert ConvertMismatch(0, 0);
        baseBquote = probe < 1e18;
        decDiff = uint64(baseBquote ? 1e18 / probe : probe / 1e18);

        // Both directions at the price scale's unit, which is the cheap check that the
        // recovered pair is self-consistent. The FULL equivalence -- that `_convert` and
        // `Orderbook.convert` agree across prices and amounts -- is pinned by
        // `test/swap/ConvertEquivalence.t.sol` against the real orderbook, because
        // proving it here would cost every pool deployment gas to re-derive a property
        // of the source that a fuzz test establishes once.
        _assertConvertAgrees(1e8, 1e18, true);
        _assertConvertAgrees(1e8, 1e18, false);

        _initBands(p.creator, p.maturity, p.spreadFracs, p.feeMultipliers);
    }

    function _assertConvertAgrees(uint256 price, uint256 amount, bool isBid) private view {
        uint256 mine = _convert(price, amount, isBid);
        uint256 theirs = IOrderbook(orderbook).convert(price, amount, isBid);
        if (mine != theirs) revert ConvertMismatch(mine, theirs);
    }

    /**
     * `Orderbook.convert`, inlined. Identical arithmetic in the same order, so the
     * rounding matches the venue step for step -- a reimplementation that floored
     * somewhere else would hand the taker or the LPs the difference.
     */
    function _convert(uint256 price, uint256 amount, bool isBid) private view returns (uint256) {
        if (isBid) {
            return baseBquote ? ((amount * price) / 1e8) / decDiff : ((amount * price) / 1e8) * decDiff;
        }
        return baseBquote ? ((amount * 1e8) / price) * decDiff : ((amount * 1e8) / price) / decDiff;
    }

    // ---------------------------------------------------------------- liquidity in

    /// @inheritdoc IBandPool
    function increase(
        uint256 tokenId,
        uint8[] calldata bandIds,
        uint256[] calldata baseAmounts,
        uint256[] calldata quoteAmounts
    ) external onlyPositionManager returns (uint128[] memory shares, uint256 baseUsed, uint256 quoteUsed) {
        uint256 n = bandIds.length;
        if (n == 0 || baseAmounts.length != n || quoteAmounts.length != n) revert LengthMismatch();
        shares = new uint128[](n);
        // Totals live in memory: three calldata arrays plus running sums exceed the stack
        // the legacy pipeline allows, and this repo does not deploy with via-ir.
        Deposit memory d = Deposit({mask: _mask[tokenId], baseUsed: 0, quoteUsed: 0});
        for (uint256 i = 0; i < n; i++) {
            if (i > 0 && bandIds[i] <= bandIds[i - 1]) revert BandsNotAscending();
            shares[i] = _depositInto(tokenId, bandIds[i], baseAmounts[i], quoteAmounts[i], d);
        }
        _mask[tokenId] = d.mask;
        baseUsed = d.baseUsed;
        quoteUsed = d.quoteUsed;
        if (baseUsed > 0) TransferHelper.safeTransferFrom(base, msg.sender, address(this), baseUsed);
        if (quoteUsed > 0) TransferHelper.safeTransferFrom(quote, msg.sender, address(this), quoteUsed);
        emit IncreaseLiquidity(tokenId, bandIds, shares, baseUsed, quoteUsed);
    }

    struct Deposit {
        uint8 mask;
        uint256 baseUsed;
        uint256 quoteUsed;
    }

    function _depositInto(uint256 tokenId, uint8 band, uint256 baseAmount, uint256 quoteAmount, Deposit memory d)
        private
        returns (uint128)
    {
        (uint256 minted, uint256 bu, uint256 qu) = _deposit(tokenId, band, baseAmount, quoteAmount);
        d.baseUsed += bu;
        d.quoteUsed += qu;
        d.mask |= _bit(band);
        return minted.toUint128();
    }

    /**
     * One band's share of a deposit. Accrual runs BEFORE the shares change and the
     * already-vested fees are locked in before the clock is blended, so neither the old
     * capital's earnings nor its vesting progress is re-measured against the new shares.
     */
    function _deposit(uint256 tokenId, uint8 band, uint256 baseAmount, uint256 quoteAmount)
        private
        returns (uint256 minted, uint256 baseUsed, uint256 quoteUsed)
    {
        if (band >= _bands.length) revert BadBand(band);
        Band storage b = _bands[band];
        if (!b.open) revert BandClosed(band);
        (minted, baseUsed, quoteUsed) = _price(b, baseAmount, quoteAmount);
        if (minted == 0) revert ZeroLiquidity();

        _accrue(tokenId, band);
        _lockVested(tokenId, band);
        Slot storage s = _slot[tokenId][band];
        s.createdAt = _blendCreatedAt(s.createdAt, s.shares, block.timestamp, minted);
        s.shares = (uint256(s.shares) + minted).toUint128();

        b.shares += minted;
        b.baseReserve += baseUsed;
        b.quoteReserve += quoteUsed;
    }

    /**
     * Shares a deposit buys and the amounts it actually uses.
     *
     * An empty band prices the first deposit at 1 share per unit of WHICHEVER token
     * opened it. A band holding both sides mints the LESSER of the two ratios (the V2
     * rule), and the amounts are recomputed from the shares minted, rounded UP, so a
     * lopsided deposit never donates its excess to the LPs already there -- the caller
     * keeps it.
     *
     * ## Why the empty band takes either token, and a funded one does not
     *
     * This branch used to read `return (baseAmount, baseAmount, quoteAmount)`, so a
     * first deposit of QUOTE ALONE minted nothing and reverted `ZeroLiquidity()`. That
     * was the only thing standing between this pool and one-sided liquidity: a band
     * whose reserve is one-sided ALREADY trades as a one-sided wall, because
     * `_fillBand` returns early for a band with nothing to pay out. So a base-only band
     * sells base and refuses to buy it, and the mint path was simply unable to create
     * the quote-side mirror of a shape the swap path already understood.
     *
     * The asymmetry that remains is deliberate and is the safety property here. Into a
     * band that already holds BOTH tokens, one side alone still mints nothing, because
     * shares are a pro-rata claim on both reserves -- minting from one token would hand
     * the depositor a slice of a reserve they never funded, taken from the LPs already
     * in the band. `min(byBase, byQuote)` is what prevents that and it is left alone.
     * Adding the token a one-sided band does NOT hold is refused for the same reason.
     *
     * The scale of a band's shares therefore depends on which token opened it -- 1e6
     * shares for a band opened with a 6-decimal quote, 1e18 for an 18-decimal base.
     * That is already true across bands and nothing compares them: shares are stored
     * per `(tokenId, band)` and every rate that reads them (`growthDelta`,
     * `rawEntitlement`) is Q128-scaled and divides by the same band's own total.
     */
    function _price(Band storage b, uint256 baseAmount, uint256 quoteAmount)
        private
        view
        returns (uint256 minted, uint256 baseUsed, uint256 quoteUsed)
    {
        if (b.shares == 0) return (baseAmount > 0 ? baseAmount : quoteAmount, baseAmount, quoteAmount);
        uint256 byBase = b.baseReserve == 0 ? type(uint256).max : Math.mulDiv(baseAmount, b.shares, b.baseReserve);
        uint256 byQuote = b.quoteReserve == 0 ? type(uint256).max : Math.mulDiv(quoteAmount, b.shares, b.quoteReserve);
        minted = byBase < byQuote ? byBase : byQuote;
        if (minted == type(uint256).max) minted = 0;

        /*
         * ONE SIDE ONLY: PRICED BY VALUE, NOT REFUSED.
         *
         * The pro-rata rule above cannot serve a deposit of one token into a band
         * holding the other, and it is right not to try: minting `byQuote` on a
         * quote-only deposit hands the depositor a claim on base they never funded.
         * Worked, on a band of 100 base + 100 quote with 100 shares, for 1 quote in:
         * `byQuote` is 1 share, and 1 share is worth 1/101 of (100 base + 101 quote)
         * -- about 1.99 quote for 1.00 paid, the difference taken from the LPs
         * already there.
         *
         * But refusing was never the only safe answer. The FAIR number exists and is
         * 0.5 shares: the deposit's value over the band's value, times the shares
         * outstanding. `0.5 / 100.5` of `(100 base + 101 quote)` is exactly the 1.00
         * quote that went in. Nobody is diluted, nothing is refunded, and the whole
         * deposit becomes reserve.
         *
         * So this branch runs ONLY where the pro-rata rule mints nothing and only one
         * side was brought. A two-sided deposit keeps the V2 rule exactly, including
         * its refund of the excess leg -- that path is unchanged and does not read a
         * price.
         *
         * ## What it costs, stated plainly
         *
         * This is the first time minting reads the anchor. Before it, a wrong price
         * could not mis-price a deposit, because minting looked at nothing but the
         * band's own reserves. Now depositing while the anchor lags the market and
         * withdrawing once it catches up is a trade. What bounds it: the anchor is a
         * 300-second TWAP (`_anchor`), every pool print is clamped to the pair's rail
         * before it can reach that TWAP, and the vesting clock already denies a fresh
         * slot its fees. Those are defences, not a proof, and `BandOneSidedValue.t.sol`
         * is where the timing case is measured rather than asserted.
         */
        if (minted == 0 && ((baseAmount == 0) != (quoteAmount == 0))) {
            uint256 price = _anchor();
            uint256 bandValue = _valueInQuote(b.baseReserve, b.quoteReserve, price);
            if (bandValue > 0) {
                // Rounds DOWN, so the depositor can never round INTO value that is
                // not theirs -- the direction every other rounding here takes.
                minted = Math.mulDiv(b.shares, _valueInQuote(baseAmount, quoteAmount, price), bandValue);
                return (minted, baseAmount, quoteAmount);
            }
        }

        if (minted == 0) return (0, 0, 0);
        baseUsed = Math.mulDiv(b.baseReserve, minted, b.shares, Math.Rounding.Ceil);
        quoteUsed = Math.mulDiv(b.quoteReserve, minted, b.shares, Math.Rounding.Ceil);
    }

    // --------------------------------------------------------------- liquidity out

    struct Removal {
        uint256 baseOut;
        uint256 quoteOut;
        uint256 forfeitBase;
        uint256 forfeitQuote;
        bool toProtocol;
    }

    /// @inheritdoc IBandPool
    function decrease(uint256 tokenId, uint16 bps, address recipient)
        external
        onlyPositionManager
        returns (uint256 baseOut, uint256 quoteOut)
    {
        if (bps == 0 || bps > BPS) revert BadBps(bps);
        uint8 mask = _mask[tokenId];
        uint256 count = _popcount(mask);
        uint8[] memory bandIds = new uint8[](count);
        uint128[] memory removed = new uint128[](count);
        Removal memory total;
        uint256 k;
        for (uint8 band = 0; band < _bands.length; band++) {
            if (mask & _bit(band) == 0) continue;
            uint256 sharesOut = Math.mulDiv(_slot[tokenId][band].shares, bps, BPS);
            Removal memory r = _remove(tokenId, band, sharesOut);
            bandIds[k] = band;
            removed[k] = sharesOut.toUint128();
            k++;
            _addRemoval(total, r);
        }
        _settleRemoval(tokenId, recipient, bandIds, removed, total);
        return (total.baseOut, total.quoteOut);
    }

    /// @inheritdoc IBandPool
    function decreaseBand(uint256 tokenId, uint8 band, uint128 shares, address recipient)
        external
        onlyPositionManager
        returns (uint256 baseOut, uint256 quoteOut)
    {
        if (band >= _bands.length) revert BadBand(band);
        uint128 held = _slot[tokenId][band].shares;
        uint128 sharesOut = shares > held ? held : shares;
        Removal memory r = _remove(tokenId, band, sharesOut);
        uint8[] memory bandIds = new uint8[](1);
        uint128[] memory removed = new uint128[](1);
        bandIds[0] = band;
        removed[0] = sharesOut;
        _settleRemoval(tokenId, recipient, bandIds, removed, r);
        return (r.baseOut, r.quoteOut);
    }

    /**
     * Take `sharesOut` out of one band. The unvested fee attached to those shares
     * forfeits -- `unvested × sharesOut ÷ shares`, rounded UP so a small or oddly-sized
     * removal can never under-forfeit -- and goes to the band's OTHER shares. Its
     * checkpoint moves only after that disbursement, so this slot cannot earn from its
     * own forfeit.
     */
    function _remove(uint256 tokenId, uint8 band, uint256 sharesOut) private returns (Removal memory r) {
        _accrue(tokenId, band);
        _lockVested(tokenId, band);
        if (sharesOut == 0) return r;

        Band storage b = _bands[band];
        Slot storage s = _slot[tokenId][band];
        Amounts storage p = _pending[tokenId][band];
        r.forfeitBase = _mulDivUp(p.base, sharesOut, s.shares);
        r.forfeitQuote = _mulDivUp(p.quote, sharesOut, s.shares);
        p.base -= r.forfeitBase.toUint128();
        p.quote -= r.forfeitQuote.toUint128();

        // The released record leaves with its shares, as pending does.
        _scaleReleased(tokenId, band, s.shares - sharesOut, s.shares);

        r.baseOut = Math.mulDiv(b.baseReserve, sharesOut, b.shares);
        r.quoteOut = Math.mulDiv(b.quoteReserve, sharesOut, b.shares);
        b.baseReserve -= r.baseOut;
        b.quoteReserve -= r.quoteOut;
        b.shares -= sharesOut;
        s.shares -= sharesOut.toUint128();

        r.toProtocol = _disburseForfeit(b, b.shares - s.shares, r.forfeitBase, r.forfeitQuote);
        _syncCheckpoint(tokenId, band);
        if (s.shares == 0) _mask[tokenId] &= ~_bit(band);
    }

    function _addRemoval(Removal memory total, Removal memory r) private pure {
        total.baseOut += r.baseOut;
        total.quoteOut += r.quoteOut;
        total.forfeitBase += r.forfeitBase;
        total.forfeitQuote += r.forfeitQuote;
        total.toProtocol = total.toProtocol || r.toProtocol;
    }

    /// Principal and every vested fee, to the recipient, in one transfer per currency each.
    function _settleRemoval(
        uint256 tokenId,
        address recipient,
        uint8[] memory bandIds,
        uint128[] memory removed,
        Removal memory r
    ) private {
        // Only when shares actually left: a repeat exit on an emptied token is a no-op and
        // must not read downstream as a second withdrawal. Owed fees still pay (and emit
        // `Collect`) below.
        bool any;
        for (uint256 i = 0; i < removed.length; i++) {
            if (removed[i] > 0) any = true;
        }
        if (any) {
            emit DecreaseLiquidity(
                tokenId, bandIds, removed, r.baseOut, r.quoteOut, r.forfeitBase, r.forfeitQuote, r.toProtocol
            );
        }
        if (r.baseOut > 0) TransferHelper.safeTransfer(base, recipient, r.baseOut);
        if (r.quoteOut > 0) TransferHelper.safeTransfer(quote, recipient, r.quoteOut);
        _payOwed(tokenId, recipient);
    }

    // --------------------------------------------------------------------- moves

    struct Move {
        uint256 baseOut;
        uint256 quoteOut;
        uint256 pendingBase;
        uint256 pendingQuote;
        uint64 age;
        uint256 releasedBase;
        uint256 releasedQuote;
        uint256 minted;
        uint256 baseUsed;
        uint256 quoteUsed;
    }

    /// @inheritdoc IBandPool
    function move(uint256 tokenId, uint8 fromBand, uint8 toBand, uint128 shares, address refundTo)
        external
        onlyPositionManager
        returns (uint128 sharesIn, uint256 baseRefund, uint256 quoteRefund)
    {
        if (fromBand == toBand) revert SameBand(toBand);
        if (fromBand >= _bands.length) revert BadBand(fromBand);
        if (toBand >= _bands.length) revert BadBand(toBand);
        if (!_bands[toBand].open) revert BandClosed(toBand);

        Move memory m = _takeForMove(tokenId, fromBand, shares);
        _accrue(tokenId, toBand);
        _lockVested(tokenId, toBand);
        (m.minted, m.baseUsed, m.quoteUsed) = _price(_bands[toBand], m.baseOut, m.quoteOut);
        if (m.minted == 0) revert ZeroLiquidity();
        baseRefund = m.baseOut - m.baseUsed;
        quoteRefund = m.quoteOut - m.quoteUsed;

        // A refund is value leaving the position, so it forfeits its share of the moved
        // unvested fees exactly as a withdrawal would. Without this, a move into a band
        // whose ratio absorbs little would be a withdrawal that skips the forfeit.
        if ((baseRefund > 0 || quoteRefund > 0) && (m.pendingBase > 0 || m.pendingQuote > 0)) {
            _forfeitRefunded(tokenId, fromBand, m, baseRefund, quoteRefund);
        }
        _syncCheckpoint(tokenId, fromBand);
        _placeMoved(tokenId, toBand, m);

        if (baseRefund > 0) TransferHelper.safeTransfer(base, refundTo, baseRefund);
        if (quoteRefund > 0) TransferHelper.safeTransfer(quote, refundTo, quoteRefund);
        sharesIn = m.minted.toUint128();
        emit MoveLiquidity(tokenId, fromBand, toBand, shares, sharesIn, baseRefund, quoteRefund);
    }

    /// Lift `shares` of capital, and the unvested fees and age attached to it, out of `band`.
    function _takeForMove(uint256 tokenId, uint8 band, uint128 shares) private returns (Move memory m) {
        _accrue(tokenId, band);
        _lockVested(tokenId, band);
        Slot storage s = _slot[tokenId][band];
        if (shares > s.shares) shares = s.shares;
        if (shares == 0) revert ZeroLiquidity();
        Band storage b = _bands[band];
        Amounts storage p = _pending[tokenId][band];

        m.baseOut = Math.mulDiv(b.baseReserve, shares, b.shares);
        m.quoteOut = Math.mulDiv(b.quoteReserve, shares, b.shares);
        m.pendingBase = Math.mulDiv(p.base, shares, s.shares);
        m.pendingQuote = Math.mulDiv(p.quote, shares, s.shares);
        m.age = s.createdAt;
        // The released record travels with the capital, so moved pending cannot vest
        // again in its new band.
        (m.releasedBase, m.releasedQuote) = _scaleReleased(tokenId, band, s.shares - shares, s.shares);

        p.base -= m.pendingBase.toUint128();
        p.quote -= m.pendingQuote.toUint128();
        b.baseReserve -= m.baseOut;
        b.quoteReserve -= m.quoteOut;
        b.shares -= shares;
        s.shares -= shares;
        if (s.shares == 0) _mask[tokenId] &= ~_bit(band);
    }

    function _forfeitRefunded(uint256 tokenId, uint8 fromBand, Move memory m, uint256 baseRefund, uint256 quoteRefund)
        private
    {
        uint256 price = _anchor();
        uint256 valueOut = _valueInQuote(m.baseOut, m.quoteOut, price);
        uint256 valueRefund = _valueInQuote(baseRefund, quoteRefund, price);
        uint256 fb = valueOut == 0 ? m.pendingBase : _mulDivUp(m.pendingBase, valueRefund, valueOut);
        uint256 fq = valueOut == 0 ? m.pendingQuote : _mulDivUp(m.pendingQuote, valueRefund, valueOut);
        if (fb > m.pendingBase) fb = m.pendingBase;
        if (fq > m.pendingQuote) fq = m.pendingQuote;
        m.pendingBase -= fb;
        m.pendingQuote -= fq;
        Band storage b = _bands[fromBand];
        _disburseForfeit(b, b.shares - _slot[tokenId][fromBand].shares, fb, fq);
    }

    /// Land moved capital in `band`: its age blends in as the SOURCE's age, not now.
    function _placeMoved(uint256 tokenId, uint8 band, Move memory m) private {
        Band storage b = _bands[band];
        Slot storage s = _slot[tokenId][band];
        s.createdAt = _blendCreatedAt(s.createdAt, s.shares, m.age, m.minted);
        s.shares = (uint256(s.shares) + m.minted).toUint128();
        Amounts storage p = _pending[tokenId][band];
        p.base = (uint256(p.base) + m.pendingBase).toUint128();
        p.quote = (uint256(p.quote) + m.pendingQuote).toUint128();
        Amounts storage rel = _released[tokenId][band];
        rel.base = (uint256(rel.base) + m.releasedBase).toUint128();
        rel.quote = (uint256(rel.quote) + m.releasedQuote).toUint128();
        b.shares += m.minted;
        b.baseReserve += m.baseUsed;
        b.quoteReserve += m.quoteUsed;
        _mask[tokenId] |= _bit(band);
    }

    // ---------------------------------------------------------------------- fees

    /// @inheritdoc IBandPool
    function collect(uint256 tokenId, address recipient)
        external
        onlyPositionManager
        returns (uint256 paidBase, uint256 paidQuote)
    {
        uint8 mask = _mask[tokenId];
        for (uint8 band = 0; band < _bands.length; band++) {
            if (mask & _bit(band) == 0) continue;
            _accrue(tokenId, band);
            _lockVested(tokenId, band);
        }
        return _payOwed(tokenId, recipient);
    }

    function _payOwed(uint256 tokenId, address recipient) private returns (uint256 paidBase, uint256 paidQuote) {
        Amounts storage o = _owed[tokenId];
        paidBase = o.base;
        paidQuote = o.quote;
        if (paidBase == 0 && paidQuote == 0) return (0, 0);
        o.base = 0;
        o.quote = 0;
        if (paidBase > 0) TransferHelper.safeTransfer(base, recipient, paidBase);
        if (paidQuote > 0) TransferHelper.safeTransfer(quote, recipient, paidQuote);
        emit Collect(tokenId, recipient, paidBase, paidQuote);
    }

    function _syncCheckpoint(uint256 tokenId, uint8 band) private {
        Band storage b = _bands[band];
        Checkpoint storage c = _ckpt[tokenId][band];
        if (c.base != b.feeGrowthBase) c.base = b.feeGrowthBase;
        if (c.quote != b.feeGrowthQuote) c.quote = b.feeGrowthQuote;
    }

    /**
     * Push a forfeit back into the band, or to the protocol when no other shares exist.
     * Returns which, because an indexer cannot tell from the amounts alone.
     */
    function _disburseForfeit(Band storage b, uint256 others, uint256 forfeitBase, uint256 forfeitQuote)
        private
        returns (bool toProtocol)
    {
        if (forfeitBase == 0 && forfeitQuote == 0) return false;
        if (others > 0) {
            if (forfeitBase > 0) b.feeGrowthBase += PoolFeeMath.growthDelta(forfeitBase, others);
            if (forfeitQuote > 0) b.feeGrowthQuote += PoolFeeMath.growthDelta(forfeitQuote, others);
            return false;
        }
        protocolFeesBase += forfeitBase;
        protocolFeesQuote += forfeitQuote;
        return true;
    }

    /// Permissionless: the destination is read from the engine, never taken from the caller.
    function sweepProtocolFees() external returns (uint256 sweptBase, uint256 sweptQuote) {
        address feeTo = IMatchingEngine(engine).feeTo();
        sweptBase = protocolFeesBase;
        sweptQuote = protocolFeesQuote;
        protocolFeesBase = 0;
        protocolFeesQuote = 0;
        if (sweptBase > 0) TransferHelper.safeTransfer(base, feeTo, sweptBase);
        if (sweptQuote > 0) TransferHelper.safeTransfer(quote, feeTo, sweptQuote);
        emit ProtocolFeesSwept(feeTo, sweptBase, sweptQuote);
    }

    // ---------------------------------------------------------------------- swap

    /// @inheritdoc IBandPool
    function swap(uint256 amountIn, bool quoteToBase, address recipient, uint256 minAmountOut)
        external
        onlyRouter
        returns (uint256 amountOut, uint256 matchedPrice)
    {
        uint256 marketPrice = _anchor();
        uint256 remainingIn;
        (amountOut, matchedPrice, remainingIn) = _walk(amountIn, quoteToBase, marketPrice);
        if (amountOut == 0) revert NoLiquidity();
        // A band's tolerance is the LP's price, not a cap on the trade, so the taker
        // states their own bound.
        if (amountOut < minAmountOut) revert SlippageExceeded(minAmountOut, amountOut);
        TransferHelper.safeTransferFrom(quoteToBase ? quote : base, msg.sender, address(this), amountIn - remainingIn);
        TransferHelper.safeTransfer(quoteToBase ? base : quote, recipient, amountOut);
        emit BandSwap(msg.sender, amountIn - remainingIn, amountOut, marketPrice);
    }

    /// Tightest band first, each at its own live bound. The limit is read once per swap.
    function _walk(uint256 amountIn, bool quoteToBase, uint256 marketPrice)
        private
        returns (uint256 amountOut, uint256 matchedPrice, uint256 remainingIn)
    {
        uint32 limit = quoteToBase ? limitBuy : limitSell;
        remainingIn = amountIn;
        if (limit == 0) return (0, 0, remainingIn); // this side is idle for every band

        /*
         * Read ONCE, not per band. Neither of these can change inside a swap: the taker
         * is the same account at every band, and the protocol's share is one storage
         * slot on the engine. They used to be two external calls per band, so a
         * three-band walk paid six times for two answers.
         */
        FeeRates memory rates = FeeRates({
            engine: IMatchingEngine(engine).feeOf(base, quote, msg.sender, false),
            poolShare: IMatchingEngine(engine).poolFeeShare()
        });

        for (uint256 t = 0; t < _bands.length && remainingIn > 0; t++) {
            // `t > 0`: halting before the first band would only swap one revert for another.
            if (t > 0 && gasleft() < SWAP_GAS_RESERVE) {
                emit SwapHaltedForGas(msg.sender, remainingIn, t);
                break;
            }
            Band storage b = _bands[t];
            uint256 bound = _bandBound(_tolerance(b.spreadFrac, limit), marketPrice, limit, quoteToBase);
            if (bound == 0) continue;
            Fill memory f = _fillBand(b, bound, remainingIn, quoteToBase, rates);
            amountOut += f.netOut;
            remainingIn -= f.take;
            if (f.reportable > 0) matchedPrice = f.reportable;
        }
    }

    /**
     * The price a band fills at, or 0 when the band is idle for this fill.
     *
     * A tolerance of zero means the synced limit is too small to express this band's
     * fraction at 8 decimals: idle, rather than a band quoting at the anchor with no
     * spread. A buy bound rounds UP, in the LPs' favour, but is capped at
     * `price × (1 + limit)` -- the ceiling the rail itself computes -- so the rounding can
     * never step past what the engine will record. A sell bound rounds DOWN, and a sell
     * tolerance of 100% or more would price at zero, so that band is idle too.
     */
    function _bandBound(uint256 tol, uint256 marketPrice, uint256 limit, bool quoteToBase)
        internal
        pure
        returns (uint256)
    {
        if (tol == 0) return 0;
        if (quoteToBase) {
            uint256 up = Math.mulDiv(marketPrice, DENOM + tol, DENOM, Math.Rounding.Ceil);
            uint256 rail = (marketPrice * (DENOM + limit)) / DENOM;
            return up < rail ? up : rail;
        }
        if (tol >= DENOM) return 0;
        return (marketPrice * (DENOM - tol)) / DENOM;
    }

    /**
     * Take one band at `bound`. One accumulator write and two reserve writes, for any
     * number of LPs inside it. Reserves are chosen by direction: a quote-to-base fill
     * pays out base and takes in quote.
     */
    function _fillBand(
        Band storage b,
        uint256 bound,
        uint256 remainingIn,
        bool quoteToBase,
        FeeRates memory rates
    ) private returns (Fill memory f) {
        uint256 payOut = quoteToBase ? b.baseReserve : b.quoteReserve;
        if (b.shares == 0 || payOut == 0) return f;

        uint256 available = _convert(bound, payOut, quoteToBase);
        if (available == 0) return f;
        f.take = remainingIn < available ? remainingIn : available;
        uint256 out = _convert(bound, f.take, !quoteToBase);
        if (out == 0) return (f = Fill(0, 0, 0));
        if (out >= payOut / MIN_REPORT_DIVISOR) f.reportable = bound;

        uint256 fee = (out * _cappedRate(rates.engine, b.feeMultiplier)) / DENOM;
        uint256 poolShare = (fee * rates.poolShare) / DENOM;
        if (poolShare > 0) {
            if (quoteToBase) b.feeGrowthBase += PoolFeeMath.growthDelta(poolShare, b.shares);
            else b.feeGrowthQuote += PoolFeeMath.growthDelta(poolShare, b.shares);
        }
        if (fee > poolShare) {
            if (quoteToBase) protocolFeesBase += fee - poolShare;
            else protocolFeesQuote += fee - poolShare;
        }
        f.netOut = out - fee;
        if (quoteToBase) {
            b.baseReserve -= out;
            b.quoteReserve += f.take;
        } else {
            b.quoteReserve -= out;
            b.baseReserve += f.take;
        }
    }

    // --------------------------------------------------------------------- views

    /// @inheritdoc IBandPool
    function pairLimit(bool isBuy) external view returns (uint32) {
        return isBuy ? limitBuy : limitSell;
    }

    /**
     * Re-read the pair's limit and store it. Every band follows, because a band holds
     * only its fraction of this number.
     *
     * Permissionless: it only copies the canonical values, so nobody can push a wrong
     * number. The engine calls it from `_setSpread` and the generator from its pair-config
     * setters, in the same transaction as the change; anyone can call it after the rare
     * change neither of them sees (an admin re-pointing the engine's `incentive`).
     */
    function syncLimit() external returns (uint32 buy, uint32 sell) {
        buy = liveLimit(true);
        sell = liveLimit(false);
        limitBuy = buy;
        limitSell = sell;
        emit PairLimitSynced(buy, sell);
    }

    /// @inheritdoc IBandPool
    function liveLimit(bool isBuy) public view returns (uint32 limit) {
        // Mirrors MatchingEngine._pairSlippageLimit, which bounds every market order on
        // this pair: the creator's cap (bps, so × 10,000 onto DENOM) capped by the
        // engine's market spread for this side. A missing or reverting policy leaves the
        // spread alone, exactly as the engine does.
        limit = IMatchingEngine(engine).getSpread(orderbook, isBuy, true);
        address policy = IMatchingEngine(engine).incentive();
        if (policy == address(0)) return limit;
        (bool ok, bytes memory data) =
            policy.staticcall(abi.encodeWithSignature("slippageLimitOf(address,address)", base, quote));
        if (!ok || data.length < 32) return limit;
        uint256 cap = abi.decode(data, (uint256)) * 10_000;
        if (cap < limit) limit = cap.toUint32();
    }

    /// @inheritdoc IBandPool
    function anchorPrice() external view returns (uint256) {
        return _anchor();
    }

    /// @inheritdoc IBandPool
    function bandMaskOf(uint256 tokenId) external view returns (uint8) {
        return _mask[tokenId];
    }

    /// @inheritdoc IBandPool
    function positionView(uint256 tokenId)
        external
        view
        returns (BandView[] memory out, uint256 owedBase, uint256 owedQuote)
    {
        uint8 mask = _mask[tokenId];
        out = new BandView[](_popcount(mask));
        uint256 k;
        for (uint8 band = 0; band < _bands.length; band++) {
            if (mask & _bit(band) == 0) continue;
            out[k++] = _bandView(tokenId, band);
        }
        owedBase = _owed[tokenId].base;
        owedQuote = _owed[tokenId].quote;
    }

    function _bandView(uint256 tokenId, uint8 band) private view returns (BandView memory v) {
        Band storage b = _bands[band];
        Slot storage s = _slot[tokenId][band];
        v.band = band;
        v.spreadFrac = b.spreadFrac;
        v.toleranceBuy = _tolerance(b.spreadFrac, limitBuy);
        v.toleranceSell = _tolerance(b.spreadFrac, limitSell);
        v.feeMultiplier = b.feeMultiplier;
        v.open = b.open;
        v.shares = s.shares;
        v.bandShares = b.shares;
        v.createdAt = s.createdAt;
        if (b.shares > 0) {
            v.baseOwned = Math.mulDiv(b.baseReserve, s.shares, b.shares);
            v.quoteOwned = Math.mulDiv(b.quoteReserve, s.shares, b.shares);
        }
        Checkpoint storage c = _ckpt[tokenId][band];
        v.pendingBase = _pending[tokenId][band].base + PoolFeeMath.rawEntitlement(s.shares, b.feeGrowthBase, c.base);
        v.pendingQuote =
            _pending[tokenId][band].quote + PoolFeeMath.rawEntitlement(s.shares, b.feeGrowthQuote, c.quote);
        v.vestedNum = _vestNum(s).toUint32();
        // The same release rule collect applies, so the preview is what collect pays.
        Amounts storage rel = _released[tokenId][band];
        v.vestedBase = _vestedPart(s, v.pendingBase, rel.base);
        v.vestedQuote = _vestedPart(s, v.pendingQuote, rel.quote);
    }

    /// Kept in this shape because the launch contracts read a pair this way.
    function getBaseQuote() external view returns (address, address) {
        return (base, quote);
    }

    // ------------------------------------------------------------------- helpers

    function _storedLimits() internal view override returns (uint32, uint32) {
        return (limitBuy, limitSell);
    }

    /**
     * The price bands hang off: the TWAP, or the listing price until there is one. Only
     * InsufficientHistory is absorbed, by selector; any other oracle failure takes the
     * swap with it rather than pricing off a stale constant.
     *
     * KNOWN RISK (accepted 2026-10-02, review finding N-1): the TWAP reads the book's
     * `lmp`, which MatchingEngine also writes when a maker order merely RESTS (bids above
     * lmp, asks below it), bounded only by the limit spread per order. Place-and-cancel
     * loops compound that for gas alone, and after 300 s every band here fills at the
     * manufactured price. Measured: 200 orders at a 3% rail moved the anchor 369x and
     * drained an honest LP's quote side; the downward version bought a coin-only pool
     * at 1/442 of its price. Only a pool whose price moves with its own reserves closes
     * this; until then it is disclosed, not defended.
     */
    function _anchor() private view returns (uint256) {
        try IOrderbook(orderbook).twap(TWAP_WINDOW) returns (uint256 price, uint32) {
            return price;
        } catch (bytes memory err) {
            if (err.length < 4 || bytes4(err) != Oracle.InsufficientHistory.selector) {
                assembly {
                    revert(add(err, 0x20), mload(err))
                }
            }
            if (seedPrice == 0) revert NoAnchorPrice();
            return seedPrice;
        }
    }

    /// `quote + base at price`, in quote units.
    function _valueInQuote(uint256 baseAmount, uint256 quoteAmount, uint256 price) private view returns (uint256) {
        if (baseAmount == 0) return quoteAmount;
        return quoteAmount + IOrderbook(orderbook).convert(price, baseAmount, true);
    }

    /// The mask bit for `band`. Exact for 0..7, and MAX_BANDS is 8.
    function _bit(uint8 band) private pure returns (uint8) {
        return uint8(2) ** band;
    }

    function _popcount(uint8 mask) private pure returns (uint256 count) {
        while (mask != 0) {
            count += mask & 1;
            mask >>= 1;
        }
    }
}
