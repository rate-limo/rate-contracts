// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {PoolBaseSetup} from "./PoolBaseSetup.sol";
import {SwapRouter} from "../../src/swap/SwapRouter.sol";
import {ISwapRouter} from "../../src/swap/interfaces/ISwapRouter.sol";
import {IPool} from "../../src/swap/interfaces/IPool.sol";
import {IOrderbook} from "../../src/exchange/interfaces/IOrderbook.sol";
import {ExchangeOrderbook} from "../../src/exchange/libraries/ExchangeOrderbook.sol";
import {MockQuote} from "../../src/mock/MockQuote.sol";
import {Pool} from "../../src/swap/Pool.sol";
import {console} from "forge-std/console.sol";

/// PoC for the second half of the class: the revert DOES carry data, but the selector
/// belongs to Pool / Orderbook / MatchingEngine, none of which appear in the ABI a wagmi
/// client holds for SwapRouter (SwapRouter's ABI declares exactly two errors:
/// PoolDoesNotExist and SlippageExceeded). viem cannot map the selector, so the UI falls
/// back to a bare "execution reverted" with no name and no arguments -- indistinguishable,
/// from the frontend's point of view, from the out-of-gas case.
contract PoCUndecodableError is PoolBaseSetup {
    SwapRouter router;
    ISwapRouter.RemainderConfig empty;

    // The complete set of custom errors SwapRouter's own ABI can decode.
    function _routerAbiSelectors() internal pure returns (bytes4[] memory sels) {
        sels = new bytes4[](2);
        sels[0] = ISwapRouter.PoolDoesNotExist.selector;
        sels[1] = ISwapRouter.SlippageExceeded.selector;
    }

    function _decodableByRouterAbi(bytes4 sel) internal pure returns (bool) {
        bytes4[] memory sels = _routerAbiSelectors();
        for (uint256 i = 0; i < sels.length; i++) {
            if (sels[i] == sel) return true;
        }
        return false;
    }

    function _selectorOf(bytes memory ret) internal pure returns (bytes4 sel) {
        if (ret.length < 4) return bytes4(0);
        assembly {
            sel := mload(add(ret, 32))
        }
    }

    function setUp() public override {
        super.setUp();
        router = new SwapRouter(address(poolFactory));
        matchingEngine.setSwapRouter(address(router));
    }

    function _swapCalldata(address tokenIn, address tokenOut, uint256 amountIn)
        internal
        view
        returns (bytes memory)
    {
        address[] memory path = new address[](2);
        path[0] = tokenIn;
        path[1] = tokenOut;
        // encodeCall, not encodeWithSelector: the compiler then type-checks these arguments
        // against the real signature. Hand-encoded positional calldata survived the move to
        // ISwapRouter.SwapInput without a murmur — it simply stopped decoding, and every
        // assertion here reported "no return data", which is exactly what these tests are
        // built to detect. They were reporting on their own broken calldata.
        return abi.encodeCall(
            ISwapRouter.swap,
            (
                ISwapRouter.SwapInput({
                    path: path,
                    amountIn: amountIn,
                    minAmountOut: uint256(0),
                    recipient: trader1,
                    remainderMode: ISwapRouter.RemainderMode.Refund,
                    remainderConfig: empty
                })
            )
        );
    }

    /// Pool has no position covering the TWAP price -- the single most common real failure
    /// for a user hitting "swap" on a thin pair.
    function test_PoC_NoLiquidityInRange_isUndecodableThroughRouter() public {
        vm.prank(trader1);
        token2.approve(address(router), type(uint256).max);

        vm.prank(trader1);
        (bool ok, bytes memory ret) = address(router).call(
            _swapCalldata(address(token2), address(token1), 1e18)
        );

        assertFalse(ok, "swap should revert");
        bytes4 sel = _selectorOf(ret);
        console.log("revert selector:");
        console.logBytes4(sel);
        assertEq(sel, IPool.NoLiquidityInRange.selector, "revert really is Pool.NoLiquidityInRange");
        assertFalse(_decodableByRouterAbi(sel), "but SwapRouter's ABI cannot name it");
    }

    /// Freshly-listed pair: Orderbook's oracle has less than TWAP_WINDOW of history.
    /// The error is defined in the Oracle library and surfaces in Orderbook's ABI -- and
    /// nowhere near SwapRouter's.
    function test_PoC_InsufficientHistory_isUndecodableThroughRouter() public {
        MockQuote token3 = new MockQuote("Quote3", "QUOTE3");
        token3.mint(trader1, 10000e18);
        matchingEngine.addPair(
            address(token1), address(token3), 1e8, 0, address(token1), ExchangeOrderbook.MatchingMode.PriceTimePriority
        );
        Pool freshPool = Pool(poolFactory.getPool(address(token1), address(token3)));
        assertTrue(address(freshPool) != address(0));

        vm.prank(trader1);
        token3.approve(address(router), type(uint256).max);

        vm.prank(trader1);
        (bool ok, bytes memory ret) = address(router).call(
            _swapCalldata(address(token3), address(token1), 1e18)
        );

        assertFalse(ok, "swap should revert");
        bytes4 sel = _selectorOf(ret);
        console.log("revert selector:");
        console.logBytes4(sel);
        assertFalse(_decodableByRouterAbi(sel), "SwapRouter's ABI cannot name it");
        assertGt(ret.length, 0, "data is present -- it is simply unmappable");
    }

    /// The TransferHelper family: a failed pull reverts with Error(string) carrying a
    /// two-letter code ("TFF"), not a custom error. Nothing in the string tells a user
    /// which token, which allowance, or which hop.
    function test_PoC_transferHelperRevertsWithOpaqueTwoLetterString() public {
        // trader1 never approved the router.
        vm.prank(trader1);
        (bool ok, bytes memory ret) = address(router).call(
            _swapCalldata(address(token2), address(token1), 1e18)
        );

        assertFalse(ok, "swap should revert");
        assertEq(_selectorOf(ret), bytes4(keccak256("Error(string)")), "plain Error(string)");
        string memory reason = abi.decode(_slice4(ret), (string));
        console.log("revert string:", reason);
        assertEq(reason, "TFF");
    }

    function _slice4(bytes memory b) internal pure returns (bytes memory out) {
        out = new bytes(b.length - 4);
        for (uint256 i = 4; i < b.length; i++) {
            out[i - 4] = b[i];
        }
    }
}
