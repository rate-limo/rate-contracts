// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {AssetGenerator, Coin} from "../../src/asset/AssetGenerator.sol";
import {ExchangeOrderbook} from "../../src/exchange/libraries/ExchangeOrderbook.sol";

/// @notice Minimal stand-in for the MatchingEngine: only the two functions the generator
/// calls. Rates are set per directed pair so a test can price a coin without a live book.
contract MockEngine {
    error PairDoesNotExist(address base, address quote, address pair);

    /// 1e18-scaled quote-per-base.
    mapping(address base => mapping(address quote => uint256 rate)) public rates;
    mapping(address base => mapping(address quote => address pair)) public pairs;

    uint256 public listingCost;
    address public lastBase;
    address public lastQuote;
    address public lastPayment;
    uint256 public lastListingPrice;

    function setRate(address base, address quote, uint256 rate) external {
        rates[base][quote] = rate;
    }

    /// @notice Charge a listing cost, exercising the generator's approve/transferFrom path.
    function setListingCost(uint256 cost) external {
        listingCost = cost;
    }

    function setPairFor(address base, address quote, address pair) external {
        pairs[base][quote] = pair;
    }

    function convert(address base, address quote, uint256 amount, bool) external view returns (uint256) {
        if (base == quote) return amount;
        uint256 rate = rates[base][quote];
        if (rate == 0) revert PairDoesNotExist(base, quote, address(0));
        return (amount * rate) / 1e18;
    }

    function addPair(
        address base,
        address quote,
        uint256 listingPrice,
        uint256,
        address payment,
        ExchangeOrderbook.MatchingMode
    ) external returns (address pair) {
        if (listingCost > 0) {
            IERC20(payment).transferFrom(msg.sender, address(this), listingCost);
        }
        pair = address(uint160(uint256(keccak256(abi.encodePacked(base, quote)))));
        pairs[base][quote] = pair;
        lastBase = base;
        lastQuote = quote;
        lastPayment = payment;
        lastListingPrice = listingPrice;
    }

    function getPair(address base, address quote) external view returns (address) {
        return pairs[base][quote];
    }
}

/// @notice Stands in for the incentive contract the engine used before the generator was
/// wired in — the thing foreign pairs must keep being answered by.
contract MockIncentive {
    uint32 internal immutable fee;
    string internal name_;

    constructor(uint32 fee_, string memory terminal) {
        fee = fee_;
        name_ = terminal;
    }

    function feeOf(address, address, address, bool) external view returns (uint32) {
        return fee;
    }

    function isSubscribed(address) external pure returns (bool) {
        return true;
    }

    function terminalName(address) external view returns (string memory) {
        return name_;
    }
}

contract MockStable is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {
        _mint(msg.sender, 1_000_000e6);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

contract MockWETH is ERC20 {
    constructor() ERC20("Wrapped Ether", "WETH") {
        _mint(msg.sender, 1_000e18);
    }
}

contract MockPoolIdentity {
    address internal immutable base;
    address internal immutable quote;

    constructor(address base_, address quote_) {
        base = base_;
        quote = quote_;
    }

    function getBaseQuote() external view returns (address, address) {
        return (base, quote);
    }
}

contract MockPositionManager is ERC1155 {
    mapping(uint256 => address) internal pools;

    constructor() ERC1155("") {}

    function mint(address to, uint256 tokenId, address pool) external {
        pools[tokenId] = pool;
        _mint(to, tokenId, 1, "");
    }

    function tokenPosition(uint256 tokenId) external view returns (address pool, uint256 positionId) {
        return (pools[tokenId], tokenId);
    }
}

contract AssetGeneratorTest is Test {
    AssetGenerator internal gen;
    MockEngine internal engine;
    MockStable internal usdc;
    MockWETH internal weth;

    address internal admin = makeAddr("admin");
    address internal creator = makeAddr("creator");
    address internal stranger = makeAddr("stranger");
    address internal feeTo = makeAddr("feeTo");

    uint256 internal constant SUPPLY = 1_000_000e18;
    uint256 internal constant FEE = 0.01 ether;

    event Launched(
        address indexed coin, address indexed creator, address indexed pair, address quote, uint256 totalSupply
    );

    function setUp() public {
        engine = new MockEngine();
        usdc = new MockStable();
        weth = new MockWETH();
        gen = new AssetGenerator(admin, address(engine));

        vm.startPrank(admin);
        gen.setFeeTo(feeTo);
        gen.setLaunchFee(FEE);
        gen.setQuoteOption(address(weth), true, 1e8, address(0), ExchangeOrderbook.MatchingMode.PriceTimePriority, 1_000_000);
        vm.stopPrank();

        // 1 WETH = 2,000 USDC, in USDC's 6 decimals against WETH's 18.
        engine.setRate(address(weth), address(usdc), 2000e6 * 1e18 / 1e18);
        vm.deal(creator, 10 ether);
        vm.deal(stranger, 10 ether);
    }

    function _launch() internal returns (address coin) {
        vm.prank(creator);
        return gen.launch{value: FEE}("Nova Protocol", "NOVA", SUPPLY, address(weth));
    }

    function _launchSettings(address paymentToken, uint64 lockDuration)
        internal
        pure
        returns (AssetGenerator.LaunchSettings memory)
    {
        return AssetGenerator.LaunchSettings({
            volatilityPreset: AssetGenerator.Preset.Standard,
            volatilityBps: 10,
            feePreset: AssetGenerator.Preset.Meme,
            makerFee: 50_000,
            takerFee: 1_000_000,
            paymentToken: paymentToken,
            liquidityLockDuration: lockDuration
        });
    }

    /* ------------------------------ access control ----------------------------- */

    function test_setQuoteOption_revertsForNonAdmin() public {
        // Read the role BEFORE pranking: a call inside the expectRevert argument would
        // consume the prank and the revert would name this test contract instead.
        bytes32 role = gen.ADMIN_ROLE();
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, role)
        );
        gen.setQuoteOption(address(usdc), true, 1e8, address(0), ExchangeOrderbook.MatchingMode.PriceTimePriority, 1_000_000);
    }

    function test_setLaunchFee_revertsForNonAdmin() public {
        vm.prank(stranger);
        vm.expectRevert();
        gen.setLaunchFee(1 ether);
    }

    /// The old contract left setFee/setFeeTo callable by anyone; this pins that they aren't.
    function test_setFeeTo_revertsForNonAdmin() public {
        vm.prank(stranger);
        vm.expectRevert();
        gen.setFeeTo(stranger);
    }

    function test_admin_holdsBothRoles() public view {
        assertTrue(gen.hasRole(gen.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(gen.hasRole(gen.ADMIN_ROLE(), admin));
    }

    /* -------------------------------- quote options ---------------------------- */

    function test_enabledQuoteTokens_reflectsToggles() public {
        vm.startPrank(admin);
        gen.setQuoteOption(address(usdc), true, 1e8, address(0), ExchangeOrderbook.MatchingMode.PriceTimePriority, 1_000_000);
        assertEq(gen.enabledQuoteTokens().length, 2);

        gen.setQuoteOption(address(weth), false, 1e8, address(0), ExchangeOrderbook.MatchingMode.PriceTimePriority, 1_000_000);
        vm.stopPrank();

        address[] memory enabled = gen.enabledQuoteTokens();
        assertEq(enabled.length, 1);
        assertEq(enabled[0], address(usdc));
        // disabling keeps the entry, so re-enabling cannot append a duplicate
        assertEq(gen.quoteTokens().length, 2);
    }

    function test_setQuoteOption_doesNotDuplicateOnRetune() public {
        vm.startPrank(admin);
        gen.setQuoteOption(address(weth), true, 2e8, address(0), ExchangeOrderbook.MatchingMode.PriceTimePriority, 1_000_000);
        gen.setQuoteOption(address(weth), true, 3e8, address(0), ExchangeOrderbook.MatchingMode.PriceTimePriority, 1_000_000);
        vm.stopPrank();
        assertEq(gen.quoteTokens().length, 1);
        assertEq(gen.quoteOption(address(weth)).listingPrice, 3e8);
    }

    /// Configuring a quote to all-default values and then to real ones must not append it
    /// twice — the enumeration is keyed on an explicit membership flag, not on the option
    /// still looking untouched.
    function test_setQuoteOption_doesNotDuplicateAfterADefaultValuedWrite() public {
        vm.startPrank(admin);
        gen.setQuoteOption(address(usdc), false, 0, address(0), ExchangeOrderbook.MatchingMode.PriceTimePriority, 1_000_000);
        gen.setQuoteOption(address(usdc), true, 1e8, address(0), ExchangeOrderbook.MatchingMode.PriceTimePriority, 1_000_000);
        vm.stopPrank();

        assertEq(gen.quoteTokens().length, 2, "weth + usdc, each once");
        assertEq(gen.enabledQuoteTokens().length, 2);
    }

    /* ----------------------------------- launch -------------------------------- */

    function test_launch_revertsWhenQuoteNotEnabled() public {
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(AssetGenerator.QuoteNotEnabled.selector, address(usdc)));
        gen.launch{value: FEE}("Nova", "NOVA", SUPPLY, address(usdc));
    }

    function test_launch_revertsWhenFeeIsShort() public {
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(AssetGenerator.InsufficientFee.selector, FEE - 1, FEE));
        gen.launch{value: FEE - 1}("Nova", "NOVA", SUPPLY, address(weth));
    }

    function test_launch_revertsOnEmptyMetadata() public {
        vm.prank(creator);
        vm.expectRevert(AssetGenerator.EmptyMetadata.selector);
        gen.launch{value: FEE}("", "NOVA", SUPPLY, address(weth));
    }

    function test_launch_revertsOnZeroSupply() public {
        vm.prank(creator);
        vm.expectRevert(AssetGenerator.SupplyIsZero.selector);
        gen.launch{value: FEE}("Nova", "NOVA", 0, address(weth));
    }

    function test_launch_sendsSupplyToCreatorAndListsThePair() public {
        address coin = _launch();

        assertEq(IERC20(coin).balanceOf(creator), SUPPLY, "creator holds the supply");
        assertEq(IERC20(coin).balanceOf(address(gen)), 0, "generator keeps nothing");
        assertEq(engine.lastBase(), coin);
        assertEq(engine.lastQuote(), address(weth));
        assertEq(engine.lastPayment(), coin, "listing paid in the new coin by default");
        assertEq(engine.lastListingPrice(), 1e8);

        (
            address recordedCreator,
            address quote,
            address pair,
            uint64 launchedAt,
            uint16 slippageLimitBps,
            uint32 makerFee,
            uint32 takerFee,
            bool creatorFeeLocked
        ) = gen.launches(coin);
        assertEq(recordedCreator, creator);
        assertEq(quote, address(weth));
        assertEq(pair, engine.pairs(coin, address(weth)));
        assertEq(launchedAt, uint64(block.timestamp));
        assertEq(slippageLimitBps, 10);
        assertEq(makerFee, 50_000);
        assertEq(takerFee, 1_000_000, "seeded from the quote option");
        assertFalse(creatorFeeLocked, "creator controls only this recorded pair");
    }

    /// The shape the indexer builds its topic filter from. `pair` holds the third and last
    /// indexed slot; `quote` sits in the data section.
    function test_launch_emitsLaunchedWithThePairIndexed() public {
        address expectedCoin = vm.computeCreateAddress(address(gen), vm.getNonce(address(gen)));
        address expectedPair =
            address(uint160(uint256(keccak256(abi.encodePacked(expectedCoin, address(weth))))));

        vm.expectEmit(true, true, true, true);
        emit Launched(expectedCoin, creator, expectedPair, address(weth), SUPPLY);
        vm.prank(creator);
        gen.launch{value: FEE}("Nova Protocol", "NOVA", SUPPLY, address(weth));
    }

    function test_launch_paysFeeToAndRefundsTheExcess() public {
        uint256 before = creator.balance;
        vm.prank(creator);
        gen.launch{value: FEE + 1 ether}("Nova", "NOVA", SUPPLY, address(weth));

        assertEq(feeTo.balance, FEE, "fee forwarded");
        assertEq(creator.balance, before - FEE, "excess refunded, only the fee is kept");
    }

    /// The engine pulls its listing cost from the generator, so the creator receives the
    /// supply NET of it — not a balance the generator could not cover.
    function test_launch_creditsCreatorNetOfTheListingCost() public {
        engine.setListingCost(1_000e18);
        address coin = _launch();

        assertEq(IERC20(coin).balanceOf(creator), SUPPLY - 1_000e18);
        assertEq(IERC20(coin).balanceOf(address(engine)), 1_000e18);
        assertEq(IERC20(coin).allowance(address(gen), address(engine)), 0, "allowance reset after listing");
    }

    function test_launch_worksWithoutAFeeWhenAdminSetsItToZero() public {
        vm.prank(admin);
        gen.setLaunchFee(0);
        vm.prank(creator);
        address coin = gen.launch("Nova", "NOVA", SUPPLY, address(weth));
        assertEq(IERC20(coin).balanceOf(creator), SUPPLY);
    }

    function test_launchAsset_recordsVolatilityFeePaymentAndLockChoices() public {
        AssetGenerator.LaunchSettings memory settings = _launchSettings(address(0), 30 days);
        vm.prank(creator);
        address coin = gen.launchAsset{value: FEE}("Nova", "NOVA", SUPPLY, address(weth), settings);

        (
            AssetGenerator.Preset volatilityPreset,
            uint16 volatilityBps,
            AssetGenerator.Preset feePreset,
            uint32 makerFee,
            uint32 takerFee,
            address paymentToken,
            uint64 lockDuration
        ) = gen.launchSettings(coin);
        assertEq(uint8(volatilityPreset), uint8(AssetGenerator.Preset.Standard));
        assertEq(volatilityBps, 10);
        assertEq(uint8(feePreset), uint8(AssetGenerator.Preset.Meme));
        assertEq(makerFee, 50_000);
        assertEq(takerFee, 1_000_000);
        assertEq(paymentToken, address(0));
        assertEq(lockDuration, 30 days);
        assertEq(gen.takerFeeOf(coin), 1_000_000);
    }

    function test_launchAsset_revertsWhenPresetDoesNotMatchValue() public {
        AssetGenerator.LaunchSettings memory settings = _launchSettings(address(0), 0);
        settings.volatilityBps = 50;
        vm.prank(creator);
        vm.expectRevert(
            abi.encodeWithSelector(
                AssetGenerator.InvalidPresetValue.selector, AssetGenerator.Preset.Standard, uint256(50)
            )
        );
        gen.launchAsset{value: FEE}("Nova", "NOVA", SUPPLY, address(weth), settings);
    }

    function test_launchAsset_acceptsConfiguredErc20Payment() public {
        uint256 tokenFee = 25e6;
        vm.prank(admin);
        gen.setPaymentOption(address(usdc), true, tokenFee);
        usdc.transfer(creator, tokenFee);

        vm.prank(creator);
        usdc.approve(address(gen), tokenFee);
        AssetGenerator.LaunchSettings memory settings = _launchSettings(address(usdc), 0);
        uint256 recipientBefore = usdc.balanceOf(feeTo);
        vm.prank(creator);
        gen.launchAsset("Nova", "NOVA", SUPPLY, address(weth), settings);

        assertEq(usdc.balanceOf(feeTo), recipientBefore + tokenFee);
        assertEq(address(gen).balance, 0);
    }

    function test_launchAsset_revertsForDisabledPaymentToken() public {
        AssetGenerator.LaunchSettings memory settings = _launchSettings(address(usdc), 0);
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(AssetGenerator.PaymentNotEnabled.selector, address(usdc)));
        gen.launchAsset("Nova", "NOVA", SUPPLY, address(weth), settings);
    }

    function test_liquidityLock_custodiesExtendsAndReleasesTheRealPairPosition() public {
        AssetGenerator.LaunchSettings memory settings = _launchSettings(address(0), 30 days);
        vm.prank(creator);
        address coin = gen.launchAsset{value: FEE}("Nova", "NOVA", SUPPLY, address(weth), settings);

        MockPositionManager manager = new MockPositionManager();
        MockPoolIdentity pool = new MockPoolIdentity(coin, address(weth));
        manager.mint(creator, 7, address(pool));
        vm.prank(creator);
        manager.setApprovalForAll(address(gen), true);

        vm.prank(creator);
        gen.lockLiquidity(coin, address(manager), 7);
        assertEq(manager.balanceOf(address(gen), 7), 1);
        (,, uint64 firstUnlock,) = gen.liquidityLocks(coin);

        vm.prank(creator);
        gen.extendLiquidityLock(coin, 7 days);
        (,, uint64 extendedUnlock,) = gen.liquidityLocks(coin);
        assertEq(extendedUnlock, firstUnlock + 7 days);

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(AssetGenerator.LiquidityStillLocked.selector, extendedUnlock));
        gen.releaseLiquidity(coin, creator);

        vm.warp(extendedUnlock);
        vm.prank(creator);
        gen.releaseLiquidity(coin, creator);
        assertEq(manager.balanceOf(creator, 7), 1);
        assertEq(manager.balanceOf(address(gen), 7), 0);
    }

    function test_liquidityLock_rejectsAnUnrelatedPosition() public {
        AssetGenerator.LaunchSettings memory settings = _launchSettings(address(0), 30 days);
        vm.prank(creator);
        address coin = gen.launchAsset{value: FEE}("Nova", "NOVA", SUPPLY, address(weth), settings);
        MockPositionManager manager = new MockPositionManager();
        MockPoolIdentity unrelated = new MockPoolIdentity(address(usdc), address(weth));
        manager.mint(creator, 9, address(unrelated));
        vm.prank(creator);
        manager.setApprovalForAll(address(gen), true);

        vm.prank(creator);
        vm.expectRevert(
            abi.encodeWithSelector(AssetGenerator.InvalidLiquidityPosition.selector, coin, address(unrelated))
        );
        gen.lockLiquidity(coin, address(manager), 9);
    }

    /* -------------------------------- fee schedule ----------------------------- */

    function _unlockCreator(address coin) internal {
        vm.prank(admin);
        gen.setCreatorFeeControl(coin, false);
    }

    function test_takerFee_startsFromTheQuoteConfiguration() public {
        address coin = _launch();
        assertEq(gen.takerFeeOf(coin), 1_000_000);
        assertEq(uint256(gen.takerFeeOf(coin)) * 10_000 / gen.FEE_DENOM(), 100, "100 bps");
    }

    function test_feeOf_chargesTheTakerAndNeverTheMaker() public {
        address coin = _launch();
        assertEq(gen.feeOf(coin, address(weth), creator, false), 1_000_000, "configured taker fee");
        assertEq(gen.feeOf(coin, address(weth), creator, true), 50_000, "maker fee follows pair policy");
    }

    /// The engine wraps feeOf in try/catch and falls back to its own defaults on a revert.
    /// Reverting is therefore the correct answer for a pair this generator did not launch —
    /// returning 0 would make every other pair on the venue free.
    function test_feeOf_revertsForAForeignPairSoTheEngineFallsBack() public {
        vm.expectRevert(abi.encodeWithSelector(AssetGenerator.NotAGeneratedCoin.selector, address(weth)));
        gen.feeOf(address(weth), address(usdc), creator, false);
    }

    function test_feeOf_delegatesForeignPairsWhenAFallbackIsSet() public {
        MockIncentive fallbackIncentive = new MockIncentive(42, "terminal-x");
        vm.prank(admin);
        gen.setFallbackIncentive(address(fallbackIncentive));

        assertEq(gen.feeOf(address(weth), address(usdc), creator, false), 42);
        assertEq(gen.terminalName(creator), "terminal-x");
        assertTrue(gen.isSubscribed(creator));

        // a generated coin is still answered locally, not delegated
        address coin = _launch();
        assertEq(gen.feeOf(coin, address(weth), creator, false), 1_000_000);
    }

    /// Listing calls terminalName outside a try/catch, so an unset delegate must return
    /// empty — the engine's own "not a registered terminal" answer — rather than revert.
    function test_terminalName_isEmptyWithoutADelegate() public view {
        assertEq(bytes(gen.terminalName(creator)).length, 0);
        assertFalse(gen.isSubscribed(creator));
    }

    function test_startingTakerFee_isPerQuote() public {
        // USDC opens cheaper than WETH: a coin against a deep stable book is not the same
        // trade as one against a volatile quote.
        vm.prank(admin);
        gen.setQuoteOption(address(usdc), true, 1e8, address(0), ExchangeOrderbook.MatchingMode.PriceTimePriority, 250_000);

        address vsWeth = _launch();
        vm.prank(creator);
        address vsUsdc = gen.launch{value: FEE}("Halo", "HALO", SUPPLY, address(usdc));

        assertEq(gen.takerFeeOf(vsWeth), 1_000_000, "1.00% against WETH");
        assertEq(gen.takerFeeOf(vsUsdc), 250_000, "0.25% against USDC");
    }

    /// Retuning a quote must reprice FUTURE launches only — a live coin holds its own
    /// snapshot, so nobody's trading cost moves because an admin adjusted a quote.
    function test_retuningAQuote_doesNotRepriceLiveCoins() public {
        address coin = _launch();
        assertEq(gen.takerFeeOf(coin), 1_000_000);

        vm.prank(admin);
        gen.setQuoteOption(address(weth), true, 1e8, address(0), ExchangeOrderbook.MatchingMode.PriceTimePriority, 42);

        assertEq(gen.takerFeeOf(coin), 1_000_000, "live coin unchanged");
        vm.prank(creator);
        address later = gen.launch{value: FEE}("Later", "LATE", SUPPLY, address(weth));
        assertEq(gen.takerFeeOf(later), 42, "next launch takes the new rate");
    }

    /* --------------------- creator control of the taker fee -------------------- */

    function test_creator_canSetTheirOwnFeeAfterAdminUnlocksControl() public {
        address coin = _launch();
        _unlockCreator(coin);

        vm.prank(creator);
        gen.setPairTakerFee(coin, 300_000);

        assertEq(gen.takerFeeOf(coin), 300_000);
        assertEq(gen.feeOf(coin, address(weth), stranger, false), 300_000, "the engine would charge it");
    }

    function test_creator_canConfigureTheirPairImmediately() public {
        address coin = _launch();
        vm.prank(creator);
        gen.setPairTradingConfig(coin, 50, 50_000, 300_000);

        (address pair, uint16 slippage, uint32 makerFee, uint32 takerFee) =
            gen.pairTradingConfig(coin);
        assertEq(pair, engine.pairs(coin, address(weth)));
        assertEq(slippage, 50);
        assertEq(makerFee, 50_000);
        assertEq(takerFee, 300_000);
        assertEq(gen.feeOf(coin, address(weth), stranger, true), 50_000);
        assertEq(gen.feeOf(coin, address(weth), stranger, false), 300_000);
        assertEq(gen.slippageLimitOf(coin, address(weth)), 50);
    }

    /// The bound that stops a creator taking a taker's whole order.
    function test_creator_cannotExceedTheCap() public {
        address coin = _launch();
        _unlockCreator(coin);

        vm.prank(creator);
        vm.expectRevert(
            abi.encodeWithSelector(AssetGenerator.FeeAboveCreatorCap.selector, uint32(1_000_001), uint32(1_000_000))
        );
        gen.setPairTakerFee(coin, 1_000_001);
    }

    function test_creator_cannotSetTheFeeOnSomeoneElsesCoin() public {
        address coin = _launch();
        _unlockCreator(coin);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(AssetGenerator.NotTheCreator.selector, stranger));
        gen.setPairTakerFee(coin, 0);
    }

    function test_creatorCap_ofZeroLeavesOnlyTheZeroFeeReachable() public {
        address coin = _launch();
        _unlockCreator(coin);
        vm.prank(admin);
        gen.setMaxCreatorTakerFee(0);

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(AssetGenerator.FeeOutsidePairRange.selector, uint32(0), uint32(50_000), uint32(3_000_000)));
        gen.setPairTakerFee(coin, 0);
    }

    /* ------------------- admin overrides of the same control ------------------- */

    function test_admin_canSetAnyFeeWhileCreatorControlIsLocked() public {
        address coin = _launch();
        vm.prank(admin);
        gen.setPairTakerFee(coin, 2_000_000);
        assertEq(gen.takerFeeOf(coin), 2_000_000, "above the creator cap, but an admin set it");
    }

    /// The lever for forcing a hostile fee back down.
    function test_admin_canOverrideAFeeTheCreatorSet() public {
        address coin = _launch();
        _unlockCreator(coin);
        vm.prank(creator);
        gen.setPairTakerFee(coin, 1_000_000);

        vm.prank(admin);
        gen.setPairTakerFee(coin, 100_000);
        assertEq(gen.takerFeeOf(coin), 100_000);
    }

    function test_admin_canRevokeAndRestoreCreatorControl() public {
        address coin = _launch();
        vm.prank(admin);
        gen.setCreatorFeeControl(coin, true);
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(AssetGenerator.CreatorFeeControlLocked.selector, coin));
        gen.setPairTradingConfig(coin, 10, 50_000, 50_000);

        vm.prank(admin);
        gen.setCreatorFeeControl(coin, false);
        vm.prank(creator);
        gen.setPairTradingConfig(coin, 10, 50_000, 50_000);
        assertEq(gen.takerFeeOf(coin), 50_000);
    }

    function test_generatedCoinPolicy_doesNotLeakToAnotherQuote() public {
        address coin = _launch();
        vm.expectRevert(abi.encodeWithSelector(AssetGenerator.NotAGeneratedCoin.selector, coin));
        gen.slippageLimitOf(coin, address(usdc));

        vm.expectRevert(abi.encodeWithSelector(AssetGenerator.NotAGeneratedCoin.selector, coin));
        gen.feeOf(coin, address(usdc), stranger, false);
    }

    function test_creator_cannotConfigureAnotherCreatorsPair() public {
        address coin = _launch();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(AssetGenerator.NotTheCreator.selector, stranger));
        gen.setPairTradingConfig(coin, 10, 50_000, 100_000);
    }

    function test_pairConfigRole_canManageAnyPairWithinBounds() public {
        address coin = _launch();
        bytes32 role = gen.PAIR_CONFIG_ROLE();
        vm.prank(admin);
        gen.grantRole(role, stranger);

        vm.prank(stranger);
        gen.setPairTradingConfig(coin, 100, 3_000_000, 3_000_000);
        (,, uint32 makerFee, uint32 takerFee) = gen.pairTradingConfig(coin);
        assertEq(makerFee, 3_000_000);
        assertEq(takerFee, 3_000_000);
    }

    function test_pairConfigRole_canConfigureAnExistingPair() public {
        address base = makeAddr("existingBase");
        address quote = makeAddr("existingQuote");
        address pair = makeAddr("existingPair");
        engine.setPairFor(base, quote, pair);
        vm.prank(admin);
        gen.setExistingPairTradingConfig(base, quote, 50, 50_000, 100_000);
        (uint16 slippage, uint32 makerFee, uint32 takerFee, bool configured) = gen.pairPolicies(pair);
        assertTrue(configured);
        assertEq(slippage, 50);
        assertEq(makerFee, 50_000);
        assertEq(takerFee, 100_000);
    }

    function test_existingPairPolicy_rejectsCallerWithoutPairConfigRole() public {
        address base = makeAddr("accessBase");
        address quote = makeAddr("accessQuote");
        engine.setPairFor(base, quote, makeAddr("accessPair"));
        bytes32 role = gen.PAIR_CONFIG_ROLE();

        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, role)
        );
        gen.setExistingPairTradingConfig(base, quote, 50, 50_000, 100_000);
    }

    function test_defaultAdmin_canConfigureExistingPairWithoutPairConfigRole() public {
        address base = makeAddr("adminBase");
        address quote = makeAddr("adminQuote");
        address pair = makeAddr("adminPair");
        engine.setPairFor(base, quote, pair);
        bytes32 role = gen.PAIR_CONFIG_ROLE();

        vm.prank(admin);
        gen.revokeRole(role, admin);
        assertFalse(gen.hasRole(role, admin));

        vm.prank(admin);
        gen.setExistingPairTradingConfig(base, quote, 50, 50_000, 100_000);
        (,,, bool configured) = gen.pairPolicies(pair);
        assertTrue(configured);
    }

    function test_pairConfigRole_cannotExceedConfiguredBounds() public {
        address base = makeAddr("boundsBase");
        address quote = makeAddr("boundsQuote");
        engine.setPairFor(base, quote, makeAddr("boundsPair"));
        bytes32 role = gen.PAIR_CONFIG_ROLE();
        vm.prank(admin);
        gen.grantRole(role, stranger);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(AssetGenerator.InvalidVolatility.selector, uint16(101)));
        gen.setExistingPairTradingConfig(base, quote, 101, 50_000, 50_000);

        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(AssetGenerator.FeeOutsidePairRange.selector, uint32(3_000_001), uint32(50_000), uint32(3_000_000))
        );
        gen.setExistingPairTradingConfig(base, quote, 100, 3_000_001, 50_000);
    }

    function test_defaultAdmin_canChangeBoundsAndOverridePairPolicy() public {
        address coin = _launch();
        vm.prank(admin);
        gen.setPairPolicyBounds(5, 50, 50_000, 500_000);

        vm.prank(creator);
        gen.setPairTradingConfig(coin, 50, 500_000, 500_000);

        vm.prank(admin);
        gen.setPairTradingConfig(coin, 5, 0, 0);
        (,, uint32 makerFee, uint32 takerFee) = gen.pairTradingConfig(coin);
        assertEq(makerFee, 0);
        assertEq(takerFee, 0);
    }

    /// Locking one coin must not touch another launch by the same creator.
    function test_lockingOneCoinLeavesTheCreatorsOthersAlone() public {
        address first = _launch();
        vm.prank(creator);
        address second = gen.launch{value: FEE}("Second", "SEC", SUPPLY, address(weth));
        _unlockCreator(first);
        _unlockCreator(second);

        vm.prank(admin);
        gen.setCreatorFeeControl(first, true);

        vm.prank(creator);
        gen.setPairTakerFee(second, 50_000);
        assertEq(gen.takerFeeOf(second), 50_000);
    }

    function test_setPairTakerFee_revertsForACoinThisGeneratorDidNotLaunch() public {
        address foreign = address(new Coin("Foreign", "FRGN", SUPPLY, address(this)));
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(AssetGenerator.CoinNotLaunched.selector, foreign));
        gen.setPairTakerFee(foreign, 0);
    }

    function test_takerFeeOf_revertsForACoinThisGeneratorDidNotLaunch() public {
        address foreign = address(new Coin("Foreign", "FRGN", SUPPLY, address(this)));
        vm.expectRevert(abi.encodeWithSelector(AssetGenerator.CoinNotLaunched.selector, foreign));
        gen.takerFeeOf(foreign);
    }

}
