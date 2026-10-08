// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {console2} from "forge-std/console2.sol";
import {BandBaseSetup} from "../BandBaseSetup.sol";
import {IBandPositionManager} from "../../../src/swap/interfaces/IBandPositionManager.sol";

/**
 * What each LP path costs in v2, where ONE token holds the whole ladder, against the v1
 * baseline where one token held one band.
 *
 * The setup is the v1 probe's (GasLpShapeProbe, deleted with this file's arrival): the
 * real stack, `_seedBands(1_000e18)` so every band already has an LP, and a second LP
 * depositing 100e18 base per band. The engine's pool fee share is left at its shipped
 * zero, as it was for the baseline, except in the one row that says otherwise.
 *
 * v1 baseline -- GasLpShapeProbe run against the v1 sources at 3faf1cf7 with
 * `forge test --isolate` (each external call its own transaction, cold storage):
 *
 *   A  addLiquidity, 1 band                      279,422
 *   B  addLiquidityAcross, 3 bands (3 tokens)    666,526
 *   C  addLiquidityAcross, 1 band                283,311
 *   D  BandPool.addLiquidity (pool only)         145,895
 *   E  removeLiquidity, 1 token, full             94,191
 *   F  full exit of a 3-band deposit (3 txs)     282,435
 *   G  collectMany, 3 tokens                      99,045
 *   H  transfer 1 token                           60,700
 *
 * v2, the same file under `--isolate` on 2026-09-26 (plain mode in brackets -- there the
 * mint's storage is still warm for every later row, so only the mint rows compare):
 *
 *   mint, 1 band                                 255,080  [273,848]   v1 A 279,422
 *   mint, 3 bands, ONE token                     369,522  [387,074]   v1 B 666,526
 *   top-up, 1 band, same token                   142,086              (no v1 path)
 *   decrease 100%, 3 bands, one tx               189,665              v1 F 282,435
 *   collect, 3 bands (fee share 0)                89,944              v1 G  99,045
 *   collect, 3 bands, paying fees                219,078              (v1 G paid nothing)
 *   redistribute 3 bands to 60/30/10             309,348              (no v1 path)
 *   transfer the token                            60,571              v1 H  60,700
 *
 * The ceiling asserted on a 3-band mint must hold in plain `forge test`, which is what
 * CI runs; it holds in both modes.
 */
contract GasV2Test is BandBaseSetup {
    uint256 internal constant MINT3_CEILING = 435_000;

    address internal lp2;

    function setUp() public override {
        super.setUp();
        lp2 = trader1;
        _seedBands(1_000e18);
        vm.startPrank(lp2);
        token1.approve(address(positionManager), type(uint256).max);
        token2.approve(address(positionManager), type(uint256).max);
        vm.stopPrank();
    }

    function _g(uint256 g0) internal view returns (uint256) {
        return g0 - gasleft();
    }

    function _p(uint256 n) internal view returns (IBandPositionManager.MintParams memory p) {
        p.pool = address(pool);
        p.bands = new uint8[](n);
        p.baseAmounts = new uint256[](n);
        p.quoteAmounts = new uint256[](n);
        p.minShares = new uint128[](n);
        for (uint256 i = 0; i < n; i++) {
            p.bands[i] = uint8(i);
            p.baseAmounts[i] = 100e18;
        }
        p.recipient = lp2;
        p.deadline = block.timestamp;
    }

    function _mint3() internal returns (uint256 id) {
        IBandPositionManager.MintParams memory p = _p(3);
        vm.prank(lp2);
        (id,) = positionManager.mint(p);
    }

    /// v1 A / C: 279,422 / 283,311.
    function test_gas_mint1Band() public {
        IBandPositionManager.MintParams memory p = _p(1);
        vm.prank(lp2);
        uint256 g0 = gasleft();
        positionManager.mint(p);
        console2.log("v2 mint, 1 band", _g(g0));
    }

    /// v1 B: 666,526 for three tokens.
    function test_gas_mint3Bands() public {
        IBandPositionManager.MintParams memory p = _p(3);
        vm.prank(lp2);
        uint256 g0 = gasleft();
        positionManager.mint(p);
        uint256 used = _g(g0);
        console2.log("v2 mint, 3 bands (1 token)", used);
        assertLe(used, MINT3_CEILING, "a 3-band mint must stay under the ceiling");
    }

    /// No v1 equivalent: v1 minted a new token for every deposit.
    function test_gas_topUp1Band() public {
        uint256 id = _mint3();
        vm.warp(block.timestamp + 60);
        uint8[] memory bands = new uint8[](1);
        uint256[] memory base = new uint256[](1);
        base[0] = 100e18;
        vm.prank(lp2);
        uint256 g0 = gasleft();
        positionManager.increaseLiquidity(id, bands, base, new uint256[](1), new uint128[](1), block.timestamp);
        console2.log("v2 top-up, 1 band, same token", _g(g0));
    }

    /// v1 F: 282,435 across three transactions.
    function test_gas_decrease100Pct3Bands() public {
        uint256 id = _mint3();
        vm.warp(block.timestamp + 700);
        vm.prank(lp2);
        uint256 g0 = gasleft();
        positionManager.decreaseLiquidity(id, 10_000, 0, 0, lp2, block.timestamp);
        console2.log("v2 decrease 100%, 3 bands (1 tx)", _g(g0));
    }

    /// v1 G: 99,045 for collectMany over three tokens, fee share at zero.
    function test_gas_collect3Bands() public {
        uint256 id = _mint3();
        _buy(trader2, 50e18);
        vm.warp(block.timestamp + 700);
        vm.prank(lp2);
        uint256 g0 = gasleft();
        positionManager.collect(id, lp2);
        console2.log("v2 collect, 3 bands (fee share 0, as v1 G)", _g(g0));
    }

    /// The same collect with fees actually accruing, so it pays out.
    function test_gas_collect3BandsWithFees() public {
        matchingEngine.setPoolFeeShare(50000000);
        uint256 id = _mint3();
        _buy(trader2, 500_000e18); // through every band
        vm.warp(block.timestamp + 700);
        vm.prank(lp2);
        uint256 g0 = gasleft();
        (uint256 paid,) = positionManager.collect(id, lp2);
        console2.log("v2 collect, 3 bands, paying fees", _g(g0));
        assertGt(paid, 0, "the row measures a real payout");
    }

    /// No v1 equivalent: v1 had to withdraw and re-deposit.
    function test_gas_redistribute3Bands() public {
        uint256 id = _mint3();
        uint8[] memory bands = new uint8[](3);
        uint16[] memory targets = new uint16[](3);
        for (uint8 i = 0; i < 3; i++) {
            bands[i] = i;
        }
        targets[0] = 6_000;
        targets[1] = 3_000;
        targets[2] = 1_000;
        IBandPositionManager.RedistributeParams memory p = IBandPositionManager.RedistributeParams({
            tokenId: id,
            bands: bands,
            targetBps: targets,
            minSharesAfter: new uint128[](3),
            refundTo: lp2,
            deadline: block.timestamp
        });
        vm.prank(lp2);
        uint256 g0 = gasleft();
        positionManager.redistribute(p);
        console2.log("v2 redistribute 3 bands to 60/30/10", _g(g0));
    }

    /// v1 H: 60,700.
    function test_gas_transfer() public {
        uint256 id = _mint3();
        vm.prank(lp2);
        uint256 g0 = gasleft();
        positionManager.safeTransferFrom(lp2, trader2, id, 1, "");
        console2.log("v2 transfer 1 token (whole ladder)", _g(g0));
    }
}
