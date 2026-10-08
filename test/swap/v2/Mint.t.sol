// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {Vm} from "forge-std/Vm.sol";
import {V2Base} from "./V2Base.sol";
import {PoolPositions} from "../../../src/swap/PoolPositions.sol";
import {IBandPool} from "../../../src/swap/interfaces/IBandPool.sol";
import {IBandPositionManager} from "../../../src/swap/interfaces/IBandPositionManager.sol";

/// A mint across any number of bands is ONE token holding all of them.
contract V2MintTest is V2Base {
    function test_mintAcrossOneTwoAndThreeBandsGivesOneTokenEach() public {
        for (uint8 n = 1; n <= 3; n++) {
            uint8[] memory bands = new uint8[](n);
            for (uint8 i = 0; i < n; i++) {
                bands[i] = i;
            }
            uint256 expectedId = positionManager.nextTokenId();
            (uint256 id, uint128[] memory shares) = _mint(alice, bands, _fill(n, 100e18), _fill(n, 0));

            assertEq(id, expectedId, "the id nextTokenId announced");
            assertEq(positionManager.nextTokenId(), id + 1);
            assertEq(positionManager.balanceOf(alice, id), 1, "one token, amount 1");
            assertEq(shares.length, n, "shares per band, in band order");

            IBandPositionManager.PositionView memory v = positionManager.positionOf(id);
            assertEq(v.pool, address(pool));
            assertEq(v.holder, alice);
            assertEq(v.base, address(token1));
            assertEq(v.quote, address(token2));
            assertEq(v.mintedAt, block.timestamp);
            assertEq(v.bands.length, n, "positionOf lists every band");
            assertEq(v.bandMask, uint8((1 << n) - 1));
            for (uint8 i = 0; i < n; i++) {
                assertEq(v.bands[i].band, i);
                assertEq(v.bands[i].shares, shares[i], "the slot holds what mint reported");
                assertGt(shares[i], 0);
            }
        }
    }

    function test_idsStartAtOne() public {
        assertEq(positionManager.nextTokenId(), 1);
        uint256 id = _mintBase(alice, _b(0), 1e18);
        assertEq(id, 1, "token 0 would read as 'no position' downstream");
    }

    function test_mintEmitsOneIncreaseLiquidityForTheWholeLadder() public {
        vm.recordLogs();
        (uint256 id, uint128[] memory shares) = _mint(alice, _b(0, 1, 2), _fill(3, 10e18), _fill(3, 0));
        (uint256 count, Vm.Log memory log) =
            _poolLog(vm.getRecordedLogs(), keccak256("IncreaseLiquidity(uint256,uint8[],uint128[],uint256,uint256)"));
        assertEq(count, 1, "one event, not one per band");
        assertEq(uint256(log.topics[1]), id);
        (uint8[] memory bands, uint128[] memory logged, uint256 baseIn, uint256 quoteIn) =
            abi.decode(log.data, (uint8[], uint128[], uint256, uint256));
        assertEq(bands.length, 3);
        assertEq(bands[2], 2);
        assertEq(logged[2], shares[2]);
        assertEq(baseIn, 30e18);
        assertEq(quoteIn, 0);
    }

    /// A band's ratio decides what is used; the manager hands back the rest in the same tx.
    function test_whatTheBandsRatioDoesNotUseIsRefunded() public {
        // 1 base : 50 quote.
        _mint(alice, _b(0), _u(1_000e18), _u(50_000e18));

        uint256 base0 = token1.balanceOf(bob);
        uint256 quote0 = token2.balanceOf(bob);
        // Offers twice the quote the ratio wants for 100 base.
        (, uint128[] memory shares) = _mint(bob, _b(0), _u(100e18), _u(10_000e18));

        assertEq(shares[0], 100e18, "minted on the lesser side");
        assertEq(base0 - token1.balanceOf(bob), 100e18, "base fully used");
        assertEq(quote0 - token2.balanceOf(bob), 5_000e18, "half the quote came back");
        assertEq(token1.balanceOf(address(positionManager)), 0, "nothing stranded");
        assertEq(token2.balanceOf(address(positionManager)), 0, "nothing stranded");
        assertEq(token2.allowance(address(positionManager), address(pool)), 0, "approval cleared");
    }

    /// Refunds are per band but settled once: a quote offer into a base-only band comes back whole.
    function test_aSideABandCannotHoldIsRefundedWhole() public {
        _mintBase(alice, _b(0, 1), 1_000e18);
        uint256 quote0 = token2.balanceOf(bob);
        _mint(bob, _b(0, 1), _u(10e18, 10e18), _u(7e18, 9e18));
        assertEq(token2.balanceOf(bob), quote0, "base-only bands take no quote");
    }

    function test_minSharesIsPerBand() public {
        IBandPositionManager.MintParams memory p = _params(_b(0, 1), _fill(2, 100e18), _fill(2, 0), alice);
        p.minShares[0] = 100e18; // exactly what the first deposit mints: passes
        p.minShares[1] = 100e18 + 1;
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IBandPositionManager.SharesBelowMinimum.selector, uint8(1), uint128(100e18), uint128(100e18 + 1)
            )
        );
        positionManager.mint(p);

        p.minShares[1] = 100e18;
        vm.prank(alice);
        positionManager.mint(p);
    }

    function test_bandsMustBeStrictlyAscending() public {
        uint256 next = positionManager.nextTokenId();
        uint256 spent = token1.balanceOf(alice);
        vm.startPrank(alice);
        vm.expectRevert(IBandPositionManager.BandsNotAscending.selector);
        positionManager.mint(_params(_b(1, 0), _fill(2, 1e18), _fill(2, 0), alice));
        vm.expectRevert(IBandPositionManager.BandsNotAscending.selector);
        positionManager.mint(_params(_b(0, 0), _fill(2, 1e18), _fill(2, 0), alice));
        vm.stopPrank();
        assertEq(positionManager.nextTokenId(), next, "a refused mint takes no id");
        assertEq(token1.balanceOf(alice), spent, "and spends nothing");
    }

    function test_arraysMustLineUp() public {
        vm.startPrank(alice);
        vm.expectRevert(IBandPositionManager.LengthMismatch.selector);
        positionManager.mint(_params(_b(0, 1), _fill(1, 1e18), _fill(2, 0), alice));
        vm.expectRevert(IBandPositionManager.LengthMismatch.selector);
        positionManager.mint(_params(_b(0, 1), _fill(2, 1e18), _fill(1, 0), alice));
        IBandPositionManager.MintParams memory p = _params(_b(0, 1), _fill(2, 1e18), _fill(2, 0), alice);
        p.minShares = _mins(1);
        vm.expectRevert(IBandPositionManager.LengthMismatch.selector);
        positionManager.mint(p);
        vm.expectRevert(IBandPositionManager.LengthMismatch.selector);
        positionManager.mint(_params(new uint8[](0), new uint256[](0), new uint256[](0), alice));
        vm.stopPrank();
    }

    function test_onlyAPoolTheFactoryClonedIsAccepted() public {
        address[3] memory fakes = [address(0), address(0xDEAD), address(book)];
        for (uint256 i = 0; i < fakes.length; i++) {
            IBandPositionManager.MintParams memory p = _params(_b(0), _u(1e18), _u(0), alice);
            p.pool = fakes[i];
            vm.prank(alice);
            vm.expectRevert(abi.encodeWithSelector(IBandPositionManager.UnknownPool.selector, fakes[i]));
            positionManager.mint(p);
        }
    }

    function test_aPassedDeadlineIsRefused() public {
        IBandPositionManager.MintParams memory p = _params(_b(0), _u(1e18), _u(0), alice);
        p.deadline = block.timestamp - 1;
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IBandPositionManager.DeadlinePassed.selector, block.timestamp - 1, block.timestamp)
        );
        positionManager.mint(p);

        p.deadline = block.timestamp; // inclusive
        vm.prank(alice);
        positionManager.mint(p);
    }

    function test_theTokenGoesToTheRecipientNotTheCaller() public {
        vm.prank(alice);
        (uint256 id,) = positionManager.mint(_params(_b(0), _u(1e18), _u(0), bob));
        assertEq(positionManager.balanceOf(bob, id), 1);
        assertEq(positionManager.balanceOf(alice, id), 0);
        assertEq(positionManager.holderOf(id), bob);
    }

    function test_aBandThatDoesNotExistIsRefused() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(PoolPositions.BadBand.selector, uint8(3)));
        positionManager.mint(_params(_b(0, 3), _fill(2, 1e18), _fill(2, 0), alice));
    }

    function test_positionViewAgreesWithThePool() public {
        uint256 id = _mintBase(alice, _b(0, 2), 5e18);
        IBandPool.BandView[] memory held = _held(id);
        assertEq(held.length, 2);
        assertEq(held[1].band, 2);
        assertEq(pool.bandMaskOf(id), 0x5);
    }
}
