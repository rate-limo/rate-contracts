// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

/**
 * Band storage and the creator's control over it.
 *
 * A band is a price tolerance anchored to the orderbook TWAP. What is stored is not
 * the tolerance but the band's FRACTION of the pair's limit (`spreadFrac`); the swap
 * derives `spreadFrac × limit ÷ DENOM` from the limit the pool last synced. So when
 * the pair creator changes the limit, one write of the pool's two limits moves every
 * band at once -- the cost of a spread change does not grow with the ladder -- and no
 * band can quote past the rail the engine clamps price reports to.
 *
 * This replaces a one-shot scale: the ladder used to be fitted to the pair's spread at
 * the first deposit and then frozen as absolute tolerances, so a later change to the
 * limit left bands quoting outside it -- deposits refused, fills the rail would not
 * record, a TWAP drifting from what the pool traded at.
 */
abstract contract PoolBands {
    uint32 public constant DENOM = 100000000;
    uint8 public constant MAX_BANDS = 8;
    /**
     * The hard ceiling on any band's effective taker fee: 3% of DENOM. A multiplier
     * times a per-taker engine fee is two numbers this contract owns neither of, so the
     * product is capped at swap time rather than trusted.
     */
    uint32 public constant MAX_FEE_RATE = 3000000;

    /**
     * `shares` is the fee-share denominator AND the claim on the two reserves. A band
     * fills at a fixed TWAP-anchored bound rather than along a curve, so a swap moves
     * the reserves by exactly what it took and gave, and a share owns shares/total of
     * both.
     *
     * Two fee accumulators because a fee is denominated in whatever the taker received;
     * only one is written per swap, so swap gas stays flat in the number of LPs.
     */
    struct Band {
        /// Share of the pair's limit this band quotes at, over DENOM. 0 < f <= DENOM.
        uint32 spreadFrac;
        /// Premium over the engine's taker fee, DENOM-scaled: 1e8 is 1x.
        uint32 feeMultiplier;
        bool open;
        uint256 shares;
        uint256 baseReserve;
        uint256 quoteReserve;
        uint256 feeGrowthBase;
        uint256 feeGrowthQuote;
    }

    address public creator;
    uint64 public maturity;
    Band[] internal _bands;

    error NotCreator(address caller);
    error BadSpreadFrac(uint32 spreadFrac);
    error SpreadFracsNotAscending();
    error TooManyBands(uint256 given);
    error BandHoldsLiquidity(uint8 index);
    error ZeroCreator();
    error BadFeeMultiplier(uint32 multiplier);
    error MultipliersLengthMismatch(uint256 spreadFracs, uint256 multipliers);

    event BandsConfigured(uint32[] spreadFracs, uint32[] feeMultipliers);
    event BandFeeMultiplierSet(uint8 indexed index, uint32 multiplier);
    event BandOpenSet(uint8 indexed index, bool open);
    event CreatorTransferred(address indexed from, address indexed to);

    modifier onlyCreator() {
        if (msg.sender != creator) revert NotCreator(msg.sender);
        _;
    }

    /**
     * Seeded at creation so a new pair never sits in a state where liquidity is
     * impossible until somebody remembers a second transaction.
     */
    function _initBands(
        address creator_,
        uint64 maturity_,
        uint32[] calldata spreadFracs,
        uint32[] calldata feeMultipliers
    ) internal {
        if (creator_ == address(0)) revert ZeroCreator();
        creator = creator_;
        maturity = maturity_;
        _setBands(spreadFracs, feeMultipliers);
    }

    function bandCount() external view returns (uint256) {
        return _bands.length;
    }

    function bands(uint8 i)
        external
        view
        returns (uint32 spreadFrac, uint256 shares, uint256 feeGrowthBase, uint256 feeGrowthQuote, bool open)
    {
        Band storage b = _bands[i];
        return (b.spreadFrac, b.shares, b.feeGrowthBase, b.feeGrowthQuote, b.open);
    }

    /// The tolerances band `i` currently fills at, per side, over DENOM.
    function bandTolerances(uint8 i) external view returns (uint32 toleranceBuy, uint32 toleranceSell) {
        (uint32 buy, uint32 sell) = _storedLimits();
        uint32 frac = _bands[i].spreadFrac;
        return (_tolerance(frac, buy), _tolerance(frac, sell));
    }

    function bandFeeMultiplier(uint8 i) external view returns (uint32) {
        return _bands[i].feeMultiplier;
    }

    /// The fee this band would charge a taker whose engine rate is `engineRate`.
    function effectiveFeeRate(uint8 i, uint256 engineRate) external view returns (uint256) {
        return _cappedRate(engineRate, _bands[i].feeMultiplier);
    }

    function _cappedRate(uint256 engineRate, uint32 multiplier) internal pure returns (uint256 rate) {
        rate = (engineRate * multiplier) / DENOM;
        if (rate > MAX_FEE_RATE) rate = MAX_FEE_RATE;
    }

    function bandReserves(uint8 i) external view returns (uint256 baseReserve, uint256 quoteReserve) {
        Band storage b = _bands[i];
        return (b.baseReserve, b.quoteReserve);
    }

    /**
     * Set the ladder, ascending. Re-configuring is allowed, but a band holding liquidity
     * cannot be dropped: its LPs would have no way to settle or withdraw.
     */
    function configureBands(uint32[] calldata spreadFracs, uint32[] calldata feeMultipliers) external onlyCreator {
        _setBands(spreadFracs, feeMultipliers);
    }

    /// Reprice one band's premium. Allowed while it holds liquidity, which is when it matters.
    function setBandFeeMultiplier(uint8 index, uint32 multiplier) external onlyCreator {
        if (multiplier < DENOM) revert BadFeeMultiplier(multiplier);
        _bands[index].feeMultiplier = multiplier;
        emit BandFeeMultiplierSet(index, multiplier);
    }

    /// Hand band configuration to another address -- how a pool reaches its pair creator.
    function transferCreator(address to) external onlyCreator {
        if (to == address(0)) revert ZeroCreator();
        emit CreatorTransferred(creator, to);
        creator = to;
    }

    /// Closing a band stops new liquidity. It keeps settling, claiming and withdrawing.
    function setBandOpen(uint8 index, bool open) external onlyCreator {
        _bands[index].open = open;
        emit BandOpenSet(index, open);
    }

    function _setBands(uint32[] memory spreadFracs, uint32[] memory feeMultipliers) internal {
        if (spreadFracs.length == 0 || spreadFracs.length > MAX_BANDS) revert TooManyBands(spreadFracs.length);
        if (spreadFracs.length != feeMultipliers.length) {
            revert MultipliersLengthMismatch(spreadFracs.length, feeMultipliers.length);
        }
        for (uint256 i = 0; i < spreadFracs.length; i++) {
            // At most the whole limit: a band beyond it would quote past the rail.
            if (spreadFracs[i] == 0 || spreadFracs[i] > DENOM) revert BadSpreadFrac(spreadFracs[i]);
            if (i > 0 && spreadFracs[i] <= spreadFracs[i - 1]) revert SpreadFracsNotAscending();
            // Never below the engine's own rate: the protocol takes a cut of the fee,
            // so a discount here quietly discounts the protocol too.
            if (feeMultipliers[i] < DENOM) revert BadFeeMultiplier(feeMultipliers[i]);
        }
        for (uint256 i = spreadFracs.length; i < _bands.length; i++) {
            if (_bands[i].shares != 0) revert BandHoldsLiquidity(uint8(i));
        }

        while (_bands.length > spreadFracs.length) _bands.pop();
        for (uint256 i = 0; i < spreadFracs.length; i++) {
            if (i < _bands.length) {
                _bands[i].spreadFrac = spreadFracs[i];
                _bands[i].feeMultiplier = feeMultipliers[i];
            } else {
                _bands.push(
                    Band({
                        spreadFrac: spreadFracs[i],
                        feeMultiplier: feeMultipliers[i],
                        open: true,
                        shares: 0,
                        baseReserve: 0,
                        quoteReserve: 0,
                        feeGrowthBase: 0,
                        feeGrowthQuote: 0
                    })
                );
            }
        }
        emit BandsConfigured(spreadFracs, feeMultipliers);
    }

    /// The pair limits last synced into this pool, per side.
    function _storedLimits() internal view virtual returns (uint32 buy, uint32 sell);

    /**
     * `frac × limit ÷ DENOM`, rounded DOWN so a band always quotes inside the limit.
     * Fits in uint32 because `frac <= DENOM`. Zero means the limit is too small to
     * express this fraction at 8 decimals; the swap treats that band as idle.
     */
    function _tolerance(uint32 frac, uint32 limit) internal pure returns (uint32) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint32((uint256(frac) * limit) / DENOM);
    }
}
