// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {PoolBands} from "../../src/swap/PoolBands.sol";

contract BandsHarness is PoolBands {
    uint32 internal _limitBuy;
    uint32 internal _limitSell;

    function init(address creator_, uint64 maturity_, uint32[] calldata t, uint32[] calldata m) external {
        _initBands(creator_, maturity_, t, m);
    }

    function pokeShares(uint8 i, uint256 amount) external {
        _bands[i].shares = amount;
    }

    /// Stands in for `BandPool.syncLimit`: the stored limits are all a tolerance reads.
    function setLimits(uint32 buy, uint32 sell) external {
        _limitBuy = buy;
        _limitSell = sell;
    }

    function _storedLimits() internal view override returns (uint32, uint32) {
        return (_limitBuy, _limitSell);
    }
}

contract PoolBandsTest is Test {
    BandsHarness h;
    address creator = address(0xC0FFEE);
    address stranger = address(0xBAD);
    uint32 constant DENOM = 100000000;

    function setUp() public {
        h = new BandsHarness();
        // Seeded with a single band, the state a factory-created pool starts in.
        uint32[] memory seed = new uint32[](1);
        seed[0] = 20000000;
        h.init(creator, 600, seed, _mults(1));
        h.setLimits(10000000, 10000000); // 10%
    }

    /// Flat 1x multipliers of length n -- the premium is exercised in its own tests.
    function _mults(uint256 n) internal pure returns (uint32[] memory m) {
        m = new uint32[](n);
        for (uint256 i = 0; i < n; i++) m[i] = 100000000;
    }

    /// The factory's default ladder: 20 / 60 / 100% of the pair limit.
    function _tiers() internal pure returns (uint32[] memory t) {
        t = new uint32[](3);
        t[0] = 20000000;
        t[1] = 60000000;
        t[2] = 100000000;
    }

    function _one(uint32 frac) internal pure returns (uint32[] memory t) {
        t = new uint32[](1);
        t[0] = frac;
    }

    function test_creatorCanConfigureBands() public {
        vm.prank(creator);
        h.configureBands(_tiers(), _mults(3));
        assertEq(h.bandCount(), 3);
        (uint32 frac,,,, bool open) = h.bands(0);
        assertEq(frac, 20000000);
        assertTrue(open);
    }

    function test_strangerCannotConfigure() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(PoolBands.NotCreator.selector, stranger));
        h.configureBands(_tiers(), _mults(3));
    }

    function test_strangerCannotTouchAnyBandSetting() public {
        vm.startPrank(stranger);
        vm.expectRevert(abi.encodeWithSelector(PoolBands.NotCreator.selector, stranger));
        h.setBandOpen(0, false);
        vm.expectRevert(abi.encodeWithSelector(PoolBands.NotCreator.selector, stranger));
        h.setBandFeeMultiplier(0, 2 * DENOM);
        vm.expectRevert(abi.encodeWithSelector(PoolBands.NotCreator.selector, stranger));
        h.transferCreator(stranger);
        vm.stopPrank();
    }

    function test_spreadFracsMustAscend() public {
        uint32[] memory t = new uint32[](2);
        t[0] = 60000000;
        t[1] = 20000000;
        vm.prank(creator);
        vm.expectRevert(PoolBands.SpreadFracsNotAscending.selector);
        h.configureBands(t, _mults(t.length));
    }

    function test_equalSpreadFracsAreNotAscending() public {
        uint32[] memory t = new uint32[](2);
        t[0] = 20000000;
        t[1] = 20000000;
        vm.prank(creator);
        vm.expectRevert(PoolBands.SpreadFracsNotAscending.selector);
        h.configureBands(t, _mults(t.length));
    }

    function test_zeroSpreadFracIsRejected() public {
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(PoolBands.BadSpreadFrac.selector, uint32(0)));
        h.configureBands(_one(0), _mults(1));
    }

    /// Past the whole limit a band would quote beyond the rail.
    function test_spreadFracAboveTheWholeLimitIsRejected() public {
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(PoolBands.BadSpreadFrac.selector, DENOM + 1));
        h.configureBands(_one(DENOM + 1), _mults(1));
    }

    /// v1 rejected a tolerance AT DENOM (a 100% tolerance prices a sell at zero). A
    /// fraction of DENOM is the whole limit, which is exactly the widest legal band.
    function test_spreadFracOfTheWholeLimitIsAccepted() public {
        vm.prank(creator);
        h.configureBands(_one(DENOM), _mults(1));
        (uint32 buy, uint32 sell) = h.bandTolerances(0);
        assertEq(buy, 10000000, "the band quotes at the limit itself");
        assertEq(sell, 10000000);
    }

    function test_feeMultiplierBelowOneXIsRejected() public {
        uint32[] memory m = _mults(1);
        m[0] = DENOM - 1;
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(PoolBands.BadFeeMultiplier.selector, DENOM - 1));
        h.configureBands(_one(20000000), m);
    }

    function test_setFeeMultiplierBelowOneXIsRejected() public {
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(PoolBands.BadFeeMultiplier.selector, uint32(0)));
        h.setBandFeeMultiplier(0, 0);
    }

    function test_multiplierLengthMustMatch() public {
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(PoolBands.MultipliersLengthMismatch.selector, 3, 2));
        h.configureBands(_tiers(), _mults(2));
    }

    function test_tooManyBandsRejected() public {
        uint32[] memory t = new uint32[](uint256(h.MAX_BANDS()) + 1);
        for (uint256 i = 0; i < t.length; i++) {
            t[i] = uint32(1000000 * (i + 1));
        }
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(PoolBands.TooManyBands.selector, uint256(9)));
        h.configureBands(t, _mults(t.length));
    }

    function test_anEmptyLadderIsRejected() public {
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(PoolBands.TooManyBands.selector, uint256(0)));
        h.configureBands(new uint32[](0), new uint32[](0));
    }

    function test_closingABandStopsNewLiquidityButKeepsTheBand() public {
        vm.prank(creator);
        h.configureBands(_tiers(), _mults(3));
        vm.prank(creator);
        h.setBandOpen(1, false);
        (,,,, bool open) = h.bands(1);
        assertFalse(open);
        assertEq(h.bandCount(), 3);
    }

    function test_reconfigureCannotDropABandThatHoldsLiquidity() public {
        vm.prank(creator);
        h.configureBands(_tiers(), _mults(3));
        h.pokeShares(2, 1e18);
        uint32[] memory t = new uint32[](2);
        t[0] = 20000000;
        t[1] = 60000000;
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(PoolBands.BandHoldsLiquidity.selector, uint8(2)));
        h.configureBands(t, _mults(t.length));
    }

    /// A band holding liquidity may be REPRICED, only not dropped.
    function test_reconfigureMayRepriceABandThatHoldsLiquidity() public {
        vm.prank(creator);
        h.configureBands(_tiers(), _mults(3));
        h.pokeShares(0, 1e18);
        uint32[] memory t = _tiers();
        t[0] = 10000000;
        vm.prank(creator);
        h.configureBands(t, _mults(3));
        (uint32 frac, uint256 shares,,,) = h.bands(0);
        assertEq(frac, 10000000);
        assertEq(shares, 1e18, "its liquidity is untouched");
    }

    function test_transferCreatorHandsOverConfiguration() public {
        address next = address(0xB0B);
        vm.prank(creator);
        h.transferCreator(next);
        assertEq(h.creator(), next);

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(PoolBands.NotCreator.selector, creator));
        h.configureBands(_tiers(), _mults(3));

        vm.prank(next);
        h.configureBands(_tiers(), _mults(3));
        assertEq(h.bandCount(), 3);
    }

    function test_transferCreatorToZeroIsRejected() public {
        vm.prank(creator);
        vm.expectRevert(PoolBands.ZeroCreator.selector);
        h.transferCreator(address(0));
    }

    /// One write of the stored limits moves every band; nothing per band is rewritten.
    function test_tolerancesFollowAChangedLimit() public {
        vm.prank(creator);
        h.configureBands(_tiers(), _mults(3));
        (uint32 b0,) = h.bandTolerances(0);
        (uint32 b2,) = h.bandTolerances(2);
        assertEq(b0, 2000000, "20% of 10% is 2%");
        assertEq(b2, 10000000);

        h.setLimits(5000000, 1000000); // 5% buy, 1% sell
        (uint32 buy0, uint32 sell0) = h.bandTolerances(0);
        (uint32 buy1, uint32 sell1) = h.bandTolerances(1);
        assertEq(buy0, 1000000, "20% of 5%");
        assertEq(sell0, 200000, "20% of 1%, each side from its own limit");
        assertEq(buy1, 3000000);
        assertEq(sell1, 600000);
    }

    /// Rounded DOWN so a band always quotes inside the limit; a limit too small to
    /// express the fraction gives zero, which the swap treats as an idle band.
    function test_aToleranceThatRoundsToZeroIsIdle() public {
        h.setLimits(4, 5);
        (uint32 buy, uint32 sell) = h.bandTolerances(0);
        assertEq(buy, 0, "2e7 x 4 / 1e8 = 0.8, floored");
        assertEq(sell, 1, "2e7 x 5 / 1e8 = 1 exactly");
    }

    function test_anUnsyncedPoolQuotesNothing() public {
        h.setLimits(0, 0);
        (uint32 buy, uint32 sell) = h.bandTolerances(0);
        assertEq(buy + sell, 0, "a new pool's bands are idle until the limit is synced");
    }

    function testFuzz_toleranceNeverExceedsTheLimit(uint32 frac, uint32 limit) public {
        frac = uint32(bound(frac, 1, DENOM));
        h.setLimits(limit, limit);
        vm.prank(creator);
        h.configureBands(_one(frac), _mults(1));
        (uint32 buy,) = h.bandTolerances(0);
        assertLe(buy, limit);
        assertEq(buy, uint32((uint256(frac) * limit) / DENOM));
    }
}
