// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {BandPool} from "../../src/swap/BandPool.sol";
import {BandSwapRouter} from "../../src/swap/BandSwapRouter.sol";
import {WalkTok} from "./GasBandCount.t.sol";

contract AuditBook {
    uint256 public price = 2e8;
    function lmp() external view returns (uint256) { return price; }
    function twap(uint32) external view returns (uint256, uint32) { return (price, 300); }
    function convert(uint256 p, uint256 amount, bool isBid) external pure returns (uint256) {
        return isBid ? (amount * p) / 1e8 : (amount * 1e8) / p;
    }
}

/// Lets a test break each engine read the swap depends on, one at a time.
contract AuditEngine {

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

    /// The pair's whole limit, per side: `incentive` is zero, so no creator cap applies.
    uint32 public spreadBuy = 10000000; // 10% of DENOM
    uint32 public spreadSell = 10000000;
    function setSpreads(uint32 buy, uint32 sell) external { spreadBuy = buy; spreadSell = sell; }
    function getSpread(address, bool isBuy, bool) external view returns (uint32) {
        return isBuy ? spreadBuy : spreadSell;
    }
    address public incentive;


    /// The router the pool gates on and the engine reports through -- one address,
    /// both halves of the price loop.
    address public swapRouter;
    function setSwapRouter(address r) external { swapRouter = r; }
    /// Records that the loop closed; the real engine clamps and writes lmp here.
    uint256 public reports;
    uint256 public lastReported;
    function reportSwap(address, address, bool, uint256 matchedPrice) external {
        reports++; lastReported = matchedPrice;
    }
    address public feeTo = address(0xFEE);
    uint32 public poolFeeShare = 50000000;
    uint32 public rate = 100000;
    bool public feeOfBroken;
    bool public shareBroken;
    bool public feeToBroken;

    function breakFeeOf() external { feeOfBroken = true; }
    function breakShare() external { shareBroken = true; }
    function breakFeeTo() external { feeToBroken = true; }

    function feeOf(address, address, address, bool) external view returns (uint32) {
        if (feeOfBroken) revert("engine: feeOf");
        return rate;
    }
    function poolFeeShare_() external view returns (uint32) { return poolFeeShare; }
}

/// Rejects any transfer to one address, the way a blacklisting token would.
contract PickyTok {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    address public blocked;

    function block_(address a) external { blocked = a; }
    function mint(address to, uint256 a) external { balanceOf[to] += a; }
    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; return true; }
    function transfer(address to, uint256 a) external returns (bool) {
        require(to != blocked, "blocked");
        balanceOf[msg.sender] -= a; balanceOf[to] += a; return true;
    }
    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        require(to != blocked, "blocked");
        if (allowance[f][msg.sender] != type(uint256).max) allowance[f][msg.sender] -= a;
        balanceOf[f] -= a; balanceOf[to] += a; return true;
    }
}

/**
 * Everything that can still fail a swap while the bands hold liquidity.
 *
 * "There is depth, so it fills" is the intuition, and the gap between it and the
 * truth is where an outage looks like a bug in the wrong component. Each case below
 * is a funded pool that refuses, and each one is somebody else's fault.
 */
contract BandSwapFailuresTest is Test {
    BandPool pool;
    BandSwapRouter router;
    WalkTok baseTok;
    WalkTok quoteTok;
    AuditBook book;
    AuditEngine eng;

    /// The position manager, as far as the pool knows: any id it is handed is valid.
    address pm = address(0xBEEF);
    address taker = address(0xABCD);
    address creator = address(0xC0FFEE);

    function setUp() public {
        router = new BandSwapRouter();
        vm.warp(1_000_000);
        baseTok = new WalkTok();
        quoteTok = new WalkTok();
        book = new AuditBook();
        eng = new AuditEngine();
        eng.setSwapRouter(address(router));
        pool = _pool(address(baseTok), address(quoteTok), address(eng));
        _fundAll(pool, baseTok);
    }

    function _pool(address b, address q, address e) internal returns (BandPool p) {
        p = _unsynced(b, q, e);
        p.syncLimit();
        AuditEngine(e).listPool(address(p));
    }

    /// Initialised but never synced: its limits are still zero.
    function _unsynced(address b, address q, address e) internal returns (BandPool p) {
        p = new BandPool();
        // 0.10 / 0.30 / 0.50% as fractions of the engine's 10% limit.
        uint32[] memory t = new uint32[](3);
        t[0] = 1000000; t[1] = 3000000; t[2] = 5000000;
        uint32[] memory m = new uint32[](3);
        m[0] = 100000000; m[1] = 200000000; m[2] = 300000000;
        p.initialize(BandPool.InitParams({
            id: 1, base: b, quote: q, orderbook: address(book), engine: e,
            positionManager: pm, creator: creator, maturity: 600,
            spreadFracs: t, feeMultipliers: m
        }));
    }

    /// 100 base in each of the first `n` bands, as one position.
    function _fund(BandPool p, address bt, uint8 n) internal {
        uint8[] memory bands = new uint8[](n);
        uint256[] memory baseAmts = new uint256[](n);
        for (uint8 i = 0; i < n; i++) {
            bands[i] = i;
            baseAmts[i] = 100e18;
        }
        WalkTok(bt).mint(pm, 100e18 * n);
        vm.startPrank(pm);
        WalkTok(bt).approve(address(p), type(uint256).max);
        p.increase(1, bands, baseAmts, new uint256[](n));
        vm.stopPrank();
    }

    function _fundAll(BandPool p, WalkTok bt) internal {
        _fund(p, address(bt), 3);
    }

    function _try(uint256 quoteIn) internal {
        quoteTok.mint(taker, quoteIn);
        vm.startPrank(taker);
        quoteTok.approve(address(pool), type(uint256).max);
        quoteTok.approve(address(router), type(uint256).max);
        router.swap(address(pool), quoteIn, true, taker, 0);
        vm.stopPrank();
    }

    // ---- the pool's own ------------------------------------------------------

    /**
     * The one that reads as a bug and is not. Bands hold plenty of QUOTE and no BASE
     * after a one-way run, so a buy finds nothing to pay out and reverts NoLiquidity
     * -- while the pool's TVL chart shows it full. Liquidity is directional.
     */
    function test_aPoolFullOfQuoteRefusesEveryBuy() public {
        _try(2_000e18); // sweeps all the base out
        (uint256 r0b, uint256 r0q) = pool.bandReserves(0);
        assertEq(r0b, 0, "no base left anywhere");
        assertGt(r0q, 0, "but the quote is right there");

        quoteTok.mint(taker, 10e18);
        vm.startPrank(taker);
        quoteTok.approve(address(pool), type(uint256).max);
        quoteTok.approve(address(router), type(uint256).max);
        vm.expectRevert(BandPool.NoLiquidity.selector);
        router.swap(address(pool), 10e18, true, taker, 0);
        vm.stopPrank();

        // The other direction works perfectly, on the same reserves.
        baseTok.mint(taker, 1e18);
        vm.startPrank(taker);
        baseTok.approve(address(pool), type(uint256).max);
        baseTok.approve(address(router), type(uint256).max);
        uint256 out = router.swap(address(pool), 1e18, false, taker, 0);
        assertGt(out, 0, "selling into it is fine");
        vm.stopPrank();
    }

    /// A closed band still fills. Closing stops DEPOSITS, never settlement.
    function test_closingEveryBandDoesNotCloseThePool() public {
        vm.startPrank(creator);
        pool.setBandOpen(0, false);
        pool.setBandOpen(1, false);
        pool.setBandOpen(2, false);
        vm.stopPrank();
        _try(20e18); // does not revert
    }

    // ---- the engine ----------------------------------------------------------

    /// Every swap reads the taker's fee from the engine, so an engine that cannot
    /// answer takes the pool down with it however deep the bands are.
    function test_anEngineThatCannotPriceTheFeeStopsEverySwap() public {
        eng.breakFeeOf();
        quoteTok.mint(taker, 10e18);
        vm.startPrank(taker);
        quoteTok.approve(address(pool), type(uint256).max);
        quoteTok.approve(address(router), type(uint256).max);
        vm.expectRevert(bytes("engine: feeOf"));
        router.swap(address(pool), 10e18, true, taker, 0);
        vm.stopPrank();
    }

    /**
     * A token that blacklists feeTo used to brick the pair: the protocol fee was
     * pushed mid-swap, so an arbitrary external token sat in the settlement path and a
     * funded pool refused trades over the PROTOCOL's leg of a fee. Fees accrue now, so
     * the market keeps running and only the sweep fails.
     */
    function test_aTokenThatRefusesFeeToNoLongerBricksThePair() public {
        PickyTok picky = new PickyTok();
        BandPool p2 = _pool(address(picky), address(quoteTok), address(eng));
        _fund(p2, address(picky), 1);

        picky.block_(address(0xFEE));
        quoteTok.mint(taker, 10e18);
        vm.startPrank(taker);
        quoteTok.approve(address(router), type(uint256).max);
        uint256 out = router.swap(address(p2), 10e18, true, taker, 0);
        vm.stopPrank();

        assertGt(out, 0, "the trade goes through -- the protocol fee is only accrued");
        assertGt(p2.protocolFeesBase(), 0, "and waits to be swept");

        // The blacklist now fails only the sweep, in isolation, with the market open.
        vm.expectRevert(bytes("blocked"));
        p2.sweepProtocolFees();
    }

    // ---- the pair's limit ------------------------------------------------------

    /**
     * Bands are fractions of the pair's limit, and a pool's limit is zero until
     * something syncs it. Funded or not, an unsynced pool has nothing to multiply by,
     * so every band is idle. The real engine syncs on `addPair` and `setSpread`; a pool
     * wired to anything else has to be synced by hand, or it is this.
     */
    function test_aFundedPoolThatWasNeverSyncedRefusesEverySwap() public {
        BandPool p2 = _unsynced(address(baseTok), address(quoteTok), address(eng));
        // Listed but never synced: the refusal under test is the POOL's, not the router's.
        eng.listPool(address(p2));
        _fund(p2, address(baseTok), 3);
        assertEq(p2.pairLimit(true), 0, "never synced");
        assertEq(p2.liveLimit(true), 10000000, "though the engine has a limit to give");

        quoteTok.mint(taker, 10e18);
        vm.startPrank(taker);
        quoteTok.approve(address(router), type(uint256).max);
        vm.expectRevert(BandPool.NoLiquidity.selector);
        router.swap(address(p2), 10e18, true, taker, 0);
        vm.stopPrank();

        p2.syncLimit(); // permissionless, and all it takes
        eng.listPool(address(p2));
        _try2(p2, 10e18);
    }

    /**
     * A limit of zero on ONE side idles that side for every band, and only that side.
     * The bands hold both currencies here, so each direction has something to pay out.
     */
    function test_aZeroLimitIdlesThatSideOnly() public {
        _try(20e18); // band 0 now holds quote as well as base
        eng.setSpreads(10000000, 0);
        pool.syncLimit();
        assertEq(pool.pairLimit(false), 0);
        for (uint8 i = 0; i < 3; i++) {
            (uint32 buyTol, uint32 sellTol) = pool.bandTolerances(i);
            assertGt(buyTol, 0, "buys still quote");
            assertEq(sellTol, 0, "sells do not, in any band");
        }

        baseTok.mint(taker, 1e18);
        vm.startPrank(taker);
        baseTok.approve(address(router), type(uint256).max);
        vm.expectRevert(BandPool.NoLiquidity.selector);
        router.swap(address(pool), 1e18, false, taker, 0);
        vm.stopPrank();

        _try(10e18); // the buy side trades on, from the same reserves
    }

    function _try2(BandPool p, uint256 quoteIn) internal {
        quoteTok.mint(taker, quoteIn);
        vm.startPrank(taker);
        quoteTok.approve(address(router), type(uint256).max);
        uint256 out = router.swap(address(p), quoteIn, true, taker, 0);
        vm.stopPrank();
        assertGt(out, 0, "synced, it trades");
    }

    // ---- arithmetic ----------------------------------------------------------

    /**
     * The reserve decrement is a checked subtraction, so a rounding direction that
     * let `out` exceed what the band holds would revert on a legitimate trade.
     * convert() floors twice on the round trip, so it cannot -- fuzzed rather than
     * argued, across sizes that both under- and over-shoot the band.
     */
    function testFuzz_takingAWholeBandNeverUnderflowsItsReserve(uint96 amountIn) public {
        vm.assume(amountIn > 1e6);
        quoteTok.mint(taker, amountIn);
        vm.startPrank(taker);
        quoteTok.approve(address(pool), type(uint256).max);
        quoteTok.approve(address(router), type(uint256).max);
        router.swap(address(pool), amountIn, true, taker, 0);
        vm.stopPrank();
        (uint256 r,) = pool.bandReserves(0);
        assertLe(r, 100e18, "reserve never wrapped");
    }
}
