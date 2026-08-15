/// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TransferHelper} from "../../exchange/libraries/TransferHelper.sol";
import {IMatchingEngine} from "../../exchange/interfaces/IMatchingEngine.sol";
import {AssetGenerator} from "../AssetGenerator.sol";

/**
 * @title AssetLaunchLib
 * @notice Two pieces of `AssetGenerator._launch`, moved out purely for EIP-170
 * headroom -- AssetGenerator was 568 bytes over the 24,576 limit and could not be
 * deployed at all.
 *
 * Unlike a storage-touching extraction, neither function here takes a storage
 * reference: AssetGenerator still does its own mapping reads and writes directly
 * (a plain SLOAD/SSTORE against a constant slot costs nothing in stack terms), and
 * passes the already-resolved values in. That keeps AssetGenerator's own `_launch`
 * well clear of "stack too deep" -- an 11-parameter version of this that took all four
 * mappings as storage parameters hit that wall repeatedly, because a storage-reference
 * parameter (unlike a direct state-variable access) occupies a stack slot for the
 * whole function. Passing values instead of mappings is also the shape
 * MatchingLib already uses throughout: every one of its public functions takes plain
 * values or an address to call out to, never a storage pointer into its caller.
 *
 * Behaviour is unchanged: `settleListing` is `public`, so AssetGenerator's wrapper
 * reaches it via DELEGATECALL. `address(this)`, `msg.sender` and `msg.value` inside it
 * therefore still resolve to AssetGenerator's address and the original caller.
 *
 * Only the errors these two functions can actually revert with are re-declared here,
 * matching AssetGenerator's own declarations exactly (custom errors are keyed by
 * signature, so an identical name+types pair always produces the same selector
 * regardless of which contract declares it -- this is not the `indexed`-on-events trap
 * described in MatchingLib, just ordinary error duplication). The declarations in
 * AssetGenerator itself are kept even though these two paths no longer revert from
 * there directly: removing them would change AssetGenerator's ABI, which callers (the
 * frontend, the broker, `packages/abis`) depend on staying put.
 */
library AssetLaunchLib {
    error InsufficientFee(uint256 sent, uint256 required);
    error PaymentNotEnabled(address token);
    error UnexpectedNativePayment(uint256 sent);
    error FeeToNotSet();
    error RefundFailed();
    error InvalidFee(uint32 feeNum);
    error InvalidVolatility(uint16 volatilityBps);
    error InvalidPresetValue(AssetGenerator.Preset preset, uint256 value);

    /// @notice Validates a creator-supplied `launchAsset` settings struct against the
    /// venue's published bounds and preset table. Reverts on any violation.
    function validateLaunchSettings(
        AssetGenerator.LaunchSettings memory settings,
        uint16 minSlippageLimitBps,
        uint16 maxSlippageLimitBps,
        uint32 minPairFee,
        uint32 maxPairFee
    ) public pure {
        if (settings.volatilityBps < minSlippageLimitBps || settings.volatilityBps > maxSlippageLimitBps) {
            revert InvalidVolatility(settings.volatilityBps);
        }
        if (settings.takerFee < minPairFee || settings.takerFee > maxPairFee) {
            revert InvalidFee(settings.takerFee);
        }
        if (settings.makerFee < minPairFee || settings.makerFee > maxPairFee) {
            revert InvalidFee(settings.makerFee);
        }
        _validatePreset(settings.volatilityPreset, settings.volatilityBps, true);
        _validatePreset(settings.feePreset, settings.takerFee, false);
    }

    function _validatePreset(AssetGenerator.Preset preset, uint256 value, bool volatility) private pure {
        if (preset == AssetGenerator.Preset.Custom) return;
        uint256 expected;
        if (preset == AssetGenerator.Preset.Stable) expected = volatility ? 5 : 50_000;
        else if (preset == AssetGenerator.Preset.Standard) expected = volatility ? 10 : 100_000;
        else if (preset == AssetGenerator.Preset.Uniswap) expected = volatility ? 50 : 500_000;
        else expected = volatility ? 100 : 1_000_000;
        if (value != expected) revert InvalidPresetValue(preset, value);
    }

    /// @notice The launch-fee inputs `settleListing` needs, bundled to keep its
    /// parameter count (and therefore its stack pressure) low -- unbundled, this
    /// function hit "stack too deep" on the `addPair` call, which alone pushes six
    /// arguments on top of whatever else is live.
    /// @dev `tokenEnabled`/`tokenAmount` are the caller's already-loaded
    /// `paymentOptions[settings.paymentToken]` fields rather than the mapping itself --
    /// see the contract-level docs for why a storage reference was dropped in favour of
    /// this. They are meaningless (and unread) when `token == address(0)`, same as the
    /// mapping entry at that key always is.
    struct PaymentInfo {
        address token;
        uint256 launchFee;
        bool tokenEnabled;
        uint256 tokenAmount;
        address feeTo;
    }

    /**
     * @notice Charges the launch fee, lists the pair on the engine, and returns any
     * unspent balances to the creator.
     * @return pair The MatchingEngine pair address created for this listing.
     */
    function settleListing(
        address matchingEngine,
        address coin,
        address quote,
        AssetGenerator.QuoteOption memory option,
        PaymentInfo memory payment
    ) public returns (address pair) {
        uint256 paymentAmount;
        if (payment.token == address(0)) {
            paymentAmount = payment.launchFee;
            if (msg.value < paymentAmount) revert InsufficientFee(msg.value, paymentAmount);
        } else {
            if (!payment.tokenEnabled) revert PaymentNotEnabled(payment.token);
            if (msg.value != 0) revert UnexpectedNativePayment(msg.value);
            paymentAmount = payment.tokenAmount;
        }
        if (paymentAmount > 0 && payment.feeTo == address(0)) revert FeeToNotSet();

        // The engine pulls the listing cost from msg.sender -- this contract -- with
        // transferFrom, unless it holds MARKET_MAKER_ROLE and lists for free. Approve
        // only what this contract actually holds of the payment token, then drop the
        // allowance again: a listing that spends less than the balance must not leave
        // the engine able to move the rest, and resetting to zero also keeps
        // approve-from-nonzero tokens working on the next launch.
        address listingPayment = option.listingPayment == address(0) ? coin : option.listingPayment;
        uint256 paymentBalance = IERC20(listingPayment).balanceOf(address(this));
        if (paymentBalance > 0) TransferHelper.safeApprove(listingPayment, matchingEngine, paymentBalance);
        pair = IMatchingEngine(matchingEngine).addPair(
            coin, quote, option.listingPrice, block.timestamp, listingPayment, option.mode
        );
        if (paymentBalance > 0) TransferHelper.safeApprove(listingPayment, matchingEngine, 0);

        uint256 remaining = IERC20(coin).balanceOf(address(this));
        if (remaining > 0) TransferHelper.safeTransfer(coin, msg.sender, remaining);

        if (paymentAmount > 0) {
            if (payment.token == address(0)) {
                TransferHelper.safeTransferETH(payment.feeTo, paymentAmount);
            } else {
                TransferHelper.safeTransferFrom(payment.token, msg.sender, payment.feeTo, paymentAmount);
            }
        }
        if (payment.token == address(0)) {
            uint256 refund = msg.value - paymentAmount;
            if (refund > 0) {
                (bool ok,) = payable(msg.sender).call{value: refund}("");
                if (!ok) revert RefundFailed();
            }
        }
    }
}
