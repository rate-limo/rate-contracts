// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {BandPool} from "../../src/swap/BandPool.sol";
import {BandSwapRouter} from "../../src/swap/BandSwapRouter.sol";
import {BandPoolFactory} from "../../src/swap/BandPoolFactory.sol";
import {BandPositionManager} from "../../src/swap/BandPositionManager.sol";
import {PoolBands} from "../../src/swap/PoolBands.sol";
import {IBandPool} from "../../src/swap/interfaces/IBandPool.sol";
import {IBandPositionManager} from "../../src/swap/interfaces/IBandPositionManager.sol";
import {WalkTok, PricedBook} from "./GasBandCount.t.sol";

/// Lets a test dial the engine's per-taker rate, which is half of the capped product.
contract DialEngine {

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
    uint32 public rate = 100000; // 0.10%
    function setRate(uint32 r) external { rate = r; }
    function feeOf(address, address, address, bool) external view returns (uint32) { return rate; }
}

/**
 * The per-band fee premium, and the ceiling on it.
 *
 * A band re-anchors to a moving TWAP, so a wide band never comes into range the way a
 * v3 position does -- it fills only when a single trade exhausts every tighter band.
 * At a flat rate it therefore earns a fraction of what the tight band earns per unit
 * of capital, and rational LPs withdraw, draining exactly the depth large trades need.
 * The premium is what makes that capital rational to provide.
 *
 * The cap exists because the charged rate is a product of two numbers this contract
 * does not own: the engine's per-taker fee and the creator's multiplier. Neither
 * bounds the other.
 *
 * The engine's limit is 0.5% here, so the factory's default fractions (20 / 60 / 100%)
 * are the 0.10 / 0.30 / 0.50% ladder these numbers were derived on.
 */
contract BandFeePremiumTest is Test {
    BandPoolFactory factory;
    BandPositionManager manager;
    BandPool pool;
    BandSwapRouter router;
    WalkTok baseTok;
    WalkTok quoteTok;
    DialEngine eng;

    address creator = address(0xC0FFEE);
    address lp = address(0xA11CE);
    address taker = address(0xABCD);

    uint32 constant LIMIT = 500000; // 0.5%

    function setUp() public {
        router = new BandSwapRouter();
        baseTok = new WalkTok();
        quoteTok = new WalkTok();
        eng = new DialEngine();
        eng.setSwapRouter(address(router));
        eng.setSpread_(LIMIT);
        manager = new BandPositionManager();
        manager.initialize("");
        factory = new BandPoolFactory();
        factory.initialize(address(eng), address(manager), address(new BandPool()), creator);
        manager.setPoolFactory(address(factory));
        eng.setPoolFactory(address(factory));
        address book = address(new PricedBook());
        vm.prank(address(eng));
        pool = BandPool(factory.createPool(address(baseTok), address(quoteTok), book, address(0)));
        pool.syncLimit();
        vm.warp(1_000_000);
    }

    function _seed(uint8 band, uint256 amt) internal returns (uint256 id) {
        baseTok.mint(lp, amt);
        uint8[] memory bands = new uint8[](1);
        uint256[] memory baseAmts = new uint256[](1);
        bands[0] = band;
        baseAmts[0] = amt;
        vm.startPrank(lp);
        baseTok.approve(address(manager), type(uint256).max);
        (id,) = manager.mint(
            IBandPositionManager.MintParams({
                pool: address(pool),
                bands: bands,
                baseAmounts: baseAmts,
                quoteAmounts: new uint256[](1),
                minShares: new uint128[](1),
                recipient: lp,
                deadline: block.timestamp
            })
        );
        vm.stopPrank();
    }

    function _buy(uint256 quoteIn) internal {
        quoteTok.mint(taker, quoteIn);
        vm.startPrank(taker);
        quoteTok.approve(address(pool), type(uint256).max);
        quoteTok.approve(address(router), type(uint256).max);
        router.swap(address(pool), quoteIn, true, taker, 0);
        vm.stopPrank();
    }

    /// Everything accrued, vested or not -- v1's `rawOwed`.
    function _accrued(BandPool p, uint256 id) internal view returns (uint256 ab, uint256 aq) {
        (IBandPool.BandView[] memory all, uint256 ob, uint256 oq) = p.positionView(id);
        ab = ob;
        aq = oq;
        for (uint256 i = 0; i < all.length; i++) {
            ab += all[i].pendingBase;
            aq += all[i].pendingQuote;
        }
    }

    function test_theFactorySeedsThePremiumSoANewPoolIsNotFlat() public view {
        assertEq(pool.bandFeeMultiplier(0), 100000000, "1x");
        assertEq(pool.bandFeeMultiplier(1), 200000000, "2x");
        assertEq(pool.bandFeeMultiplier(2), 300000000, "3x");
    }

    /**
     * The gap this exists to close. Equal capital in band 0 and band 2, one trade big
     * enough to reach both: without the premium band 2's return on capital is a small
     * fraction of band 0's.
     */
    function test_thePremiumNarrowsTheReturnGapBetweenTightAndWide() public {
        uint256 tight = _seed(0, 10e18);
        uint256 far = _seed(2, 10e18);
        _buy(60e18); // exhausts band 0 (and band 1, which is empty), reaches band 2

        (uint256 tightFee,) = _accrued(pool, tight);
        (uint256 farFee,) = _accrued(pool, far);
        assertGt(tightFee, 0);
        assertGt(farFee, 0, "band 2 was reached");

        // Both hold 10e18, so the fee ratio IS the return-on-capital ratio. Band 0
        // still earns more -- it filled far more volume -- but 3x closes most of it.
        assertLt(tightFee, farFee * 4, "the premium keeps band 2 within reach of band 0");
    }

    /**
     * Same trade, same depth, only the multiplier differs -- so two fresh pools rather
     * than two deposits into one. A second base-only deposit into a band that has
     * already traded correctly mints ZERO shares under the lesser-ratio rule, which is
     * how the first version of this test managed to assert nothing.
     */
    function test_aHigherMultiplierEarnsProportionallyMore() public {
        (BandPool flatPool, uint256 flatId) = _freshPool(100000000); // 1x
        (BandPool dearPool, uint256 dearId) = _freshPool(300000000); // 3x

        // Two pools on one pair, which a real factory never has: the engine's registry
        // (the router checks every pool against it) is pointed at each in turn.
        eng.setPoolFactory(address(0));
        eng.listPool(address(flatPool));
        _buyIn(flatPool, 5e18);
        eng.listPool(address(dearPool));
        _buyIn(dearPool, 5e18);

        (uint256 flatFee,) = _accrued(flatPool, flatId);
        (uint256 dearFee,) = _accrued(dearPool, dearId);
        assertGt(flatFee, 0);
        assertApproxEqRel(dearFee, flatFee * 3, 1e12, "3x the multiplier, 3x the fee");
    }

    /// A standalone pool whose band 0 carries `multiplier`, seeded with 10e18 base.
    /// This test is its position manager, so it deposits into the pool directly.
    function _freshPool(uint32 multiplier) internal returns (BandPool p, uint256 id) {
        p = new BandPool();
        uint32[] memory t = new uint32[](1);
        t[0] = 20000000; // 0.10% of price, as 20% of the 0.5% limit
        uint32[] memory m = new uint32[](1);
        m[0] = multiplier;
        p.initialize(BandPool.InitParams({
            id: 1, base: address(baseTok), quote: address(quoteTok),
            orderbook: address(new PricedBook()), engine: address(eng),
            positionManager: address(this), creator: creator, maturity: 600,
            spreadFracs: t, feeMultipliers: m
        }));
        p.syncLimit();
        baseTok.mint(address(this), 10e18);
        baseTok.approve(address(p), type(uint256).max);
        uint8[] memory b = new uint8[](1);
        uint256[] memory ba = new uint256[](1);
        ba[0] = 10e18;
        id = 1;
        p.increase(id, b, ba, new uint256[](1));
    }

    function _buyIn(BandPool p, uint256 quoteIn) internal {
        quoteTok.mint(taker, quoteIn);
        vm.startPrank(taker);
        quoteTok.approve(address(p), type(uint256).max);
        quoteTok.approve(address(router), type(uint256).max);
        router.swap(address(p), quoteIn, true, taker, 0);
        vm.stopPrank();
    }

    // ---- the cap ------------------------------------------------------------

    function test_theRateIsCappedAtThreePercent() public view {
        // 1.00% engine rate at 3x is exactly 3%; the cap holds anything past it there.
        assertEq(pool.effectiveFeeRate(2, 1000000), 3000000, "1.00% engine rate x3 = 3.00%, exactly the cap");
        assertEq(pool.effectiveFeeRate(2, 2000000), 3000000, "2.00% x3 would be 6%; capped at 3%");
        // Below the ceiling it is simply the product.
        assertEq(pool.effectiveFeeRate(2, 100000), 300000, "0.10% x 3 = 0.30%");
        assertEq(pool.effectiveFeeRate(0, 100000), 100000, "1x is unchanged");
    }

    /// The cap has to bind on the real swap path, not just in the view.
    function test_theCapBindsOnAnActualSwap() public {
        eng.setRate(2000000); // 2.00% engine fee; band 2 is 3x, so 6% uncapped
        uint256 far = _seed(2, 100e18);
        _buy(100e18);

        (uint256 farFee,) = _accrued(pool, far);
        // 100 quote at band 2's bound (2.010) buys grossOut base; the LP takes half of
        // the capped 3% of that, not half of 6%.
        uint256 grossOut = (uint256(100e18) * 1e8) / 201000000;
        uint256 expected = ((grossOut * 3000000) / 100000000) / 2;
        assertApproxEqRel(farFee, expected, 1e15, "3% of the output, halved with the protocol");
    }

    function test_aMultiplierBelowOneIsRefused() public {
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(PoolBands.BadFeeMultiplier.selector, 99999999));
        pool.setBandFeeMultiplier(0, 99999999);
    }

    function test_onlyTheCreatorCanReprice() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(abi.encodeWithSelector(PoolBands.NotCreator.selector, address(0xBAD)));
        pool.setBandFeeMultiplier(0, 200000000);
    }

    /**
     * Repricing must work while the band holds liquidity. configureBands refuses to
     * drop a funded band, correctly; a creator whose wide band is bleeding capital
     * needs to raise its premium precisely when it is full.
     */
    function test_aFundedBandCanStillBeRepriced() public {
        _seed(2, 10e18);
        vm.prank(creator);
        pool.setBandFeeMultiplier(2, 600000000);
        assertEq(pool.bandFeeMultiplier(2), 600000000);
    }
}
