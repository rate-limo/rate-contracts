// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {ERC1155Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC1155/ERC1155Upgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {IMatchingEngine} from "../exchange/interfaces/IMatchingEngine.sol";
import {IOrderbook} from "../exchange/interfaces/IOrderbook.sol";
import {IPoolFactory} from "./interfaces/IPoolFactory.sol";
import {IBandPool} from "./interfaces/IBandPool.sol";
import {IBandPositionManager} from "./interfaces/IBandPositionManager.sol";
import {BandPool} from "./BandPool.sol";
import {BandSwapRouter} from "./BandSwapRouter.sol";
import {TransferHelper} from "./libraries/TransferHelper.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/**
 * The ERC-1155 wrapper around `BandPool` positions: ONE token per position, holding the
 * whole band ladder.
 *
 * A deposit across three bands mints one token; a later deposit into the same position
 * tops that token up; a withdrawal takes a percentage of every band in one call; and
 * the distribution across bands can be changed in place without the capital leaving the
 * pool. Everything about a position lives in the pool keyed by this contract's token id,
 * so there is no second id and nothing to keep in step.
 */
contract BandPositionManager is
    IBandPositionManager,
    ERC1155Upgradeable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable
{
    using SafeCast for uint256;

    uint16 private constant BPS = 10_000;

    struct Position {
        address pool;
        uint64 mintedAt;
    }

    mapping(uint256 tokenId => Position) internal _positions;
    /// ERC-1155 has no per-id owner, so the owner-or-approved check needs a tracked holder.
    mapping(uint256 tokenId => address) internal _holder;
    /// The id the next mint will take. Ids start at 1.
    uint256 public nextTokenId;
    address public poolFactory;
    /// The on-chain metadata renderer, or zero for the static base URI.
    address public descriptor;

    event DescriptorSet(address indexed descriptor);

    modifier onlyOwnerOrApproved(uint256 tokenId) {
        if (!_isOwnerOrApproved(msg.sender, tokenId)) revert NotOwnerOrApproved(msg.sender, tokenId);
        _;
    }

    modifier beforeDeadline(uint256 deadline) {
        if (block.timestamp > deadline) revert DeadlinePassed(deadline, block.timestamp);
        _;
    }

    function initialize(string memory uri_) external initializer {
        __ERC1155_init(uri_);
        __Ownable_init(msg.sender);
        __ReentrancyGuard_init();
        // Ids start at 1: token 0 would read as "no position" to every consumer that
        // treats a zero id as unset (PresaleLaunch.positionTokenId, the lock records).
        nextTokenId = 1;
    }

    function setPoolFactory(address poolFactory_) external onlyOwner {
        poolFactory = poolFactory_;
    }

    /// Swappable on purpose: revising the artwork must never mean redeploying the token.
    function setDescriptor(address descriptor_) external onlyOwner {
        descriptor = descriptor_;
        emit DescriptorSet(descriptor_);
    }

    /**
     * ERC-1155 metadata. A reverting renderer falls back to the base URI -- a `uri()`
     * that reverts renders as a blank tile on every marketplace.
     */
    function uri(uint256 tokenId) public view override returns (string memory) {
        address d = descriptor;
        if (d == address(0)) return super.uri(tokenId);
        (bool ok, bytes memory data) =
            d.staticcall(abi.encodeWithSignature("tokenURI(address,uint256)", address(this), tokenId));
        if (!ok || data.length == 0) return super.uri(tokenId);
        return abi.decode(data, (string));
    }

    // ------------------------------------------------------------------ opening

    /// @inheritdoc IBandPositionManager
    function mint(MintParams calldata p)
        external
        nonReentrant
        beforeDeadline(p.deadline)
        returns (uint256 tokenId, uint128[] memory shares)
    {
        _requirePool(p.pool);
        tokenId = nextTokenId++;
        _positions[tokenId] = Position({pool: p.pool, mintedAt: block.timestamp.toUint64()});
        shares = _increase(p.pool, tokenId, p.bands, p.baseAmounts, p.quoteAmounts, p.minShares);
        _mint(p.recipient, tokenId, 1, "");
    }

    /// @inheritdoc IBandPositionManager
    function mintSingleSided(
        address pool,
        uint8[] calldata bands,
        uint256[] calldata amountsIn,
        bool inputIsBase,
        uint128[] calldata minShares,
        address recipient,
        uint256 deadline
    ) external nonReentrant beforeDeadline(deadline) returns (uint256 tokenId, uint128[] memory shares) {
        _requirePool(pool);
        tokenId = nextTokenId++;
        _positions[tokenId] = Position({pool: pool, mintedAt: block.timestamp.toUint64()});
        shares = _increaseSingleSided(pool, tokenId, bands, amountsIn, inputIsBase, minShares);
        _mint(recipient, tokenId, 1, "");
    }

    /// @inheritdoc IBandPositionManager
    function increaseLiquidity(
        uint256 tokenId,
        uint8[] calldata bands,
        uint256[] calldata baseAmounts,
        uint256[] calldata quoteAmounts,
        uint128[] calldata minShares,
        uint256 deadline
    ) external nonReentrant beforeDeadline(deadline) onlyOwnerOrApproved(tokenId) returns (uint128[] memory shares) {
        shares = _increase(_positions[tokenId].pool, tokenId, bands, baseAmounts, quoteAmounts, minShares);
    }

    /**
     * Pull the offered totals once, let the pool price every band, refund what the
     * bands' ratios did not use. The pool pulls from here, so the approval is exactly the
     * offer and is cleared afterwards.
     */
    function _increase(
        address pool,
        uint256 tokenId,
        uint8[] calldata bands,
        uint256[] calldata baseAmounts,
        uint256[] calldata quoteAmounts,
        uint128[] calldata minShares
    ) private returns (uint128[] memory shares) {
        uint256 n = bands.length;
        if (n == 0 || baseAmounts.length != n || quoteAmounts.length != n || minShares.length != n) {
            revert LengthMismatch();
        }
        // The offer and what the pool used of it live in memory: four calldata arrays
        // already take eight stack slots, and this repo does not deploy with via-ir.
        Offer memory o = _pullOffer(pool, baseAmounts, quoteAmounts);
        shares = _callIncrease(pool, tokenId, bands, baseAmounts, quoteAmounts, o);
        for (uint256 i = 0; i < n; i++) {
            if (shares[i] < minShares[i]) revert SharesBelowMinimum(bands[i], shares[i], minShares[i]);
        }
        _settleApproval(o.baseTok, pool, o.baseTotal, o.baseUsed);
        _settleApproval(o.quoteTok, pool, o.quoteTotal, o.quoteUsed);
    }

    struct Offer {
        address baseTok;
        address quoteTok;
        uint256 baseTotal;
        uint256 quoteTotal;
        uint256 baseUsed;
        uint256 quoteUsed;
    }

    function _pullOffer(address pool, uint256[] calldata baseAmounts, uint256[] calldata quoteAmounts)
        private
        returns (Offer memory o)
    {
        (o.baseTotal, o.quoteTotal) = _sum(baseAmounts, quoteAmounts);
        o.baseTok = IBandPool(pool).base();
        o.quoteTok = IBandPool(pool).quote();
        _pullAndApprove(o.baseTok, pool, o.baseTotal);
        _pullAndApprove(o.quoteTok, pool, o.quoteTotal);
    }

    function _callIncrease(
        address pool,
        uint256 tokenId,
        uint8[] calldata bands,
        uint256[] calldata baseAmounts,
        uint256[] calldata quoteAmounts,
        Offer memory o
    ) private returns (uint128[] memory shares) {
        (shares, o.baseUsed, o.quoteUsed) = IBandPool(pool).increase(tokenId, bands, baseAmounts, quoteAmounts);
    }

    /**
     * One token to many bands. Each band's slice is converted against THAT band before
     * it is deposited: one conversion of the total would land at one ratio, and every
     * band holding a different one would mint on its lesser side. So the loop converts
     * and deposits band by band, and `minShares` stays per band -- it is the only guard
     * on each conversion.
     */
    function _increaseSingleSided(
        address pool,
        uint256 tokenId,
        uint8[] calldata bands,
        uint256[] calldata amountsIn,
        bool inputIsBase,
        uint128[] calldata minShares
    ) private returns (uint128[] memory shares) {
        uint256 n = bands.length;
        if (n == 0 || amountsIn.length != n || minShares.length != n) revert LengthMismatch();
        address inTok = inputIsBase ? IBandPool(pool).base() : IBandPool(pool).quote();
        uint256 total;
        for (uint256 i = 0; i < n; i++) {
            total += amountsIn[i];
        }
        TransferHelper.safeTransferFrom(inTok, msg.sender, address(this), total);

        shares = new uint128[](n);
        for (uint256 i = 0; i < n; i++) {
            if (i > 0 && bands[i] <= bands[i - 1]) revert BandsNotAscending();
            shares[i] = _depositOneSided(pool, tokenId, bands[i], amountsIn[i], inputIsBase);
            if (shares[i] < minShares[i]) revert SharesBelowMinimum(bands[i], shares[i], minShares[i]);
        }
    }

    function _depositOneSided(address pool, uint256 tokenId, uint8 band, uint256 amountIn, bool inputIsBase)
        private
        returns (uint128)
    {
        (uint256 baseAmount, uint256 quoteAmount) = _singleSidedAmounts(pool, band, amountIn, inputIsBase);
        uint8[] memory one = new uint8[](1);
        uint256[] memory b = new uint256[](1);
        uint256[] memory q = new uint256[](1);
        one[0] = band;
        b[0] = baseAmount;
        q[0] = quoteAmount;
        Offer memory o;
        o.baseTok = IBandPool(pool).base();
        o.quoteTok = IBandPool(pool).quote();
        o.baseTotal = baseAmount;
        o.quoteTotal = quoteAmount;
        TransferHelper.safeApprove(o.baseTok, pool, baseAmount);
        TransferHelper.safeApprove(o.quoteTok, pool, quoteAmount);
        uint128[] memory minted = _callIncreaseMem(pool, tokenId, one, b, q, o);
        _settleApproval(o.baseTok, pool, o.baseTotal, o.baseUsed);
        _settleApproval(o.quoteTok, pool, o.quoteTotal, o.quoteUsed);
        return minted[0];
    }

    function _callIncreaseMem(
        address pool,
        uint256 tokenId,
        uint8[] memory bands,
        uint256[] memory baseAmounts,
        uint256[] memory quoteAmounts,
        Offer memory o
    ) private returns (uint128[] memory shares) {
        (shares, o.baseUsed, o.quoteUsed) = IBandPool(pool).increase(tokenId, bands, baseAmounts, quoteAmounts);
    }

    /**
     * Convert half the input through the ROUTER, so the conversion is a real, reported
     * trade. `minAmountOut` is 0 because `minShares` guards the whole operation: a
     * sandwiched conversion yields a lopsided pair, which mints fewer shares, which
     * reverts. An EMPTY band takes the input as-is -- the first deposit defines its ratio.
     */
    function _singleSidedAmounts(address pool, uint8 band, uint256 amountIn, bool inputIsBase)
        private
        returns (uint256 baseAmount, uint256 quoteAmount)
    {
        (uint256 rBase, uint256 rQuote) = BandPool(pool).bandReserves(band);
        uint256 half = (rBase == 0 && rQuote == 0) ? 0 : amountIn / 2;
        uint256 converted;
        // What the conversion actually COST, which is not always `half`.
        uint256 spent = half;
        if (half > 0) {
            address inTok = inputIsBase ? IBandPool(pool).base() : IBandPool(pool).quote();
            address router = IMatchingEngine(IBandPool(pool).engine()).swapRouter();
            uint256 held = _balanceOf(inTok);
            TransferHelper.safeApprove(inTok, router, half);
            converted = BandSwapRouter(router).swap(pool, half, !inputIsBase, address(this), 0);
            TransferHelper.safeApprove(inTok, router, 0);
            /*
             * THE LADDER MAY NOT HAVE HAD ENOUGH TO SELL.
             *
             * `BandPool._walk` stops when the bands run out of the payout token, and the
             * router hands the unfilled remainder straight back here -- so `half` is what
             * was OFFERED and the balance delta is what was taken. Assuming `half` was
             * spent left that remainder sitting in this contract with nothing to return
             * it: measured at 48.999 of a 100-unit deposit, permanently, because nothing
             * sweeps this balance and the caller's refund is computed from the offer.
             *
             * Reading the delta instead makes the unfilled part part of the deposit's own
             * quote side, so `_price` refuses what the ratio cannot use and
             * `_settleApproval` returns it to the depositor with the rest.
             */
            spent = held - _balanceOf(inTok);
        }
        baseAmount = inputIsBase ? amountIn - spent : converted;
        quoteAmount = inputIsBase ? converted : amountIn - spent;
    }

    function _balanceOf(address token) private view returns (uint256) {
        (bool ok, bytes memory data) = token.staticcall(abi.encodeWithSelector(0x70a08231, address(this)));
        return ok && data.length >= 32 ? abi.decode(data, (uint256)) : 0;
    }

    // ------------------------------------------------------------------ closing

    /// @inheritdoc IBandPositionManager
    function decreaseLiquidity(
        uint256 tokenId,
        uint16 bps,
        uint256 minBase,
        uint256 minQuote,
        address recipient,
        uint256 deadline
    )
        external
        nonReentrant
        beforeDeadline(deadline)
        onlyOwnerOrApproved(tokenId)
        returns (uint256 baseOut, uint256 quoteOut)
    {
        if (bps == 0 || bps > BPS) revert BadBps(bps);
        (baseOut, quoteOut) = IBandPool(_positions[tokenId].pool).decrease(tokenId, bps, recipient);
        if (baseOut < minBase || quoteOut < minQuote) revert AmountBelowMinimum(baseOut, quoteOut);
    }

    /// @inheritdoc IBandPositionManager
    function decreaseBand(
        uint256 tokenId,
        uint8 band,
        uint128 shares,
        uint256 minBase,
        uint256 minQuote,
        address recipient,
        uint256 deadline
    )
        external
        nonReentrant
        beforeDeadline(deadline)
        onlyOwnerOrApproved(tokenId)
        returns (uint256 baseOut, uint256 quoteOut)
    {
        (baseOut, quoteOut) = IBandPool(_positions[tokenId].pool).decreaseBand(tokenId, band, shares, recipient);
        if (baseOut < minBase || quoteOut < minQuote) revert AmountBelowMinimum(baseOut, quoteOut);
    }

    /// @inheritdoc IBandPositionManager
    function collect(uint256 tokenId, address recipient)
        external
        nonReentrant
        onlyOwnerOrApproved(tokenId)
        returns (uint256 base, uint256 quote)
    {
        return IBandPool(_positions[tokenId].pool).collect(tokenId, recipient);
    }

    /// @inheritdoc IBandPositionManager
    function collectMany(uint256[] calldata tokenIds, address recipient)
        external
        nonReentrant
        returns (uint256[] memory base, uint256[] memory quote)
    {
        base = new uint256[](tokenIds.length);
        quote = new uint256[](tokenIds.length);
        for (uint256 i = 0; i < tokenIds.length; i++) {
            // The same gate as `collect`, per token: one unowned id reverts the batch
            // rather than being skipped, so a claim never silently pays less than asked.
            if (!_isOwnerOrApproved(msg.sender, tokenIds[i])) revert NotOwnerOrApproved(msg.sender, tokenIds[i]);
            (base[i], quote[i]) = IBandPool(_positions[tokenIds[i]].pool).collect(tokenIds[i], recipient);
        }
    }

    /// @inheritdoc IBandPositionManager
    function burn(uint256 tokenId) external nonReentrant onlyOwnerOrApproved(tokenId) {
        address pool = _positions[tokenId].pool;
        if (IBandPool(pool).bandMaskOf(tokenId) != 0) revert PositionNotEmpty(tokenId);
        (, uint256 owedBase, uint256 owedQuote) = IBandPool(pool).positionView(tokenId);
        if (owedBase != 0 || owedQuote != 0) revert PositionNotEmpty(tokenId);
        delete _positions[tokenId];
        _burn(_holder[tokenId], tokenId, 1);
    }

    // ------------------------------------------------------------ distribution

    /// @inheritdoc IBandPositionManager
    function moveLiquidity(
        uint256 tokenId,
        uint8 fromBand,
        uint8 toBand,
        uint128 shares,
        uint128 minSharesIn,
        address refundTo,
        uint256 deadline
    )
        external
        nonReentrant
        beforeDeadline(deadline)
        onlyOwnerOrApproved(tokenId)
        returns (uint128 sharesIn, uint256 baseRefund, uint256 quoteRefund)
    {
        (sharesIn, baseRefund, quoteRefund) =
            IBandPool(_positions[tokenId].pool).move(tokenId, fromBand, toBand, shares, refundTo);
        if (sharesIn < minSharesIn) revert SharesBelowMinimum(toBand, sharesIn, minSharesIn);
    }

    /// Per-band state the redistribution solver works on, all in quote units at the anchor.
    struct Leg {
        uint8 band;
        uint128 shares;
        uint256 value;
        uint256 target;
    }

    /// @inheritdoc IBandPositionManager
    function redistribute(RedistributeParams calldata p)
        external
        nonReentrant
        beforeDeadline(p.deadline)
        onlyOwnerOrApproved(p.tokenId)
        returns (uint256 baseRefund, uint256 quoteRefund)
    {
        address pool = _positions[p.tokenId].pool;
        Leg[] memory legs = _plan(pool, p);
        (baseRefund, quoteRefund) = _execute(pool, p.tokenId, legs, p.refundTo);
        _checkAfter(pool, p);
        emit Redistributed(p.tokenId, p.bands, p.targetBps);
    }

    /**
     * Value every band the position holds or is asked to hold, at the pool's anchor, and
     * attach each its target. A held band absent from `bands` has a target of zero:
     * redistributing to 100% of two bands empties the third.
     */
    function _plan(address pool, RedistributeParams calldata p) private view returns (Leg[] memory legs) {
        uint256 n = p.bands.length;
        if (n == 0 || p.targetBps.length != n || p.minSharesAfter.length != n) revert LengthMismatch();
        uint256 sum;
        for (uint256 i = 0; i < n; i++) {
            if (i > 0 && p.bands[i] <= p.bands[i - 1]) revert BandsNotAscending();
            sum += p.targetBps[i];
        }
        if (sum != BPS) revert TargetsNotWhole(sum);

        (IBandPool.BandView[] memory held,,) = IBandPool(pool).positionView(p.tokenId);
        uint256 price = IBandPool(pool).anchorPrice();
        address book = IBandPool(pool).orderbook();

        legs = new Leg[](BandPool(pool).bandCount());
        uint256 total;
        for (uint256 i = 0; i < legs.length; i++) {
            legs[i].band = i.toUint8();
        }
        for (uint256 i = 0; i < held.length; i++) {
            Leg memory leg = legs[held[i].band];
            leg.shares = held[i].shares;
            leg.value = held[i].quoteOwned
                + (held[i].baseOwned == 0 ? 0 : IOrderbook(book).convert(price, held[i].baseOwned, true));
            total += leg.value;
        }
        for (uint256 i = 0; i < n; i++) {
            legs[p.bands[i]].target = (total * p.targetBps[i]) / BPS;
        }
    }

    /**
     * Greedy: walk the over-weight bands and pour each into the under-weight ones in
     * index order. Shares to lift are the source's shares times the value to move over
     * the source's value at planning time.
     */
    function _execute(address pool, uint256 tokenId, Leg[] memory legs, address refundTo)
        private
        returns (uint256 baseRefund, uint256 quoteRefund)
    {
        Amounts2 memory refund;
        uint256 dst;
        for (uint256 src = 0; src < legs.length; src++) {
            Leg memory s = legs[src];
            if (s.value <= s.target) continue;
            uint256 surplus = s.value - s.target;
            while (surplus > 0 && dst < legs.length) {
                Leg memory d = legs[dst];
                if (d.value >= d.target || dst == src) {
                    dst++;
                    continue;
                }
                uint256 poured = _pour(pool, tokenId, s, d, surplus, refundTo, refund);
                if (poured == 0) break;
                surplus -= poured;
            }
        }
        return (refund.base, refund.quote);
    }

    struct Amounts2 {
        uint256 base;
        uint256 quote;
    }

    /// One move from `s` into `d`, sized to whichever is smaller: the source's surplus or
    /// the destination's shortfall. Returns the value poured; zero when it rounds to no shares.
    function _pour(
        address pool,
        uint256 tokenId,
        Leg memory s,
        Leg memory d,
        uint256 surplus,
        address refundTo,
        Amounts2 memory refund
    ) private returns (uint256 amount) {
        amount = surplus < d.target - d.value ? surplus : d.target - d.value;
        uint128 lift = ((uint256(s.shares) * amount) / s.value).toUint128();
        if (lift == 0) return 0;
        (, uint256 rb, uint256 rq) = IBandPool(pool).move(tokenId, s.band, d.band, lift, refundTo);
        refund.base += rb;
        refund.quote += rq;
        d.value += amount;
    }

    function _checkAfter(address pool, RedistributeParams calldata p) private view {
        (IBandPool.BandView[] memory held,,) = IBandPool(pool).positionView(p.tokenId);
        for (uint256 i = 0; i < p.bands.length; i++) {
            if (p.minSharesAfter[i] == 0) continue;
            uint128 got;
            for (uint256 j = 0; j < held.length; j++) {
                if (held[j].band == p.bands[i]) got = held[j].shares;
            }
            if (got < p.minSharesAfter[i]) revert SharesBelowMinimum(p.bands[i], got, p.minSharesAfter[i]);
        }
    }

    // --------------------------------------------------------------------- views

    /// @inheritdoc IBandPositionManager
    function positionOf(uint256 tokenId) public view returns (PositionView memory v) {
        Position memory p = _positions[tokenId];
        v.tokenId = tokenId;
        v.pool = p.pool;
        v.holder = _holder[tokenId];
        v.mintedAt = p.mintedAt;
        if (p.pool == address(0)) return v;
        v.base = IBandPool(p.pool).base();
        v.quote = IBandPool(p.pool).quote();
        v.bandMask = IBandPool(p.pool).bandMaskOf(tokenId);
        (v.bands, v.owedBase, v.owedQuote) = IBandPool(p.pool).positionView(tokenId);
    }

    /// @inheritdoc IBandPositionManager
    function portfolio(uint256[] calldata tokenIds) external view returns (PositionView[] memory rows) {
        rows = new PositionView[](tokenIds.length);
        for (uint256 i = 0; i < tokenIds.length; i++) {
            rows[i] = positionOf(tokenIds[i]);
        }
    }

    /// @inheritdoc IBandPositionManager
    function poolOf(uint256 tokenId) external view returns (address) {
        return _positions[tokenId].pool;
    }

    /// @inheritdoc IBandPositionManager
    function holderOf(uint256 tokenId) external view returns (address) {
        return _holder[tokenId];
    }

    // ------------------------------------------------------------------ helpers

    /// The factory's pool FOR ITS PAIR, not merely a clone: anyone can clone and initialize
    /// the implementation with their own orderbook, and that would be real BandPool code.
    function _requirePool(address pool) private view {
        if (
            pool == address(0) || !IPoolFactory(poolFactory).isClone(pool)
                || IPoolFactory(poolFactory).getPool(IBandPool(pool).base(), IBandPool(pool).quote()) != pool
        ) revert UnknownPool(pool);
    }

    function _sum(uint256[] calldata a, uint256[] calldata b) private pure returns (uint256 sa, uint256 sb) {
        for (uint256 i = 0; i < a.length; i++) {
            sa += a[i];
            sb += b[i];
        }
    }

    function _pullAndApprove(address token, address pool, uint256 amount) private {
        if (amount == 0) return;
        TransferHelper.safeTransferFrom(token, msg.sender, address(this), amount);
        TransferHelper.safeApprove(token, pool, amount);
    }

    /// Clear the leftover approval and return what the bands' ratios did not use.
    function _settleApproval(address token, address pool, uint256 offered, uint256 used) private {
        if (offered == 0) return;
        if (offered > used) {
            TransferHelper.safeApprove(token, pool, 0);
            TransferHelper.safeTransfer(token, msg.sender, offered - used);
        }
    }

    function _isOwnerOrApproved(address caller, uint256 tokenId) private view returns (bool) {
        address holder = _holder[tokenId];
        if (holder == address(0)) return false;
        return caller == holder || isApprovedForAll(holder, caller);
    }

    /**
     * Keeps `_holder` in sync across mint, transfer, batch transfer and burn.
     *
     * Only a NON-ZERO movement moves the holder. ERC-1155 lets anyone transfer zero units
     * of any id -- the balance check `0 <= 0` passes for an id they do not hold -- so a
     * holder written on every `_update` let any address make itself the holder of any
     * position with a zero-value self-transfer and then withdraw it. Every id has a supply
     * of exactly 1, so a non-zero transfer is proof the sender held it.
     */
    function _update(address from, address to, uint256[] memory ids, uint256[] memory values) internal override {
        super._update(from, to, ids, values);
        for (uint256 i = 0; i < ids.length; i++) {
            if (values[i] == 0) continue;
            if (to == address(0)) delete _holder[ids[i]];
            else _holder[ids[i]] = to;
        }
    }
}
