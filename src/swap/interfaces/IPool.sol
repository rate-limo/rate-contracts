// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

interface IPool {
    struct Position {
        uint256 minPrice;
        uint256 maxPrice;
        // createdAt packs into slippageLimit's slot (4 + 8 bytes) -- adding it
        // costs no extra storage slot, so addLiquidity gas is unchanged. It
        // drives the settlement age multiplier: 0 before maturity (JIT mints
        // earn nothing), 1.0 at maturity, ramping to 1.5x over the loyalty
        // window (see Pool._ageMultiplier).
        uint32 slippageLimit;
        uint64 createdAt;
        uint256 baseAmount;
        uint256 quoteAmount;
        uint256 feeOwedBase;
        uint256 feeOwedQuote;
        bool active;
    }

    event LiquidityAdded(
        uint256 indexed positionId,
        uint256 minPrice,
        uint256 maxPrice,
        uint32 slippageLimit,
        uint256 baseAmount,
        uint256 quoteAmount
    );
    event LiquidityRemoved(uint256 indexed positionId, uint256 baseAmount, uint256 quoteAmount);
    event FeeCollected(uint256 indexed positionId, uint256 baseFee, uint256 quoteFee);
    event Swap(
        address indexed recipient,
        bool quoteToBase,
        uint256 amountIn,
        uint256 amountOut,
        uint256 leftoverIn
    );
    event PositionDeactivated(uint256 indexed positionId);

    error OnlyPositionManager(address caller, address positionManager);

    /// Thrown when a non-router calls `swap`. `router` is what the engine currently
    /// reports; address(0) means none has been wired yet, so nothing can pass.
    error NotRouter(address caller, address router);
    error PositionDoesNotExist(uint256 positionId);
    error PositionNotEmpty(uint256 positionId);
    error NoLiquidityInRange(uint256 marketPrice);
    error TooManyPositionsInRange(uint32 cap);
    error InsufficientPositionBalance(uint256 positionId, uint256 requested, uint256 available);
    error InvalidSlippageLimit(uint32 slippageLimit);

    function initialize(
        uint256 id_,
        address base_,
        address quote_,
        address orderbook_,
        address engine_,
        address positionManager_
    ) external;

    function addLiquidity(
        uint256 minPrice,
        uint256 maxPrice,
        uint32 slippageLimit,
        uint256 baseAmount,
        uint256 quoteAmount,
        address payer
    ) external returns (uint256 positionId);

    function removeLiquidity(uint256 positionId, uint256 baseAmount, uint256 quoteAmount, address recipient)
        external;

    function collect(uint256 positionId, address recipient) external returns (uint256 baseFee, uint256 quoteFee);

    /// @return amountOut  output paid to `recipient`, net of the taker fee
    /// @return leftoverIn unconsumed input (0 when rested rather than refunded)
    /// @return matchedPrice the price this swap actually traded at -- the bound of the
    ///         last tier that changed hands. Tiers fill tightest-first, so it is the
    ///         worst price touched, mirroring how the book sets lmp from the last level
    ///         it walked. 0 when nothing filled. The router reports it verbatim.
    function swap(uint256 amountIn, bool quoteToBase, address recipient, bool restLeftoverOnFinalHop)
        external
        returns (uint256 amountOut, uint256 leftoverIn, uint256 matchedPrice);

    function creditFee(uint256[] calldata positionIds, uint256[] calldata shares, bool isBaseFee, uint256 totalFee)
        external;

    function getPosition(uint256 positionId) external view returns (Position memory);

    function getBaseQuote() external view returns (address base, address quote);

    function activePositionsLength() external view returns (uint256);

    function engine() external view returns (address);

    /// The pair this pool settles against.
    function orderbook() external view returns (address);

    function positionManager() external view returns (address);
}
