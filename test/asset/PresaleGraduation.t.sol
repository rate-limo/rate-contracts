// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {ExchangeOrderbook} from "../../src/exchange/libraries/ExchangeOrderbook.sol";
import {PresaleLaunch} from "../../src/asset/PresaleLaunch.sol";
import {BandPool} from "../../src/swap/BandPool.sol";
import {IBandPositionManager} from "../../src/swap/interfaces/IBandPositionManager.sol";
import {BandBaseSetup} from "../swap/BandBaseSetup.sol";

/**
 * Graduation against the real engine, factory and manager -- the path where a presale
 * becomes a listed pair with a v2 LP token.
 *
 * `graduate` lists the pair itself, and `MatchingEngine.addPair` names its CALLER as the
 * pool's creator. Without the hand-over in `graduate` the launch contract would own the
 * ladder forever and nobody could ever configure a graduated pair's bands.
 */
contract PresaleGraduationTest is BandBaseSetup {
    PresaleLaunch internal launch;
    address internal saleCreator = address(0xA11CE);
    address internal treasury = address(0xB0B);

    function setUp() public override {
        super.setUp();
        launch = new PresaleLaunch(
            address(this), address(matchingEngine), address(positionManager), address(0), address(token2)
        );
    }

    function _create() internal returns (uint256 id, address coin) {
        PresaleLaunch.CreateParams memory p = PresaleLaunch.CreateParams({
            name: "White Coin",
            symbol: "WHITE",
            totalSupply: 100_000_000e18,
            presaleAllocation: 10_000_000e18,
            lpTokenAllocation: 2_000_000e18,
            priceQuotePerToken: 10_000,
            targetRaise: 100_000e18,
            minimumRaise: 50_000e18,
            maxPerWallet: 100_000e18,
            creatorTokenAllocation: 20_000_000e18,
            treasuryTokenAllocation: 68_000_000e18,
            startAt: uint64(block.timestamp),
            endAt: uint64(block.timestamp + 1 days),
            creatorCliff: 90 days,
            creatorVestingDuration: 365 days,
            lpBps: 2_000,
            quote: address(token2),
            treasury: treasury
        });
        vm.prank(saleCreator);
        (id, coin) = launch.createPresale(p);
    }

    function _graduated() internal returns (address coin, address pool, uint256 tokenId) {
        uint256 id;
        (id, coin) = _create();
        vm.startPrank(trader1);
        token2.approve(address(launch), type(uint256).max);
        launch.commit(id, 60_000e18);
        vm.stopPrank();
        vm.warp(block.timestamp + 1 days);
        launch.finalizeSale(id);
        vm.prank(saleCreator);
        launch.configureGraduation(
            id,
            PresaleLaunch.GraduationConfig({
                listingPrice: 1e8,
                minPrice: 1,
                maxPrice: type(uint256).max,
                lpSlippageLimit: 1_000_000,
                volatilityBps: 100,
                makerFee: 0,
                takerFee: 100_000,
                liquidityLockDuration: 30 days,
                mode: ExchangeOrderbook.MatchingMode.PriceTimePriority
            })
        );
        tokenId = positionManager.nextTokenId();
        launch.graduate(id);
        pool = poolFactory.getPool(coin, address(token2));
    }

    function test_graduate_handsThePoolToTheSaleCreator() public {
        (, address pool,) = _graduated();
        assertTrue(pool != address(0), "graduation listed a pool");
        assertEq(BandPool(pool).creator(), saleCreator, "the sale's creator configures the bands");
    }

    function test_graduate_mintsOneV2TokenOnBandZero() public {
        (, address pool, uint256 tokenId) = _graduated();
        assertEq(positionManager.balanceOf(address(launch), tokenId), 1, "locked in the launch contract");
        IBandPositionManager.PositionView memory v = positionManager.positionOf(tokenId);
        assertEq(v.pool, pool);
        assertEq(v.bands.length, 1, "one band");
        assertEq(v.bands[0].band, 0, "the tightest");
        assertGt(v.bands[0].shares, 0);
    }

    function test_graduate_syncsThePairLimitIntoThePool() public {
        (address coin, address pool,) = _graduated();
        address pair = matchingEngine.getPair(coin, address(token2));
        assertEq(BandPool(pool).pairLimit(true), matchingEngine.getSpread(pair, true, true));
        assertEq(BandPool(pool).pairLimit(false), matchingEngine.getSpread(pair, false, true));
        assertGt(BandPool(pool).pairLimit(true), 0, "bands are live, not idle");
    }

    function test_releaseLiquidity_movesTheWholeLadderToken() public {
        (,, uint256 tokenId) = _graduated();
        vm.warp(block.timestamp + 30 days);
        vm.prank(saleCreator);
        launch.releaseLiquidity(1, saleCreator);
        assertEq(positionManager.balanceOf(saleCreator, tokenId), 1);
        assertEq(positionManager.holderOf(tokenId), saleCreator, "the manager tracks the new holder");
    }
}
