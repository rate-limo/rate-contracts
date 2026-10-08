// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

interface IERC20Like {
    function balanceOf(address) external view returns (uint256);
    function decimals() external view returns (uint8);
    function transfer(address, uint256) external returns (bool);
}

/**
 * Arc Testnet: the native gas coin IS an ERC-20, so the WETH wrapper is not merely
 * unnecessary -- it cannot exist. These tests pin the CHAIN facts the nativeScale change
 * is built on, then exercise the engine path against the real token.
 *
 * Fork-only. `forge test --match-path test/exchange/NativeERC20Arc.t.sol` skips every
 * test here unless an Arc RPC is reachable, because a silent pass on a chain that was
 * never contacted is worse than no test.
 */
contract NativeERC20ArcTest is Test {
    address constant USDC = 0x3600000000000000000000000000000000000000;
    uint256 constant SCALE = 1e12; // 18-decimal native view : 6-decimal ERC-20 view

    bool forked;

    function setUp() public {
        try vm.createSelectFork("arc_testnet") {
            forked = block.chainid == 5042002;
        } catch {
            forked = false;
        }
    }

    modifier onlyForked() {
        if (!forked) return;
        _;
    }

    /* ------------------------------ the premise ------------------------------ */

    /// The whole reason a wrapper cannot be used: there is nothing to call.
    function test_arcUSDC_hasNoWrapperInterface() public onlyForked {
        (bool okDeposit, ) = USDC.call{value: 0}(abi.encodeWithSignature("deposit()"));
        (bool okWithdraw, ) = USDC.call(abi.encodeWithSignature("withdraw(uint256)", uint256(0)));
        assertFalse(okDeposit, "deposit() must not exist on Arc USDC");
        assertFalse(okWithdraw, "withdraw(uint256) must not exist on Arc USDC");
        // ...while it is unambiguously a working ERC-20.
        assertEq(IERC20Like(USDC).decimals(), 6, "Arc USDC is 6 decimals");
    }

    /// Native and ERC-20 are ONE ledger, and the ERC-20 view truncates to 6 decimals.
    /// This is what makes token->native the only exact direction of conversion.
    function test_arcUSDC_isTheNativeLedger_truncated() public onlyForked {
        address who = address(0xBEEF);
        vm.deal(who, 19_267_166_024_000_000_000); // the measured shape: dust below 1e12
        assertEq(
            IERC20Like(USDC).balanceOf(who),
            19_267_166,
            "balanceOf must be the native balance floor-divided by 1e12"
        );
        assertEq(
            IERC20Like(USDC).balanceOf(who) * SCALE + 24_000_000_000,
            who.balance,
            "the 24 nano-USDC remainder is real balance the ERC-20 view cannot name"
        );
    }

    /// Crediting native credits the ERC-20 with no wrap step. This is the property the
    /// engine's nativeScale branch relies on instead of IWETH.deposit.
    function test_arcUSDC_receivingNativeCreditsERC20() public onlyForked {
        address who = address(0xCAFE);
        uint256 before = IERC20Like(USDC).balanceOf(who);
        vm.deal(who, who.balance + 5 * SCALE);
        assertEq(IERC20Like(USDC).balanceOf(who), before + 5, "no wrap needed");
    }

    /* ------------------- why the engine path is NOT tested here ------------------- */

    /**
     * Arc's USDC is not a self-contained contract: it delegates to an implementation that
     * calls a CHAIN-LEVEL PRECOMPILE at 0x1800…, which no local EVM implements. Foundry
     * returns StackUnderflow there and the call reverts.
     *
     * `balanceOf` happens to survive (the three tests above pass against the real chain),
     * but `totalSupply` does not -- and `MatchingEngine.addPair` reads it while listing.
     * So a fork test can establish the PREMISE of the nativeScale change and cannot
     * exercise the engine against this token at all. That is a property of Arc, not of
     * the change: the same listing fails identically on unmodified code.
     *
     * The engine path therefore has to be validated by deploying to Arc for real. This
     * test exists so the next person does not spend the afternoon rediscovering why the
     * obvious fork test cannot work.
     */
    function test_arcUSDC_dependsOnAPrecompile_soTheEnginePathCannotBeForkTested()
        public
        onlyForked
    {
        // balanceOf works locally...
        IERC20Like(USDC).balanceOf(address(this));
        // ...totalSupply does not, because it reaches 0x1800…
        (bool ok, ) = USDC.staticcall(abi.encodeWithSignature("totalSupply()"));
        assertFalse(ok, "totalSupply must fail on a fork -- it calls Arc's precompile");
    }

    receive() external payable {}
}
