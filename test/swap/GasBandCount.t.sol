// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {BandPool} from "../../src/swap/BandPool.sol";
import {BandSwapRouter} from "../../src/swap/BandSwapRouter.sol";

/// A bare ERC-20 for the swap-walk suites: no decimals, no hooks, unbounded mint.
contract WalkTok {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    function mint(address to, uint256 a) external { balanceOf[to] += a; }
    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; return true; }
    function transfer(address to, uint256 a) external returns (bool) {
        balanceOf[msg.sender] -= a; balanceOf[to] += a; return true;
    }
    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        if (allowance[f][msg.sender] != type(uint256).max) allowance[f][msg.sender] -= a;
        balanceOf[f] -= a; balanceOf[to] += a; return true;
    }
}

/// Honours the bound, so a wider band genuinely prices worse.
contract PricedBook {
    /// The listing price the pool anchors to until the TWAP can answer.
    function lmp() external pure returns (uint256) { return 2e8; }

    function twap(uint32) external pure returns (uint256, uint32) { return (2e8, 300); }
    function convert(uint256 p, uint256 amount, bool isBid) external pure returns (uint256) {
        return isBid ? (amount * p) / 1e8 : (amount * 1e8) / p;
    }
}

contract CountEngine {

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

    /// The pair's market spread, which is the whole limit here: `incentive` is zero,
    /// so no creator cap applies. A pool reads it only through `syncLimit`.
    uint32 public spread = 10000000; // 10% of DENOM
    /// Per-side overrides, for cases that idle one side of the book and not the other.
    bool public sided;
    uint32 public spreadBuy;
    uint32 public spreadSell;
    function setSpread_(uint32 s) external { spread = s; sided = false; }
    function setSideSpreads(uint32 buy, uint32 sell) external { sided = true; spreadBuy = buy; spreadSell = sell; }
    function getSpread(address, bool isBuy, bool) external view returns (uint32) {
        if (sided) return isBuy ? spreadBuy : spreadSell;
        return spread;
    }

    /// No slippage policy: the limit is the market spread alone, as on a pair the
    /// generator did not launch.
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
    function feeOf(address, address, address, bool) external pure returns (uint32) { return 100000; }
}

/**
 * Why a pool ships THREE bands rather than one or eight.
 *
 * The intuitive answer -- "more bands cost more gas" -- is wrong, and this file
 * exists partly to record that it was measured and disproved. The swap loop is
 * `t < n && remainingIn > 0`, so it stops the moment the trade is filled. A trade
 * that the tightest band can absorb never looks at the others, and eight bands cost
 * the same as one.
 *
 * The real cost of splitting is EXECUTION, and it is paid by the taker on large
 * trades and by the LPs who sit in bands that rarely fill.
 */
contract GasBandCountTest is Test {
    BandSwapRouter router;

    function setUp() public {
        router = new BandSwapRouter();
    }
    address pm = address(0xBEEF);
    address creator = address(0xC0FFEE);
    address taker = address(0xABCD);

    uint256 constant TOTAL_LIQUIDITY = 120_000e18;

    /// Fresh tokens every run: reusing them measures storage warmth, not band count.
    function _build(uint8 bandCount)
        internal
        returns (BandPool p, WalkTok baseTok, WalkTok quoteTok)
    {
        baseTok = new WalkTok();
        quoteTok = new WalkTok();
        p = new BandPool();
        // The engine is hoisted so its router can be wired BEFORE the pool uses it --
        // constructed inline it never was, and the pool's onlyRouter saw address(0).
        CountEngine e = new CountEngine();
        e.setSwapRouter(address(router));
        uint32[] memory t = new uint32[](bandCount);
        uint32[] memory fm = new uint32[](bandCount);
        for (uint256 _f = 0; _f < bandCount; _f++) fm[_f] = 100000000; // 1x, unless a test says otherwise
        // 0.10%, 0.20%, ... 0.80% as fractions of the engine's 10% limit: T × 1e8 / 1e7.
        for (uint256 i = 0; i < bandCount; i++) t[i] = uint32(1000000 * (i + 1));
        p.initialize(BandPool.InitParams({
            id: 1, base: address(baseTok), quote: address(quoteTok),
            orderbook: address(new PricedBook()), engine: address(e),
            positionManager: pm, creator: creator, maturity: 600, spreadFracs: t,
            feeMultipliers: fm
        }));
        p.syncLimit();
        e.listPool(address(p));
    }

    /// The SAME total liquidity, spread evenly over `bandCount` bands, in one position.
    function _seedEvenly(BandPool p, WalkTok baseTok, uint8 bandCount) internal {
        uint256 each = TOTAL_LIQUIDITY / bandCount;
        uint8[] memory bands = new uint8[](bandCount);
        uint256[] memory baseAmts = new uint256[](bandCount);
        uint256[] memory quoteAmts = new uint256[](bandCount);
        for (uint256 i = 0; i < bandCount; i++) {
            bands[i] = uint8(i);
            baseAmts[i] = each;
        }
        baseTok.mint(pm, TOTAL_LIQUIDITY);
        vm.startPrank(pm);
        baseTok.approve(address(p), type(uint256).max);
        p.increase(1, bands, baseAmts, quoteAmts);
        vm.stopPrank();
    }

    function _trade(BandPool p, WalkTok quoteTok, uint256 amountIn) internal returns (uint256 out, uint256 gas_) {
        quoteTok.mint(taker, amountIn);
        vm.startPrank(taker);
        quoteTok.approve(address(p), type(uint256).max);
        quoteTok.approve(address(router), type(uint256).max);
        uint256 g0 = gasleft();
        out = router.swap(address(p), amountIn, true, taker, 0);
        gas_ = g0 - gasleft();
        vm.stopPrank();
    }

    /**
     * The loop stops when the trade is filled, so bands past the fill are never read.
     * Eight bands cost what one costs. Band count is NOT a gas argument.
     */
    function test_idleBandsAreFreeBecauseTheLoopStopsAtTheFill() public {
        // Warm the router first. It is shared across both measurements, so whichever
        // trade runs first pays EIP-2929's cold account access for it -- ~2,600 gas
        // that has nothing to do with band count, and enough to swamp the effect being
        // measured. Same confound as reusing tokens, which this file already avoids.
        (BandPool warm, WalkTok wb, WalkTok wq) = _build(1);
        _seedEvenly(warm, wb, 1);
        _trade(warm, wq, 1e18);

        (BandPool p1, WalkTok b1, WalkTok q1) = _build(1);
        _seedEvenly(p1, b1, 1);
        (, uint256 g1) = _trade(p1, q1, 1e18);

        (BandPool p8, WalkTok b8, WalkTok q8) = _build(8);
        // Only band 0 funded, so seven bands sit idle behind the fill.
        _seedEvenly(p8, b8, 1);
        (, uint256 g8) = _trade(p8, q8, 1e18);

        console2.log("1 band, small trade ", g1);
        console2.log("8 bands, small trade", g8);
        assertApproxEqAbs(g8, g1, 100, "seven idle bands are free");
    }

    /**
     * The argument that is real. Hold TVL fixed, split it more ways, and a large
     * trade is pushed out of the tight band into worse-priced ones sooner.
     */
    function test_splittingTheSameLiquidityAcrossMoreBandsWorsensExecution() public {
        uint256 big = 200_000e18; // buys ~100k base: more than any single band holds when split

        (BandPool p1, WalkTok b1, WalkTok q1) = _build(1);
        _seedEvenly(p1, b1, 1);
        (uint256 out1,) = _trade(p1, q1, big);

        (BandPool p3, WalkTok b3, WalkTok q3) = _build(3);
        _seedEvenly(p3, b3, 3);
        (uint256 out3,) = _trade(p3, q3, big);

        (BandPool p8, WalkTok b8, WalkTok q8) = _build(8);
        _seedEvenly(p8, b8, 8);
        (uint256 out8,) = _trade(p8, q8, big);

        console2.log("1 band  out", out1);
        console2.log("3 bands out", out3);
        console2.log("8 bands out", out8);
        console2.log("3 vs 1 bps worse", ((out1 - out3) * 10000) / out1);
        console2.log("8 vs 1 bps worse", ((out1 - out8) * 10000) / out1);

        assertLt(out3, out1, "splitting three ways costs the taker");
        assertLt(out8, out3, "splitting eight ways costs more");
    }

    /// What the taker pays in gas when a trade actually has to walk the bands.
    function test_walkingBandsCostsGasOnlyWhenTheyAreDoingWork() public {
        uint256 big = 200_000e18;
        (BandPool p1, WalkTok b1, WalkTok q1) = _build(1);
        _seedEvenly(p1, b1, 1);
        (, uint256 g1) = _trade(p1, q1, big);

        (BandPool p8, WalkTok b8, WalkTok q8) = _build(8);
        _seedEvenly(p8, b8, 8);
        (, uint256 g8) = _trade(p8, q8, big);

        console2.log("1 band, large trade ", g1);
        console2.log("8 bands, large trade", g8);
        console2.log("per band walked     ", (g8 - g1) / 7);
        assertGt(g8, g1, "a walk that does work in eight bands costs more than one");
    }
}
