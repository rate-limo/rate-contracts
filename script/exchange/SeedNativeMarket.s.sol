// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {MatchingEngine} from "../../src/exchange/MatchingEngine.sol";
import {IMatchingEngine} from "../../src/exchange/interfaces/IMatchingEngine.sol";
import {ExchangeOrderbook} from "../../src/exchange/libraries/ExchangeOrderbook.sol";

/// @notice Lists the chain's NATIVE token against the settlement stable and gives it depth.
///
/// ## Why this is its own script, and why it is not optional
///
/// The swap card opens on the chain's native token, because that is what a visitor
/// arrives holding. Every other seed script lists MOCK tokens — TBASE/TUSD, a launch
/// coin — so a freshly deployed venue had markets for tokens nobody owns and no market
/// for the one everybody does. The card asked for an ETH route, the gateway correctly
/// answered that no such market exists, and the whole stack looked broken while every
/// component was behaving exactly as designed.
///
/// So: a deploy is not finished until the native market exists. It is the only market
/// the default UI state depends on.
///
/// ## Nothing here is a hardcoded address, and that is the point
///
/// The first version of this script carried the engine as a constant, copied from the
/// seed script beside it. That constant named the PREVIOUS generation, so the market was
/// listed on a retired engine — which has code, answers every call, and returns a pair
/// address, so the run reported success while indexing nothing. Both addresses are read
/// live instead:
///
/// - the **engine** comes from `packages/deployments/deployments.json`, the same file the
///   indexer reads, so a redeploy that updates the registry updates this script too;
/// - **WETH** comes from `ENGINE.WETH()`, because the engine is the only thing whose
///   opinion matters. It wraps `msg.value` into that exact contract, and RISE carries
///   several WETH9s all answering `symbol() = "WETH"` — a market listed against the wrong
///   one quotes on chain and can never be routed to from the app.
///
/// The registry's own `weth` field is checked against the engine's rather than used: it
/// was wrong on 2026-08-15, carried forward across a redeploy that changed the engine, and
/// a mismatch there is worth failing on rather than silently working around.
///
/// Required environment:
///   RISE_TESTNET_DEPLOYER_KEY
///
/// Run:
///   forge script script/exchange/SeedNativeMarket.s.sol:SeedNativeMarket \
///     --rpc-url $RPC_URL --broadcast --via-ir
contract SeedNativeMarket is Script {
    /// The settlement stable. Not in the registry — it is not deployed by the exchange
    /// scripts, so `pnpm sync` never sees it — so it is checked by symbol and decimals
    /// below rather than taken on trust.
    IERC20 constant USDC = IERC20(0x1f18a1724D8960f10165788dba3123F3f5623BB9);

    /// 1 WETH = 2,000 USDC, in the venue's 1e8 price scale (independent of either
    /// token's decimals).
    uint256 constant LISTING_PRICE = 2000e8;

    /// Match budget per order. maxMatches is 20 and `n` above it REVERTS rather than
    /// clamping, so this stays well under.
    uint32 constant N = 4;

    /// Native ETH sent with the ask; the engine wraps it.
    uint256 constant ASK_SIZE = 0.02 ether;

    MatchingEngine engine;
    address weth;

    function run() external {
        uint256 key = vm.envUint("RISE_TESTNET_DEPLOYER_KEY");
        address me = vm.addr(key);

        string memory registry = vm.readFile("../packages/deployments/deployments.json");
        string memory base = string.concat(".chains.", vm.toString(block.chainid), ".contracts");

        engine = MatchingEngine(payable(vm.parseJsonAddress(registry, string.concat(base, ".matchingEngine.address"))));
        require(address(engine).code.length > 0, "registry's matching engine has no code on this chain");

        weth = engine.WETH();
        address registryWeth = vm.parseJsonAddress(registry, string.concat(base, ".weth.address"));
        require(weth == registryWeth, "deployments.json's weth is not the engine's WETH");

        require(
            keccak256(bytes(IERC20Metadata(address(USDC)).symbol())) == keccak256("USDC"), "USDC is not where expected"
        );
        require(IERC20Metadata(address(USDC)).decimals() == 6, "USDC decimals changed");

        console.log("engine (registry)     %s", address(engine));
        console.log("weth   (engine)       %s", weth);

        vm.startBroadcast(key);

        // No manual wrap and no WETH approval: for a WETH leg the ENGINE wraps
        // msg.value itself (`_createOrder`: `base == WETH` on a sell, `quote == WETH`
        // on a bid). Pre-wrapping and approving leaves the engine still asking for
        // value and reverting OutOfFunds — which is exactly how this script failed
        // the first time. Only the USDC side is a conventional ERC-20 approval.
        USDC.approve(address(engine), type(uint256).max);

        address pair = engine.getPair(weth, address(USDC));
        if (pair == address(0)) {
            // PriceTimePriority, never SizePriority — see contracts/CLAUDE.md: the
            // latter's insert walks the whole price level and is unbounded.
            pair = engine.addPair(
                weth,
                address(USDC),
                LISTING_PRICE,
                0,
                address(USDC),
                ExchangeOrderbook.MatchingMode.PriceTimePriority
            );
            console.log("listed WETH/USDC      %s", pair);
        } else {
            console.log("WETH/USDC exists      %s", pair);
        }

        // A resting ask ABOVE the market and a resting bid BELOW it, so the book has two
        // live sides and a swap in either direction has something to hit. Sized small:
        // this is a fixture, not a liquidity programme.
        //
        // The ask sells WETH, so it carries `value` — this IS the native path, and it
        // is the one an ETH-holding visitor takes.
        _order(false, LISTING_PRICE, ASK_SIZE, me, ASK_SIZE);
        _order(true, (LISTING_PRICE * 99) / 100, 20e6, me, 0);

        // One crossing bid, so the pair has a last matched price and a trade in history.
        // Without it `mktPrice` is the listing price and nothing has ever traded, which
        // reads downstream as a market that exists but has never worked.
        _order(true, LISTING_PRICE, 10e6, me, 0);

        (uint256 bidHead, uint256 askHead) = engine.heads(weth, address(USDC));

        vm.stopBroadcast();

        console.log("=== native market seeded ===");
        console.log("pair                  %s", pair);
        console.log("bidHead               %s", bidHead);
        console.log("askHead               %s", askHead);
        console.log("mktPrice              %s", engine.mktPrice(weth, address(USDC)));
        console.log("weth held by pair     %s", IERC20(weth).balanceOf(pair));
    }

    function _order(bool isBid, uint256 price, uint256 amount, address recipient, uint256 value)
        internal
        returns (IMatchingEngine.OrderResult memory)
    {
        return engine.createOrder{value: value}(
            IMatchingEngine.CreateOrderInput({
                base: weth,
                quote: address(USDC),
                isBid: isBid,
                isLimit: true,
                orderId: 0,
                price: price,
                amount: amount,
                n: N,
                recipient: recipient,
                isMaker: true,
                // 0 is the venue default, NOT zero tolerance — see SeedNewExchange.
                slippageLimit: 0,
                deadline: 0
            })
        );
    }
}
