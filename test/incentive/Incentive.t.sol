// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Incentive} from "../../src/incentive/Incentive.sol";
import {IProtocol} from "../../src/incentive/interfaces/IProtocol.sol";

/// @notice Stands in for PointFarm: subscription state plus the fee ladder, on the
/// ladder's own 1e6 scale, with a switch to make either call revert.
contract MockMembership {
    error Boom();

    mapping(address => bool) public subscribed;
    uint32 public makerFee;
    uint32 public takerFee;
    bool public revertOnSubscribed;
    bool public revertOnFee;

    function setSubscribed(address account, bool value) external {
        subscribed[account] = value;
    }

    function setLadder(uint32 maker, uint32 taker) external {
        makerFee = maker;
        takerFee = taker;
    }

    function setRevertOnSubscribed(bool value) external {
        revertOnSubscribed = value;
    }

    function setRevertOnFee(bool value) external {
        revertOnFee = value;
    }

    function isSubscribed(address account) external view returns (bool) {
        if (revertOnSubscribed) revert Boom();
        return subscribed[account];
    }

    function feeOf(address, bool isMaker) external view returns (uint32) {
        if (revertOnFee) revert Boom();
        return isMaker ? makerFee : takerFee;
    }
}

/**
 * @notice A byte-for-byte copy of `MatchingEngine.feeOf`'s dispatch, so these tests
 * exercise the real fallback contract rather than an assumption about it. Kept in sync
 * with MatchingEngine.sol (the `try IProtocol(incentive).feeOf(...) catch` block).
 */
contract EngineFallbackHarness {
    address public incentive;
    uint32 public defaultMakerFee;
    uint32 public defaultTakerFee;

    constructor(uint32 maker, uint32 taker) {
        defaultMakerFee = maker;
        defaultTakerFee = taker;
    }

    function setIncentive(address incentive_) external {
        incentive = incentive_;
    }

    function feeOf(address base, address quote, address account, bool isMaker) external view returns (uint32) {
        if (incentive == address(0)) {
            return _dfltFee(isMaker);
        } else {
            try IProtocol(incentive).feeOf(base, quote, account, isMaker) returns (uint32 num) {
                return num;
            } catch {
                return _dfltFee(isMaker);
            }
        }
    }

    function _dfltFee(bool isMaker) internal view returns (uint32) {
        return isMaker ? defaultMakerFee : defaultTakerFee;
    }
}

/// @notice The contract as it was: returns 0 for everything, never reverts.
contract OldStubIncentive {
    function feeOf(address, address, address, bool) external pure returns (uint32) {
        return 0;
    }
}

contract IncentiveTest is Test {
    Incentive internal incentive;
    MockMembership internal membership;
    EngineFallbackHarness internal engine;

    address internal admin = makeAddr("admin");
    address internal trader = makeAddr("trader");
    address internal stranger = makeAddr("stranger");
    address internal terminal = makeAddr("terminal");

    /// MatchingEngine's own defaults: maker 0, taker 100_000 (= 0.10% of 1e8).
    uint32 internal constant DEFAULT_MAKER = 0;
    uint32 internal constant DEFAULT_TAKER = 100_000;

    function setUp() public {
        incentive = new Incentive(admin);
        membership = new MockMembership();
        engine = new EngineFallbackHarness(DEFAULT_MAKER, DEFAULT_TAKER);
        engine.setIncentive(address(incentive));
    }

    /* ------------------------------- the actual bug ---------------------------- */

    /**
     * The regression this whole change exists for. The engine only falls back when the
     * incentive REVERTS; a zero return is a valid numerator meaning "free". With the old
     * stub wired in, every fill on the venue cost nothing.
     */
    function test_oldStub_wouldHaveZeroedEveryFeeOnTheVenue() public {
        engine.setIncentive(address(new OldStubIncentive()));
        assertEq(engine.feeOf(address(1), address(2), trader, false), 0, "taker paid nothing");
        assertEq(engine.feeOf(address(1), address(2), trader, true), 0, "maker paid nothing");
    }

    /// The fix: with nothing configured the incentive declines, and the engine charges
    /// its own default instead of zero.
    function test_engineFallsBackToItsDefaultWhenNothingIsConfigured() public view {
        assertEq(engine.feeOf(address(1), address(2), trader, false), DEFAULT_TAKER);
        assertEq(engine.feeOf(address(1), address(2), trader, true), DEFAULT_MAKER);
    }

    function test_feeOf_revertsWhenNothingIsConfigured() public {
        vm.expectRevert(abi.encodeWithSelector(Incentive.NoFeeOpinion.selector, trader));
        incentive.feeOf(address(1), address(2), trader, false);
    }

    function test_accountFee_revertsRatherThanReturningZero() public {
        vm.expectRevert(abi.encodeWithSelector(Incentive.NoFeeOpinion.selector, trader));
        incentive.accountFee(trader, false);
    }

    /* --------------------------------- overrides ------------------------------- */

    function test_feeOf_returnsTheOverridePerSide() public {
        vm.prank(admin);
        incentive.setFeeOverride(trader, true, 5_000, 250_000);

        assertEq(incentive.feeOf(address(1), address(2), trader, true), 5_000);
        assertEq(incentive.feeOf(address(1), address(2), trader, false), 250_000);
        assertEq(engine.feeOf(address(1), address(2), trader, false), 250_000, "engine takes it");
    }

    /// A configured zero is a real policy — a market-maker agreement — and must survive,
    /// which is why the struct carries `set` instead of treating 0 as absent.
    function test_feeOf_honoursAnOverrideOfZero() public {
        vm.prank(admin);
        incentive.setFeeOverride(trader, true, 0, 0);
        assertEq(incentive.feeOf(address(1), address(2), trader, false), 0);
        assertEq(engine.feeOf(address(1), address(2), trader, false), 0, "deliberately free");

        // and an unconfigured account beside it still falls back
        assertEq(engine.feeOf(address(1), address(2), stranger, false), DEFAULT_TAKER);
    }

    function test_clearingAnOverrideSendsTheAccountBackToTheLadder() public {
        vm.startPrank(admin);
        incentive.setFeeOverride(trader, true, 0, 250_000);
        incentive.setFeeOverride(trader, false, 0, 0);
        vm.stopPrank();

        assertEq(engine.feeOf(address(1), address(2), trader, false), DEFAULT_TAKER, "back to default");
    }

    function test_setFeeOverride_revertsAboveTheDenominator() public {
        uint32 denom = incentive.DENOM();
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(Incentive.InvalidFee.selector, uint256(denom) + 1));
        incentive.setFeeOverride(trader, true, 0, denom + 1);
    }

    /* -------------------------------- membership ------------------------------- */

    function _useMembership(uint32 maker, uint32 taker) internal {
        membership.setLadder(maker, taker);
        membership.setSubscribed(trader, true);
        vm.prank(admin);
        incentive.setMembership(address(membership));
    }

    /**
     * The second bug found while fixing the first: MembershipLib's ladder is written
     * against 1e6 (`// 1% / 1%` above `return 10000`) while the engine's DENOM is 1e8.
     * Forwarding it unscaled would charge 0.01% where the ladder says 1%.
     */
    function test_membershipLadder_isRescaledOntoTheEngineDenominator() public {
        _useMembership(7_500, 10_000); // ladder: 0.75% maker, 1.00% taker

        assertEq(incentive.feeOf(address(1), address(2), trader, true), 750_000, "0.75% of 1e8");
        assertEq(incentive.feeOf(address(1), address(2), trader, false), 1_000_000, "1.00% of 1e8");
    }

    function test_membershipLadder_needsNoRescaleOnceRestatedOn1e8() public {
        _useMembership(750_000, 1_000_000);
        // Read DENOM before pranking: a call inside the argument consumes the prank.
        uint32 denom = incentive.DENOM();
        vm.prank(admin);
        incentive.setMembershipFeeDenom(denom);

        assertEq(incentive.feeOf(address(1), address(2), trader, false), 1_000_000);
    }

    function test_feeOf_declinesForAnUnsubscribedAccount() public {
        _useMembership(7_500, 10_000);
        membership.setSubscribed(trader, false);

        vm.expectRevert(abi.encodeWithSelector(Incentive.NoFeeOpinion.selector, trader));
        incentive.feeOf(address(1), address(2), trader, false);
        assertEq(engine.feeOf(address(1), address(2), trader, false), DEFAULT_TAKER);
    }

    /// A membership contract that reverts must not become a zero fee.
    function test_feeOf_declinesWhenTheMembershipCallFails() public {
        _useMembership(7_500, 10_000);

        membership.setRevertOnSubscribed(true);
        assertEq(engine.feeOf(address(1), address(2), trader, false), DEFAULT_TAKER, "isSubscribed reverted");

        membership.setRevertOnSubscribed(false);
        membership.setRevertOnFee(true);
        assertEq(engine.feeOf(address(1), address(2), trader, false), DEFAULT_TAKER, "feeOf reverted");
    }

    function test_feeOf_declinesWhenTheRescaledFeeExceedsTheDenominator() public {
        _useMembership(0, 2_000_000); // 200% once rescaled

        vm.expectRevert(abi.encodeWithSelector(Incentive.InvalidFee.selector, uint256(200_000_000)));
        incentive.feeOf(address(1), address(2), trader, false);
        assertEq(engine.feeOf(address(1), address(2), trader, false), DEFAULT_TAKER);
    }

    function test_overrideBeatsTheMembershipLadder() public {
        _useMembership(7_500, 10_000);
        vm.prank(admin);
        incentive.setFeeOverride(trader, true, 1, 2);

        assertEq(incentive.feeOf(address(1), address(2), trader, false), 2);
    }

    /* ------------------------------- subscriptions ----------------------------- */

    function test_isSubscribed_isFalseWithoutAMembershipContract() public view {
        assertFalse(incentive.isSubscribed(trader));
    }

    function test_isSubscribed_delegatesAndSwallowsFailures() public {
        _useMembership(7_500, 10_000);
        assertTrue(incentive.isSubscribed(trader));
        assertFalse(incentive.isSubscribed(stranger));

        membership.setRevertOnSubscribed(true);
        assertFalse(incentive.isSubscribed(trader), "a failing membership is not a subscription");
    }

    /* --------------------------------- terminals ------------------------------- */

    function test_terminalName_roundTrips() public {
        assertEq(bytes(incentive.terminalName(terminal)).length, 0);

        vm.prank(admin);
        incentive.setTerminalName(terminal, "iter");
        assertEq(incentive.terminalName(terminal), "iter");

        vm.prank(admin);
        incentive.setTerminalName(terminal, "");
        assertEq(bytes(incentive.terminalName(terminal)).length, 0, "de-registered");
    }

    /* ------------------------------ access control ----------------------------- */

    /// The old contract had no constructor, so DEFAULT_ADMIN_ROLE was held by nobody and
    /// every setter it lacked would have been unreachable anyway.
    function test_constructor_grantsBothRoles() public view {
        assertTrue(incentive.hasRole(incentive.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(incentive.hasRole(incentive.ADMIN_ROLE(), admin));
    }

    function test_constructor_rejectsAZeroAdmin() public {
        vm.expectRevert(Incentive.ZeroAddress.selector);
        new Incentive(address(0));
    }

    function test_setMembership_revertsForNonAdmin() public {
        bytes32 role = incentive.ADMIN_ROLE();
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, role)
        );
        incentive.setMembership(address(membership));
    }

    function test_setFeeOverride_revertsForNonAdmin() public {
        vm.prank(stranger);
        vm.expectRevert();
        incentive.setFeeOverride(stranger, true, 0, 0);
    }

    function test_setTerminalName_revertsForNonAdmin() public {
        vm.prank(stranger);
        vm.expectRevert();
        incentive.setTerminalName(stranger, "self-serve");
    }

    function test_setMembershipFeeDenom_rejectsZero() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(Incentive.InvalidFee.selector, uint256(0)));
        incentive.setMembershipFeeDenom(0);
    }
}
