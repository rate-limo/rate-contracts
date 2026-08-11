// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {BaseSetup} from "../OrderbookBaseSetup.sol";
import {ExchangeOrderbook} from "../../../src/exchange/libraries/ExchangeOrderbook.sol";
import {MarketListingRegistry} from "../../../src/exchange/MarketListingRegistry.sol";
import {PairFeeManager} from "../../../src/exchange/PairFeeManager.sol";
import {Vm} from "forge-std/Vm.sol";

contract ListingStrategyTest is BaseSetup {
    MarketListingRegistry private registry;
    PairFeeManager private feeManager;
    uint96 private constant ESTABLISHED_BOND = 500e18;
    uint96 private constant STANDARD_BOND = 1_000e18;
    uint96 private constant HIGH_RISK_BOND = 2_000e18;
    uint64 private constant REVIEW_PERIOD = 30 days;

    function setUp() public override {
        super.setUp();
        uint96[3] memory bonds = [ESTABLISHED_BOND, STANDARD_BOND, HIGH_RISK_BOND];
        registry = new MarketListingRegistry(
            address(matchingEngine), address(token2), booker, REVIEW_PERIOD, bonds
        );
        feeManager = new PairFeeManager(address(matchingEngine));
        matchingEngine.setFeeManager(address(feeManager));

        vm.prank(trader1);
        token2.approve(address(registry), type(uint256).max);
        vm.prank(trader2);
        token2.approve(address(registry), type(uint256).max);
    }

    function _createPair(address creator) private returns (address pair) {
        vm.prank(creator);
        pair = matchingEngine.addPair(
            address(token1), address(token2), 100e8, 0, address(token2),
            ExchangeOrderbook.MatchingMode.PriceTimePriority
        );
    }

    function testPermissionlessPairCreationChargesNoProtocolListingFee() public {
        uint256 beforeBalance = token2.balanceOf(trader1);
        vm.recordLogs();
        address pair = _createPair(trader1);
        assertTrue(pair != address(0));
        assertEq(token2.balanceOf(trader1), beforeBalance);
        assertFalse(registry.isVerified(pair));

        bytes32 pairAddedTopic = keccak256(
            "PairAdded(address,address,(address,uint8,string,string,uint256),(address,uint8,string,string,uint256),uint256,uint256,string)"
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length != 0 && logs[i].topics[0] == pairAddedTopic) {
                assertEq(logs[i].emitter, address(matchingEngine));
                assertEq(address(uint160(uint256(logs[i].topics[1]))), pair);
                assertEq(address(uint160(uint256(logs[i].topics[2]))), trader1);
                found = true;
            }
        }
        assertTrue(found, "indexed pair creator event missing");
    }

    function testLegacyNativeListingPaymentIsRejectedInsteadOfTrapped() public {
        vm.deal(trader1, 1 ether);
        vm.prank(trader1);
        (bool success,) = address(matchingEngine).call{value: 1 ether}(
            abi.encodeWithSignature(
                "addPairETH(address,address,uint256,uint256,uint8)",
                address(token1), address(token2), 100e8, 0,
                ExchangeOrderbook.MatchingMode.PriceTimePriority
            )
        );
        assertFalse(success, "obsolete payable listing selector must reject value");
    }

    function testVerifiedBondIsLockedThenRefundedWithoutRemovingVerification() public {
        address pair = _createPair(trader1);
        uint256 beforeBalance = token2.balanceOf(trader1);
        vm.prank(trader1);
        registry.requestVerification(address(token1), address(token2), 1);
        assertEq(token2.balanceOf(trader1), beforeBalance - STANDARD_BOND);

        registry.approve(pair);
        assertTrue(registry.isVerified(pair));

        vm.prank(trader1);
        vm.expectRevert();
        registry.withdrawBond(pair);

        vm.warp(block.timestamp + REVIEW_PERIOD);
        vm.prank(trader1);
        assertEq(registry.withdrawBond(pair), STANDARD_BOND);
        assertEq(token2.balanceOf(trader1), beforeBalance);
        assertTrue(registry.isVerified(pair));
    }

    function testApplicantCanCancelPendingRequestForFullRefund() public {
        address pair = _createPair(trader1);
        uint256 beforeBalance = token2.balanceOf(trader1);
        vm.prank(trader1);
        registry.requestVerification(address(token1), address(token2), 0);
        vm.prank(trader1);
        registry.cancelRequest(pair);
        assertEq(token2.balanceOf(trader1), beforeBalance);
        assertFalse(registry.isVerified(pair));
    }

    function testRejectedBondCanBeSlashedWithReason() public {
        address pair = _createPair(trader1);
        uint256 treasuryBefore = token2.balanceOf(booker);
        vm.prank(trader1);
        registry.requestVerification(address(token1), address(token2), 2);
        registry.reject(pair, true, keccak256("undisclosed-transfer-tax"));
        assertEq(token2.balanceOf(booker) - treasuryBefore, HIGH_RISK_BOND);
        assertFalse(registry.isVerified(pair));
    }

    function testApprovedBondCanBeSlashedDuringReviewWindow() public {
        address pair = _createPair(trader1);
        uint256 treasuryBefore = token2.balanceOf(booker);
        vm.prank(trader1);
        registry.requestVerification(address(token1), address(token2), 1);
        registry.approve(pair);

        registry.revoke(pair, true, keccak256("confirmed-malicious-behavior"));
        assertEq(token2.balanceOf(booker) - treasuryBefore, STANDARD_BOND);
        assertFalse(registry.isVerified(pair));

        vm.warp(block.timestamp + REVIEW_PERIOD);
        vm.prank(trader1);
        vm.expectRevert();
        registry.withdrawBond(pair);
    }

    function testFiveDefaultFeeClassesMatchPublishedSchedule() public view {
        uint32[5] memory expected = [
            uint32(10_000), uint32(50_000), uint32(100_000), uint32(200_000), uint32(300_000)
        ];
        for (uint8 i; i < 5; ++i) {
            (uint32 makerFee, uint32 takerFee) = feeManager.feePreset(i);
            assertEq(makerFee, 0);
            assertEq(takerFee, expected[i]);
        }
    }

    function testModuleConfigurationCanBeRebuiltFromConstructorEvents() public {
        uint96[3] memory bonds = [ESTABLISHED_BOND, STANDARD_BOND, HIGH_RISK_BOND];
        vm.recordLogs();
        PairFeeManager freshFeeManager = new PairFeeManager(address(matchingEngine));
        MarketListingRegistry freshRegistry = new MarketListingRegistry(
            address(matchingEngine), address(token2), booker, REVIEW_PERIOD, bonds
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 presetTopic = keccak256("FeePresetSet(uint8,uint32,uint32)");
        bytes32 registryTopic = keccak256(
            "ListingRegistryInitialized(address,address,address,uint64)"
        );
        bytes32 tierTopic = keccak256("TierBondSet(uint8,uint256)");
        uint256 presets;
        uint256 tiers;
        bool initialized;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length == 0) continue;
            if (logs[i].emitter == address(freshFeeManager) && logs[i].topics[0] == presetTopic) {
                ++presets;
            } else if (logs[i].emitter == address(freshRegistry) && logs[i].topics[0] == tierTopic) {
                ++tiers;
            } else if (logs[i].emitter == address(freshRegistry) && logs[i].topics[0] == registryTopic) {
                initialized = true;
            }
        }
        assertEq(presets, 5, "all fee presets must exist in deployment logs");
        assertEq(tiers, 3, "all bond tiers must exist in deployment logs");
        assertTrue(initialized, "registry dependencies must exist in deployment logs");
    }

    function testDefaultFeePolicyChangesEmitCompleteSnapshot() public {
        vm.recordLogs();
        matchingEngine.setDefaultFee(false, 75_000);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 policyTopic = keccak256("DefaultFeePolicySet(uint8,uint32,uint32,uint32)");
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length != 0 && logs[i].topics[0] == policyTopic) {
                assertEq(uint8(uint256(logs[i].topics[1])), 2);
                (uint32 makerFee, uint32 takerFee, uint32 poolShare) =
                    abi.decode(logs[i].data, (uint32, uint32, uint32));
                assertEq(makerFee, 100_000);
                assertEq(takerFee, 75_000);
                assertEq(poolShare, 0);
                found = true;
            }
        }
        assertTrue(found, "complete default policy snapshot missing");
    }

    function testOnlyVerifiedMarketsCanBeFeatured() public {
        address pair = _createPair(trader1);
        vm.expectRevert();
        registry.setFeatured(pair, uint64(block.timestamp + 7 days), keccak256("campaign"));

        vm.prank(trader1);
        registry.requestVerification(address(token1), address(token2), 0);
        registry.approve(pair);
        registry.setFeatured(pair, uint64(block.timestamp + 7 days), keccak256("campaign"));
        assertTrue(registry.isFeatured(pair));
        vm.warp(block.timestamp + 7 days + 1);
        assertFalse(registry.isFeatured(pair));
    }

    function testFeeManagerAppliesFiveClassPresetWithoutBroadEngineAdmin() public {
        address pair = _createPair(trader1);
        (uint32 makerFee, uint32 takerFee) = feeManager.feePreset(1);
        assertEq(makerFee, 0);
        assertEq(takerFee, 50_000);

        feeManager.applyFeePreset(pair, 1);
        assertEq(
            matchingEngine.feeOf(address(token1), address(token2), trader1, false),
            50_000
        );
        uint8 feeClass;
        bool configured;
        (makerFee, takerFee, feeClass, configured) = matchingEngine.pairFeePolicy(pair);
        assertEq(makerFee, 0);
        assertEq(takerFee, 50_000);
        assertEq(feeClass, 1);
        assertTrue(configured);
    }

    function testUnauthorizedCallerCannotAssignFeeClass() public {
        address pair = _createPair(trader1);
        vm.prank(trader1);
        vm.expectRevert();
        matchingEngine.setPairFeeClass(pair, 4, 0, 300_000);
    }
}
