// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {BandPool} from "../../src/swap/BandPool.sol";
import {IBandPool} from "../../src/swap/interfaces/IBandPool.sol";
import {BandSwapRouter} from "../../src/swap/BandSwapRouter.sol";

contract Tok {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
    }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        return true;
    }

    function transfer(address to, uint256 a) external returns (bool) {
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
        return true;
    }

    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        if (allowance[f][msg.sender] != type(uint256).max) allowance[f][msg.sender] -= a;
        balanceOf[f] -= a;
        balanceOf[to] += a;
        return true;
    }
}

/// Unlike BandPoolBase's stub this actually honours the direction flag, which is the
/// whole point: an identity convert() cannot tell a base leg from a quote leg.
contract RealisticBook {
    uint256 public price;

    constructor(uint256 p) {
        price = p;
    }

    /// The listing price the pool anchors to until the TWAP can answer.
    function lmp() external view returns (uint256) { return price; }

    function twap(uint32) external view returns (uint256, uint32) {
        return (price, 300);
    }

    function convert(uint256 p, uint256 amount, bool isBid) external pure returns (uint256) {
        return isBid ? (amount * p) / 1e8 : (amount * 1e8) / p;
    }
}

contract Eng {

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

    /// The pair's whole limit: `incentive` is zero, so no creator cap applies.
    uint32 public spread = 10000000; // 10% of DENOM
    function setSpread_(uint32 s) external { spread = s; }
    function getSpread(address, bool, bool) external view returns (uint32) { return spread; }
    address public incentive;

    address public swapRouter;
    function setSwapRouter(address r) external { swapRouter = r; }
    /// The price each fill reported: the bound of the last band that filled reportably.
    uint256 public lastReported;
    function reportSwap(address, address, bool, uint256 matchedPrice) external {
        lastReported = matchedPrice;
    }

    address public feeTo = address(0xFEE);
    uint32 public poolFeeShare = 50000000;

    function feeOf(address, address, address, bool) external pure returns (uint32) {
        return 100000;
    }
}

contract BandPoolDirectionTest is Test {
    BandPool pool;
    BandSwapRouter router;
    Tok baseTok;
    Tok quoteTok;
    RealisticBook book;
    Eng eng;
    address creator = address(0xC0FFEE);
    address pm = address(0xBEEF);
    address taker = address(0xABCD);

    /// The pool takes whatever token id the manager hands it.
    uint256 constant ID = 1;

    function setUp() public {
        router = new BandSwapRouter();
        baseTok = new Tok();
        quoteTok = new Tok();
        book = new RealisticBook(2e8); // 1 base = 2 quote
        eng = new Eng();
        eng.setSwapRouter(address(router));
        uint32[] memory t = new uint32[](1);
        // 0.10% as a fraction of the engine's 10% limit: 1e5 × 1e8 / 1e7.
        t[0] = 1000000;
        pool = _pool(book, t);
        vm.warp(1_000_000);
    }

    function _pool(RealisticBook b, uint32[] memory fracs) internal returns (BandPool p) {
        p = new BandPool();
        uint32[] memory fm = new uint32[](fracs.length);
        for (uint256 _f = 0; _f < fracs.length; _f++) fm[_f] = 100000000; // 1x, unless a test says otherwise
        p.initialize(
            BandPool.InitParams({
                id: 1,
                base: address(baseTok),
                quote: address(quoteTok),
                orderbook: address(b),
                engine: address(eng),
                positionManager: pm,
                creator: creator,
                maturity: 600,
                spreadFracs: fracs,
                feeMultipliers: fm
            })
        );
        p.syncLimit();
        eng.listPool(address(p));
    }

    /// Seed `band` with BOTH sides, the state any band is in after it has traded.
    function _seedInto(BandPool p, uint8 band, uint256 baseAmt, uint256 quoteAmt) internal {
        baseTok.mint(pm, baseAmt);
        quoteTok.mint(pm, quoteAmt);
        uint8[] memory b = new uint8[](1);
        uint256[] memory ba = new uint256[](1);
        uint256[] memory qa = new uint256[](1);
        b[0] = band;
        ba[0] = baseAmt;
        qa[0] = quoteAmt;
        vm.startPrank(pm);
        baseTok.approve(address(p), type(uint256).max);
        quoteTok.approve(address(p), type(uint256).max);
        p.increase(ID, b, ba, qa);
        vm.stopPrank();
    }

    function _seed() internal returns (uint256 id) {
        _seedInto(pool, 0, 1_000e18, 2_000e18);
        id = ID;
    }

    function _sell(BandPool p, uint256 baseIn) internal returns (uint256 out) {
        baseTok.mint(taker, baseIn);
        vm.startPrank(taker);
        baseTok.approve(address(router), type(uint256).max);
        out = router.swap(address(p), baseIn, false, taker, 0);
        vm.stopPrank();
    }

    function _buyIn(BandPool p, uint256 quoteIn) internal returns (uint256 out) {
        quoteTok.mint(taker, quoteIn);
        vm.startPrank(taker);
        quoteTok.approve(address(router), type(uint256).max);
        out = router.swap(address(p), quoteIn, true, taker, 0);
        vm.stopPrank();
    }

    /// Everything accrued, vested or not -- v1's `rawOwed`.
    function _accrued(uint256 id) internal view returns (uint256 ab, uint256 aq) {
        (IBandPool.BandView[] memory all, uint256 ob, uint256 oq) = pool.positionView(id);
        ab = ob;
        aq = oq;
        for (uint256 i = 0; i < all.length; i++) {
            ab += all[i].pendingBase;
            aq += all[i].pendingQuote;
        }
    }

    function test_baseToQuoteMovesTheRightReserves() public {
        _seed();
        (uint256 b0, uint256 q0) = pool.bandReserves(0);

        _sell(pool, 10e18); // base in, quote out

        (uint256 b1, uint256 q1) = pool.bandReserves(0);
        assertGt(b1, b0, "the band took base IN, so baseReserve must rise");
        assertLt(q1, q0, "the band paid quote OUT, so quoteReserve must fall");
    }

    function test_baseToQuoteFeeIsClaimableInQuote() public {
        uint256 id = _seed();
        _sell(pool, 10e18);

        vm.warp(block.timestamp + 601);
        uint256 quoteBefore = quoteTok.balanceOf(address(this));
        uint256 baseBefore = baseTok.balanceOf(address(this));
        vm.prank(pm);
        pool.collect(id, address(this));
        assertGt(quoteTok.balanceOf(address(this)), quoteBefore, "a quote-denominated fee pays out in quote");
        assertEq(baseTok.balanceOf(address(this)), baseBefore, "and never in base");
    }

    function test_bothDirectionsAccrueSeparatelyAndBothAreClaimable() public {
        uint256 id = _seed();

        _buyIn(pool, 20e18); // fee accrues in base
        _sell(pool, 10e18); // fee accrues in quote

        (uint256 rawBase, uint256 rawQuote) = _accrued(id);
        assertGt(rawBase, 0, "the base leg earned");
        assertGt(rawQuote, 0, "and so did the quote leg, on its own accumulator");

        vm.warp(block.timestamp + 601);
        vm.prank(pm);
        (uint256 vestedBase, uint256 vestedQuote) = pool.collect(id, address(this));
        assertEq(vestedBase, rawBase, "fully vested, so all of the base leg");
        assertEq(vestedQuote, rawQuote, "and all of the quote leg");
    }

    /// The claim event is the only record of LP income, so it has to carry both legs.
    event Collect(uint256 indexed tokenId, address indexed recipient, uint256 base, uint256 quote);

    function test_theClaimEventCarriesTheQuoteLegToo() public {
        uint256 id = _seed();
        _sell(pool, 10e18);

        (, uint256 rawQuote) = _accrued(id);
        vm.warp(block.timestamp + 601);
        vm.expectEmit(true, true, true, true, address(pool));
        emit Collect(id, address(this), 0, rawQuote);
        vm.prank(pm);
        pool.collect(id, address(this));
    }

    /**
     * The band was the only LP, so an early exit's forfeit leaves in BOTH currencies.
     * In v1 a collect at age 0 was that exit; in v2 collect never forfeits, so it is
     * checked to leave everything in place, and the WITHDRAWAL is what forfeits.
     */
    function test_soleLpForfeitsBothLegsToTheProtocol() public {
        uint256 id = _seed();
        _buyIn(pool, 20e18);
        _sell(pool, 10e18);

        (uint256 accruedBase, uint256 accruedQuote) = _accrued(id);
        uint256 beforeBase = pool.protocolFeesBase();
        uint256 beforeQuote = pool.protocolFeesQuote();

        vm.prank(pm);
        (uint256 paidBase, uint256 paidQuote) = pool.collect(id, address(this)); // age 0
        assertEq(paidBase, 0, "nothing vested yet, so nothing paid");
        assertEq(paidQuote, 0);
        assertEq(pool.protocolFeesBase(), beforeBase, "a collect forfeits nothing");
        assertEq(pool.protocolFeesQuote(), beforeQuote);
        (uint256 stillBase, uint256 stillQuote) = _accrued(id);
        assertEq(stillBase, accruedBase, "the unvested base keeps vesting");
        assertEq(stillQuote, accruedQuote, "and so does the quote");

        vm.prank(pm);
        pool.decrease(id, 10_000, address(this)); // still age 0: the exit
        assertEq(pool.protocolFeesBase(), beforeBase + accruedBase, "base leg forfeited to the protocol");
        assertEq(pool.protocolFeesQuote(), beforeQuote + accruedQuote, "quote leg too");
    }

    // ---- which way each side's bound rounds ------------------------------------

    /**
     * A price the bound arithmetic cannot divide exactly, so every rounding direction
     * shows in the reported price. Band 0 is 1% of a 10% limit (0.10%); band 1 is the
     * whole limit, so its buy bound sits on the rail.
     */
    uint256 constant ODD = 200000001;

    function _oddPool() internal returns (BandPool p) {
        uint32[] memory t = new uint32[](2);
        t[0] = 1000000;
        t[1] = 100000000;
        p = _pool(new RealisticBook(ODD), t);
    }

    /// A buy bound rounds UP, in the LPs' favour.
    function test_aBuyBoundRoundsUp() public {
        BandPool p = _oddPool();
        _seedInto(p, 0, 1_000e18, 0);
        _buyIn(p, 10e18);
        // ODD × 1.001 = 200200001.2002 -- the band asks for the next unit up.
        assertEq(eng.lastReported(), 200200002, "ceil, not floor");
    }

    /// ...but never past `price × (1e8 + limit) / 1e8`, the ceiling the rail computes.
    function test_aBuyBoundNeverRoundsPastTheRail() public {
        BandPool p = _oddPool();
        _seedInto(p, 1, 1_000e18, 0); // band 0 empty, so the fill lands in band 1
        _buyIn(p, 10e18);
        uint256 rail = (ODD * (1e8 + 10000000)) / 1e8; // 220000001.1 -> 220000001
        assertEq(rail, 220000001);
        assertEq(eng.lastReported(), rail, "rounding up would have stepped past the rail");
    }

    /// A sell bound rounds DOWN, also in the LPs' favour: the taker gets the lower price.
    function test_aSellBoundRoundsDown() public {
        BandPool p = _oddPool();
        _seedInto(p, 0, 1_000e18, 2_000e18);
        _sell(p, 1e18);
        // ODD × 0.999 = 199800000.999 -> 199800000.
        assertEq(eng.lastReported(), 199800000, "floor, not ceil");
    }
}
