// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {ExchangeOrderbook} from "../../src/exchange/libraries/ExchangeOrderbook.sol";
import {Test} from "forge-std/Test.sol";
import {MatchingEngine} from "../../src/exchange/MatchingEngine.sol";
import {OrderbookFactory} from "../../src/exchange/orderbooks/OrderbookFactory.sol";
import {Orderbook} from "../../src/exchange/orderbooks/Orderbook.sol";
import {WETH9} from "../../src/mock/WETH9.sol";
import {MockBase} from "../../src/mock/MockBase.sol";
import {MockQuote} from "../../src/mock/MockQuote.sol";
import {PoolFactory} from "../../src/swap/PoolFactory.sol";
import {Pool} from "../../src/swap/Pool.sol";
import {Utils} from "../utils/Utils.sol";

contract PoolBaseSetup is Test {
    Utils public utils;
    MatchingEngine public matchingEngine;
    WETH9 public weth;
    OrderbookFactory public orderbookFactory;
    PoolFactory public poolFactory;
    MockBase public token1; // base
    MockQuote public token2; // quote
    Orderbook public book;
    Pool public pool;

    address payable[] public users;
    address public trader1;
    address public trader2;
    address public lp1;
    address public lp2;
    address public booker;
    address public positionManager;

    function setUp() public virtual {
        utils = new Utils();
        users = utils.createUsers(5);
        trader1 = users[0];
        trader2 = users[1];
        lp1 = users[2];
        lp2 = users[3];
        booker = users[4];
        positionManager = address(0xBEEF); // placeholder caller until Task 12 -- production
        // deployments set this to the real PositionManager contract via
        // poolFactory.setPositionManager, matching how Task 5's PoolCreationTest does it.

        token1 = new MockBase("Base", "BASE");
        token2 = new MockQuote("Quote", "QUOTE");
        weth = new WETH9();

        token1.mint(trader1, 10000000e18);
        token2.mint(trader1, 10000000e18);
        token1.mint(trader2, 10000000e18);
        token2.mint(trader2, 10000000e18);
        token1.mint(lp1, 10000000e18);
        token2.mint(lp1, 10000000e18);
        token1.mint(lp2, 10000000e18);
        token2.mint(lp2, 10000000e18);

        matchingEngine = new MatchingEngine();
        orderbookFactory = new OrderbookFactory();
        orderbookFactory.initialize(address(matchingEngine));
        matchingEngine.initialize(address(orderbookFactory), address(booker), address(weth));

        poolFactory = new PoolFactory();
        poolFactory.initialize(address(matchingEngine));
        poolFactory.setPositionManager(positionManager);
        matchingEngine.setPoolFactory(address(poolFactory));

        // 10% each side -- comfortable headroom above the 5% slippageLimit positions used
        // throughout test/swap/Swap.t.sol (Task 10+); MatchingEngine._limitBuy/_limitSell
        // clamp actual matching to this admin-configured bound regardless of what price a
        // caller (including Pool.swap's boundPrice) requests, so it must be at least as
        // wide as the widest slippageLimit any swap test exercises, or swaps will safely
        // fail to match at all (docs/swap/design.md §4.6, point 3).
        matchingEngine.setDefaultSpread(10000000, 10000000, true);
        matchingEngine.setDefaultSpread(10000000, 10000000, false);
        matchingEngine.setDefaultFee(true, 100000);
        matchingEngine.setDefaultFee(false, 100000);

        // Pool.swap is onlyRouter, and the address it checks lives on the engine. These
        // pool-unit tests exercise the pool directly with trader1 as the caller, so
        // trader1 stands in as the router here -- it already holds the tokens and has
        // approved the pool, which a real router would. Suites that want the genuine
        // article (Router.t.sol, SwapPriceReport.t.sol) overwrite this in their own
        // setUp with the deployed SwapRouter.
        matchingEngine.setSwapRouter(trader1);

        vm.prank(trader1);
        token1.approve(address(matchingEngine), 10000000e18);
        vm.prank(trader1);
        token2.approve(address(matchingEngine), 10000000e18);
        vm.prank(trader2);
        token1.approve(address(matchingEngine), 10000000e18);
        vm.prank(trader2);
        token2.approve(address(matchingEngine), 10000000e18);

        matchingEngine.addPair(address(token1), address(token2), 100e8, 0, address(token1), ExchangeOrderbook.MatchingMode.PriceTimePriority);
        // Advance past the TWAP oracle's minimum history window so Pool.swap's
        // Orderbook.twap(600) call (Task 10+) doesn't revert InsufficientHistory on a
        // freshly-listed pair. Hardcoded 600 rather than referencing Pool.TWAP_WINDOW so
        // this fixture doesn't take a compile-time dependency on a swap-specific value --
        // same reasoning as the spread-widening above.
        vm.warp(block.timestamp + 600);
        address bookAddr = matchingEngine.getPair(address(token1), address(token2));
        book = Orderbook(payable(bookAddr));
        address poolAddr = poolFactory.getPool(address(token1), address(token2));
        pool = Pool(poolAddr);
    }
}
