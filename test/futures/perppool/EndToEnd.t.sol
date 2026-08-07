// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {PerpEngineBaseSetup} from "../PerpEngineBaseSetup.sol";
import {PerpPool} from "../../../src/futures/pools/PerpPool.sol";
import {PerpEngine} from "../../../src/futures/PerpEngine.sol";

contract PerpEngineEndToEndTest is PerpEngineBaseSetup {
    function testAddPoolRevertsWhenQuoteIsNotAllowlistedStablecoin() public {
        perpEngineSetUp();
        address[] memory collaterals = new address[](1);
        collaterals[0] = address(token2);

        vm.expectRevert();
        perpEngine.addPool(address(token1), address(token2), collaterals, 10, 8000, 1000e18);
    }

    function testAddPoolRevertsWhenNoSpotMarketExists() public {
        perpEngineSetUp();
        address[] memory collaterals = new address[](1);
        collaterals[0] = address(stablecoin);

        vm.expectRevert();
        perpEngine.addPool(address(token2), address(stablecoin), collaterals, 10, 8000, 1000e18);
    }

    function testAddPoolCreatesAPool() public {
        perpEngineSetUp();
        address[] memory collaterals = new address[](1);
        collaterals[0] = address(stablecoin);

        address pool = perpEngine.addPool(address(token1), address(stablecoin), collaterals, 10, 8000, 0);
        assertTrue(pool != address(0));
        assertTrue(PerpPool(pool).isAcceptedCollateral(address(stablecoin)));
    }

    function testLongOpenCloseRoundTripThroughPerpEngine() public {
        perpEngineSetUp();
        address[] memory collaterals = new address[](1);
        collaterals[0] = address(stablecoin);
        address pool = perpEngine.addPool(address(token1), address(stablecoin), collaterals, 10, 8000, 0);

        // Deviation C: PerpPool rejects every open on an unseeded pool (OpenInterestCapExceeded
        // against a zero cap), so seed operator backing capital through the engine's
        // MARKET_MAKER_ROLE-gated passthrough before any trader can act. This test contract
        // deployed PerpEngine, so it already holds MARKET_MAKER_ROLE.
        stablecoin.mint(address(this), 10000e18);
        stablecoin.approve(pool, 10000e18);
        perpEngine.seedPool(pool, address(stablecoin), 10000e18);

        vm.prank(trader1);
        stablecoin.approve(pool, 1000e18);

        vm.prank(trader1);
        uint256 positionId = perpEngine.long(pool, address(stablecoin), 100e18, 5);
        assertEq(positionId, 1);

        vm.prank(trader1);
        (int256 pnl, uint256 payout) = perpEngine.closePosition(pool, positionId);
        // price hasn't moved (still 100e8 from listing), so pnl should be 0 and payout == margin
        assertEq(pnl, 0);
        assertEq(payout, 100e18);
    }

    function testLiquidateThroughPerpEngineRoutesCollateralToPool() public {
        perpEngineSetUp();
        address[] memory collaterals = new address[](1);
        collaterals[0] = address(stablecoin);
        address pool = perpEngine.addPool(address(token1), address(stablecoin), collaterals, 10, 8000, 0);

        // Deviation C: seed the pool before opening, same as above.
        stablecoin.mint(address(this), 10000e18);
        stablecoin.approve(pool, 10000e18);
        perpEngine.seedPool(pool, address(stablecoin), 10000e18);

        vm.prank(trader1);
        stablecoin.approve(pool, 1000e18);
        vm.prank(trader1);
        uint256 positionId = perpEngine.long(pool, address(stablecoin), 100e18, 10);

        uint256 reserveBefore = PerpPool(pool).reserveOf(address(stablecoin));

        // Deviation E: a single marketSell into an otherwise-empty book may not print a trade
        // at all (a market sell with no resting bids has nothing to match, so lmp never moves),
        // and even a real print is bounded to a +/-3% move per order by the pair's default
        // limit-order spread (dfltLmtBuy/dfltLmtSEll = 3000000 / DENOM = 3%) -- nowhere near
        // enough to crash 100e8 -> 80e8 in one shot. Widen this pair's limit-order spread via
        // the real, admin-gated setSpread (this test contract holds MARKET_MAKER_ROLE on
        // matchingEngine, having deployed it in BaseSetup.setUp) so a single resting-bid /
        // taking-sell pair can print a real trade at 80e8 and move `lmp` there directly --
        // this is real MatchingEngine price discovery, not a mock or a faked price.
        matchingEngine.setSpread(address(token1), address(stablecoin), 90000000, 90000000, false);

        vm.prank(trader1);
        stablecoin.approve(address(matchingEngine), 1000e18);
        vm.prank(trader1);
        matchingEngine.limitBuy(address(token1), address(stablecoin), 80e8, 1000e18, true, 2, trader1);

        vm.prank(trader2);
        matchingEngine.limitSell(address(token1), address(stablecoin), 80e8, 10e18, true, 2, trader2);

        assertEq(matchingEngine.mktPrice(address(token1), address(stablecoin)), 80e8);

        // Captured after the price-crashing spot trades (which spend trader1's own stablecoin
        // on the resting limitBuy, unrelated to the perp position) so this measures only the
        // liquidation's effect on trader1's balance, not the market-crash mechanics above.
        uint256 traderBalBefore = stablecoin.balanceOf(trader1);

        perpEngine.liquidate(pool, positionId);

        // Deviation D: the trader's 100e18 margin already entered reserveOf at OPEN. Zero-fee
        // liquidation (the pool's default) RETAINS that margin instead of paying it back out --
        // reserveOf is unchanged by the liquidate call itself, and the trader receives nothing.
        assertEq(PerpPool(pool).reserveOf(address(stablecoin)), reserveBefore);
        assertEq(stablecoin.balanceOf(trader1), traderBalBefore);
        assertEq(PerpPool(pool).getPosition(positionId).owner, address(0));
    }

    // final-branch review I4: PerpPool.setLiquidationFeeBps/setLiquidationFeeRecipient are
    // onlyPerpEngine-gated but had no passthrough on PerpEngine, so in production the fee split
    // was permanently unreachable. This exercises the new setPoolLiquidationFee passthrough.
    function testSetPoolLiquidationFeeThroughEngine() public {
        perpEngineSetUp();
        address[] memory collaterals = new address[](1);
        collaterals[0] = address(stablecoin);
        address pool = perpEngine.addPool(address(token1), address(stablecoin), collaterals, 10, 8000, 0);

        // This test contract deployed PerpEngine, so it already holds MARKET_MAKER_ROLE.
        bool ok = perpEngine.setPoolLiquidationFee(pool, 500, address(0xFEE));
        assertTrue(ok);
        assertEq(PerpPool(pool).liquidationFeeBps(), 500);
        assertEq(PerpPool(pool).liquidationFeeRecipient(), address(0xFEE));
    }

    function testSetPoolLiquidationFeeRevertsForNonMarketMaker() public {
        perpEngineSetUp();
        address[] memory collaterals = new address[](1);
        collaterals[0] = address(stablecoin);
        address pool = perpEngine.addPool(address(token1), address(stablecoin), collaterals, 10, 8000, 0);

        bytes32 marketMakerRole = keccak256("MARKET_MAKER_ROLE");
        vm.prank(trader1);
        vm.expectRevert(abi.encodeWithSelector(PerpEngine.InvalidRole.selector, marketMakerRole, trader1));
        perpEngine.setPoolLiquidationFee(pool, 500, address(0xFEE));
    }
}
