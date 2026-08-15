// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

interface ISwapRouter {
    // Refund: send the remainder straight back to the recipient's wallet, in the hop's
    //         input token (MatchingEngine._detMake's default behavior, called with isMaker=false).
    // RestAsOrder: place the remainder as the recipient's own resting limit order on that
    //         hop's pair, at RemainderConfig.restPrice (or the current mktPrice() if 0).
    // DepositToLP: supply the remainder as a brand-new LP position on that hop's pair, owned
    //         by the recipient (minted via PositionManager, then forwarded to the recipient).
    enum RemainderMode {
        Refund,
        RestAsOrder,
        DepositToLP
    }

    // restPrice is only read for RemainderMode.RestAsOrder (0 = use the hop's current mktPrice()).
    // lpMinPrice/lpMaxPrice/lpSlippageLimit are only read for RemainderMode.DepositToLP.
    struct RemainderConfig {
        uint256 restPrice;
        uint256 lpMinPrice;
        uint256 lpMaxPrice;
        uint32 lpSlippageLimit;
    }

    error PoolDoesNotExist(address tokenIn, address tokenOut);
    error SlippageExceeded(uint256 requested, uint256 actual);

    // Emitted once per hop that produces a nonzero remainder, after it has been disposed of
    // per `mode` -- the single source of truth for what happened to it, since `swap` no longer
    // returns a raw leftover amount (there can be one per hop now, not just on the final hop).
    event RemainderHandled(address indexed tokenIn, address indexed tokenOut, uint256 amount, RemainderMode mode);

    // Emitted once per hop, regardless of whether it left a remainder -- lets an indexer read a
    // full router-mediated route (which pools were touched, how much each matched) from
    // SwapRouter's own address alone, without also having to watch every Pool the PoolFactory
    // may have deployed.
    event HopExecuted(
        address indexed pool, address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut, uint256 leftover
    );

    // Emitted once per `swap()` call, summarizing the whole route (first token in, last token out).
    event SwapExecuted(
        address indexed recipient, address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut
    );

    // Mirrors IPool.LiquidityAdded for a RemainderMode.DepositToLP disposal, plus the `pool` and
    // `recipient` IPool's own event doesn't need (Pool only ever refers to itself; SwapRouter
    // spans every pool it touches) -- so watching SwapRouter alone is enough to see every
    // remainder-originated position it ever created, same reasoning as HopExecuted above.
    event LiquidityAdded(
        address indexed pool,
        uint256 indexed positionId,
        address indexed recipient,
        uint256 minPrice,
        uint256 maxPrice,
        uint32 slippageLimit,
        uint256 baseAmount,
        uint256 quoteAmount
    );

    // Emitted by removeLiquidity, the router-mediated counterpart to LiquidityAdded above --
    // same reasoning, mirrors IPool.LiquidityRemoved plus the `pool`/`recipient` fields Pool's
    // own version doesn't need.
    event LiquidityRemoved(
        address indexed pool, uint256 indexed positionId, address indexed recipient, uint256 baseAmount, uint256 quoteAmount
    );

    /// One calldata struct per entrypoint, matching IMatchingEngine's order API. The six
    /// positional arguments below included two 256-bit amounts and an enum, which a
    /// wagmi/viem caller can transpose while still encoding successfully -- a named object
    /// cannot be mis-ordered. Unlike the engine, this contract has room to spare: SwapRouter
    /// deploys at well under half the EIP-170 limit.
    struct SwapInput {
        address[] path;
        uint256 amountIn;
        uint256 minAmountOut;
        address recipient;
        RemainderMode remainderMode;
        RemainderConfig remainderConfig;
    }

    /// Calldata struct for `removeLiquidity`, same reasoning as SwapInput.
    struct RemoveLiquidityInput {
        address positionManager;
        uint256 tokenId;
        uint256 baseAmount;
        uint256 quoteAmount;
        address recipient;
    }

    /// @notice Routes `input.amountIn` of `input.path[0]` through each consecutive pair in
    /// `input.path`, applying the same `input.remainderMode` to whatever doesn't match at EVERY
    /// hop (not just the final one).
    /// There is no partial-fill revert anywhere in this path anymore: a hop that only partially
    /// matches still forwards its matched output to the next hop, and its unmatched input is
    /// disposed of immediately via `input.remainderMode` -- refunded, rested as an order, or
    /// deposited as new LP liquidity -- so the route always completes.
    function swap(SwapInput calldata input) external returns (uint256 amountOut);

    /// @notice Removes liquidity from a position through its PositionManager, on behalf of
    /// msg.sender. `positionManager` must have this router wired up via its own `setRouter` --
    /// the caller must actually hold `tokenId` (or be approved for it) on that PositionManager,
    /// same authorization a direct PositionManager.removeLiquidity call would require.
    function removeLiquidity(RemoveLiquidityInput calldata input) external;
}
