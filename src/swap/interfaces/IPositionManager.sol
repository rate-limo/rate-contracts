// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

interface IPositionManager {
    error NotOwnerOrApproved(uint256 tokenId, address caller);
    error PositionNotEmpty(uint256 tokenId);
    error NotRouter(address caller);
    /// @notice Thrown when a batch exceeds the per-call position limit.
    /// @dev Out-of-gas carries zero return data, leaving a frontend nothing to decode
    /// (see test/swap/PoC_EstimateGasOnly.t.sol). This turns that silence into a
    /// decodable error, mirroring MatchingEngine's TooManyMatches.
    error TooManyPositions(uint256 count);

    // Pool.addLiquidity/removeLiquidity/collect are all gated onlyPositionManager, so this
    // singleton's log stream covers EVERY liquidity change across every factory-deployed Pool --
    // an indexer watching this one address needs no factory pattern to see all of them.
    // (SwapRouter's own LiquidityAdded only covers router-mediated remainder deposits; these
    // cover the direct add/remove flow too.)
    event LiquidityAdded(
        address indexed pool,
        uint256 indexed tokenId,
        address indexed owner,
        uint256 positionId,
        uint256 minPrice,
        uint256 maxPrice,
        uint32 slippageLimit,
        uint256 baseAmount,
        uint256 quoteAmount
    );

    event LiquidityRemoved(
        address indexed pool,
        uint256 indexed tokenId,
        address indexed recipient,
        uint256 positionId,
        uint256 baseAmount,
        uint256 quoteAmount
    );

    // adjustPosition retires the old Pool position and opens a new one under the same tokenId --
    // emitted once per adjust with the NEW range/amounts, so an aggregator can replace the old
    // range contribution keyed on tokenId rather than reconstructing it from a remove+add pair.
    event PositionAdjusted(
        address indexed pool,
        uint256 indexed tokenId,
        uint256 oldPositionId,
        uint256 newPositionId,
        uint256 newMinPrice,
        uint256 newMaxPrice,
        uint32 newSlippageLimit,
        uint256 newBaseAmount,
        uint256 newQuoteAmount
    );

    function addLiquidity(
        address pool,
        uint256 minPrice,
        uint256 maxPrice,
        uint32 slippageLimit,
        uint256 baseAmount,
        uint256 quoteAmount
    ) external returns (uint256 tokenId);

    function adjustPosition(
        uint256 tokenId,
        uint256 newMinPrice,
        uint256 newMaxPrice,
        uint32 newSlippageLimit,
        uint256 newBaseAmount,
        uint256 newQuoteAmount
    ) external;

    function removeLiquidity(uint256 tokenId, uint256 baseAmount, uint256 quoteAmount, address recipient) external;

    // Trusted-forwarder entry point for SwapRouter: `caller` is authorized against the same
    // owner-or-approved check `removeLiquidity` runs for a direct caller, just evaluated against
    // `caller` instead of msg.sender (which would otherwise be the router itself). Only the
    // address PositionManager's owner has designated via `setRouter` may call this -- see
    // PositionManager.onlyRouter.
    function removeLiquidityFor(
        address caller,
        uint256 tokenId,
        uint256 baseAmount,
        uint256 quoteAmount,
        address recipient
    ) external;

    function collect(uint256 tokenId, address recipient) external returns (uint256 baseFee, uint256 quoteFee);

    /// @notice Claims accrued fees for several positions the caller controls, in one call.
    /// @dev Positions owing nothing -- retired, or live with a zero balance on both sides --
    /// are skipped rather than reverting, because a position stays held as an ERC1155 id
    /// after Pool retires it and "claim everything I hold" would otherwise fail on any
    /// stale entry. An id the caller does not control still reverts the whole call.
    /// Amounts are reported per id rather than summed: positions may span pools with
    /// different token pairs, so a single total would add unrelated tokens together.
    /// @param tokenIds Position token ids to claim. At most MAX_CLAIM_BATCH entries.
    /// @param recipient Address paid every collected fee.
    /// @return baseFees Base-side fee claimed for tokenIds[i]; zero where skipped.
    /// @return quoteFees Quote-side fee claimed for tokenIds[i]; zero where skipped.
    function collectBatch(uint256[] calldata tokenIds, address recipient)
        external
        returns (uint256[] memory baseFees, uint256[] memory quoteFees);

    function burn(uint256 tokenId) external;

    function tokenPosition(uint256 tokenId) external view returns (address pool, uint256 positionId);
}
