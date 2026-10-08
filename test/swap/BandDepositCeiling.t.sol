// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {BandPool} from "../../src/swap/BandPool.sol";
import {BandSwapRouter} from "../../src/swap/BandSwapRouter.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

contract BigTok {
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

contract FlatBook {
    /// The listing price the pool anchors to until the TWAP can answer.
    function lmp() external pure returns (uint256) { return 1e8; }

    function twap(uint32) external pure returns (uint256, uint32) { return (1e8, 300); }
    function convert(uint256, uint256 amount, bool) external pure returns (uint256) { return amount; }
}

contract NoFeeEngine {

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
    /// No slippage policy: the limit is the market spread alone.
    address public incentive;
    address public feeTo = address(0xFEE);
    uint32 public poolFeeShare = 50000000;
    function feeOf(address, address, address, bool) external pure returns (uint32) { return 100000; }
}

/**
 * The deposit ceiling.
 *
 * v1 widened every position and band amount to uint256 so a busy band could not hit
 * a uint128 wall. v2 narrows ONE thing back on purpose: a position's shares in a band
 * are uint128, packed with its clock into one storage slot. Band totals -- shares and
 * both reserves -- stay uint256, because those are what ACCUMULATE across every
 * deposit and every swap.
 *
 * So the properties are now: a single position above uint128 is refused LOUDLY (a
 * SafeCast revert, never a truncation), and a band whose reserves pass 2^128 through
 * many positions still deposits, swaps and pays out every unit. The cast that would
 * truncate is the failure these exist to catch; SafeCast is what rules it out by
 * compiler rather than by argument.
 */
contract BandDepositCeilingTest is Test {
    BandPool pool;
    BandSwapRouter router;
    BigTok baseTok;
    BigTok quoteTok;
    address pm = address(0xBEEF);
    address creator = address(0xC0FFEE);
    uint256 internal _nextId = 1;

    uint256 constant MAX = type(uint128).max;

    function setUp() public {
        router = new BandSwapRouter();
        baseTok = new BigTok();
        quoteTok = new BigTok();
        pool = new BandPool();
        NoFeeEngine e = new NoFeeEngine();
        e.setSwapRouter(address(router));
        uint32[] memory t = new uint32[](1);
        uint32[] memory fm = new uint32[](1);
        for (uint256 _f = 0; _f < 1; _f++) fm[_f] = 100000000; // 1x, unless a test says otherwise
        t[0] = 1000000; // 1% of the 10% limit: 0.1%
        pool.initialize(BandPool.InitParams({
            id: 1, base: address(baseTok), quote: address(quoteTok),
            orderbook: address(new FlatBook()), engine: address(e),
            positionManager: pm, creator: creator, maturity: 600, spreadFracs: t,
            feeMultipliers: fm
        }));
        pool.syncLimit();
        e.listPool(address(pool));
        vm.warp(1_000_000);
        vm.startPrank(pm);
        baseTok.approve(address(pool), type(uint256).max);
        quoteTok.approve(address(pool), type(uint256).max);
        vm.stopPrank();
    }

    function _add(uint256 id, uint256 baseAmt, uint256 quoteAmt) internal returns (uint256 shares) {
        baseTok.mint(pm, baseAmt);
        quoteTok.mint(pm, quoteAmt);
        uint8[] memory b = new uint8[](1);
        uint256[] memory ba = new uint256[](1);
        uint256[] memory qa = new uint256[](1);
        ba[0] = baseAmt;
        qa[0] = quoteAmt;
        vm.prank(pm);
        (uint128[] memory minted,,) = pool.increase(id, b, ba, qa);
        shares = minted[0];
    }

    function _new(uint256 baseAmt, uint256 quoteAmt) internal returns (uint256 id, uint256 shares) {
        id = _nextId++;
        shares = _add(id, baseAmt, quoteAmt);
    }

    /// A band past 2^128 on both sides, built from `n` maximal positions.
    function _astronomical(uint256 n) internal {
        for (uint256 i = 0; i < n; i++) _new(MAX, MAX);
    }

    /// The largest single position is accepted whole.
    function test_aMaximalPositionIsAcceptedWhole() public {
        (, uint256 shares) = _new(MAX, MAX);
        assertEq(shares, MAX, "the first deposit prices one share per base unit");
        (uint256 rBase, uint256 rQuote) = pool.bandReserves(0);
        assertEq(rBase, MAX);
        assertEq(rQuote, MAX);
    }

    /// One unit more is refused with the cast named, not truncated to a small share count.
    function test_aPositionAboveUint128IsRefusedNotTruncated() public {
        uint256 over = MAX + 1e30;
        baseTok.mint(pm, over);
        quoteTok.mint(pm, over);
        uint8[] memory b = new uint8[](1);
        uint256[] memory ba = new uint256[](1);
        uint256[] memory qa = new uint256[](1);
        ba[0] = over;
        qa[0] = over;
        vm.prank(pm);
        vm.expectRevert(abi.encodeWithSelector(SafeCast.SafeCastOverflowedUintDowncast.selector, uint8(128), over));
        pool.increase(1, b, ba, qa);
    }

    /// Band totals are uint256: several positions carry the reserves past 2^128.
    function test_bandReservesAccumulatePastUint128() public {
        _astronomical(3);
        (uint256 rBase, uint256 rQuote) = pool.bandReserves(0);
        assertEq(rBase, MAX * 3, "the reserve holds the full amount, not a truncation of it");
        assertEq(rQuote, MAX * 3);
        (, uint256 shares,,,) = pool.bands(0);
        assertEq(shares, MAX * 3);
    }

    /**
     * The failure a cast would have produced: a reserve that WRAPPED rather than
     * reverted. Withdrawing every position from an astronomical band returns every unit.
     */
    function test_anEnormousReserveIsNotSilentlyTruncatedOnTheWayOut() public {
        _astronomical(3);
        vm.warp(block.timestamp + 601);
        uint256 baseOut;
        uint256 quoteOut;
        for (uint256 id = 1; id <= 3; id++) {
            vm.prank(pm);
            (uint256 b, uint256 q) = pool.decrease(id, 10_000, pm);
            baseOut += b;
            quoteOut += q;
        }
        assertEq(baseOut, MAX * 3, "every unit came back");
        assertEq(quoteOut, MAX * 3);
        (uint256 rBase, uint256 rQuote) = pool.bandReserves(0);
        assertEq(rBase + rQuote, 0);
    }

    /// The share arithmetic is mulDiv, so a proportional split survives at full width.
    function test_twoHugeDepositsStillSplitProportionally() public {
        _astronomical(2);
        (, uint256 first) = _new(MAX, MAX);
        (, uint256 second) = _new(MAX / 2, MAX / 2);
        assertApproxEqRel(second, first / 2, 1e12, "half the deposit, half the shares");
    }

    /**
     * The plain `amount * shares / reserve` form overflows here long before the
     * quotient is unrepresentable: uint128.max times a band of 2 x uint128.max shares
     * is ~2.3e77, past uint256. mulDiv carries 512 bits.
     */
    function test_aMaximalDepositIntoAnAstronomicalBandDoesNotOverflow() public {
        _astronomical(2);
        (, uint256 shares) = _new(MAX, MAX);
        assertEq(shares, MAX, "the product would have overflowed without mulDiv");
    }

    /// A swap against reserves that large must not wrap either.
    function test_aSwapAgainstAnAstronomicalBandSettlesWithoutWrapping() public {
        _astronomical(2);
        uint256 huge = MAX * 2;
        address taker = address(0xABCD);
        quoteTok.mint(taker, 1_000e18);
        vm.startPrank(taker);
        quoteTok.approve(address(pool), type(uint256).max);
        quoteTok.approve(address(router), type(uint256).max);
        router.swap(address(pool), 1_000e18, true, taker, 0);
        vm.stopPrank();
        (uint256 rBase, uint256 rQuote) = pool.bandReserves(0);
        assertLt(rBase, huge, "base went out");
        assertGt(rBase, huge - 1_001e18, "and only about what was traded");
        assertEq(rQuote, huge + 1_000e18, "the quote came in on top");
    }
}
