// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

interface IFeeMatchingEngine {
    function setPairFeeClass(address pair, uint8 feeClass, uint32 makerFee, uint32 takerFee)
        external returns (bool success);
}

/// @notice Owns Iter's configurable five-class fee schedule outside MatchingEngine.
contract PairFeeManager is AccessControl {
    uint32 public constant DENOM = 100_000_000;

    struct FeePreset {
        uint32 makerFee;
        uint32 takerFee;
    }

    address public immutable matchingEngine;
    mapping(uint8 => FeePreset) public feePreset;

    event FeePresetSet(uint8 indexed feeClass, uint32 makerFee, uint32 takerFee);
    event FeePresetApplied(address indexed pair, uint8 indexed feeClass, uint32 makerFee, uint32 takerFee);
    event PairFeeManagerInitialized(address indexed matchingEngine);

    error InvalidAddress();
    error InvalidFeeClass(uint8 feeClass);
    error InvalidFeeRate(uint32 fee, uint256 denom);

    constructor(address matchingEngine_) {
        if (matchingEngine_ == address(0)) revert InvalidAddress();
        matchingEngine = matchingEngine_;
        feePreset[0] = FeePreset(0, 10_000);
        feePreset[1] = FeePreset(0, 50_000);
        feePreset[2] = FeePreset(0, 100_000);
        feePreset[3] = FeePreset(0, 200_000);
        feePreset[4] = FeePreset(0, 300_000);
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        emit PairFeeManagerInitialized(matchingEngine_);
        for (uint8 i; i < 5; ++i) {
            emit FeePresetSet(i, feePreset[i].makerFee, feePreset[i].takerFee);
        }
    }

    function setFeePreset(uint8 feeClass, uint32 makerFee, uint32 takerFee)
        external onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (feeClass > 4) revert InvalidFeeClass(feeClass);
        if (makerFee > DENOM || takerFee > DENOM) {
            revert InvalidFeeRate(makerFee > takerFee ? makerFee : takerFee, DENOM);
        }
        feePreset[feeClass] = FeePreset(makerFee, takerFee);
        emit FeePresetSet(feeClass, makerFee, takerFee);
    }

    function applyFeePreset(address pair, uint8 feeClass)
        external onlyRole(DEFAULT_ADMIN_ROLE) returns (bool success)
    {
        if (feeClass > 4) revert InvalidFeeClass(feeClass);
        FeePreset memory preset = feePreset[feeClass];
        success = IFeeMatchingEngine(matchingEngine).setPairFeeClass(
            pair, feeClass, preset.makerFee, preset.takerFee
        );
        emit FeePresetApplied(pair, feeClass, preset.makerFee, preset.takerFee);
    }
}
