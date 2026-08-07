// SPDX-License-Identifier: BUSL-1.1

pragma solidity 0.8.24;

import {IProtocol} from "./interfaces/IProtocol.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/// @notice The subset of the membership contract (PointFarm) this consults.
interface IMembership {
    function isSubscribed(address account) external view returns (bool);
    function feeOf(address account, bool isMaker) external view returns (uint32 feeNum);
}

/**
 * @title Incentive
 * @notice The MatchingEngine's fee oracle: answers "what does this account pay", or
 * declines to answer so the engine charges its own defaults.
 *
 * @dev **Declining is a revert, never a zero.** `MatchingEngine.feeOf` falls back to
 * `_dfltFee` only when this call *reverts*:
 *
 * ```
 * try IProtocol(incentive).feeOf(base, quote, account, isMaker) returns (uint32 num) {
 *     return num;
 * } catch {
 *     return _dfltFee(isMaker);
 * }
 * ```
 *
 * A returned `0` is not "no opinion" -- it is a valid numerator meaning *free*. This
 * contract previously returned `0` unconditionally, so wiring it up with `setIncentive`
 * would have silently zeroed every fee on the venue: no revert, no event, just no
 * revenue. Every path below either returns a fee somebody configured or reverts. Zero
 * is returned only when an admin explicitly set an override to zero, which is a real
 * policy (a market-maker agreement), not an accident.
 */
contract Incentive is IProtocol, AccessControl {
    /// @notice Configures memberships, overrides and terminals.
    /// @dev Distinct from DEFAULT_ADMIN_ROLE, which only grants and revokes roles.
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    /// @notice Fee scale, mirroring `MatchingEngine.DENOM`. 1% is 1_000_000.
    /// @dev Every numerator returned here is on this scale. The engine hands it straight
    /// to the orderbook, so a value on any other scale misprices fills silently.
    uint32 public constant DENOM = 100_000_000;

    /// @notice A fee an admin set for one account, on `DENOM`'s scale.
    /// @dev `set` distinguishes "configured to zero" from "not configured". Without the
    /// flag those are the same value -- the exact ambiguity that made the old stub
    /// dangerous.
    struct FeeOverride {
        bool set;
        uint32 makerFee;
        uint32 takerFee;
    }

    /// @notice Membership contract consulted when an account has no override. Optional.
    address public membership;

    /**
     * @notice Denominator the membership contract's fee ladder is written against.
     * @dev Defaults to 1e6 because that is what `MembershipLib._getFeeRate` returns
     * against: its own comments read `// 1% / 1%` above `return 10000`, and 10000/1e6 is
     * 1%. The engine's DENOM is 1e8, so forwarding those numbers unscaled would charge
     * 0.01% where the ladder says 1% -- a 100x under-charge, and the same class of silent
     * mispricing this contract is being fixed for. Rescaling happens in `_membershipFee`;
     * set this to 1e8 if the ladder is ever restated on that scale.
     */
    uint32 public membershipFeeDenom = 1_000_000;

    mapping(address account => FeeOverride feeOverride) private _overrides;

    /// @notice Terminal registry. The engine reads this during listing: an empty name
    /// means "not a registered terminal" and listing is refused.
    mapping(address terminal => string name) public terminalNames;

    event MembershipSet(address indexed membership);
    event MembershipFeeDenomSet(uint32 denom);
    event FeeOverrideSet(address indexed account, bool set, uint32 makerFee, uint32 takerFee);
    event TerminalNameSet(address indexed terminal, string name);

    error InvalidFee(uint256 feeNum);
    error ZeroAddress();
    /// @notice Thrown when nothing is configured for this account.
    /// @dev Not a failure: the engine catches it and applies its own default fee. This is
    /// the "no opinion" answer, expressed the only way the engine actually listens to.
    error NoFeeOpinion(address account);

    constructor(address admin) {
        // The old contract had no constructor at all, so DEFAULT_ADMIN_ROLE was held by
        // nobody: `membership` and `terminalNames` could never be written and the
        // AccessControl inheritance was decoration.
        if (admin == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ADMIN_ROLE, admin);
    }

    /* ---------------------------------- admin --------------------------------- */

    /// @notice Points the fee ladder at a membership contract. address(0) disables it.
    function setMembership(address membership_) external onlyRole(ADMIN_ROLE) {
        membership = membership_;
        emit MembershipSet(membership_);
    }

    /// @notice Sets the scale the membership ladder's numerators are written against.
    function setMembershipFeeDenom(uint32 denom) external onlyRole(ADMIN_ROLE) {
        if (denom == 0) revert InvalidFee(denom);
        membershipFeeDenom = denom;
        emit MembershipFeeDenomSet(denom);
    }

    /**
     * @notice Sets or clears one account's fee, bypassing the membership ladder.
     * @param set False clears the override and sends the account back to the ladder.
     * @param makerFee Numerator on `DENOM`'s scale. Zero is a valid, deliberate "free".
     * @param takerFee Numerator on `DENOM`'s scale.
     */
    function setFeeOverride(address account, bool set, uint32 makerFee, uint32 takerFee)
        external
        onlyRole(ADMIN_ROLE)
    {
        if (account == address(0)) revert ZeroAddress();
        if (makerFee > DENOM) revert InvalidFee(makerFee);
        if (takerFee > DENOM) revert InvalidFee(takerFee);
        _overrides[account] = FeeOverride({set: set, makerFee: makerFee, takerFee: takerFee});
        emit FeeOverrideSet(account, set, makerFee, takerFee);
    }

    /// @notice Registers (or, with an empty name, de-registers) a listing terminal.
    function setTerminalName(address terminal, string calldata name) external onlyRole(ADMIN_ROLE) {
        if (terminal == address(0)) revert ZeroAddress();
        terminalNames[terminal] = name;
        emit TerminalNameSet(terminal, name);
    }

    /* ---------------------------------- views --------------------------------- */

    function feeOverrideOf(address account) external view returns (FeeOverride memory) {
        return _overrides[account];
    }

    /**
     * @notice Fee numerator for an account, on `DENOM`'s scale.
     * @dev Resolution order: explicit override, then the membership ladder, then revert so
     * the engine applies its default. `base` and `quote` are unused -- this contract prices
     * accounts, not pairs. Per-pair pricing lives in the pair's own generator (see
     * CoinGenerator's graduation tiers), which chains to this contract for everything else.
     */
    function feeOf(address, address, address account, bool isMaker) external view returns (uint32 feeNum) {
        return _feeOf(account, isMaker);
    }

    /// @notice Whether the account holds a live membership.
    /// @dev False when no membership contract is set, and false rather than a revert if the
    /// call fails: this answers a question about subscription, not about money, and no fee
    /// path depends on it.
    function isSubscribed(address account) external view returns (bool) {
        if (membership == address(0)) return false;
        try IMembership(membership).isSubscribed(account) returns (bool subscribed) {
            return subscribed;
        } catch {
            return false;
        }
    }

    /// @notice Registered name of a listing terminal, empty if it is not one.
    function terminalName(address terminal) external view returns (string memory name) {
        return terminalNames[terminal];
    }

    /// @notice The account's fee, ignoring the pair. Same resolution and same revert as
    /// `feeOf` -- a caller must not read a zero here as "no fee configured".
    function accountFee(address account, bool isMaker) external view returns (uint256 feeNum) {
        return _feeOf(account, isMaker);
    }

    /* --------------------------------- internal -------------------------------- */

    function _feeOf(address account, bool isMaker) internal view returns (uint32) {
        FeeOverride memory feeOverride = _overrides[account];
        if (feeOverride.set) {
            return isMaker ? feeOverride.makerFee : feeOverride.takerFee;
        }
        return _membershipFee(account, isMaker);
    }

    /**
     * @dev The membership ladder, rescaled onto the engine's DENOM.
     *
     * Reverts -- rather than substituting a number -- whenever the ladder cannot answer:
     * no membership contract, an unsubscribed account, a membership call that fails, or a
     * rescaled fee above 100%. Each of those means "we have no fee for you", and the
     * engine's default is the right answer to that, not a value invented here.
     */
    function _membershipFee(address account, bool isMaker) internal view returns (uint32) {
        address membership_ = membership;
        if (membership_ == address(0)) revert NoFeeOpinion(account);

        try IMembership(membership_).isSubscribed(account) returns (bool subscribed) {
            if (!subscribed) revert NoFeeOpinion(account);
        } catch {
            revert NoFeeOpinion(account);
        }

        uint32 raw = 0;
        try IMembership(membership_).feeOf(account, isMaker) returns (uint32 num) {
            raw = num;
        } catch {
            revert NoFeeOpinion(account);
        }

        // Widened before multiplying: a 100x scale-up overflows uint32 for any realistic
        // ladder value.
        uint256 scaled = (uint256(raw) * uint256(DENOM)) / uint256(membershipFeeDenom);
        if (scaled > DENOM) revert InvalidFee(scaled);
        return uint32(scaled);
    }
}
