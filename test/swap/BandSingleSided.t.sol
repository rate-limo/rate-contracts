// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {BandPool} from "../../src/swap/BandPool.sol";
import {BandSwapRouter} from "../../src/swap/BandSwapRouter.sol";
import {BandPoolFactory} from "../../src/swap/BandPoolFactory.sol";
import {BandPositionManager} from "../../src/swap/BandPositionManager.sol";
import {PoolPositions} from "../../src/swap/PoolPositions.sol";
import {IBandPositionManager} from "../../src/swap/interfaces/IBandPositionManager.sol";

contract SSTok {
    string public symbol = "T";
    uint8 public constant decimals = 18;
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

contract SSBook {
    uint256 public price = 1e8;

    /// The listing price the pool anchors to until the TWAP can answer.

    function lmp() external view returns (uint256) { return price; }


    function twap(uint32) external view returns (uint256, uint32) {
        return (price, 300);
    }

    function convert(uint256 p, uint256 amount, bool isBid) external pure returns (uint256) {
        return isBid ? (amount * p) / 1e8 : (amount * 1e8) / p;
    }
}

contract SSEngine {

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

    /// Wide by default, so the deposit gate is out of the way unless a case sets it.
    uint32 public spread = 10000000; // 10% of DENOM
    function setSpread_(uint32 s) external { spread = s; }
    function getSpread(address, bool, bool) external view returns (uint32) { return spread; }
    /// No slippage policy: the pair limit is the market spread alone.
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

    function feeOf(address, address, address, bool) external pure returns (uint32) {
        return 100000;
    }
}

/**
 * `mintSingleSided` -- one token in, an ordinary two-sided position out.
 *
 * The point of these is the distinction the function's own docs insist on: it is
 * single-sided in what the depositor BRINGS, never in what the position HOLDS. A
 * band cannot hold a lopsided position, because one `shares` scalar over pooled
 * reserves is what makes a single fee accumulator describe every LP in it.
 *
 * v2: the conversion is a real swap through the ROUTER, which walks the ladder from
 * the tightest band -- it trades against band 0 whichever band the deposit is for (see
 * `test_theConversionWalksTheLadderNotTheTargetBand`). And one call is ONE token
 * holding every band it names.
 */
contract BandSingleSidedTest is Test {
    BandPoolFactory factory;
    BandPositionManager manager;
    BandPool pool;
    BandSwapRouter router;
    SSTok baseTok;
    SSTok quoteTok;
    SSBook book;
    SSEngine eng;

    address engine;
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address protocolCreator = address(0xC0FFEE);

    function setUp() public {
        baseTok = new SSTok();
        quoteTok = new SSTok();
        book = new SSBook();
        router = new BandSwapRouter();
        eng = new SSEngine();
        eng.setSwapRouter(address(router));
        engine = address(eng);

        manager = new BandPositionManager();
        manager.initialize("");
        factory = new BandPoolFactory();
        factory.initialize(engine, address(manager), address(new BandPool()), protocolCreator);
        eng.setPoolFactory(address(factory));
        manager.setPoolFactory(address(factory));

        vm.prank(engine);
        pool = BandPool(factory.createPool(address(baseTok), address(quoteTok), address(book), address(0)));
        // 0.10 / 0.30 / 0.50% under the stub's 10% limit, the ladder these were written against.
        uint32[] memory fracs = new uint32[](3);
        uint32[] memory mults = new uint32[](3);
        fracs[0] = 1000000;
        fracs[1] = 3000000;
        fracs[2] = 5000000;
        for (uint256 i = 0; i < 3; i++) {
            mults[i] = 100000000;
        }
        vm.prank(protocolCreator);
        pool.configureBands(fracs, mults);
        pool.syncLimit();
        vm.warp(1_000_000);
    }

    function _fund(address who, uint128 b, uint128 q) internal {
        baseTok.mint(who, b);
        quoteTok.mint(who, q);
        vm.startPrank(who);
        baseTok.approve(address(manager), type(uint256).max);
        quoteTok.approve(address(manager), type(uint256).max);
        vm.stopPrank();
    }

    function _bands(uint8 n) internal pure returns (uint8[] memory b) {
        b = new uint8[](n);
        for (uint8 i = 0; i < n; i++) {
            b[i] = i;
        }
    }

    function _one(uint256 v) internal pure returns (uint256[] memory r) {
        r = new uint256[](1);
        r[0] = v;
    }

    function _mins(uint256 n, uint128 v) internal pure returns (uint128[] memory r) {
        r = new uint128[](n);
        for (uint256 i = 0; i < n; i++) {
            r[i] = v;
        }
    }

    /// The ordinary two-sided mint, one band.
    function _add(address who, uint8 band, uint256 b, uint256 q) internal returns (uint256 id) {
        uint8[] memory bands = new uint8[](1);
        bands[0] = band;
        vm.prank(who);
        (id,) = manager.mint(
            IBandPositionManager.MintParams({
                pool: address(pool),
                bands: bands,
                baseAmounts: _one(b),
                quoteAmounts: _one(q),
                minShares: _mins(1, 0),
                recipient: who,
                deadline: block.timestamp
            })
        );
    }

    function _single(address who, uint8[] memory bands, uint256[] memory amounts, bool inputIsBase, uint128[] memory mins)
        internal
        returns (uint256 id, uint128[] memory got)
    {
        vm.prank(who);
        (id, got) = manager.mintSingleSided(address(pool), bands, amounts, inputIsBase, mins, who, block.timestamp);
    }

    function _singleOne(address who, uint8 band, uint256 amount, bool inputIsBase, uint128 min)
        internal
        returns (uint256 id, uint128 shares)
    {
        uint8[] memory bands = new uint8[](1);
        bands[0] = band;
        uint128[] memory got;
        (id, got) = _single(who, bands, _one(amount), inputIsBase, _mins(1, min));
        shares = got[0];
    }

    function _assertNothingStranded() internal view {
        assertEq(baseTok.balanceOf(address(manager)), 0, "no base left behind");
        assertEq(quoteTok.balanceOf(address(manager)), 0, "no quote left behind");
    }

    /// A band nobody has funded takes the one token as-is: the first deposit DEFINES
    /// the ratio, so there is nothing to convert into and no liquidity to convert from.
    function test_emptyBandTakesOneSidedWithoutConverting() public {
        _fund(alice, 1_000e18, 0);
        (, uint128 shares) = _singleOne(alice, 0, 1_000e18, true, 1);

        assertGt(shares, 0, "first deposit should mint");
        (uint256 rBase, uint256 rQuote) = pool.bandReserves(0);
        assertEq(rBase, 1_000e18, "all of it should be principal");
        assertEq(rQuote, 0, "nothing was converted");
        assertEq(baseTok.balanceOf(alice), 0, "no refund on the defining deposit");
        assertEq(eng.reports(), 0, "no swap was reported");
    }

    /// The case that used to be impossible: a band already holding both sides.
    ///
    /// Note what is NOT asserted. Band 0 is the tightest, so the conversion trades
    /// against it and takes quote OUT of its reserve on the way in -- `quoteReserve` ends
    /// LOWER than it started. What the depositor gets is shares against both reserves;
    /// what the band gets is a shifted ratio and a fee.
    function test_fundedBandConvertsHalfAndMints() public {
        _fund(alice, 1_000e18, 1_000e18);
        _add(alice, 0, 1_000e18, 1_000e18);

        (uint256 beforeBase, uint256 beforeQuote) = pool.bandReserves(0);

        _fund(bob, 100e18, 0);
        (uint256 tokenId, uint128 shares) = _singleOne(bob, 0, 100e18, true, 1);

        assertGt(shares, 0, "a base-only deposit must now mint shares");
        assertEq(manager.holderOf(tokenId), bob, "receipt goes to the depositor");
        assertEq(eng.reports(), 1, "the conversion was a real, reported trade");

        // Bob brought one token and deployed all but the rounding the band's ratio refuses.
        assertLt(baseTok.balanceOf(bob), 1e18, "principal deployed, the remainder refunded");

        (uint256 afterBase, uint256 afterQuote) = pool.bandReserves(0);
        assertGt(afterBase, beforeBase, "base side grew by the deposit");
        assertLt(afterQuote, beforeQuote, "quote side paid for the conversion");
        _assertNothingStranded();
    }

    /// The consequence worth stating out loud: the conversion trades against the tightest
    /// band, so that band's ratio moves toward the token the depositor brought. The pool
    /// fee is what compensates its LPs.
    function test_singleSidedShiftsTheBandsRatioForEveryoneInIt() public {
        _fund(alice, 1_000e18, 1_000e18);
        _add(alice, 0, 1_000e18, 1_000e18);

        (uint256 b0, uint256 q0) = pool.bandReserves(0);
        uint256 ratioBefore = (uint256(b0) * 1e18) / q0;

        _fund(bob, 200e18, 0);
        _singleOne(bob, 0, 200e18, true, 1);

        (uint256 b1, uint256 q1) = pool.bandReserves(0);
        uint256 ratioAfter = (uint256(b1) * 1e18) / q1;

        assertGt(ratioAfter, ratioBefore, "the band is more base-heavy than before");
    }

    /**
     * NEW in v2, and a correction to the manager's own comment: the router walks the
     * ladder tightest-first, so a single-sided deposit for band 2 converts against band 0
     * (the cheapest liquidity), not against band 2. Band 2 then takes the pair at its OWN
     * ratio, and whatever that ratio cannot use is refunded -- never stranded.
     */
    function test_theConversionWalksTheLadderNotTheTargetBand() public {
        _fund(alice, 2_000e18, 2_000e18);
        _add(alice, 0, 1_000e18, 1_000e18);
        _add(alice, 2, 1_000e18, 1_000e18);
        (uint256 b0, uint256 q0) = pool.bandReserves(0);
        (uint256 b2, uint256 q2) = pool.bandReserves(2);

        _fund(bob, 100e18, 0);
        (, uint128 shares) = _singleOne(bob, 2, 100e18, true, 1);
        assertGt(shares, 0);

        (uint256 b0After, uint256 q0After) = pool.bandReserves(0);
        (uint256 b2After, uint256 q2After) = pool.bandReserves(2);
        assertEq(b0After, b0 + 50e18, "band 0 took the converted half");
        assertLt(q0After, q0, "and paid the quote out");
        assertGt(b2After, b2, "band 2 received the deposit");
        assertGt(q2After, q2, "on both sides");
        _assertNothingStranded();
    }

    /// Passing zero on one side of the ordinary entry point still mints nothing --
    /// the reason this function exists rather than a flag on `mint`.
    /**
     * A plain one-sided add into a funded band is priced BY VALUE now, not
     * refused. See `_price` and BandOneSidedValue.t.sol for the fairness proof;
     * this only pins that the path mints and consumes the whole deposit.
     */
    function test_plainAddWithOneSideIsPricedByValue() public {
        _fund(alice, 1_000e18, 1_000e18);
        _add(alice, 0, 1_000e18, 1_000e18);

        _fund(bob, 100e18, 0);
        _add(bob, 0, 100e18, 0);
        assertEq(baseTok.balanceOf(bob), 0, "all of it became reserve");
        assertEq(eng.reports(), 0, "and no swap ran");
    }

    /// The guard that keeps a bad split loud. Ask for more shares than the converted
    /// half can buy and the whole deposit reverts rather than quietly under-minting.
    function test_minSharesRevertsRatherThanUnderMinting() public {
        _fund(alice, 1_000e18, 1_000e18);
        _add(alice, 0, 1_000e18, 1_000e18);

        _fund(bob, 100e18, 0);
        uint8[] memory bands = _bands(1);
        vm.prank(bob);
        vm.expectPartialRevert(IBandPositionManager.SharesBelowMinimum.selector);
        manager.mintSingleSided(address(pool), bands, _one(100e18), true, _mins(1, type(uint128).max), bob, block.timestamp);
        assertEq(baseTok.balanceOf(bob), 100e18, "a reverted deposit spends nothing");
    }

    /// Quote-only is the mirror image, and the direction flag must not be inverted.
    function test_quoteOnlyDepositAlsoWorks() public {
        _fund(alice, 1_000e18, 1_000e18);
        _add(alice, 0, 1_000e18, 1_000e18);

        _fund(bob, 0, 100e18);
        (, uint128 shares) = _singleOne(bob, 0, 100e18, false, 1);

        assertGt(shares, 0, "a quote-only deposit must mint too");
        _assertNothingStranded();
    }

    /// The batched form seeds every band it names, from one token, in ONE token.
    function test_singleSidedAcrossSeedsEveryBandItNamesInOneToken() public {
        _fund(alice, 1_000e18, 1_000e18);
        _add(alice, 0, 300e18, 300e18);
        _add(alice, 1, 300e18, 300e18);
        _add(alice, 2, 300e18, 300e18);

        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 50e18;
        amounts[1] = 30e18;
        amounts[2] = 20e18;

        _fund(bob, 0, 100e18);
        (uint256 id, uint128[] memory got) = _single(bob, _bands(3), amounts, false, _mins(3, 1));

        assertEq(manager.balanceOf(bob, id), 1, "one token for the whole ladder");
        IBandPositionManager.PositionView memory v = manager.positionOf(id);
        assertEq(v.bands.length, 3, "holding every band it named");
        for (uint256 i = 0; i < 3; i++) {
            assertGt(got[i], 0, "every band must mint");
            assertEq(v.bands[i].shares, got[i]);
        }
        // The tighter band got more input, so it must hold more shares.
        assertGt(got[0], got[2], "the split must follow the amounts");
        _assertNothingStranded();
    }

    /// One signature, and the wallet is debited at most the sum of the slices.
    function test_singleSidedAcrossPullsAtMostTheSum() public {
        _fund(alice, 1_000e18, 1_000e18);
        _add(alice, 0, 500e18, 500e18);
        _add(alice, 1, 500e18, 500e18);

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 60e18;
        amounts[1] = 40e18;

        _fund(bob, 0, 250e18);
        _single(bob, _bands(2), amounts, false, _mins(2, 1));

        // Not an equality: the conversion lands near the band's ratio rather than on it,
        // and the manager refunds what the minted shares did not buy.
        uint256 spent = 250e18 - quoteTok.balanceOf(bob);
        assertLe(spent, 100e18, "never more than the named slices leaves the wallet");
        assertGt(spent, 99e18, "and substantially all of it is deployed");
        _assertNothingStranded();
    }

    /// `minShares` survives batching: one band short reverts the whole call, so a
    /// sandwiched conversion cannot hide behind a healthy total.
    function test_singleSidedAcrossRevertsWhenOneBandUnderMints() public {
        _fund(alice, 1_000e18, 1_000e18);
        _add(alice, 0, 500e18, 500e18);
        _add(alice, 1, 500e18, 500e18);

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 50e18;
        amounts[1] = 50e18;
        uint128[] memory mins = _mins(2, 1);
        mins[1] = type(uint128).max;

        _fund(bob, 0, 100e18);
        vm.prank(bob);
        vm.expectPartialRevert(IBandPositionManager.SharesBelowMinimum.selector);
        manager.mintSingleSided(address(pool), _bands(2), amounts, false, mins, bob, block.timestamp);

        assertEq(quoteTok.balanceOf(bob), 100e18, "a reverted batch spends nothing");
    }

    /// Arrays that do not line up are refused before any money moves.
    function test_singleSidedAcrossRefusesMismatchedArrays() public {
        _fund(bob, 0, 100e18);
        vm.startPrank(bob);
        vm.expectRevert(IBandPositionManager.LengthMismatch.selector);
        manager.mintSingleSided(address(pool), _bands(2), _one(1e18), false, _mins(2, 0), bob, block.timestamp);
        vm.expectRevert(IBandPositionManager.LengthMismatch.selector);
        manager.mintSingleSided(address(pool), _bands(1), _one(1e18), false, _mins(2, 0), bob, block.timestamp);
        vm.expectRevert(IBandPositionManager.LengthMismatch.selector);
        manager.mintSingleSided(address(pool), new uint8[](0), new uint256[](0), false, _mins(0, 0), bob, block.timestamp);
        vm.stopPrank();
    }

    function test_singleSidedBandsMustAscend() public {
        _fund(bob, 100e18, 0);
        uint8[] memory bands = new uint8[](2);
        bands[0] = 1;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 1e18;
        amounts[1] = 1e18;
        vm.prank(bob);
        vm.expectRevert(IBandPositionManager.BandsNotAscending.selector);
        manager.mintSingleSided(address(pool), bands, amounts, true, _mins(2, 0), bob, block.timestamp);
    }

    /// Base-only batches too -- the direction flag must not be inverted here either.
    function test_singleSidedAcrossWorksFromTheBaseSide() public {
        _fund(alice, 1_000e18, 1_000e18);
        _add(alice, 0, 500e18, 500e18);
        _add(alice, 1, 500e18, 500e18);

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 50e18;
        amounts[1] = 50e18;

        _fund(bob, 100e18, 0);
        (, uint128[] memory got) = _single(bob, _bands(2), amounts, true, _mins(2, 1));

        assertGt(got[0], 0, "base-side batch must mint");
        assertGt(got[1], 0, "base-side batch must mint");
        // All but the conversion remainder is deployed, and the remainder is refunded to
        // the depositor, never left on the manager.
        assertLt(baseTok.balanceOf(bob), 1e18, "all but the conversion remainder is deployed");
        _assertNothingStranded();
    }

    /**
     * THE FLOOR THE FRONTEND SENDS, against the contract.
     *
     * `minShares` is the only guard on the conversion, so the app has to send a real
     * one. It does NOT compute it: two closed forms over the band's reserves were
     * written and both were wrong, the second by 217x against a lopsided band,
     * because the pool mints `min(byBase, byQuote)` and either leg can bind. It PROBES
     * instead -- a static call that returns what the deposit would actually mint -- and
     * sends that less a tolerance.
     *
     * `vm.snapshotState` is that probe here: run the real deposit, read the shares,
     * roll back, then send for real with the floor derived from it.
     */
    function _probeShares(uint256 amountIn, bool inputIsBase, uint8 band) internal returns (uint128) {
        uint256 snap = vm.snapshotState();
        uint8[] memory bands = new uint8[](1);
        bands[0] = band;
        (, uint128[] memory got) = _single(bob, bands, _one(amountIn), inputIsBase, _mins(1, 0));
        vm.revertToState(snap);
        return got[0];
    }

    function _seedBalancedBandAndFundBob() internal {
        _fund(alice, 1_000e18, 1_000e18);
        _add(alice, 0, 1_000e18, 1_000e18);
        _fund(bob, 0, 200e18);
    }

    /// The probe's number, less 0.5%, is accepted -- the deposit lands.
    function test_probedFloorLessToleranceIsAccepted() public {
        _seedBalancedBandAndFundBob();
        uint128 probed = _probeShares(200e18, false, 0);
        assertGt(probed, 0, "the probe must report a real number");

        uint128 floor = (probed * 9950) / 10000; // DEPOSIT_SLIPPAGE_BPS = 50
        (, uint128 got) = _singleOne(bob, 0, 200e18, false, floor);
        assertGe(got, floor, "the floor must not trip on an unchanged state");
    }

    /// A floor ABOVE what the state can mint reverts -- the guard is real, not decorative.
    function test_floorAboveTheProbeReverts() public {
        _seedBalancedBandAndFundBob();
        uint128 probed = _probeShares(200e18, false, 0);

        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(IBandPositionManager.SharesBelowMinimum.selector, uint8(0), probed, probed + 1)
        );
        manager.mintSingleSided(address(pool), _bands(1), _one(200e18), false, _mins(1, probed + 1), bob, block.timestamp);
        assertEq(quoteTok.balanceOf(bob), 200e18, "a reverted deposit spends nothing");
    }

    /**
     * THE CASE THE FORMULAS GOT WRONG: a band whose reserve ratio is nowhere near
     * the price the conversion executes at, so the BASE leg binds and the input
     * leg's arithmetic is meaningless. Measured on Arc as `TooFewShares(4.898e17,
     * 1.065e20)`. The probe has no opinion about which leg binds, so it is right here
     * too.
     */
    function test_probeIsCorrectForALopsidedBandWhereTheBaseLegBinds() public {
        // 1000 base against 4 quote -- the shape a freshly seeded band actually has.
        _fund(alice, 1_000e18, 4e18);
        _add(alice, 0, 1_000e18, 4e18);
        _fund(bob, 0, 1e18);

        uint128 probed = _probeShares(1e18, false, 0);
        assertGt(probed, 0, "even a lopsided band mints something");

        uint128 floor = (probed * 9950) / 10000;
        (, uint128 got) = _singleOne(bob, 0, 1e18, false, floor);
        assertGe(got, floor, "the probed floor holds on a lopsided band too");
    }

    /**
     * The ladder holds shares but NO BASE, so there is nothing to convert into.
     *
     * `_fillBand` returns nothing for a band whose payout reserve is empty, so the
     * walk fills zero and `BandPool.swap` refuses with `NoLiquidity()`. The whole
     * deposit reverts -- it is not silently added as one-sided.
     */
    function test_quoteOnlyRevertsWhenTheLadderHasNoBaseToSell() public {
        // A two-sided seed, then a sell that empties the base side of every band.
        _fund(alice, 1_000e18, 1_000e18);
        _add(alice, 0, 1_000e18, 1_000e18);
        (uint256 rBase,) = pool.bandReserves(0);
        assertGt(rBase, 0, "the seed put base in");

        // A BUY takes base OUT of the band; a sell would put more in.
        _fund(bob, 0, 10_000e18);
        vm.startPrank(bob);
        quoteTok.approve(address(router), type(uint256).max);
        router.swap(address(pool), 5_000e18, true, bob, 0);
        vm.stopPrank();
        (uint256 emptied,) = pool.bandReserves(0);
        assertEq(emptied, 0, "the band has no base left to sell");

        _fund(bob, 0, 100e18);
        vm.prank(bob);
        vm.expectRevert(BandPool.NoLiquidity.selector);
        manager.mintSingleSided(address(pool), _bands(1), _one(100e18), false, _mins(1, 0), bob, block.timestamp);
    }

    /**
     * Not enough base for the WHOLE half, but some. This is the interesting case:
     * the swap fills partially, so nothing reverts, and the question is where the
     * unspent quote ends up.
     */
    function test_quoteOnlyWithTooLittleBaseFillsPartiallyAndStrandsNothing() public {
        _fund(alice, 1e18, 1_000e18);
        _add(alice, 0, 1e18, 1e18);

        uint256 before = quoteTok.balanceOf(bob);
        _fund(bob, 0, 100e18);
        (, uint128 shares) = _singleOne(bob, 0, 100e18, false, 1);

        assertGt(shares, 0, "a partial conversion still mints");
        _assertNothingStranded();
        // Whatever the band could not take comes back, so the wallet is only down
        // what actually became liquidity.
        assertGt(quoteTok.balanceOf(bob), before, "the unusable part was returned");
    }

    /**
     * A quote-only deposit into an EMPTY band used to revert, and now opens it.
     *
     * There is nothing to convert against in an empty band -- `_singleSidedAmounts`
     * sets `half = 0` and skips the swap -- so this arrives at `_price` as a pure
     * one-sided deposit and is priced on the side that was actually brought. Both
     * deposit modes therefore agree here: an empty band takes whichever token shows up.
     */
    function test_quoteOnlyOpensAnEmptyBandWithoutConverting() public {
        _fund(bob, 0, 100e18);
        vm.prank(bob);
        (, uint128[] memory got) = manager.mintSingleSided(
            address(pool), _bands(1), _one(100e18), false, _mins(1, 0), bob, block.timestamp
        );
        assertEq(got[0], 100e18, "priced on the quote it brought");
        (uint256 rb, uint256 rq) = pool.bandReserves(0);
        assertEq(rb, 0, "no base was invented");
        assertEq(rq, 100e18, "all of it is principal");
        assertEq(eng.reports(), 0, "and no swap ran");
    }
}
