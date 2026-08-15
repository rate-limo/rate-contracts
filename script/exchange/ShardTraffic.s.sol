// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MatchingEngine} from "../../src/exchange/MatchingEngine.sol";
import {IMatchingEngine} from "../../src/exchange/interfaces/IMatchingEngine.sol";

/// @notice Puts one resting bid on each of two markets, to prove event routing across a
///         sharded broker fleet.
///
/// The broker shards by pair: `pairShardIndex` is `sha256(pairAddress) % SHARD_COUNT`,
/// fixed for a pair's lifetime. On RISE at SHARD_COUNT=2 the two live markets land on
/// different shards —
///
///   ETH/USDC    0xE33e048d8C11Bf645aE14D213C0f443707015BE7  -> shard 0
///   TITER/USDC  0x80A7D6BAd0540b57d09148A15B4f816814B52327  -> shard 1
///
/// — so one order on each is the smallest transaction pair that exercises BOTH queues.
/// A fleet with a dead shard consumes one and silently drops the other, which is the
/// failure this exists to make visible: nothing errors, and every service stays green.
///
/// Both orders are BIDS placed well BELOW the market, so they rest rather than match.
/// That keeps the test additive — no fills, no price movement, nothing to unwind beyond
/// cancelling two orders — while still emitting the OrderPlaced the indexer routes on.
/// Both pay in USDC, so it needs no TITER balance.
///
/// Required environment:
///   RISE_TESTNET_DEPLOYER_KEY
///
/// Run:
///   forge script script/exchange/ShardTraffic.s.sol:ShardTraffic \
///     --rpc-url $RPC_URL --broadcast --via-ir
contract ShardTraffic is Script {
    IERC20 constant USDC = IERC20(0x1f18a1724D8960f10165788dba3123F3f5623BB9);
    address constant TITER = 0x4251229b9CE58BE70F22829cE1D72aA2eC996f22;

    /// Deliberately below each market so the order rests instead of crossing.
    /// Venue prices are 1e8-scaled, independent of either token's decimals.
    uint256 constant ETH_BID_PRICE = 1900e8; // market is 2000
    uint256 constant TITER_BID_PRICE = 0.9e8; // market is 1

    /// 5 USDC per order — a fixture, sized so the pair of orders costs about a
    /// hundredth of the deployer's stable balance.
    uint256 constant BID_QUOTE = 5e6;

    uint32 constant N = 4;

    MatchingEngine engine;
    address weth;

    function run() external {
        uint256 key = vm.envUint("RISE_TESTNET_DEPLOYER_KEY");
        address me = vm.addr(key);

        // Same registry read as SeedNativeMarket, and for the same reason: a hardcoded
        // engine survives a redeploy and silently addresses the retired one.
        string memory registry = vm.readFile("../packages/deployments/deployments.json");
        string memory base = string.concat(".chains.", vm.toString(block.chainid), ".contracts");
        engine = MatchingEngine(payable(vm.parseJsonAddress(registry, string.concat(base, ".matchingEngine.address"))));
        require(address(engine).code.length > 0, "registry's matching engine has no code on this chain");
        weth = engine.WETH();

        address ethPair = engine.getPair(weth, address(USDC));
        address titerPair = engine.getPair(TITER, address(USDC));
        require(ethPair != address(0), "ETH/USDC is not listed");
        require(titerPair != address(0), "TITER/USDC is not listed");

        console.log("engine                %s", address(engine));
        console.log("ETH/USDC   pair       %s", ethPair);
        console.log("TITER/USDC pair       %s", titerPair);

        vm.startBroadcast(key);

        USDC.approve(address(engine), type(uint256).max);

        // Bids pay the QUOTE leg, so both of these spend USDC and neither needs a
        // balance of the base token.
        _bid(weth, ETH_BID_PRICE, BID_QUOTE, me);
        _bid(TITER, TITER_BID_PRICE, BID_QUOTE, me);

        vm.stopBroadcast();

        (uint256 ethBid,) = engine.heads(weth, address(USDC));
        (uint256 titerBid,) = engine.heads(TITER, address(USDC));
        console.log("=== resting bids after ===");
        console.log("ETH/USDC   bidHead    %s", ethBid);
        console.log("TITER/USDC bidHead    %s", titerBid);
    }

    function _bid(address baseToken, uint256 price, uint256 quoteAmount, address recipient) internal {
        engine.createOrder(
            IMatchingEngine.CreateOrderInput({
                base: baseToken,
                quote: address(USDC),
                isBid: true,
                isLimit: true,
                orderId: 0,
                price: price,
                amount: quoteAmount,
                n: N,
                recipient: recipient,
                isMaker: true,
                slippageLimit: 0,
                deadline: 0
            })
        );
    }
}
