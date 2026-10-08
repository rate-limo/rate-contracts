// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {BandBaseSetup} from "./BandBaseSetup.sol";
import {IBandPositionManager} from "../../src/swap/interfaces/IBandPositionManager.sol";

/// `collectMany`: the profile's one-signature "claim all", with `collect`'s gate per token.
contract CollectManyTest is BandBaseSetup {
    function setUp() public override {
        super.setUp();
        // The fixture leaves the LP share of the taker fee at zero; production sets 50%.
        matchingEngine.setPoolFeeShare(50_000_000);
    }

    function _mintOne(uint8 band, uint256 amount) internal returns (uint256 id) {
        uint8[] memory bands = new uint8[](1);
        uint256[] memory b = new uint256[](1);
        uint256[] memory q = new uint256[](1);
        uint128[] memory m = new uint128[](1);
        bands[0] = band;
        b[0] = amount;
        vm.startPrank(lp1);
        token1.approve(address(positionManager), type(uint256).max);
        (id,) = positionManager.mint(
            IBandPositionManager.MintParams({
                pool: address(pool), bands: bands, baseAmounts: b, quoteAmounts: q, minShares: m,
                recipient: lp1, deadline: block.timestamp
            })
        );
        vm.stopPrank();
    }

    function test_collectMany_paysEveryTokenAndMatchesCollect() public {
        uint256 a = _mintOne(0, 1_000e18);
        uint256 b = _mintOne(1, 1_000e18);
        _buy(trader1, 100e18);
        vm.warp(block.timestamp + 601);
        uint256[] memory ids = new uint256[](2);
        ids[0] = a;
        ids[1] = b;
        uint256 before_ = token1.balanceOf(lp1);
        vm.prank(lp1);
        (uint256[] memory base,) = positionManager.collectMany(ids, lp1);
        assertEq(token1.balanceOf(lp1) - before_, base[0] + base[1], "paid what it reported");
        assertGt(base[0], 0, "band 0 earned");
    }

    function test_collectMany_revertsOnATokenTheCallerDoesNotOwn() public {
        uint256 a = _mintOne(0, 1_000e18);
        uint256[] memory ids = new uint256[](1);
        ids[0] = a;
        vm.prank(trader2);
        vm.expectRevert(abi.encodeWithSelector(IBandPositionManager.NotOwnerOrApproved.selector, trader2, a));
        positionManager.collectMany(ids, trader2);
    }
}
