// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8;

import {ExchangeOrderbook} from "../../src/exchange/libraries/ExchangeOrderbook.sol";
import {PoolBaseSetup} from "./PoolBaseSetup.sol";
import {SwapRouter} from "../../src/swap/SwapRouter.sol";
import {ISwapRouter} from "../../src/swap/interfaces/ISwapRouter.sol";
import {Pool} from "../../src/swap/Pool.sol";
import {MockQuote} from "../../src/mock/MockQuote.sol";
import {console2} from "forge-std/console2.sol";

// Measurement harness (untracked): STANDALONE-TX STEADY-STATE gas.
//
// Two distinct effects separate a pair's first-ever swap from its Nth:
//  1. STATE (permanent): feeTo/recipient balance slots are nonzero after the first swap,
//     so later swaps pay ~2.9k instead of 20k per SSTORE (EIP-2200). Real saving, forever.
//  2. WARMTH (per-transaction): EIP-2929 cold-access costs reset every transaction, so a
//     warm-up swap in the SAME test tx as the measurement (foundry runs one test = one tx)
//     leaks intra-tx warmth a standalone swap never gets and UNDERSTATES real gas.
// Foundry runs setUp() as a separate transaction from the test body, so: seeding + the
// warm-up swap live in setUp (state committed, warmth discarded), and the test body's
// measured swap is a clean standalone steady-state transaction.
abstract contract SteadyBase is PoolBaseSetup {
    function matchesN() internal pure virtual returns (uint256);

    function setUp() public virtual override {
        super.setUp();
        vm.startPrank(trader1);
        token1.approve(address(pool), type(uint256).max);
        token2.approve(address(pool), type(uint256).max);
        vm.stopPrank();
        vm.prank(lp1);
        token1.approve(address(pool), type(uint256).max);

        uint256 n = matchesN();
        for (uint256 i = 0; i < n; i++) {
            vm.prank(positionManager);
            pool.addLiquidity(50e8, 150e8, uint32(1000000 + i * 400000), 2e18, 0, lp1);
        }
        // warm-up: commits nonzero feeTo balances (and recipient output balance) as STATE
        vm.prank(trader1);
        pool.swap(1e18, true, trader1, false);
    }

    function testSteadySwap() public {
        uint256 amountIn = 190e18 * matchesN();
        vm.prank(trader1);
        uint256 g0 = gasleft();
        (uint256 amountOut,,) = pool.swap(amountIn, true, trader1, false);
        uint256 used = g0 - gasleft();
        require(amountOut > 0, "no out");
        console2.log(matchesN(), used);
    }
}

contract Steady1 is SteadyBase { function matchesN() internal pure override returns (uint256) { return 1; } }
contract Steady2 is SteadyBase { function matchesN() internal pure override returns (uint256) { return 2; } }
contract Steady3 is SteadyBase { function matchesN() internal pure override returns (uint256) { return 3; } }
contract Steady5 is SteadyBase { function matchesN() internal pure override returns (uint256) { return 5; } }
contract Steady10 is SteadyBase { function matchesN() internal pure override returns (uint256) { return 10; } }
contract Steady20 is SteadyBase { function matchesN() internal pure override returns (uint256) { return 20; } }

// Router totals under the same standalone-tx steady-state discipline.
abstract contract SteadyRouterBase is PoolBaseSetup {
    SwapRouter router;
    ISwapRouter.RemainderConfig empty;
    MockQuote token3;
    Pool secondPool;

    function hops() internal pure virtual returns (uint256);

    function setUp() public virtual override {
        super.setUp();
        router = new SwapRouter(address(poolFactory));
        // Pool.swap is onlyRouter and reads the address off the engine, so this suite's
        // own router has to replace PoolBaseSetup's trader1 stand-in.
        matchingEngine.setSwapRouter(address(router));
        vm.startPrank(trader1);
        token1.approve(address(router), type(uint256).max);
        token2.approve(address(router), type(uint256).max);
        vm.stopPrank();
        vm.startPrank(lp1);
        token1.approve(address(pool), type(uint256).max);
        token2.approve(address(pool), type(uint256).max);
        vm.stopPrank();
        vm.prank(positionManager);
        pool.addLiquidity(50e8, 150e8, 5000000, 1000e18, 1000e18, lp1);

        if (hops() == 2) {
            token3 = new MockQuote("Quote2", "QUOTE2");
            token3.mint(lp1, 10000e18);
            matchingEngine.addPair(
                address(token1), address(token3), 1e8, 1, address(token1), ExchangeOrderbook.MatchingMode.PriceTimePriority
            );
            secondPool = Pool(poolFactory.getPool(address(token1), address(token3)));
            vm.warp(block.timestamp + 600);
            vm.prank(lp1);
            token3.approve(address(secondPool), type(uint256).max);
            vm.prank(positionManager);
            secondPool.addLiquidity(5e7, 15e7, 5000000, 0, 5000e18, lp1);
        }

        // warm-up route (separate tx from the measurement): commits steady fee/recipient state
        vm.prank(trader1);
        router.swap(_path(), 1e18, 0, trader1, ISwapRouter.RemainderMode.Refund, empty);
    }

    function _path() internal view returns (address[] memory path) {
        if (hops() == 1) {
            path = new address[](2);
            path[0] = address(token2);
            path[1] = address(token1);
        } else {
            path = new address[](3);
            path[0] = address(token2);
            path[1] = address(token1);
            path[2] = address(token3);
        }
    }

    function testSteadyRoute() public {
        vm.prank(trader1);
        uint256 g0 = gasleft();
        uint256 amountOut = router.swap(_path(), 50e18, 0, trader1, ISwapRouter.RemainderMode.Refund, empty);
        uint256 used = g0 - gasleft();
        require(amountOut > 0, "no out");
        console2.log(hops(), used);
    }
}

contract SteadyRouter1 is SteadyRouterBase { function hops() internal pure override returns (uint256) { return 1; } }
contract SteadyRouter2 is SteadyRouterBase { function hops() internal pure override returns (uint256) { return 2; } }
