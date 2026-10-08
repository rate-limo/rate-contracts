// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

/**
 * @title IBandPool
 * @notice One pool per pair. Liquidity sits in a ladder of bands; one LP position is
 * one token id that may hold shares in any subset of them.
 *
 * @dev Positions are keyed by the position manager's token id. There is no separate
 * pool-side position id: the two used to diverge across pools, and every consumer had
 * to learn which one it was holding.
 *
 * A band stores only its fraction of the pair's limit; its tolerance is
 * `spreadFrac × pairLimit(side)`, where `pairLimit` is the limit the engine applies to a
 * market order on the pair. `syncLimit` stores the two limits when they change (the
 * engine and the generator call it in the same transaction) and each swap multiplies. Changing the pair's limit
 * therefore moves every band, and no band can quote past the price rail.
 */
interface IBandPool {
    /// @notice One band's state, as seen by one position.
    struct BandView {
        uint8 band;
        /// @notice The band's share of the pair limit, DENOM = 100%.
        uint32 spreadFrac;
        /// @notice The live tolerance a buy (quote in, base out) fills at.
        uint32 toleranceBuy;
        /// @notice The live tolerance a sell (base in, quote out) fills at.
        uint32 toleranceSell;
        uint32 feeMultiplier;
        bool open;
        /// @notice This position's shares in the band.
        uint128 shares;
        /// @notice Every position's shares in the band.
        uint256 bandShares;
        /// @notice Share-weighted age of this position's capital in the band.
        uint64 createdAt;
        uint256 baseOwned;
        uint256 quoteOwned;
        /// @notice Fees accrued to this band slot that have not yet been locked in.
        uint256 pendingBase;
        uint256 pendingQuote;
        /// @notice The part of `pending*` that would be kept if it were settled now.
        uint256 vestedBase;
        uint256 vestedQuote;
        /// @notice Position along the vesting ramp, over DENOM.
        uint32 vestedNum;
    }

    /// @notice A deposit into one or more bands of one position, mint or top-up alike.
    event IncreaseLiquidity(
        uint256 indexed tokenId, uint8[] bands, uint128[] shares, uint256 baseIn, uint256 quoteIn
    );

    /// @notice A withdrawal from one or more bands of one position.
    /// @dev `forfeit*` is the unvested fee attached to the shares that left. It goes to
    /// the band's other shares, or to the protocol when there are none.
    event DecreaseLiquidity(
        uint256 indexed tokenId,
        uint8[] bands,
        uint128[] shares,
        uint256 baseOut,
        uint256 quoteOut,
        uint256 forfeitBase,
        uint256 forfeitQuote,
        bool forfeitToProtocol
    );

    /// @notice Vested fees paid out. Never accompanied by a forfeit.
    event Collect(uint256 indexed tokenId, address indexed recipient, uint256 base, uint256 quote);

    /// @notice Value moved between two bands of one position without leaving the pool.
    /// @dev Cost basis is unchanged by a move; only a refund is value leaving.
    event MoveLiquidity(
        uint256 indexed tokenId,
        uint8 fromBand,
        uint8 toBand,
        uint128 sharesOut,
        uint128 sharesIn,
        uint256 baseRefund,
        uint256 quoteRefund
    );

    event BandSwap(address indexed taker, uint256 amountIn, uint256 amountOut, uint256 marketPrice);

    /// @notice Deposits into `bands` of `tokenId`. Mints a position when it holds nothing.
    /// @dev Only the position manager. `bands` must be strictly ascending. Pulls
    /// `baseUsed`/`quoteUsed` from the caller once, after pricing every band.
    /// @return shares Shares minted per band, in `bands` order.
    function increase(
        uint256 tokenId,
        uint8[] calldata bands,
        uint256[] calldata baseAmounts,
        uint256[] calldata quoteAmounts
    ) external returns (uint128[] memory shares, uint256 baseUsed, uint256 quoteUsed);

    /// @notice Withdraws `bps` of every band the position holds, in one call.
    /// @dev Only the position manager. Pays principal and every vested fee to `recipient`.
    function decrease(uint256 tokenId, uint16 bps, address recipient)
        external
        returns (uint256 baseOut, uint256 quoteOut);

    /// @notice Withdraws `shares` from one band. Clamped to what the position holds.
    function decreaseBand(uint256 tokenId, uint8 band, uint128 shares, address recipient)
        external
        returns (uint256 baseOut, uint256 quoteOut);

    /// @notice Moves `shares` of `fromBand` into `toBand`, inside the pool.
    /// @dev What `toBand`'s reserve ratio cannot absorb is refunded to `refundTo`, and only
    /// that refunded part forfeits its unvested fees. The capital's age travels with it.
    function move(uint256 tokenId, uint8 fromBand, uint8 toBand, uint128 shares, address refundTo)
        external
        returns (uint128 sharesIn, uint256 baseRefund, uint256 quoteRefund);

    /// @notice Pays every vested fee. The unvested remainder keeps vesting; nothing forfeits.
    function collect(uint256 tokenId, address recipient) external returns (uint256 base, uint256 quote);

    /// @notice Bit `i` set means the position holds shares in band `i`.
    function bandMaskOf(uint256 tokenId) external view returns (uint8);

    /// @notice Every band the position holds, plus fees already locked in and payable.
    function positionView(uint256 tokenId)
        external
        view
        returns (BandView[] memory bands, uint256 owedBase, uint256 owedQuote);

    /// @notice The limit last synced for `isBuy`'s side -- the one swaps price from.
    function pairLimit(bool isBuy) external view returns (uint32);

    /// @notice The limit as the engine and generator state it right now: the creator's
    /// slippage cap if the pair has one, capped by the engine's market spread for that side.
    /// Differs from `pairLimit` only between a change and its sync.
    function liveLimit(bool isBuy) external view returns (uint32);

    /// @notice Re-reads the live limit and stores it; every band's tolerance is its fraction of it. Permissionless.
    function syncLimit() external returns (uint32 limitBuy, uint32 limitSell);

    /// @notice The price bands hang off: the 300s TWAP, or the listing price before one exists.
    function anchorPrice() external view returns (uint256);

    /// @notice Walks bands tightest-first. Signature unchanged from v1: the engine's
    /// fallback path and the router both call it.
    function swap(uint256 amountIn, bool quoteToBase, address recipient, uint256 minAmountOut)
        external
        returns (uint256 amountOut, uint256 matchedPrice);

    function base() external view returns (address);
    function quote() external view returns (address);
    function orderbook() external view returns (address);
    function engine() external view returns (address);
    function positionManager() external view returns (address);
}
