// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {MockToken} from "../../src/mock/MockToken.sol";
import {MatchingEngine} from "../../src/exchange/MatchingEngine.sol";
import {IMatchingEngine} from "../../src/exchange/interfaces/IMatchingEngine.sol";
import {ExchangeOrderbook} from "../../src/exchange/libraries/ExchangeOrderbook.sol";
import {IOrderbook} from "../../src/exchange/interfaces/IOrderbook.sol";
import {StopOrderEngine} from "../../src/exchange/StopOrderEngine.sol";
import {IPoolFactory} from "../../src/swap/interfaces/IPoolFactory.sol";
import {IPositionManager} from "../../src/swap/interfaces/IPositionManager.sol";
import {ISwapRouter} from "../../src/swap/interfaces/ISwapRouter.sol";

/**
 * Opens a pair on a freshly deployed engine and drives real order flow through it, so
 * the indexer has something to process and can be checked against a known-good set of
 * events rather than against an empty chain.
 *
 * Everything goes through `createOrder` deliberately -- that is the struct entry point
 * the frontend now uses, so seeding through the surviving scalar overloads would leave
 * the path that actually ships unexercised.
 *
 * Emits, in order: PairAdded, then OrderPlaced for each resting order, then
 * OrderMatched + NewMarketPrice for the crossing buy, then (after the order stages)
 * LiquidityAdded from a direct PositionManager deposit, StopOrderPlaced from a resting
 * stop-limit, and OrderCanceled. SwapExecuted + HopExecuted + SwapPriceReport from a
 * router swap are ALSO emitted, but only when the pair already has >=10 minutes of
 * oracle history -- never true for a pair this same run just listed, so on a normal run
 * against a fresh pair that trio is skipped rather than reverting the whole batch (see
 * the swap stage's own comment in `run`). Those are the event classes the broker's
 * processors key off, which is the point -- see the printed summary.
 *
 * Decimals are deliberately mismatched (18 base / 6 quote, i.e. the WETH/USDC shape).
 * A same-decimals pair hides every scaling bug, and this venue's whole price path is
 * 1e8-scaled independently of either token.
 *
 *   RISE_TESTNET_DEPLOYER_KEY=0x... forge script \
 *     script/exchange/SeedNewExchange.s.sol:SeedNewExchange \
 *     --rpc-url https://testnet.riselabs.xyz/ --broadcast
 */
contract SeedNewExchange is Script {
    /// The live stack, READ FROM packages/deployments/deployments.json — the same file the
    /// indexer reads, so a redeploy that updates the registry updates this script with it.
    ///
    /// These were constants, with a comment warning they would go stale silently on every
    /// redeploy. They did, on 2026-08-15: the redeploy updated the registry and not this
    /// file, and a sibling seed script copied the stale engine and listed a market on the
    /// retired one. Nothing failed — a retired engine has code and answers every call — so
    /// the run reported success and the market was invisible to the app. A prediction in a
    /// comment is not a guard.
    MatchingEngine ENGINE;
    IPoolFactory POOL_FACTORY;
    IPositionManager POSITION_MANAGER;
    ISwapRouter SWAP_ROUTER;
    StopOrderEngine STOP_ORDER_ENGINE;

    /// Price is 1e8-scaled venue-wide, independent of either token's decimals:
    /// 1 TBASE = 100 TUSD.
    uint256 constant LISTING_PRICE = 100e8;

    /// Match budget per order. maxMatches is 20 and `n` above it reverts rather than
    /// clamping, so this stays well under.
    uint32 constant N = 4;

    /// Mirrors Pool.TWAP_WINDOW. Pool._prepareSwap requires the pair's oracle to hold a
    /// TWAP history at least this old before a swap can price against it -- a pair listed
    /// by THIS run has zero history, so the swap stage below has to check readiness
    /// itself rather than assume it.
    uint32 constant TWAP_WINDOW = 600;

    /// @notice Resolves the deployed stack for THIS chain from the shared registry.
    ///
    /// The code check is the part that matters: a stale address in the registry still
    /// parses, and every call against an address with no code returns empty rather than
    /// reverting, so a wrong address here reads as a working run that seeds nothing.
    function _loadRegistry() internal {
        string memory registry = vm.readFile("../packages/deployments/deployments.json");
        string memory base = string.concat(".chains.", vm.toString(block.chainid), ".contracts");

        ENGINE = MatchingEngine(payable(_at(registry, base, "matchingEngine")));
        POOL_FACTORY = IPoolFactory(_at(registry, base, "poolFactory"));
        POSITION_MANAGER = IPositionManager(_at(registry, base, "positionManager"));
        SWAP_ROUTER = ISwapRouter(_at(registry, base, "swapRouter"));
        STOP_ORDER_ENGINE = StopOrderEngine(_at(registry, base, "stopOrderEngine"));

        console.log("engine (registry)     %s", address(ENGINE));
    }

    function _at(string memory registry, string memory base, string memory name)
        internal
        view
        returns (address deployed)
    {
        deployed = vm.parseJsonAddress(registry, string.concat(base, ".", name, ".address"));
        require(deployed.code.length > 0, string.concat("registry's ", name, " has no code on this chain"));
    }

    function run() external {
        uint256 key = vm.envUint("RISE_TESTNET_DEPLOYER_KEY");
        address me = vm.addr(key);
        _loadRegistry();
        vm.startBroadcast(key);

        // ---- tokens ----
        MockToken base = new MockToken("Iter Test Base", "TBASE", 18);
        MockToken quote = new MockToken("Iter Test Quote", "TUSD", 6);
        base.mint(me, 1_000_000e18);
        quote.mint(me, 1_000_000e6);
        base.approve(address(ENGINE), type(uint256).max);
        quote.approve(address(ENGINE), type(uint256).max);

        // ---- the pair (emits PairAdded) ----
        // PriceTimePriority, never SizePriority: the latter's insert walks the whole
        // price level and is unbounded, which contracts/CLAUDE.md documents as a silent
        // out-of-gas past ~850 resting orders at one price.
        address pair = ENGINE.addPair(
            address(base),
            address(quote),
            LISTING_PRICE,
            0,
            address(base),
            ExchangeOrderbook.MatchingMode.PriceTimePriority
        );
        console.log("pair                 %s", pair);

        // ---- a resting ask (emits OrderPlaced) ----
        // isMaker true and a price above the book so it rests rather than crossing.
        _order(base, quote, false, true, LISTING_PRICE, 10e18, me, 0);

        // ---- a crossing bid (emits OrderMatched + NewMarketPrice) ----
        // Buys with 500 TUSD at the ask, so it eats half the 10 TBASE resting above.
        _order(base, quote, true, true, LISTING_PRICE, 500e6, me, 0);

        // ---- a resting bid that stays open, well below the market ----
        // Gives the indexer a live row in spotOrders to reconcile against. Its id is
        // captured (not discarded, like the other three) because the cancellation stage
        // below needs it -- this is the resting order that stage gets cancelled.
        IMatchingEngine.OrderResult memory restingBid = _order(base, quote, true, true, 90e8, 100e6, me, 0);

        // ---- a market buy, to exercise the isLimit=false branch ----
        _order(base, quote, true, false, 0, 50e6, me, 0);

        // ---- LP provision (emits LiquidityAdded) ----
        address pool = _addLiquidity(base, quote);
        console.log("pool                 %s", pool);

        bool swapRan;

        // ---- a swap through the router (emits SwapExecuted, HopExecuted, and --
        // crucially -- SwapPriceReport from the MatchingEngine) ----
        //
        // Gated on a TWAP readiness probe rather than called unconditionally: Pool.sol's
        // own comment above `_prepareSwap` documents that it "[r]everts (InsufficientHistory)
        // if this pool's pair was listed less than TWAP_WINDOW seconds ago -- a deliberate
        // fail-safe, not a bug." A pair this same run just listed has zero oracle history,
        // so an unconditional call here would revert -- and forge script aborts the ENTIRE
        // broadcast (every stage, not just this one) on any revert, which would silently
        // seed nothing at all rather than "everything except the swap." Probing first with
        // a static call keeps every other stage landing regardless of pair age; run this
        // script again >=10 minutes after a pair's first listing to see the swap trio too.
        try IOrderbook(pair).twap(TWAP_WINDOW) returns (uint256, uint32) {
            _swap(base, quote, me);
            swapRan = true;
        } catch {
            console.log("swap SKIPPED - pair has <TWAP_WINDOW (600s) of oracle history yet");
        }

        // ---- a stop-limit order that rests (emits StopOrderPlaced) ----
        _placeStop(base, quote, me);

        // ---- cancel the 90e8 resting bid from above (emits OrderCanceled) ----
        ENGINE.cancelOrder(address(base), address(quote), true, restingBid.id);

        vm.stopBroadcast();

        console.log("");
        console.log("=== seeded ===");
        console.log("base  (TBASE, 18) %s", address(base));
        console.log("quote (TUSD,   6) %s", address(quote));
        console.log("pair              %s", pair);
        console.log("pool              %s", pool);
        console.log("engine            %s", address(ENGINE));
        console.log("positionManager   %s", address(POSITION_MANAGER));
        console.log("swapRouter        %s", address(SWAP_ROUTER));
        console.log("stopOrderEngine   %s", address(STOP_ORDER_ENGINE));
        console.log("block             %s", block.number);
        console.log("");
        console.log("expect the indexer's rawEvents to cover, at minimum:");
        console.log("  PairAdded          - addPair");
        console.log("  OrderPlaced        - each resting createOrder call");
        console.log("  OrderMatched       - the crossing bid + the market buy");
        console.log("  NewMarketPrice     - every match that moves lmp");
        console.log("  LiquidityAdded     - PositionManager.addLiquidity");
        console.log("  StopOrderPlaced    - StopOrderEngine.placeStopLimit");
        console.log("  OrderCanceled      - cancelling the 90e8 resting bid");
        if (swapRan) {
            console.log("  SwapExecuted       - SwapRouter.swap, route summary");
            console.log("  HopExecuted        - SwapRouter.swap, per-hop detail");
            console.log("  SwapPriceReport    - MatchingEngine.reportSwap via the router");
            console.log("  (RemainderHandled  - only if the swap left a hop remainder)");
        } else {
            console.log("");
            console.log("  swap trio (SwapExecuted/HopExecuted/SwapPriceReport) SKIPPED this run --");
            console.log("  pair is younger than TWAP_WINDOW. Re-run >=10 min after first listing.");
        }
    }

    /// One createOrder call. Split out because the struct is 12 fields and inlining it
    /// four times is how a field silently drifts between call sites. Returns the
    /// OrderResult (rather than discarding it) so the resting-bid call site can recover
    /// its order id for the cancellation stage; the other call sites just ignore it.
    function _order(
        MockToken base,
        MockToken quote,
        bool isBid,
        bool isLimit,
        uint256 price,
        uint256 amount,
        address recipient,
        uint32 slippageLimit
    ) internal returns (IMatchingEngine.OrderResult memory) {
        return ENGINE.createOrder(
            IMatchingEngine.CreateOrderInput({
                base: address(base),
                quote: address(quote),
                isBid: isBid,
                isLimit: isLimit,
                orderId: 0,
                price: price,
                amount: amount,
                n: N,
                recipient: recipient,
                isMaker: true,
                // 0 is the venue default, NOT zero tolerance -- _pairSlippageLimit
                // passes a request straight through and _marketBuy then clamps to
                // min(request, spread), so a literal 0 would match nothing.
                slippageLimit: slippageLimit,
                deadline: 0
            })
        );
    }

    /// addPair already created the pool, so this looks it up instead of creating a
    /// second one. The range straddles LISTING_PRICE so it is two-sided and in range
    /// for `_swap` below, rather than sitting idle on one side.
    ///
    /// Pool.addLiquidity pulls tokens via `payer` (this script's EOA, forwarded through
    /// PositionManager as msg.sender) with the Pool contract itself as the ERC-20
    /// spender -- not PositionManager -- so the approvals below target the pool,
    /// mirroring how SwapRouter approves the pool rather than itself in Pool.sol's own
    /// transferFrom calls. Split out (like `_order`) purely to keep `run`'s stack frame
    /// within EVM limits -- this file has no viaIR compilation available.
    function _addLiquidity(MockToken base, MockToken quote) internal returns (address pool) {
        pool = POOL_FACTORY.getPool(address(base), address(quote));
        uint256 lpBaseAmount = 1_000e18;
        uint256 lpQuoteAmount = 100_000e6;
        base.approve(pool, lpBaseAmount);
        quote.approve(pool, lpQuoteAmount);
        POSITION_MANAGER.addLiquidity(pool, 80e8, 120e8, 5_000_000, lpBaseAmount, lpQuoteAmount);
    }

    /// SwapPriceReport is emitted from MatchingLib through a delegatecall and carries
    /// `address indexed pair`, so this is the stage that proves the rail extraction kept
    /// both the emitting address and the topic layout intact.
    function _swap(MockToken base, MockToken quote, address me) internal {
        address[] memory path = new address[](2);
        path[0] = address(base);
        path[1] = address(quote);
        uint256 swapAmountIn = 20e18;
        base.approve(address(SWAP_ROUTER), swapAmountIn);
        SWAP_ROUTER.swap(
            ISwapRouter.SwapInput({
                path: path,
                amountIn: swapAmountIn,
                minAmountOut: 0,
                // minAmountOut: 0 for a seed, there is nothing to protect against yet
                recipient: me,
                remainderMode: ISwapRouter.RemainderMode.Refund,
                remainderConfig: ISwapRouter.RemainderConfig({restPrice: 0, lpMinPrice: 0, lpMaxPrice: 0, lpSlippageLimit: 0})
            })
        );
    }

    /// A buy stop placed above the market so `_validate`'s StopAlreadyCrossed check
    /// passes and it rests waiting rather than triggering inline.
    function _placeStop(MockToken base, MockToken quote, address me) internal {
        quote.approve(address(STOP_ORDER_ENGINE), 50e6);
        STOP_ORDER_ENGINE.placeStopLimit(address(base), address(quote), true, 150e8, 155e8, 50e6, me);
    }
}
