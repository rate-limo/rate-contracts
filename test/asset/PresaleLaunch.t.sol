// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {PresaleLaunch} from "../../src/asset/PresaleLaunch.sol";

contract PresaleQuote is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract PresaleQuoteTwo is ERC20 {
    constructor() ERC20("USD Coin 2", "USDC2") {}
}

contract PresaleLaunchTest is Test {
    PresaleLaunch internal launch;
    PresaleQuote internal quote;
    address internal creator = address(0xA11CE);
    address internal treasury = address(0xB0B);
    address internal buyer = address(0xBEEF);

    function setUp() external {
        quote = new PresaleQuote();
        launch = new PresaleLaunch(address(this), address(0x100), address(0x200), address(0), address(quote));
        quote.mint(buyer, 200_000e6);
        vm.prank(buyer);
        quote.approve(address(launch), type(uint256).max);
    }

    function _params(uint64 startAt, uint64 endAt) internal view returns (PresaleLaunch.CreateParams memory p) {
        p = PresaleLaunch.CreateParams({
            name: "White Coin",
            symbol: "WHITE",
            totalSupply: 100_000_000e18,
            presaleAllocation: 10_000_000e18,
            lpTokenAllocation: 2_000_000e18,
            priceQuotePerToken: 10_000,
            targetRaise: 100_000e6,
            minimumRaise: 50_000e6,
            maxPerWallet: 5_000e6,
            creatorTokenAllocation: 20_000_000e18,
            treasuryTokenAllocation: 68_000_000e18,
            startAt: startAt,
            endAt: endAt,
            creatorCliff: 90 days,
            creatorVestingDuration: 365 days,
            lpBps: 2_000,
            quote: address(quote),
            treasury: treasury
        });
    }

    function testCreateAndEnforceWalletCap() external {
        vm.warp(100);
        PresaleLaunch.CreateParams memory p = _params(100, 200);
        vm.prank(creator);
        (uint256 id,) = launch.createPresale(p);

        vm.prank(buyer);
        launch.commit(id, 5_000e6);
        vm.prank(buyer);
        vm.expectRevert(PresaleLaunch.ExceedsWalletCap.selector);
        launch.commit(id, 1);
    }

    function testRefundOnUnmetMinimum() external {
        vm.warp(100);
        PresaleLaunch.CreateParams memory p = _params(100, 200);
        p.minimumRaise = 60_000e6;
        vm.prank(creator);
        (uint256 id,) = launch.createPresale(p);
        vm.prank(buyer);
        launch.commit(id, 5_000e6);

        vm.warp(201);
        launch.finalizeSale(id);
        assertEq(uint256(launch.statusOf(id)), uint256(PresaleLaunch.Status.Failed));
        uint256 beforeBalance = quote.balanceOf(buyer);
        vm.prank(buyer);
        launch.claim(id);
        assertEq(quote.balanceOf(buyer), beforeBalance + 5_000e6);
    }

    function testCannotClaimSuccessfulSaleBeforeGraduation() external {
        vm.warp(100);
        PresaleLaunch.CreateParams memory p = _params(100, 200);
        p.maxPerWallet = 100_000e6;
        vm.prank(creator);
        (uint256 id,) = launch.createPresale(p);
        vm.prank(buyer);
        launch.commit(id, 60_000e6);
        vm.warp(201);
        launch.finalizeSale(id);
        // A successful sale keeps the LP token allocation reserved until graduation.
        vm.prank(buyer);
        vm.expectRevert(PresaleLaunch.NotSuccessful.selector);
        launch.claim(id);
    }

    function testAdminCanConfigureAdditionalSettlementToken() external {
        PresaleQuoteTwo secondQuote = new PresaleQuoteTwo();
        launch.setSettlementToken(address(secondQuote), true);
        assertTrue(launch.settlementTokenEnabled(address(secondQuote)));
        assertEq(launch.settlementToken(), address(secondQuote));
    }
}
