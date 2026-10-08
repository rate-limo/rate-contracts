// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {console} from "forge-std/console.sol";
import {ExchangeOrderbook} from "../../src/exchange/libraries/ExchangeOrderbook.sol";
import {AssetGenerator} from "../../src/asset/AssetGenerator.sol";
import {AssetLaunchLib, LaunchEscrow} from "../../src/asset/libraries/AssetLaunchLib.sol";
import {BandPool} from "../../src/swap/BandPool.sol";
import {PoolBands} from "../../src/swap/PoolBands.sol";
import {PoolPositions} from "../../src/swap/PoolPositions.sol";
import {IBandPositionManager} from "../../src/swap/interfaces/IBandPositionManager.sol";
import {IMatchingEngine} from "../../src/exchange/interfaces/IMatchingEngine.sol";
import {IOrderbook} from "../../src/exchange/interfaces/IOrderbook.sol";
import {MockBase} from "../../src/mock/MockBase.sol";
import {MockQuote} from "../../src/mock/MockQuote.sol";
import {BandBaseSetup} from "../swap/BandBaseSetup.sol";

contract Usdc6 is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

/**
 * A launch is a dev buy plus a five-step ladder on the order book, against the real
 * engine, orderbook, oracle, band factory and position manager.
 *
 * Supply 1e9, USDC, $5,000 -> $25,000: the steps rest at 500 / 748 / 1119 / 1672 / 2500
 * (1e8 units), 160M coins each.
 */
contract DevBuyLaunchTest is BandBaseSetup {
    AssetGenerator internal gen;
    Usdc6 internal usdc;
    address internal launcher = address(0x1A0C);
    address internal feeTo = address(0xFEE);

    uint256 internal constant SUPPLY = 1_000_000_000e18;
    uint256 internal constant MCAP6 = 5_000e6;
    uint256 internal constant GRAD6 = 25_000e6;
    uint256 internal constant MIN6 = 5e6;
    uint256 internal constant FEE = 2 ether;
    uint32 internal constant COIN_FEE = 1_000_000; // 1%
    uint256 internal constant STEP = 160_000_000e18;

    AssetGenerator.LockMode internal constant FEES_ONLY = AssetGenerator.LockMode.FeesOnly;
    AssetGenerator.LockMode internal constant VEST = AssetGenerator.LockMode.Vest12Months;

    function setUp() public virtual override {
        super.setUp();
        usdc = new Usdc6();
        gen = new AssetGenerator(address(this), address(matchingEngine));
        gen.setFeeTo(feeTo);
        gen.setLaunchFee(FEE);
        gen.setQuoteOption(
            address(usdc), true, MCAP6, MIN6, GRAD6, ExchangeOrderbook.MatchingMode.PriceTimePriority, COIN_FEE
        );
        gen.setQuoteOption(
            address(token2), true, 5_000e18, 5e18, 25_000e18, ExchangeOrderbook.MatchingMode.PriceTimePriority, COIN_FEE
        );
        // As deployed: the generator lists and sets spreads (MARKET_MAKER_ROLE), writes
        // each pair's fee (feeManager) and answers the engine's per-pair lookups (incentive).
        matchingEngine.grantRole(keccak256("MARKET_MAKER_ROLE"), address(gen));
        matchingEngine.setFeeManager(address(gen));
        matchingEngine.setIncentive(address(gen));
        matchingEngine.setPoolFeeShare(50_000_000);

        usdc.mint(launcher, 1_000_000e6);
        token2.mint(launcher, 1_000_000e18);
        vm.deal(launcher, 10 ether);
        vm.startPrank(launcher);
        usdc.approve(address(gen), type(uint256).max);
        token2.approve(address(gen), type(uint256).max);
        vm.stopPrank();
    }

    function _launch(address quote, uint256 devBuy) internal returns (address coin) {
        return _launchMode(quote, devBuy, FEES_ONLY);
    }

    function _launchMode(address quote, uint256 devBuy, AssetGenerator.LockMode mode) internal returns (address coin) {
        vm.prank(launcher);
        coin = gen.launch{value: FEE}("Launch Coin", "LNCH", SUPPLY, quote, devBuy, mode);
    }

    function _pool(address coin, address quote) internal view returns (BandPool) {
        address p = poolFactory.getPool(coin, quote);
        if (p == address(0)) p = poolFactory.getPool(quote, coin);
        return BandPool(p);
    }

    /// An ordinary limit buy of everything left at ladder step `i`, as the UI sends it.
    function _buyStep(address coin, address buyer, uint256 i) internal returns (uint256 spent) {
        AssetLaunchLib.Ladder memory l = gen.ladderOf(coin);
        ExchangeOrderbook.Order memory o = IOrderbook(l.pair).getOrder(false, l.askIds[i]);
        uint256 cost = IOrderbook(l.pair).convert(o.price, o.depositAmount, true) + 1;
        usdc.mint(buyer, cost);
        uint256 before = usdc.balanceOf(buyer);
        vm.startPrank(buyer);
        usdc.approve(address(matchingEngine), type(uint256).max);
        matchingEngine.limitBuy(
            IMatchingEngine.LimitOrderInput({
                base: coin, quote: address(usdc), price: o.price, amount: cost, isMaker: false, n: 5, recipient: buyer
            })
        );
        vm.stopPrank();
        spent = before - usdc.balanceOf(buyer);
    }

    function _walk(address coin, address buyer) internal {
        for (uint256 i = 0; i < 5; i++) {
            _buyStep(coin, buyer, i);
        }
    }

    function _graduate(address coin) internal {
        gen.graduate(coin); // arms
        vm.warp(block.timestamp + gen.GRADUATION_DELAY());
        gen.graduate(coin);
    }

    /* ------------------------------ the free path ------------------------------ */

    function test_launch_givesTheCreatorOnlyWhatTheyBought() public {
        address coin = _launch(address(usdc), MIN6);
        AssetLaunchLib.Ladder memory l = gen.ladderOf(coin);
        // $5 at a $5,000 market cap is 0.1% of supply.
        assertEq(IERC20(coin).balanceOf(launcher), SUPPLY / 1000, "only the dev buy");
        assertEq(IERC20(coin).balanceOf(address(gen)), 0, "generator keeps no loose supply");
        assertEq(IERC20(coin).balanceOf(l.pair), SUPPLY * 8 / 10, "80% rests on the book");
        assertEq(IERC20(coin).balanceOf(l.escrow), SUPPLY - SUPPLY * 8 / 10 - SUPPLY / 1000, "held back");
        assertEq(usdc.balanceOf(l.escrow), MIN6, "the dev buy's quote waits in the escrow");
    }

    /* -------------------------------- dev buy size ----------------------------- */

    function test_devBuy_belowTheMinimumReverts() public {
        vm.prank(launcher);
        vm.expectRevert(abi.encodeWithSelector(AssetGenerator.DevBuyTooSmall.selector, MIN6 - 1, MIN6));
        gen.launch{value: FEE}("Launch Coin", "LNCH", SUPPLY, address(usdc), MIN6 - 1, FEES_ONLY);
    }

    function test_devBuy_ofZeroReverts() public {
        vm.prank(launcher);
        vm.expectRevert(abi.encodeWithSelector(AssetGenerator.DevBuyTooSmall.selector, 0, MIN6));
        gen.launch{value: FEE}("Launch Coin", "LNCH", SUPPLY, address(usdc), 0, FEES_ONLY);
    }

    function test_devBuy_ofExactlyTenPercentIsAllowed() public {
        address coin = _launch(address(usdc), 500e6);
        assertEq(IERC20(coin).balanceOf(launcher), SUPPLY / 10);
    }

    function test_devBuy_overTenPercentReverts() public {
        vm.prank(launcher);
        vm.expectPartialRevert(AssetGenerator.DevBuyTooLarge.selector);
        gen.launch{value: FEE}("Launch Coin", "LNCH", SUPPLY, address(usdc), 501e6, FEES_ONLY);
    }

    /* ---------------------------------- units ---------------------------------- */

    function test_ladderPrices_sixDecimalQuote() public {
        address coin = _launch(address(usdc), 50e6);
        AssetLaunchLib.Ladder memory l = gen.ladderOf(coin);
        uint256[5] memory want = [uint256(500), 748, 1119, 1672, 2500];
        for (uint256 i = 0; i < 5; i++) {
            ExchangeOrderbook.Order memory o = IOrderbook(l.pair).getOrder(false, l.askIds[i]);
            assertEq(o.price, want[i], "step price");
            assertEq(o.depositAmount, STEP, "16% of supply");
            assertEq(o.owner, l.escrow, "owned by the escrow");
        }
        assertEq(IOrderbook(l.pair).lmp(), 500, "listed at step 0");
        assertEq(IERC20(coin).balanceOf(launcher), SUPPLY / 100, "$50 is 1% of a $5,000 cap");
    }

    function test_ladderPrices_eighteenDecimalQuote() public {
        address coin = _launch(address(token2), 5e18);
        AssetLaunchLib.Ladder memory l = gen.ladderOf(coin);
        assertEq(IOrderbook(l.pair).getOrder(false, l.askIds[0]).price, 500);
        assertEq(IOrderbook(l.pair).getOrder(false, l.askIds[4]).price, 2500);
        assertEq(IERC20(coin).balanceOf(launcher), SUPPLY / 1000);
    }

    /// L-3: a price that does not divide evenly rounds UP, never selling below the cap.
    function test_listingPrice_roundsUp() public view {
        // 5,000e6 * 1e12 * 1e8 / 3e26 = 1666.67 -> 1667
        assertEq(AssetLaunchLib.listingPrice(address(usdc), 300_000_000e18, MCAP6), 1667);
    }

    function test_price_belowOneHundredUnitsReverts() public {
        vm.prank(launcher);
        vm.expectRevert(abi.encodeWithSelector(AssetGenerator.ListingPriceTooLow.selector, uint256(5)));
        gen.launch{value: FEE}("Launch Coin", "LNCH", SUPPLY * 100, address(usdc), MIN6, FEES_ONLY);
    }

    /* ------------------------------- the ladder -------------------------------- */

    function test_aPlainBuyer_walksAllFiveSteps_atRisingPrices() public {
        address coin = _launch(address(usdc), MIN6);
        uint256[5] memory want = [uint256(800e6), 1196.8e6, 1790.4e6, 2675.2e6, 4000e6];
        for (uint256 i = 0; i < 5; i++) {
            uint256 spent = _buyStep(coin, trader1, i);
            assertApproxEqAbs(spent, want[i], 1, "each step costs its own price");
        }
        // Takers pay the 1% coin fee on what they receive.
        assertEq(IERC20(coin).balanceOf(trader1), STEP * 5 * 99 / 100);
        gen.graduate(coin); // the ladder reads as filled
    }

    /// A market buy keeps the pair's 1% slippage limit and cannot climb to the next
    /// step: the ladder is bought with limit orders.
    function test_aMarketBuy_staysWithinTheCurrentStep() public {
        address coin = _launch(address(usdc), MIN6);
        usdc.mint(trader1, 5_000e6);
        vm.startPrank(trader1);
        usdc.approve(address(matchingEngine), type(uint256).max);
        matchingEngine.marketBuy(
            IMatchingEngine.MarketOrderInput({
                base: coin, quote: address(usdc), amount: 5_000e6, isMaker: false, n: 5, recipient: trader1,
                slippageLimit: 0
            })
        );
        vm.stopPrank();
        assertLe(IERC20(coin).balanceOf(trader1), STEP, "step 0 at most");
    }

    /* ----------------------------- reviewer PoCs ------------------------------- */

    /// C-1, adapted: one big buy right after launch takes step 0 at the start price and
    /// step 1 at ITS price -- one limit order reaches one step past the last fill -- and
    /// nothing more. The rest of the 6,000 USDC comes back.
    function test_poc_aSnipeGetsTwoStepsAtTheirOwnPrices() public {
        address coin = _launch(address(usdc), MIN6);
        usdc.mint(trader1, 6_000e6);
        vm.startPrank(trader1);
        usdc.approve(address(matchingEngine), type(uint256).max);
        matchingEngine.limitBuy(
            IMatchingEngine.LimitOrderInput({
                base: coin, quote: address(usdc), price: 1e12, amount: 6_000e6, isMaker: false, n: 20,
                recipient: trader1
            })
        );
        vm.stopPrank();
        uint256 got = IERC20(coin).balanceOf(trader1);
        uint256 spent = 6_000e6 - usdc.balanceOf(trader1);
        console.log("snipe share of supply (bps)", got * 10_000 / SUPPLY);
        console.log("usdc spent", spent / 1e6);
        assertEq(got, STEP * 2 * 99 / 100, "two steps, net of the 1% fee");
        assertApproxEqAbs(spent, 800e6 + 1196.8e6, 2, "each at its own price");
    }

    /// C-1, the pool route: the bands are closed and empty, so there is nothing to swap.
    function test_poc_thePoolHasNothingToSellBeforeGraduation() public {
        address coin = _launch(address(usdc), MIN6);
        BandPool p = _pool(coin, address(usdc));
        usdc.mint(trader1, 6_000e6);
        vm.startPrank(trader1);
        usdc.approve(address(router), type(uint256).max);
        vm.expectRevert();
        router.swap(address(p), 6_000e6, true, trader1, 0);
        vm.stopPrank();
        assertEq(IERC20(coin).balanceOf(trader1), 0);
    }

    /// M-1, adapted: a deposit cannot reach a closed band, and graduation reads the
    /// ladder's order state, so neither borrowed nor parked quote graduates a coin.
    function test_poc_noDepositGraduation() public {
        address coin = _launch(address(usdc), MIN6);
        BandPool p = _pool(coin, address(usdc));
        usdc.mint(launcher, 50_000e6);
        IBandPositionManager.MintParams memory m;
        m.pool = address(p);
        m.bands = new uint8[](1);
        m.baseAmounts = new uint256[](1);
        m.quoteAmounts = new uint256[](1);
        m.quoteAmounts[0] = 50_000e6;
        m.minShares = new uint128[](1);
        m.recipient = launcher;
        m.deadline = block.timestamp;
        vm.startPrank(launcher);
        usdc.approve(address(positionManager), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(PoolPositions.BandClosed.selector, uint8(0)));
        positionManager.mint(m);
        vm.expectRevert(abi.encodeWithSelector(AssetGenerator.LadderNotFilled.selector, uint256(0)));
        gen.graduate(coin);
        vm.stopPrank();
    }

    /// M-2, adapted: before graduation the pool's bands belong to the generator.
    function test_poc_aLockedCreatorCannotTouchTheBands() public {
        address coin = _launch(address(usdc), MIN6);
        BandPool p = _pool(coin, address(usdc));
        assertEq(p.creator(), address(gen));
        vm.startPrank(launcher);
        vm.expectRevert();
        p.setBandFeeMultiplier(0, 300_000_000);
        vm.expectRevert();
        p.setBandOpen(0, true);
        vm.stopPrank();
    }

    /// H-1, adapted: there is no day-30 release. Before graduation nobody can withdraw
    /// anything, and after it the principal is locked by the creator's chosen mode.
    function test_poc_nothingLeavesAnUngraduatedLaunch() public {
        address coin = _launch(address(usdc), 50e6);
        AssetLaunchLib.Ladder memory l = gen.ladderOf(coin);
        _buyStep(coin, trader1, 0);
        vm.warp(block.timestamp + 3650 days);

        vm.prank(launcher);
        vm.expectRevert(LaunchEscrow.NotGenerator.selector);
        LaunchEscrow(l.escrow).sweep(address(usdc), launcher);

        vm.prank(launcher);
        vm.expectRevert();
        matchingEngine.cancelOrder(coin, address(usdc), false, l.askIds[1]);

        vm.startPrank(launcher);
        vm.expectRevert(abi.encodeWithSelector(AssetGenerator.NotGraduated.selector, coin));
        gen.collectLockedFees(coin, launcher);
        vm.expectRevert(abi.encodeWithSelector(AssetGenerator.NotGraduated.selector, coin));
        gen.releaseVested(coin, launcher);
        vm.stopPrank();
        assertEq(usdc.balanceOf(l.escrow), 50e6 + 800e6, "every dollar raised is still there");
    }

    /* -------------------------------- graduation ------------------------------- */

    function test_graduate_twoPhase() public {
        address coin = _launch(address(usdc), MIN6);
        vm.expectRevert(abi.encodeWithSelector(AssetGenerator.LadderNotFilled.selector, uint256(0)));
        gen.graduate(coin);
        _walk(coin, trader1);

        vm.prank(trader2); // permissionless
        gen.graduate(coin);
        (, uint64 readyAt,,,,) = gen.launchLocks(coin);
        assertEq(readyAt, block.timestamp + 300);
        vm.expectRevert(abi.encodeWithSelector(AssetGenerator.GraduationNotReady.selector, readyAt));
        gen.graduate(coin);

        vm.warp(readyAt);
        vm.prank(trader2);
        gen.graduate(coin);
        (,,,,,,,, bool graduated) = gen.launches(coin);
        assertTrue(graduated);
        vm.expectRevert(abi.encodeWithSelector(AssetGenerator.AlreadyGraduated.selector, coin));
        gen.graduate(coin);
    }

    function test_graduate_seedsExactlyWhatWasRaised_andRestoresTheMarket() public {
        address coin = _launch(address(usdc), 50e6);
        AssetLaunchLib.Ladder memory l = gen.ladderOf(coin);
        uint256 restore = l.restoreBuySpread;
        assertGt(matchingEngine.getSpread(l.pair, true, false), restore, "widened for the ladder");
        _walk(coin, trader1);
        uint256 raised = usdc.balanceOf(l.escrow);
        uint256 heldBack = IERC20(coin).balanceOf(l.escrow);
        assertApproxEqAbs(raised, 50e6 + 10_462.4e6, 5, "dev buy + every step");
        assertEq(heldBack, SUPPLY - SUPPLY * 8 / 10 - SUPPLY / 100);

        _graduate(coin);
        BandPool pool = _pool(coin, address(usdc));
        (,,,,, uint256 tokenId) = gen.launchLocks(coin);

        assertEq(usdc.balanceOf(l.escrow), 0, "escrow emptied");
        assertEq(IERC20(coin).balanceOf(l.escrow), 0);
        assertEq(usdc.balanceOf(address(pool)), raised, "every unit raised is in the pool");
        assertEq(IERC20(coin).balanceOf(address(pool)), heldBack, "and every held-back coin");
        assertEq(positionManager.balanceOf(address(gen), tokenId), 1, "the generator holds the position");
        uint256 n = pool.bandCount();
        assertEq(pool.bandMaskOf(tokenId), uint8((1 << n) - 1), "in every band");
        assertEq(matchingEngine.getSpread(l.pair, true, false), restore, "the spread is back");
        assertEq(pool.creator(), launcher, "band control passes to the creator");
        assertEq(pool.anchorPrice(), 2500, "the pool quotes at the last ladder price");
    }

    function test_graduate_thenTheCreatorRetunesWithinBounds() public {
        address coin = _launch(address(usdc), MIN6);
        vm.startPrank(launcher);
        vm.expectRevert(abi.encodeWithSelector(AssetGenerator.CreatorFeeControlLocked.selector, coin));
        gen.setPairTakerFee(coin, 500_000);
        vm.expectRevert(abi.encodeWithSelector(AssetGenerator.CreatorFeeControlLocked.selector, coin));
        gen.setPairTradingConfig(coin, 50, 0, 500_000);
        vm.stopPrank();

        _walk(coin, trader1);
        _graduate(coin);
        vm.prank(launcher);
        gen.setPairTradingConfig(coin, 20, 0, 500_000);
        assertEq(matchingEngine.feeOf(coin, address(usdc), trader1, false), 500_000, "the engine follows");
        assertEq(gen.slippageLimitOf(coin, address(usdc)), 20);
        vm.startPrank(launcher);
        vm.expectRevert(
            abi.encodeWithSelector(AssetGenerator.FeeAboveCreatorCap.selector, uint32(1_000_001), uint32(1_000_000))
        );
        gen.setPairTakerFee(coin, 1_000_001);
        vm.expectRevert(abi.encodeWithSelector(AssetGenerator.InvalidVolatility.selector, uint16(101)));
        gen.setPairTradingConfig(coin, 101, 0, 500_000);
        vm.stopPrank();
    }

    /* ------------------------------- lock modes -------------------------------- */

    function test_feesOnly_collectsForever_andNeverReleases() public {
        address coin = _launch(address(usdc), 50e6);
        _walk(coin, trader1);
        _graduate(coin);
        BandPool pool = _pool(coin, address(usdc));
        (,,,,, uint256 tokenId) = gen.launchLocks(coin);

        vm.prank(launcher);
        vm.expectRevert(abi.encodeWithSelector(AssetGenerator.NotVesting.selector, coin));
        gen.releaseVested(coin, launcher);

        // Trading earns the position fees.
        usdc.mint(trader2, 1_000e6);
        vm.startPrank(trader2);
        usdc.approve(address(router), type(uint256).max);
        router.swap(address(pool), 500e6, pool.base() == coin, trader2, 0);
        vm.stopPrank();
        vm.warp(block.timestamp + 3650 days);

        uint256 coinBefore = IERC20(coin).balanceOf(launcher);
        uint256 usdcBefore = usdc.balanceOf(launcher);
        vm.prank(launcher);
        gen.collectLockedFees(coin, launcher);
        uint256 gained = (IERC20(coin).balanceOf(launcher) - coinBefore) + (usdc.balanceOf(launcher) - usdcBefore);
        assertGt(gained, 0, "fees, ten years on");
        assertEq(positionManager.balanceOf(address(gen), tokenId), 1, "the principal never moves");
        assertGt(pool.bandMaskOf(tokenId), 0);

        vm.prank(trader1);
        vm.expectRevert(abi.encodeWithSelector(AssetGenerator.NotTheCreator.selector, trader1));
        gen.collectLockedFees(coin, trader1);
    }

    function test_vest12Months_releasesLinearly() public {
        address coin = _launchMode(address(usdc), 50e6, VEST);
        AssetLaunchLib.Ladder memory l = gen.ladderOf(coin);
        _walk(coin, trader1);
        uint256 raised = usdc.balanceOf(l.escrow);
        _graduate(coin);

        vm.prank(launcher);
        vm.expectRevert(AssetGenerator.NothingToRelease.selector);
        gen.releaseVested(coin, launcher);

        uint256 u0 = usdc.balanceOf(launcher);
        vm.warp(block.timestamp + 365 days / 2);
        vm.prank(launcher);
        gen.releaseVested(coin, launcher);
        assertApproxEqRel(usdc.balanceOf(launcher) - u0, raised / 2, 0.001e18, "half at six months");

        vm.prank(trader1);
        vm.expectRevert(abi.encodeWithSelector(AssetGenerator.NotTheCreator.selector, trader1));
        gen.releaseVested(coin, trader1);

        vm.warp(block.timestamp + 365 days);
        vm.prank(launcher);
        gen.releaseVested(coin, launcher);
        assertApproxEqAbs(usdc.balanceOf(launcher) - u0, raised, 10, "all of it at a year");
        (,,, uint16 released,,) = gen.launchLocks(coin);
        assertEq(released, 10_000);
        vm.prank(launcher);
        vm.expectRevert(AssetGenerator.NothingToRelease.selector);
        gen.releaseVested(coin, launcher);
    }

    /* ----------------------------------- fee ----------------------------------- */

    function test_launchFee_goesToFeeTo_andTheExcessIsRefunded() public virtual {
        uint256 before = launcher.balance;
        vm.prank(launcher);
        gen.launch{value: FEE + 1 ether}("Launch Coin", "LNCH", SUPPLY, address(usdc), MIN6, FEES_ONLY);
        assertEq(feeTo.balance, FEE);
        assertEq(launcher.balance, before - FEE);
    }

    function test_aLaunchedCoin_chargesTakersOnePercent_andMakersNothing() public {
        address coin = _launch(address(usdc), 50e6);
        assertEq(matchingEngine.feeOf(coin, address(usdc), trader1, false), COIN_FEE);
        assertEq(matchingEngine.feeOf(coin, address(usdc), trader1, true), 0);
        uint256 sink = IERC20(coin).balanceOf(matchingEngine.feeTo());
        _buyStep(coin, trader1, 0);
        assertEq(IERC20(coin).balanceOf(matchingEngine.feeTo()) - sink, STEP / 100, "exactly 1% of the fill");
    }

    function test_aLaunchedCoin_poolBandsChargeOneTwoThreePercent() public {
        address coin = _launch(address(usdc), 50e6);
        BandPool pool = _pool(coin, address(usdc));
        uint256 rate = matchingEngine.feeOf(coin, address(usdc), trader1, false);
        assertEq(pool.effectiveFeeRate(0, rate), 1_000_000);
        assertEq(pool.effectiveFeeRate(1, rate), 2_000_000);
        assertEq(pool.effectiveFeeRate(2, rate), 3_000_000, "3x, and exactly the 3% cap");
    }

    function test_anUnrelatedMarket_keepsTheEngineDefault() public view {
        assertEq(matchingEngine.feeOf(address(token1), address(token2), trader1, false), 100_000);
    }

    function test_admin_cannotSetAFeeAboveThreePercent() public {
        address coin = _launch(address(usdc), MIN6);
        vm.expectRevert(abi.encodeWithSelector(AssetGenerator.InvalidFee.selector, uint32(3_000_001)));
        gen.setPairTakerFee(coin, 3_000_001);
    }

    /* -------------------------------- listPair --------------------------------- */

    function _newPair() internal returns (MockBase b, MockQuote q) {
        b = new MockBase("Listed", "LST");
        q = new MockQuote("Listed Quote", "LQT");
        b.mint(lp1, 1_000_000e18);
        q.mint(trader1, 1_000_000e18);
    }

    function _list(MockBase b, MockQuote q, uint16 bps, uint32 fee) internal returns (address pair) {
        vm.prank(lp1);
        pair = gen.listPair(address(b), address(q), 1e8, bps, fee);
    }

    /// Rest `amount` of base at `price` from `maker`, take it all from `taker`; returns
    /// what the engine's feeTo received, in base.
    function _fill(address base, address quote, address maker, address taker, uint256 price, uint256 amount)
        internal
        returns (uint256 fee)
    {
        address sink = matchingEngine.feeTo();
        uint256 sinkBefore = IERC20(base).balanceOf(sink);
        vm.startPrank(maker);
        IERC20(base).approve(address(matchingEngine), type(uint256).max);
        matchingEngine.limitSell(
            IMatchingEngine.LimitOrderInput({
                base: base, quote: quote, price: price, amount: amount, isMaker: true, n: 2, recipient: maker
            })
        );
        vm.stopPrank();
        uint256 cost = IOrderbook(matchingEngine.getPair(base, quote)).convert(price, amount, true);
        vm.startPrank(taker);
        IERC20(quote).approve(address(matchingEngine), type(uint256).max);
        matchingEngine.limitBuy(
            IMatchingEngine.LimitOrderInput({
                base: base, quote: quote, price: price, amount: cost, isMaker: false, n: 2, recipient: taker
            })
        );
        vm.stopPrank();
        fee = IERC20(base).balanceOf(sink) - sinkBefore;
    }

    function test_listPair_recordsThePolicy_andKeepsThePool() public {
        (MockBase b, MockQuote q) = _newPair();
        address pair = _list(b, q, 50, 300_000);
        (uint16 bps, uint32 maker, uint32 taker, bool configured) = gen.pairPolicies(pair);
        assertTrue(configured);
        assertEq(bps, 50);
        assertEq(maker, 0);
        assertEq(taker, 300_000);
        assertEq(gen.pairLister(pair), lp1);
        BandPool listed = _pool(address(b), address(q));
        assertEq(listed.creator(), address(gen), "the pool stays recoverable");
        assertEq(listed.pairLimit(true), 500_000, "50 bps reached the pool");
    }

    function test_listPair_chargesTheListersFee() public {
        (MockBase b, MockQuote q) = _newPair();
        _list(b, q, 50, 300_000);
        assertEq(_fill(address(b), address(q), lp1, trader1, 1e8, 1_000e18), 3e18, "0.30%");
        (MockBase b2, MockQuote q2) = _newPair();
        _list(b2, q2, 50, 50_000);
        assertEq(_fill(address(b2), address(q2), lp1, trader1, 1e8, 1_000e18), 0.5e18, "0.05%");
    }

    function test_listPair_refusesBadInput() public {
        (MockBase b, MockQuote q) = _newPair();
        vm.startPrank(lp1);
        vm.expectRevert(abi.encodeWithSelector(AssetGenerator.ListingPriceTooLow.selector, uint256(99)));
        gen.listPair(address(b), address(q), 99, 50, 300_000);
        vm.expectRevert(abi.encodeWithSelector(AssetGenerator.InvalidVolatility.selector, uint16(101)));
        gen.listPair(address(b), address(q), 1e8, 101, 300_000);
        vm.expectRevert(
            abi.encodeWithSelector(AssetGenerator.FeeAboveCreatorCap.selector, uint32(1_000_001), uint32(1_000_000))
        );
        gen.listPair(address(b), address(q), 1e8, 50, 1_000_001);
        vm.expectRevert(
            abi.encodeWithSelector(AssetGenerator.PairAlreadyListed.selector, address(token2), address(token1))
        );
        gen.listPair(address(token2), address(token1), 1e8, 50, 300_000);
        vm.stopPrank();
    }

    function test_lister_configuresBandsThroughTheGenerator_andAdminCanReassign() public {
        (MockBase b, MockQuote q) = _newPair();
        address pair = _list(b, q, 50, 300_000);
        BandPool pool = _pool(address(b), address(q));

        vm.prank(lp1);
        gen.listerBandCall(address(b), address(q), abi.encodeCall(PoolBands.setBandFeeMultiplier, (0, 200_000_000)));
        assertEq(pool.bandFeeMultiplier(0), 200_000_000);

        vm.prank(lp1);
        vm.expectRevert(
            abi.encodeWithSelector(AssetGenerator.BandCallNotAllowed.selector, PoolBands.transferCreator.selector)
        );
        gen.listerBandCall(address(b), address(q), abi.encodeCall(PoolBands.transferCreator, (lp1)));

        vm.prank(trader1);
        vm.expectRevert(abi.encodeWithSelector(AssetGenerator.NotTheLister.selector, trader1));
        gen.listerBandCall(address(b), address(q), abi.encodeCall(PoolBands.setBandOpen, (0, false)));

        gen.reassignPairLister(pair, trader1);
        vm.prank(trader1);
        gen.listerBandCall(address(b), address(q), abi.encodeCall(PoolBands.setBandOpen, (0, false)));
        vm.prank(lp1);
        vm.expectRevert(abi.encodeWithSelector(AssetGenerator.NotTheLister.selector, lp1));
        gen.listerBandCall(address(b), address(q), abi.encodeCall(PoolBands.setBandOpen, (0, true)));
    }

    function test_lister_retunesWithinTheCap_makersStayFree() public {
        (MockBase b, MockQuote q) = _newPair();
        address pair = _list(b, q, 50, 300_000);
        vm.prank(lp1);
        gen.setExistingPairTradingConfig(address(b), address(q), 20, 0, 1_000_000);
        assertEq(matchingEngine.feeOf(address(b), address(q), trader1, false), 1_000_000);

        vm.startPrank(lp1);
        vm.expectRevert(abi.encodeWithSelector(AssetGenerator.InvalidFee.selector, uint32(50_000)));
        gen.setExistingPairTradingConfig(address(b), address(q), 20, 50_000, 1_000_000);
        vm.expectRevert(
            abi.encodeWithSelector(AssetGenerator.FeeAboveCreatorCap.selector, uint32(1_000_001), uint32(1_000_000))
        );
        gen.setExistingPairTradingConfig(address(b), address(q), 20, 0, 1_000_001);
        vm.stopPrank();

        gen.setCreatorFeeControl(pair, true);
        vm.prank(lp1);
        vm.expectRevert(abi.encodeWithSelector(AssetGenerator.CreatorFeeControlLocked.selector, pair));
        gen.setExistingPairTradingConfig(address(b), address(q), 20, 0, 100_000);
    }

    /* ----------------------------------- gas ----------------------------------- */

    function test_gas_launchAndGraduate() public {
        vm.prank(launcher);
        address coin = gen.launch{value: FEE}("Launch Coin", "LNCH", SUPPLY, address(usdc), MIN6, FEES_ONLY);
        console.log("launch gas", vm.lastCallGas().gasTotalUsed);
        _walk(coin, trader1);
        gen.graduate(coin);
        console.log("graduate (arm) gas", vm.lastCallGas().gasTotalUsed);
        vm.warp(block.timestamp + 300);
        gen.graduate(coin);
        console.log("graduate (seed) gas", vm.lastCallGas().gasTotalUsed);
    }
}
