// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {BandPool} from "../../src/swap/BandPool.sol";
import {BandPoolFactory} from "../../src/swap/BandPoolFactory.sol";
import {PoolBands} from "../../src/swap/PoolBands.sol";

contract FTok {
    function decimals() external pure returns (uint8) { return 18; }
}

/// The pool reads `lmp()` at creation to capture the listing price, so the orderbook
/// has to be a contract now rather than a bare address.
contract FBook {
    function lmp() external pure returns (uint256) { return 2e8; }
    function twap(uint32) external pure returns (uint256, uint32) { return (2e8, 300); }
    /// `BandPool.initialize` recovers the venue's decimal conversion from this, so the
    /// double has to answer it. Equal decimals, which is the `decDiff == 1` branch of
    /// `Orderbook.convert`.
    function convert(uint256 price, uint256 amount, bool isBid) external pure returns (uint256) {
        return isBid ? (amount * price) / 1e8 : (amount * 1e8) / price;
    }
}

/// The pool reads its limit from the engine: the market spread, capped by the engine's
/// slippage policy when there is one. No policy here.
contract FEngine {
    uint32 public spread = 10000000; // 10% of DENOM
    address public incentive;

    function setSpread_(uint32 s) external { spread = s; }
    function getSpread(address, bool, bool) external view returns (uint32) { return spread; }
}

contract BandPoolFactoryTest is Test {
    BandPoolFactory factory;
    FEngine eng;
    address engine;
    address positionManager = address(0xBEEF);
    address orderbook;
    address impl;
    address admin = address(this);
    address protocolCreator = address(0xC0FFEE);
    address pairCreator = address(0xA11CE);
    address baseTok;
    address quoteTok;

    function setUp() public {
        baseTok = address(new FTok());
        quoteTok = address(new FTok());
        orderbook = address(new FBook());
        eng = new FEngine();
        engine = address(eng);
        impl = address(new BandPool());
        factory = new BandPoolFactory();
        factory.initialize(engine, positionManager, impl, protocolCreator);
    }

    function _create() internal returns (BandPool pool) {
        vm.prank(engine);
        pool = BandPool(factory.createPool(baseTok, quoteTok, orderbook, address(0)));
    }

    /// The ladder is born configured, as FRACTIONS of the pair's limit: 20 / 60 / 100%,
    /// the ratios v1's absolute 0.10 / 0.30 / 0.50% ladder had to each other.
    function test_aNewPoolIsBornWithTheDefaultLadder() public {
        BandPool pool = _create();
        assertEq(pool.bandCount(), 3, "seeded with the default fractions");
        (uint32 f0,,,, bool open0) = pool.bands(0);
        (uint32 f1,,,,) = pool.bands(1);
        (uint32 f2,,,,) = pool.bands(2);
        assertTrue(open0, "and open");
        assertEq(f0, 20000000); // 20% of the limit
        assertEq(f1, 60000000);
        assertEq(f2, 100000000); // the whole limit, never past it
        assertEq(pool.bandFeeMultiplier(0), 100000000);
        assertEq(pool.bandFeeMultiplier(2), 300000000);
    }

    /**
     * A new pool's limits are ZERO, so every band is idle until the limit is synced. The
     * real engine syncs in the same `addPair` transaction (pinned in v2/Spread.t.sol);
     * through the factory alone it is the permissionless `syncLimit` that does it.
     */
    function test_aNewPoolIsIdleUntilItsLimitIsSynced() public {
        BandPool pool = _create();
        assertEq(pool.pairLimit(true), 0);
        assertEq(pool.pairLimit(false), 0);
        (uint32 tb, uint32 ts) = pool.bandTolerances(0);
        assertEq(tb, 0, "idle");
        assertEq(ts, 0, "idle");
        assertEq(pool.liveLimit(true), 10000000, "the engine already states a limit");

        vm.prank(address(0xBAD)); // anyone may sync: it only copies the canonical value
        factory.syncLimit(baseTok, quoteTok);
        assertEq(pool.pairLimit(true), 10000000);
        assertEq(pool.pairLimit(false), 10000000);
        (tb, ts) = pool.bandTolerances(0);
        assertEq(tb, 2000000, "20% of a 10% limit is 2%");
        assertEq(ts, 2000000);
    }

    function test_syncingAPairWithNoPoolIsANoOp() public {
        factory.syncLimit(baseTok, address(0x1234));
    }

    function test_theCloneNamesItsCreatorAndMaturity() public {
        BandPool pool = _create();
        assertEq(pool.creator(), protocolCreator, "zero creator falls back to the default");
        assertEq(pool.maturity(), 600, "ten minutes to full vest");
        assertEq(pool.positionManager(), positionManager);
        assertEq(pool.engine(), engine);
        assertEq(pool.seedPrice(), 2e8, "the listing price, captured at creation");
    }

    /// The engine passes the pair's lister, so a pool can be born with its real creator.
    function test_aNamedCreatorIsTheCreator() public {
        vm.prank(engine);
        BandPool pool = BandPool(factory.createPool(baseTok, quoteTok, orderbook, pairCreator));
        assertEq(pool.creator(), pairCreator);

        uint32[] memory t = new uint32[](1);
        uint32[] memory fm = new uint32[](1);
        fm[0] = 100000000;
        t[0] = 50000000;
        vm.prank(pairCreator);
        pool.configureBands(t, fm);
        assertEq(pool.bandCount(), 1);
    }

    /// The creator right can still be handed on -- how the generator gives a launch's pool
    /// to the launcher after listing it itself.
    function test_theCreatorRightCanBeHandedOn() public {
        BandPool pool = _create();
        vm.prank(protocolCreator);
        pool.transferCreator(pairCreator);
        assertEq(pool.creator(), pairCreator);
    }

    function test_onlyTheCreatorCanReconfigure() public {
        BandPool pool = _create();
        uint32[] memory t = new uint32[](1);
        uint32[] memory fm = new uint32[](1);
        fm[0] = 100000000;
        t[0] = 50000000;
        vm.prank(address(0xBAD));
        vm.expectRevert(abi.encodeWithSelector(PoolBands.NotCreator.selector, address(0xBAD)));
        pool.configureBands(t, fm);
    }

    function test_onlyTheEngineCanCreateAPool() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(abi.encodeWithSelector(BandPoolFactory.InvalidAccess.selector, address(0xBAD), engine));
        factory.createPool(baseTok, quoteTok, orderbook, address(0));
    }

    function test_thePairIsCreatedOnceAndTheAddressIsPredictable() public {
        BandPool pool = _create();
        assertEq(factory.getPool(baseTok, quoteTok), address(pool));
        assertEq(factory.getPool(quoteTok, baseTok), address(0), "keyed by (base, quote), in order");
        assertTrue(factory.isClone(address(pool)));
        assertFalse(factory.isClone(address(this)));
        assertEq(factory.allPoolsLength(), 1);
        vm.prank(engine);
        vm.expectRevert(
            abi.encodeWithSelector(BandPoolFactory.PoolAlreadyExists.selector, baseTok, quoteTok, address(pool))
        );
        factory.createPool(baseTok, quoteTok, orderbook, address(0));
    }

    function test_theAdminCanChangeTheDefaultsForFuturePools() public {
        uint32[] memory t = new uint32[](2);
        uint32[] memory fm = new uint32[](2);
        fm[0] = 100000000;
        fm[1] = 100000000;
        t[0] = 50000000;
        t[1] = 100000000;
        factory.setDefaults(pairCreator, 900, t, fm);

        BandPool pool = _create();
        assertEq(pool.bandCount(), 2);
        assertEq(pool.creator(), pairCreator);
        assertEq(pool.maturity(), 900);
        (uint32 f1,,,,) = pool.bands(1);
        assertEq(f1, 100000000);
    }

    function test_onlyTheAdminCanChangeTheDefaults() public {
        uint32[] memory t = new uint32[](1);
        uint32[] memory fm = new uint32[](1);
        t[0] = 50000000;
        fm[0] = 100000000;
        vm.prank(address(0xBAD));
        vm.expectRevert();
        factory.setDefaults(pairCreator, 900, t, fm);
    }

    /// Defaults go through the same validation configureBands enforces -- a pool seeded
    /// with a descending or out-of-range set would be born broken.
    function test_badDefaultsAreRefusedAtTheFactoryNotAtTheClone() public {
        uint32[] memory m = new uint32[](2);
        m[0] = 100000000;
        m[1] = 100000000;
        uint32[] memory bad = new uint32[](2);

        bad[0] = 60000000;
        bad[1] = 20000000;
        vm.expectRevert(PoolBands.SpreadFracsNotAscending.selector);
        factory.setDefaults(protocolCreator, 600, bad, m);

        bad[0] = 20000000;
        bad[1] = 100000001; // past the whole limit
        vm.expectRevert(abi.encodeWithSelector(PoolBands.BadSpreadFrac.selector, uint32(100000001)));
        factory.setDefaults(protocolCreator, 600, bad, m);

        bad[0] = 0;
        bad[1] = 20000000;
        vm.expectRevert(abi.encodeWithSelector(PoolBands.BadSpreadFrac.selector, uint32(0)));
        factory.setDefaults(protocolCreator, 600, bad, m);

        bad[0] = 20000000;
        bad[1] = 60000000;
        m[1] = 99999999; // a discount on the engine fee
        vm.expectRevert(abi.encodeWithSelector(PoolBands.BadFeeMultiplier.selector, uint32(99999999)));
        factory.setDefaults(protocolCreator, 600, bad, m);
    }

    function test_initializeRefusesZeroAddresses() public {
        BandPoolFactory f = new BandPoolFactory();
        vm.expectRevert(BandPoolFactory.ZeroAddress.selector);
        f.initialize(engine, positionManager, address(0), protocolCreator);
        vm.expectRevert(BandPoolFactory.ZeroAddress.selector);
        f.initialize(address(0), positionManager, impl, protocolCreator);
        vm.expectRevert(BandPoolFactory.ZeroAddress.selector);
        f.initialize(engine, positionManager, impl, address(0));
        f.initialize(engine, positionManager, impl, protocolCreator);
        assertEq(f.impl(), impl);
    }
}
