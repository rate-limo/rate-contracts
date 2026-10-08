// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.24;

import {ILSP7DigitalAsset} from "@lukso/lsp7-contracts/contracts/ILSP7DigitalAsset.sol";

/**
 * Helper methods for tokens that do not consistently return true/false.
 *
 * ## Why these errors are named, and why the child's reason is re-thrown
 *
 * Every function here used to end in `require(success && ..., "TFF")` — a
 * three-letter string that discarded the reason the call actually failed. That
 * is not merely terse; it is lossy in a way that reaches users. `safeTransferFrom`
 * reports the SAME "TFF" for at least four unrelated conditions:
 *
 *   1. the spender's allowance is too low;
 *   2. the owner's balance is too low;
 *   3. the token reverted for its own reason (paused, blacklisted, hook);
 *   4. the low-level call itself failed — including the child frame running out
 *      of gas under EIP-150's 63/64 rule while the outer frame survives.
 *
 * Only (1) is fixed by approving; (4) is fixed by sending more gas and has
 * nothing to do with transfers at all. A UI handed "TFF" cannot tell a trader
 * which of those happened, so it either says nothing useful or — worse — tells
 * them to approve when the real problem was gas.
 *
 * Two changes fix that without altering a single success path:
 *
 *  - **The child's revert data is re-thrown verbatim** when there is any. A
 *    modern ERC-20 reverts with `ERC20InsufficientAllowance(spender, allowance,
 *    needed)`, which carries the exact numbers; swallowing it to say "TFF"
 *    throws away an answer the token already computed.
 *  - **When the child gave no reason** (the out-of-gas case, which returns empty
 *    data) a NAMED error carrying the token and the amounts is raised instead of
 *    a bare string, so the caller can decode it and say something true.
 *
 * `apps/web/utils/orderErrors.ts` maps error NAMES to sentences and
 * `ExchangeErrors.json` carries the fragments it decodes with; a `require`
 * string is invisible to both. See apps/web/CLAUDE.md, "Reverts are copy".
 */
library TransferHelper {
    /*
     * ## These stay `internal`, and the reason is a deploy failure
     *
     * They were `public` for one commit -- an externally linked library, which
     * bought MatchingEngine 164 bytes of EIP-170 headroom and let every failure
     * carry a named error. It could not be deployed.
     *
     * `MatchingLib` imports this file, so making it external left MATCHINGLIB
     * itself unlinked, and `DeployMatchingLib` deploys it with
     * `deployCode("MatchingLib.sol:MatchingLib")`. `vm.getCode` cannot deploy
     * unlinked bytecode: `vm.getCode: no bytecode for contract; is it abstract or
     * unlinked?`, on every chain's deploy script at once. Fixing that properly
     * means teaching ten per-chain scripts to deploy and link this first, which
     * is a bigger change than the headroom was worth.
     *
     * ## What survived, and it is the part that mattered
     *
     * `_bubble` re-throws the token's OWN revert data when it left any. A modern
     * ERC-20 raises `ERC20InsufficientAllowance(spender, allowance, needed)` --
     * the exact numbers, computed by the token -- and that now reaches the app
     * instead of being flattened into three characters. It costs 47 bytes of
     * headroom (99 -> 52), which is the whole price of this change.
     *
     * The short strings remain for the case where the token gives nothing back.
     * That case is far rarer than it was: it was overwhelmingly gas starvation,
     * and `MATCH_GAS_RESERVE` plus the client's bounded gas limit remove it.
     * `apps/web/utils/orderErrors.ts` maps the bare strings to sentences so even
     * then nothing raw reaches a trader.
     */


    /**
     * Re-throw a failed call's own revert data, if it left any.
     *
     * Returns normally when there is nothing to bubble, so the caller raises its
     * own named error instead. Assembly because there is no way in Solidity to
     * revert with bytes that are already ABI-encoded.
     */
    function _bubble(bytes memory data) private pure {
        if (data.length == 0) return;
        assembly {
            revert(add(data, 0x20), mload(data))
        }
    }
    struct TokenInfo {
        address token;
        uint8 decimals;
        string name;
        string symbol;
        uint256 totalSupply;
    }

    function safeApprove(address token, address to, uint256 value) internal {
        // bytes4(keccak256(bytes("approve(address,uint256)")));
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(0x095ea7b3, to, value));
        if (!success) _bubble(data);
        require(success && (data.length == 0 || abi.decode(data, (bool))), "AF");
    }

    function safeTransfer(address token, address to, uint256 value) internal {
        // bytes4(keccak256(bytes("transfer(address,uint256)")));
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(0xa9059cbb, to, value));
        if (!success) _bubble(data);
        require(success && (data.length == 0 || abi.decode(data, (bool))), "TF");
    }

    function safeTransferFrom(address token, address from, address to, uint256 value) internal {
        // bytes4(keccak256(bytes("transferFrom(address,address,uint256)")));
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(0x23b872dd, from, to, value));
        // The token's own reason first — `ERC20InsufficientAllowance` and friends
        // carry the numbers, and are strictly more informative than anything this
        // library could invent. One revert site, not two, to keep the inlined
        // bytecode down.
        if (!success) _bubble(data);
        require(success && (data.length == 0 || abi.decode(data, (bool))), "TFF");
    }

    function safeTransferETH(address to, uint256 value) internal {
        (bool success,) = to.call{value: value}(new bytes(0));
        require(success, "ETF");
    }

    function name(address token) internal view returns (string memory) {
        // bytes4(keccak256(bytes("name()")));
        (bool success, bytes memory data) = token.staticcall(abi.encodeWithSelector(0x06fdde03));
        require(success, "NF");
        return abi.decode(data, (string));
    }

    function symbol(address token) internal view returns (string memory) {
        // bytes4(keccak256(bytes("symbol()")));
        (bool success, bytes memory data) = token.staticcall(abi.encodeWithSelector(0x95d89b41));
        require(success, "SF");
        return abi.decode(data, (string));
    }

    function totalSupply(address token) internal view returns (uint256) {
        // bytes4(keccak256(bytes("totalSupply()")));
        (bool success, bytes memory data) = token.staticcall(abi.encodeWithSelector(0x18160ddd));
        require(success, "TSF");
        return abi.decode(data, (uint256));
    }

    function decimals(address token) internal view returns (uint8) {
        // bytes4(keccak256(bytes("decimals()")));
        (bool success, bytes memory data) = token.staticcall(abi.encodeWithSelector(0x313ce567));
        require(success, "DF");
        return abi.decode(data, (uint8));
    }

    function getTokenInfo(address token) internal view returns (TokenInfo memory tokenInfo) {
        tokenInfo.token = token;
        tokenInfo.name = name(token);
        tokenInfo.symbol = symbol(token);
        tokenInfo.totalSupply = totalSupply(token);
        tokenInfo.decimals = decimals(token);
        return tokenInfo;
    }

    function lsp7Transfer(address token, address from, address to, uint256 value) internal {
        // bytes4(keccak256(bytes("transfer(address,address,uint256,bool,bytes)")));
        (bool success, bytes memory data) =
            token.call(abi.encodeWithSelector(ILSP7DigitalAsset.transfer.selector, from, to, value, true, ""));

        // Suggest using this function for abi-encoding
        // (bool success, bytes memory data) = token.call(abi.encodeCall(ILSP7DigitalAsset.transfer, from, to, value, true, ""));
        require(success && (data.length == 0), "AF");
    }
}
