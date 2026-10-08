// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {Vm} from "forge-std/Vm.sol";
import {BandPoolBase} from "./BandPoolBase.sol";

/// The two events a consumer reconstructs fees from: `Collect` (vested, never a forfeit)
/// and `DecreaseLiquidity` (principal out, and the forfeit that went with it).
contract BandPoolClaimEventTest is BandPoolBase {
    event Collect(uint256 indexed tokenId, address indexed recipient, uint256 base, uint256 quote);
    event DecreaseLiquidity(
        uint256 indexed tokenId,
        uint8[] bands,
        uint128[] shares,
        uint256 baseOut,
        uint256 quoteOut,
        uint256 forfeitBase,
        uint256 forfeitQuote,
        bool forfeitToProtocol
    );

    function test_matureCollectEmitsEverythingAccrued() public {
        uint256 id = _addTo(0, 1_000e18);
        _addTo(0, 1_000e18);
        _swap(100e18);
        uint256 raw = _rawOwedBase(id);
        vm.warp(block.timestamp + 601);

        vm.expectEmit(true, true, true, true);
        emit Collect(id, address(this), raw, 0);
        _collect(id, address(this));
    }

    function test_earlyExitEmitsTheForfeitAndSaysItWasRedistributed() public {
        _addTo(0, 1_000e18);
        uint256 jit = _addTo(0, 1_000e18);
        _swap(100e18);
        uint256 raw = _rawOwedBase(jit);
        uint128 shares = _view(jit).shares;
        (uint256 baseRes, uint256 quoteRes) = pool.bandReserves(0);
        (, uint256 total,,,) = pool.bands(0);

        uint8[] memory bands = new uint8[](1);
        uint128[] memory removed = new uint128[](1);
        removed[0] = shares;
        vm.expectEmit(true, true, true, true);
        emit DecreaseLiquidity(
            jit, bands, removed, (baseRes * shares) / total, (quoteRes * shares) / total, raw, 0, false
        );
        _decrease(jit, 10_000, address(this));
    }

    function test_soleLpForfeitSaysItWentToTheProtocol() public {
        uint256 only = _addTo(0, 1_000e18);
        _swap(100e18);
        uint256 raw = _rawOwedBase(only);
        vm.recordLogs();
        _decrease(only, 10_000, address(this));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic =
            keccak256("DecreaseLiquidity(uint256,uint8[],uint128[],uint256,uint256,uint256,uint256,bool)");
        uint256 found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(pool) || logs[i].topics[0] != topic) continue;
            (,,,, uint256 forfeitBase,, bool toProtocol) =
                abi.decode(logs[i].data, (uint8[], uint128[], uint256, uint256, uint256, uint256, bool));
            assertEq(forfeitBase, raw, "the whole unvested fee");
            assertTrue(toProtocol, "no other shares, so the protocol");
            found++;
        }
        assertEq(found, 1);
    }

    function test_aCollectWithNothingAccruedIsSilent() public {
        uint256 id = _addTo(0, 1_000e18);
        vm.recordLogs();
        _collect(id, address(this));
        assertEq(vm.getRecordedLogs().length, 0, "no zero-valued claim");
    }
}
