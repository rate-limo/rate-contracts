// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.24;

import {ILSP7DigitalAsset} from "@lukso/lsp7-contracts/contracts/ILSP7DigitalAsset.sol";

// helper methods for interacting with ERC20 tokens and sending ETH that do not consistently return true/false
library TransferHelper {
    /*
     * The swap side's own copy of the exchange's fix, and it needs the same one
     * for the same reason: a bare `require(success, "TFF")` reports FOUR
     * unrelated conditions with one string -- allowance, balance, the token's own
     * revert, and the low-level call running out of gas. Only the first is fixed
     * by approving, so "TFF" sends a trader to fix something that was never
     * wrong.
     *
     * A swap is exposed to the gas half of that just as an order is: the band
     * walk in `BandPool` costs ~44,765 per extra band crossed, so what a swap
     * COSTS depends on pool state that can change between estimating and mining.
     *
     * Unlike the exchange copy these stay `internal`. That copy had to become an
     * externally linked library because MatchingEngine sits within ~100 bytes of
     * EIP-170 and inlining the errors put it over; BandPool has 10,617 bytes
     * spare and BandSwapRouter 22,247, so inlining costs nothing here and avoids
     * adding a link step to the swap deploy.
     */
    error TransferFailed(address token, address to, uint256 value);
    error TransferFromFailed(address token, address from, address to, uint256 value);
    error TransferRejected(address token, address from, address to, uint256 value);
    error ApproveFailed(address token, address spender, uint256 value);
    error NativeTransferFailed(address to, uint256 value);

    /// Re-throw a failed call's own revert data, if it left any. Assembly because
    /// Solidity cannot revert with bytes that are already ABI-encoded.
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
        if (!success) {
            _bubble(data);
            revert ApproveFailed(token, to, value);
        }
        if (data.length != 0 && !abi.decode(data, (bool))) revert ApproveFailed(token, to, value);
    }

    function safeTransfer(address token, address to, uint256 value) internal {
        // bytes4(keccak256(bytes("transfer(address,uint256)")));
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(0xa9059cbb, to, value));
        if (!success) {
            _bubble(data);
            revert TransferFailed(token, to, value);
        }
        if (data.length != 0 && !abi.decode(data, (bool))) {
            revert TransferRejected(token, address(this), to, value);
        }
    }

    function safeTransferFrom(address token, address from, address to, uint256 value) internal {
        // bytes4(keccak256(bytes("transferFrom(address,address,uint256)")));
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(0x23b872dd, from, to, value));
        if (!success) {
            _bubble(data);
            revert TransferFromFailed(token, from, to, value);
        }
        if (data.length != 0 && !abi.decode(data, (bool))) {
            revert TransferRejected(token, from, to, value);
        }
    }

    function safeTransferETH(address to, uint256 value) internal {
        (bool success,) = to.call{value: value}(new bytes(0));
        if (!success) revert NativeTransferFailed(to, value);
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
