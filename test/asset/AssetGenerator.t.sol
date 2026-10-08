// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {AssetGenerator, Coin} from "../../src/asset/AssetGenerator.sol";
import {AssetLaunchLib} from "../../src/asset/libraries/AssetLaunchLib.sol";
import {IBandPositionManager} from "../../src/swap/interfaces/IBandPositionManager.sol";
import {IMatchingEngine} from "../../src/exchange/interfaces/IMatchingEngine.sol";
import {ExchangeOrderbook} from "../../src/exchange/libraries/ExchangeOrderbook.sol";

/// @notice A pair with the real Orderbook's `convert`, which the dev buy prices through.
contract MockBook {
    uint256 internal immutable decDiff;
    bool internal immutable baseBquote;

    constructor(address base, address quote) {
        uint8 b = ERC20(base).decimals();
        uint8 q = ERC20(quote).decimals();
        baseBquote = b >= q;
        decDiff = 10 ** (b >= q ? b - q : q - b);
    }

    function convert(uint256 price, uint256 amount, bool isBid) external view returns (uint256) {
        if (isBid) return baseBquote ? ((amount * price) / 1e8) / decDiff : ((amount * price) / 1e8) * decDiff;
        return baseBquote ? ((amount * 1e8) / price) * decDiff : ((amount * 1e8) / price) / decDiff;
    }
}

/// @notice Minimal stand-in for the MatchingEngine: lists a book and a band pool, the way
/// `addPair` does on chain, and records the fee the generator writes for each pair.
contract MockEngine {
    mapping(address base => mapping(address quote => address pair)) public pairs;
    mapping(address pair => uint32 takerFee) public pairTakerFee;
    mapping(address pair => uint32 makerFee) public pairMakerFee;

    address public lastBase;
    address public lastQuote;
    address public lastPayment;
    uint256 public lastListingPrice;
    address public poolFactory;

    function setPoolFactory(address f) external {
        poolFactory = f;
    }

    function setPairFor(address base, address quote, address pair) external {
        pairs[base][quote] = pair;
    }

    function addPair(
        address base,
        address quote,
        uint256 listingPrice,
        uint256,
        address payment,
        ExchangeOrderbook.MatchingMode
    ) external returns (address pair) {
        pair = address(new MockBook(base, quote));
        pairs[base][quote] = pair;
        lastBase = base;
        lastQuote = quote;
        lastPayment = payment;
        lastListingPrice = listingPrice;
        if (poolFactory != address(0)) MockFactory(poolFactory).list(base, quote, address(new MockBandPool(base, quote)));
    }

    function setPairFeeClass(address pair, uint8, uint32 makerFee, uint32 takerFee) external returns (bool) {
        pairMakerFee[pair] = makerFee;
        pairTakerFee[pair] = takerFee;
        return true;
    }

    function getPair(address base, address quote) external view returns (address) {
        return pairs[base][quote];
    }

    uint32 public limitBuySpread = 3_000_000;
    uint32 public nextOrderId;
    mapping(uint32 => address) public orderOwner;

    function getSpread(address, bool isBuy, bool) external view returns (uint32) {
        return isBuy ? limitBuySpread : 3_000_000;
    }

    function setSpread(address, address, uint32 buy, uint32, bool) external returns (bool) {
        limitBuySpread = buy;
        return true;
    }

    /// Takes the ask's coins, as the book does, and gives it an id.
    function limitSell(IMatchingEngine.LimitOrderInput calldata input)
        external
        returns (IMatchingEngine.OrderResult memory result)
    {
        IERC20(input.base).transferFrom(msg.sender, address(this), input.amount);
        result.id = ++nextOrderId;
        result.makePrice = input.price;
        result.placed = input.amount;
        orderOwner[result.id] = input.recipient;
    }
}

/// Just enough of a band factory for a launch: the registry the generator resolves the
/// new pool and its position manager from.
contract MockFactory {
    address public positionManager;
    mapping(address => mapping(address => address)) internal pools;

    constructor(address manager) {
        positionManager = manager;
    }

    function list(address base, address quote, address pool) external {
        pools[base][quote] = pool;
    }

    function getPool(address base, address quote) external view returns (address) {
        return pools[base][quote];
    }

    function syncLimit(address, address) external {}
}

contract MockBandPool {
    address public immutable base;
    address public immutable quote;
    address public creator;

    constructor(address b, address q) {
        base = b;
        quote = q;
    }

    function bandCount() external pure returns (uint256) {
        return 3;
    }

    function transferCreator(address to) external {
        creator = to;
    }

    mapping(uint8 => bool) public bandOpen;

    function setBandOpen(uint8 index, bool open) external {
        bandOpen[index] = open;
    }
}

/// Takes the deposit and mints the position, as the manager does on chain.
contract MockPositionManager is ERC1155 {
    uint256 public nextTokenId = 1;
    mapping(uint256 => address) public poolOf;
    mapping(uint256 => uint256) public baseHeld;
    mapping(uint256 => uint256) public quoteHeld;
    uint256 public collected;

    constructor() ERC1155("") {}

    function mint(IBandPositionManager.MintParams calldata p) external returns (uint256 tokenId, uint128[] memory) {
        tokenId = nextTokenId++;
        poolOf[tokenId] = p.pool;
        for (uint256 i = 0; i < p.bands.length; i++) {
            baseHeld[tokenId] += p.baseAmounts[i];
            quoteHeld[tokenId] += p.quoteAmounts[i];
        }
        IERC20(MockBandPool(p.pool).base()).transferFrom(msg.sender, address(this), baseHeld[tokenId]);
        if (quoteHeld[tokenId] > 0) {
            IERC20(MockBandPool(p.pool).quote()).transferFrom(msg.sender, address(this), quoteHeld[tokenId]);
        }
        _mint(p.recipient, tokenId, 1, "");
        return (tokenId, new uint128[](p.bands.length));
    }

    function collect(uint256 tokenId, address) external returns (uint256, uint256) {
        require(balanceOf(msg.sender, tokenId) == 1, "not the owner");
        collected++;
        return (0, 0);
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
    /// Dev buy: 0.001 WETH at a 5,000 WETH market cap is 0.00002% of supply.
    uint256 internal constant DEV = 0.001 ether;
    MockPositionManager internal manager;

    event Launched(
        address indexed coin, address indexed creator, address indexed pair, address quote, uint256 totalSupply
    );

    function setUp() public {
        engine = new MockEngine();
        usdc = new MockStable();
        weth = new MockWETH();
        manager = new MockPositionManager();
        engine.setPoolFactory(address(new MockFactory(address(manager))));
        gen = new AssetGenerator(admin, address(engine));

        vm.startPrank(admin);
        gen.setFeeTo(feeTo);
        gen.setLaunchFee(FEE);
        gen.setQuoteOption(address(weth), true, 5_000e18, DEV, 25_000e18, ExchangeOrderbook.MatchingMode.PriceTimePriority, 1_000_000);
        vm.stopPrank();

        weth.transfer(creator, 10 ether);
        usdc.transfer(creator, 10_000e6);
        vm.startPrank(creator);
        weth.approve(address(gen), type(uint256).max);
        usdc.approve(address(gen), type(uint256).max);
        vm.stopPrank();
        vm.deal(creator, 10 ether);
        vm.deal(stranger, 10 ether);
    }

    /**
     * What a creator pays to put a coin on this venue, in gas.
     *
     * `launch()` is one transaction doing a lot: it deploys the coin, lists the pair,
     * creates the band pool, widens the pair's buy spread and rests the five-step
     * ladder -- five limit sells on their own. The number matters because a creator
     * pays it before anyone has bought anything, and because it is what moves if the
     * ladder ever gains steps. It lives here rather than in its own GasProbe_ file
     * because this contract is not an abstract base: inheriting it to measure one
     * number re-runs all 47 tests above under a second name.
     */
    function test_gas_launch() public {
        uint256 g = gasleft();
        _launch();
        emit log_named_uint("launch(): coin + pair + pool + 5-step ladder", g - gasleft());
    }

    function _launch() internal returns (address coin) {
        vm.prank(creator);
        return gen.launch{value: FEE}("Nova Protocol", "NOVA", SUPPLY, address(weth), DEV, AssetGenerator.LockMode.FeesOnly);
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
        gen.setQuoteOption(address(usdc), true, 5_000e18, DEV, 25_000e18, ExchangeOrderbook.MatchingMode.PriceTimePriority, 1_000_000);
        assertEq(gen.enabledQuoteTokens().length, 2);

        gen.setQuoteOption(address(weth), false, 5_000e18, DEV, 25_000e18, ExchangeOrderbook.MatchingMode.PriceTimePriority, 1_000_000);
        vm.stopPrank();

        address[] memory enabled = gen.enabledQuoteTokens();
        assertEq(enabled.length, 1);
        assertEq(enabled[0], address(usdc));
        // disabling keeps the entry, so re-enabling cannot append a duplicate
        assertEq(gen.quoteTokens().length, 2);
    }

    function test_setQuoteOption_doesNotDuplicateOnRetune() public {
        vm.startPrank(admin);
        gen.setQuoteOption(address(weth), true, 2e8, DEV, 2e8, ExchangeOrderbook.MatchingMode.PriceTimePriority, 1_000_000);
        gen.setQuoteOption(address(weth), true, 3e8, DEV, 3e8, ExchangeOrderbook.MatchingMode.PriceTimePriority, 1_000_000);
        vm.stopPrank();
        assertEq(gen.quoteTokens().length, 1);
        assertEq(gen.quoteOption(address(weth)).startingMarketCap, 3e8);
    }

    /// Configuring a quote to all-default values and then to real ones must not append it
    /// twice — the enumeration is keyed on an explicit membership flag, not on the option
    /// still looking untouched.
    function test_setQuoteOption_doesNotDuplicateAfterADefaultValuedWrite() public {
        vm.startPrank(admin);
        gen.setQuoteOption(address(usdc), false, 0, 0, 0, ExchangeOrderbook.MatchingMode.PriceTimePriority, 1_000_000);
        gen.setQuoteOption(address(usdc), true, 5_000e18, DEV, 25_000e18, ExchangeOrderbook.MatchingMode.PriceTimePriority, 1_000_000);
        vm.stopPrank();

        assertEq(gen.quoteTokens().length, 2, "weth + usdc, each once");
        assertEq(gen.enabledQuoteTokens().length, 2);
    }

    /* ----------------------------------- launch -------------------------------- */

    function test_launch_revertsWhenQuoteNotEnabled() public {
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(AssetGenerator.QuoteNotEnabled.selector, address(usdc)));
        gen.launch{value: FEE}("Nova", "NOVA", SUPPLY, address(usdc), DEV, AssetGenerator.LockMode.FeesOnly);
    }

    function test_launch_revertsWhenFeeIsShort() public {
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(AssetGenerator.InsufficientFee.selector, FEE - 1, FEE));
        gen.launch{value: FEE - 1}("Nova", "NOVA", SUPPLY, address(weth), DEV, AssetGenerator.LockMode.FeesOnly);
    }

    function test_launch_revertsOnEmptyMetadata() public {
        vm.prank(creator);
        vm.expectRevert(AssetGenerator.EmptyMetadata.selector);
        gen.launch{value: FEE}("", "NOVA", SUPPLY, address(weth), DEV, AssetGenerator.LockMode.FeesOnly);
    }

    function test_launch_revertsOnZeroSupply() public {
        vm.prank(creator);
        vm.expectRevert(AssetGenerator.SupplyIsZero.selector);
        gen.launch{value: FEE}("Nova", "NOVA", 0, address(weth), DEV, AssetGenerator.LockMode.FeesOnly);
    }

    function test_launch_givesTheCreatorOnlyTheDevBuyAndListsThePair() public {
        address coin = _launch();
        // 5,000 WETH over 1,000,000 coins: 0.005 WETH each, 500,000 in 1e8 units.
        uint256 price = 5_000e18 * 1e8 / SUPPLY;
        uint256 bought = DEV * 1e8 / price;
        AssetLaunchLib.Ladder memory l = gen.ladderOf(coin);

        assertEq(IERC20(coin).balanceOf(creator), bought, "the creator holds what they paid for");
        assertEq(IERC20(coin).balanceOf(address(gen)), 0, "generator keeps no loose supply");
        assertEq(IERC20(coin).balanceOf(address(engine)), SUPPLY * 8 / 10, "80% rests as the ladder");
        assertEq(IERC20(coin).balanceOf(l.escrow), SUPPLY - SUPPLY * 8 / 10 - bought, "the rest is held back");
        assertEq(weth.balanceOf(l.escrow), DEV, "and the dev buy's quote waits with it");
        assertEq(engine.lastBase(), coin);
        assertEq(engine.lastQuote(), address(weth));
        assertEq(engine.lastListingPrice(), price);
        for (uint256 i = 0; i < 5; i++) {
            assertEq(engine.orderOwner(l.askIds[i]), l.escrow, "every ask pays the escrow");
        }
    }

    function test_launch_recordsTheFixedPolicy() public {
        address coin = _launch();
        (
            address recordedCreator,
            address quote,
            address pair,
            uint64 launchedAt,
            uint16 slippageLimitBps,
            uint32 makerFee,
            uint32 takerFee,
            bool creatorFeeLocked,
            bool graduated
        ) = gen.launches(coin);
        assertEq(recordedCreator, creator);
        assertEq(quote, address(weth));
        assertEq(pair, engine.pairs(coin, address(weth)));
        assertEq(launchedAt, uint64(block.timestamp));
        assertEq(slippageLimitBps, 100, "Meme volatility, fixed");
        assertEq(makerFee, 0, "makers are free");
        assertEq(takerFee, 1_000_000, "seeded from the quote option");
        assertTrue(creatorFeeLocked, "the creator controls nothing until graduation");
        assertFalse(graduated);
        assertEq(engine.pairTakerFee(pair), 1_000_000, "and written to the engine, which charges the lower");
        assertEq(engine.pairMakerFee(pair), 0);
    }

    /// The shape the indexer builds its topic filter from. `pair` holds the third and last
    /// indexed slot; `quote` sits in the data section.
    function test_launch_emitsLaunchedWithThePairIndexed() public {
        address expectedCoin = vm.computeCreateAddress(address(gen), vm.getNonce(address(gen)));
        address expectedPair = vm.computeCreateAddress(address(engine), vm.getNonce(address(engine)));

        vm.expectEmit(true, true, true, true);
        emit Launched(expectedCoin, creator, expectedPair, address(weth), SUPPLY);
        vm.prank(creator);
        gen.launch{value: FEE}("Nova Protocol", "NOVA", SUPPLY, address(weth), DEV, AssetGenerator.LockMode.FeesOnly);
    }

    function test_launch_paysFeeToAndRefundsTheExcess() public {
        uint256 before = creator.balance;
        vm.prank(creator);
        gen.launch{value: FEE + 1 ether}("Nova", "NOVA", SUPPLY, address(weth), DEV, AssetGenerator.LockMode.FeesOnly);

        assertEq(feeTo.balance, FEE, "fee forwarded");
        assertEq(creator.balance, before - FEE, "excess refunded, only the fee is kept");
    }

    function test_launch_worksWithoutAFeeWhenAdminSetsItToZero() public {
        vm.prank(admin);
        gen.setLaunchFee(0);
        vm.prank(creator);
        address coin = gen.launch("Nova", "NOVA", SUPPLY, address(weth), DEV, AssetGenerator.LockMode.FeesOnly);
        assertGt(IERC20(coin).balanceOf(creator), 0);
    }

    function test_launch_revertsWithoutABandPool() public {
        engine.setPoolFactory(address(0));
        vm.prank(creator);
        vm.expectPartialRevert(AssetGenerator.NoBandPool.selector);
        gen.launch{value: FEE}("Nova", "NOVA", SUPPLY, address(weth), DEV, AssetGenerator.LockMode.FeesOnly);
    }

    function test_launch_devBuyBelowTheMinimumReverts() public {
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(AssetGenerator.DevBuyTooSmall.selector, DEV - 1, DEV));
        gen.launch{value: FEE}("Nova", "NOVA", SUPPLY, address(weth), DEV - 1, AssetGenerator.LockMode.FeesOnly);
    }

    function test_launch_widensTheLimitBuySpreadAndClosesTheBands() public {
        address coin = _launch();
        // A 5x ladder rises sqrt(sqrt(5)) - 1, about 49.5%, per step.
        assertGt(engine.limitBuySpread(), 49_000_000);
        assertLt(engine.limitBuySpread(), 50_000_000);
        address pool = MockFactory(engine.poolFactory()).getPool(coin, address(weth));
        assertEq(MockBandPool(pool).creator(), address(0), "the generator keeps the pool's bands");
        assertFalse(MockBandPool(pool).bandOpen(0));
    }

    function test_beforeGraduation_nothingCanBeCollectedOrReleased() public {
        address coin = _launch();
        vm.startPrank(creator);
        vm.expectRevert(abi.encodeWithSelector(AssetGenerator.NotGraduated.selector, coin));
        gen.collectLockedFees(coin, creator);
        vm.expectRevert(abi.encodeWithSelector(AssetGenerator.NotGraduated.selector, coin));
        gen.releaseVested(coin, creator);
        vm.stopPrank();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(AssetGenerator.NotTheCreator.selector, stranger));
        gen.collectLockedFees(coin, stranger);
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
        assertEq(gen.feeOf(coin, address(weth), creator, true), 0, "makers are free");
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
        gen.setQuoteOption(address(usdc), true, 5_000e6, 5e6, 25_000e6, ExchangeOrderbook.MatchingMode.PriceTimePriority, 250_000);

        address vsWeth = _launch();
        vm.prank(creator);
        address vsUsdc = gen.launch{value: FEE}("Halo", "HALO", SUPPLY, address(usdc), 5e6, AssetGenerator.LockMode.FeesOnly);

        assertEq(gen.takerFeeOf(vsWeth), 1_000_000, "1.00% against WETH");
        assertEq(gen.takerFeeOf(vsUsdc), 250_000, "0.25% against USDC");
    }

    /// Retuning a quote must reprice FUTURE launches only — a live coin holds its own
    /// snapshot, so nobody's trading cost moves because an admin adjusted a quote.
    function test_retuningAQuote_doesNotRepriceLiveCoins() public {
        address coin = _launch();
        assertEq(gen.takerFeeOf(coin), 1_000_000);

        vm.prank(admin);
        gen.setQuoteOption(address(weth), true, 5_000e18, DEV, 25_000e18, ExchangeOrderbook.MatchingMode.PriceTimePriority, 42);

        assertEq(gen.takerFeeOf(coin), 1_000_000, "live coin unchanged");
        vm.prank(creator);
        address later = gen.launch{value: FEE}("Later", "LATE", SUPPLY, address(weth), DEV, AssetGenerator.LockMode.FeesOnly);
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

    function test_creator_cannotConfigureBeforeGraduation() public {
        address coin = _launch();
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(AssetGenerator.CreatorFeeControlLocked.selector, coin));
        gen.setPairTradingConfig(coin, 50, 0, 300_000);
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(AssetGenerator.CreatorFeeControlLocked.selector, coin));
        gen.setPairTakerFee(coin, 300_000);
    }

    function test_creator_canConfigureTheirPairOnceUnlocked() public {
        address coin = _launch();
        _unlockCreator(coin);
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

    function test_pairConfigRole_canKeepMakersFreeOnExistingPair() public {
        address base = makeAddr("freeMakerBase");
        address quote = makeAddr("freeMakerQuote");
        address pair = makeAddr("freeMakerPair");
        engine.setPairFor(base, quote, pair);

        vm.prank(admin);
        gen.setExistingPairTradingConfig(base, quote, 50, 0, 100_000);

        (uint16 slippage, uint32 makerFee, uint32 takerFee, bool configured) = gen.pairPolicies(pair);
        assertTrue(configured);
        assertEq(slippage, 50);
        assertEq(makerFee, 0);
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
        _unlockCreator(coin);

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
        address second = gen.launch{value: FEE}("Second", "SEC", SUPPLY, address(weth), DEV, AssetGenerator.LockMode.FeesOnly);
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
