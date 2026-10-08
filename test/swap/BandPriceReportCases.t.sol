// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {BandPool} from "../../src/swap/BandPool.sol";
import {BandSwapRouter} from "../../src/swap/BandSwapRouter.sol";
import {StubToken} from "./BandPoolBase.sol";

/// A book with a real rail: the same block-open-anchored clamp MatchingLib applies,
/// so the cases below exercise the behaviour rather than a stub that always accepts.
contract RailBook {
    uint256 public price = 2e8;
    uint256 public blockOpen = 2e8;
    uint256 public openBlock;
    uint32 public spread = 100000; // 0.1% of DENOM, the production default
    uint256 public writes;

    constructor() { openBlock = block.number; }
    function setSpread(uint32 s) external { spread = s; }
    function lmp() external view returns (uint256) { return price; }
    function lmpAtBlockOpen() external view returns (uint256) { return blockOpen; }
    function twap(uint32) external view returns (uint256, uint32) { return (price, 300); }
    function convert(uint256 p, uint256 amount, bool isBid) external pure returns (uint256) {
        return isBid ? (amount * p) / 1e8 : (amount * 1e8) / p;
    }

    /// Mirrors MatchingLib.reportSwapPrice: clamp to the block's OPEN, not the last write.
    function report(uint256 matchedPrice) external {
        if (block.number != openBlock) { openBlock = block.number; blockOpen = price; }
        if (price == 0 || matchedPrice == 0) return;
        uint256 ceil_ = (blockOpen * (1e8 + spread)) / 1e8;
        uint256 floor_ = spread >= 1e8 ? 0 : (blockOpen * (1e8 - spread)) / 1e8;
        uint256 n = matchedPrice;
        if (n > ceil_) n = ceil_;
        if (n < floor_) n = floor_;
        if (n == 0 || n == price) return;
        price = n;
        writes++;
    }
}

/**
 * The pool's limit comes from HERE (10%) and the rail from the book (0.1%). The real
 * engine reads both from one number, and `setSpread` syncs the pool to it, so it can
 * no longer produce a band quoting past the rail at a steady anchor -- that now takes an
 * anchor lagging the book (BandSpreadSide). Decoupled here on purpose: this file's
 * subject is the POOL-side report gate, and a ladder beyond the rail lets the clamp
 * cases below keep v1's numbers.
 */
contract RailEngine {

    // The router checks every pool against `poolFactory().getPool(base, quote)`, as it
    // does against the real engine's factory (a fake pool could otherwise feed prices to
    // reportSwap). The stub is its own one-pool-per-pair registry unless a suite points it
    // at a real factory with `setPoolFactory`.
    address internal _factory;
    mapping(address => mapping(address => address)) internal _listedPool;

    function setPoolFactory(address f) external {
        _factory = f;
    }

    function poolFactory() external view returns (address) {
        return _factory == address(0) ? address(this) : _factory;
    }

    function listPool(address p) external {
        _listedPool[BandPool(p).base()][BandPool(p).quote()] = p;
    }

    function getPool(address b, address q) external view returns (address) {
        return _listedPool[b][q];
    }

    uint32 public spread = 10000000; // 10% of DENOM
    function setSpread_(uint32 s) external { spread = s; }
    function getSpread(address, bool, bool) external view returns (uint32) { return spread; }

    /// No slippage policy: the limit is the spread alone.
    address public incentive;
    address public feeTo = address(0xFEE);
    uint32 public poolFeeShare = 50000000;
    address public swapRouter;
    address public book;
    function setSwapRouter(address r) external { swapRouter = r; }
    function setBook(address b) external { book = b; }
    function feeOf(address, address, address, bool) external pure returns (uint32) { return 100000; }
    function reportSwap(address, address, bool, uint256 matchedPrice) external {
        RailBook(book).report(matchedPrice);
    }
}

/**
 * The `lmp` rules, run against BandPool rather than assumed to transfer.
 *
 * `Pool` has these pinned across SwapPriceReport and SwapPriceReportEdges, and it was
 * tempting to say they "apply" to band pools because both paths end in
 * MatchingLib.reportSwapPrice. They do not all live in that library. The report threshold
 * (Pool's MIN_REPORT_FRACTION, BandPool's MIN_REPORT_DIVISOR) is a POOL-side gate, and
 * BandPool first shipped without it -- so until this file existed, a
 * dust swap through a band pool moved the public reference for the cost of gas, which is
 * the exact vulnerability Pool's M2 work removed.
 */
contract BandPriceReportCasesTest is Test {
    BandPool pool;
    BandSwapRouter router;
    StubToken baseTok;
    StubToken quoteTok;
    RailBook book;
    RailEngine eng;

    /// The position manager is just an address here: the pool takes whatever id it is handed.
    address pm = address(0xBEEF);
    address taker = address(0xABCD);
    address creator = address(0xC0FFEE);

    function setUp() public {
        vm.warp(1_000_000);
        vm.roll(100);
        router = new BandSwapRouter();
        baseTok = new StubToken();
        quoteTok = new StubToken();
        book = new RailBook();
        eng = new RailEngine();
        eng.setSwapRouter(address(router));
        eng.setBook(address(book));

        pool = new BandPool();
        // Fractions of the engine's 10% limit: 0.1 / 0.3 / 0.5%, the ladder v1 shipped.
        uint32[] memory t = new uint32[](3);
        t[0] = 1000000; t[1] = 3000000; t[2] = 5000000;
        uint32[] memory m = new uint32[](3);
        m[0] = 100000000; m[1] = 200000000; m[2] = 300000000;
        pool.initialize(BandPool.InitParams({
            id: 1, base: address(baseTok), quote: address(quoteTok),
            orderbook: address(book), engine: address(eng),
            positionManager: pm, creator: creator, maturity: 600,
            spreadFracs: t, feeMultipliers: m
        }));
        pool.syncLimit();
        eng.listPool(address(pool));

        // One position holding all three bands, as the manager would deposit it.
        baseTok.mint(pm, 3_000e18);
        vm.prank(pm);
        baseTok.approve(address(pool), type(uint256).max);
        uint8[] memory bands = new uint8[](3);
        uint256[] memory baseAmounts = new uint256[](3);
        uint256[] memory quoteAmounts = new uint256[](3);
        for (uint8 i = 0; i < 3; i++) {
            bands[i] = i;
            baseAmounts[i] = 1_000e18;
        }
        vm.prank(pm);
        pool.increase(1, bands, baseAmounts, quoteAmounts);
    }

    function _buy(uint256 q) internal returns (uint256) {
        quoteTok.mint(taker, q);
        vm.startPrank(taker);
        quoteTok.approve(address(router), type(uint256).max);
        uint256 out = router.swap(address(pool), q, true, taker, 0);
        vm.stopPrank();
        return out;
    }

    function _sell(uint256 b) internal returns (uint256) {
        baseTok.mint(taker, b);
        vm.startPrank(taker);
        baseTok.approve(address(router), type(uint256).max);
        uint256 out = router.swap(address(pool), b, false, taker, 0);
        vm.stopPrank();
        return out;
    }

    // ---- 1/2. a real trade prints; dust does not -----------------------------

    function test_aRealBuyMovesThePrice() public {
        assertEq(book.price(), 2e8);
        _buy(100e18);
        assertGt(book.price(), 2e8, "a real trade prints");
    }

    function test_aRealSellMovesThePriceDown() public {
        // The bands are seeded base-only, so they hold no quote to pay a seller with
        // until something has bought from them. Liquidity is directional.
        _buy(2_000e18);
        vm.roll(block.number + 1); // a fresh cap, so the sell is not fighting the buy's
        _sell(200e18);
        assertLt(book.price(), (2e8 * (1e8 + 100000)) / 1e8, "the sell side prints down");
    }

    /**
     * The case that was broken. 210 wei of quote is rounding dust against a 1,000e18
     * band, and before the gate it moved the reference the full clamped step for gas.
     */
    function test_dustCannotMoveThePrice() public {
        _buy(210);
        assertEq(book.price(), 2e8, "dust prints nothing");
        assertEq(book.writes(), 0);
    }

    /// And gating the REPORT is not gating the price: the dust still trades.
    function test_dustStillFillsEvenThoughItCannotPrint() public {
        uint256 out = _buy(210e6);
        assertGt(out, 0, "the swap executed");
        assertEq(book.price(), 2e8, "the public reference is untouched");
    }

    /// Repeating it does not add up to a print either -- this is the walk it prevents.
    function test_dustCannotWalkTheOracleAcrossBlocks() public {
        for (uint256 i = 0; i < 20; i++) {
            vm.roll(block.number + 1);
            _buy(210);
        }
        assertEq(book.price(), 2e8, "twenty blocks of dust moved nothing");
    }

    // ---- 3. the rail clamps a real trade -------------------------------------

    /// A swap reaching band 2 trades at 2.020 and prints the clamped 2.002.
    function test_theRailClampsAPrintToTheBlockOpenCeiling() public {
        _buy(5_000e18); // deep enough to reach band 2
        assertEq(book.price(), (2e8 * (1e8 + 100000)) / 1e8, "clamped to +0.1%");
    }

    // ---- 4. a batch in one block is bounded AS a batch ------------------------

    function test_aBatchInOneBlockIsBoundedTogether() public {
        uint256 ceiling = (2e8 * (1e8 + 100000)) / 1e8;
        for (uint256 i = 0; i < 5; i++) _buy(800e18); // same block, within the pool's depth
        assertEq(book.price(), ceiling, "five prints, one block, one step");
    }

    /// ...and the cap re-arms next block, so honest sustained flow is not frozen out.
    function test_theCapReArmsEachBlock() public {
        _buy(2_000e18);
        uint256 afterOne = book.price();
        vm.roll(block.number + 1);
        _buy(2_000e18);
        assertGt(book.price(), afterOne, "a second block earns a second step");
    }

    // ---- 5. a zero spread freezes the price ----------------------------------

    function test_aZeroSpreadFreezesThePrice() public {
        book.setSpread(0);
        _buy(2_000e18);
        assertEq(book.price(), 2e8, "ceiling == floor == the block open");
    }

    // ---- 6. nothing filled, nothing reported ---------------------------------

    function test_aSwapThatFillsNothingReportsNothing() public {
        // Drain every band's base, then try to buy again.
        _buy(20_000e18);
        uint256 writesBefore = book.writes();
        quoteTok.mint(taker, 1e18);
        vm.startPrank(taker);
        quoteTok.approve(address(router), type(uint256).max);
        vm.expectRevert(BandPool.NoLiquidity.selector);
        router.swap(address(pool), 1e18, true, taker, 0);
        vm.stopPrank();
        assertEq(book.writes(), writesBefore, "a reverted swap prints nothing");
    }

    // ---- 7. the report describes a price someone really paid -----------------

    /**
     * `matchedPrice` is the LAST band that meaningfully filled, so a trade confined to
     * band 0 prints band 0's bound and a trade reaching band 2 prints a higher one --
     * the property that made dust and whales indistinguishable before Pool's M2 work.
     */
    function test_aSmallTradeAndALargeOneDoNotPrintTheSamePrice() public {
        book.setSpread(50000000); // 50%: let the rail out of the way to see the raw print
        _buy(100e18); // fits in band 0
        uint256 small = book.price();

        setUp();
        book.setSpread(50000000);
        _buy(5_000e18); // reaches band 2
        uint256 large = book.price();

        assertEq(small, (2e8 * (1e8 + 100000)) / 1e8, "band 0's bound");
        assertEq(large, (2e8 * (1e8 + 500000)) / 1e8, "band 2's bound");
        assertTrue(small != large, "size changes the print, as it must");
    }
}
