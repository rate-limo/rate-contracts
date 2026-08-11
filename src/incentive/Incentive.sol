// SPDX-License-Identifier: BUSL-1.1

pragma solidity 0.8.24;

import {IProtocol} from "./interfaces/IProtocol.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/// @notice OG Pass ownership and fee-policy surface.
interface IOGPass {
    function balanceOf(address owner) external view returns (uint256);
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
    /// @notice Configures OG Pass fee policy, overrides and terminals.
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

    /// @notice OG Pass NFT whose holders may use the configured fee policy.
    address public ogPass;

    mapping(address account => FeeOverride feeOverride) private _overrides;

    /// @notice Terminal registry. The engine reads this during listing: an empty name
    /// means "not a registered terminal" and listing is refused.
    mapping(address terminal => string name) public terminalNames;

    event OGPassSet(address indexed ogPass);
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

    /// @notice Sets the ERC-721 collection that owns the fee policy.
    function setOGPass(address ogPass_) external onlyRole(ADMIN_ROLE) {
        ogPass = ogPass_;
        emit OGPassSet(ogPass_);
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
     * AssetGenerator's graduation tiers), which chains to this contract for everything else.
     */
    function feeOf(address, address, address account, bool isMaker) external view returns (uint32 feeNum) {
        return _feeOf(account, isMaker);
    }

    /// @notice Whether the account currently holds an OG Pass NFT.
    function isSubscribed(address account) external view returns (bool) {
        return isOGPassHolder(account);
    }

    /// @notice Whether an account currently owns at least one configured OG Pass NFT.
    /// @dev A missing or reverting collection is treated as no pass, never as a discount.
    function isOGPassHolder(address account) public view returns (bool) {
        address ogPass_ = ogPass;
        if (ogPass_ == address(0)) return false;
        try IOGPass(ogPass_).balanceOf(account) returns (uint256 balance) {
            return balance != 0;
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
        return _ogPassFee(account, isMaker);
    }

    /// @dev Points are deliberately not consulted on-chain. The OG Pass contract owns
    /// the maker/taker fee policy; it may derive a tier from the NFT held by the account.
    function _ogPassFee(address account, bool isMaker) internal view returns (uint32) {
        address ogPass_ = ogPass;
        if (ogPass_ == address(0)) revert NoFeeOpinion(account);
        if (!isOGPassHolder(account)) revert NoFeeOpinion(account);
        try IOGPass(ogPass_).feeOf(account, isMaker) returns (uint32 feeNum) {
            if (feeNum > DENOM) revert InvalidFee(feeNum);
            return feeNum;
        } catch {
            revert NoFeeOpinion(account);
        }
    }
}
