// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {ExchangeOrderbook} from "../../src/exchange/libraries/ExchangeOrderbook.sol";
import {AssetGenerator} from "../../src/asset/AssetGenerator.sol";
import {BandPool} from "../../src/swap/BandPool.sol";
import {BandBaseSetup} from "../swap/BandBaseSetup.sol";

/**
 * A launch through the generator, against the real engine and band factory.
 *
 * Two v2 rules meet here. `addPair` names its caller -- the generator -- as the pool's
 * creator, so the generator must hand the ladder to the launcher in the same call. And
 * the creator's slippage cap is half of every band's limit, so changing it must re-sync
 * the pool; otherwise the bands keep quoting at the old cap.
 */
contract GeneratorPoolHandoverTest is BandBaseSetup {
    AssetGenerator internal gen;
    address internal launcher = address(0x1A0C);

    function setUp() public override {
        super.setUp();
        gen = new AssetGenerator(address(this), address(matchingEngine));
        gen.setQuoteOption(
            address(token2), true, 5_000e18, 5e18, 25_000e18, ExchangeOrderbook.MatchingMode.PriceTimePriority, 100_000
        );
        matchingEngine.grantRole(keccak256("MARKET_MAKER_ROLE"), address(gen));
        // The creator's cap reaches the engine (and so the pool) only through the
        // incentive hook. Production sets this deliberately after deploy.
        matchingEngine.setIncentive(address(gen));
        matchingEngine.setFeeManager(address(gen));
        token2.mint(launcher, 1_000e18);
        vm.prank(launcher);
        token2.approve(address(gen), type(uint256).max);
    }

    function _launch() internal returns (address coin, BandPool pool) {
        vm.prank(launcher);
        coin = gen.launch("Launch Coin", "LNCH", 1_000_000_000e18, address(token2), 5e18, AssetGenerator.LockMode.FeesOnly);
        pool = BandPool(poolFactory.getPool(coin, address(token2)));
    }

    /// Until graduation the generator keeps the bands: a creator who could configure
    /// them before the ladder sells out could reprice a pool they do not own yet.
    function test_launch_keepsThePoolUntilGraduation() public {
        (, BandPool pool) = _launch();
        assertTrue(address(pool) != address(0));
        assertEq(pool.creator(), address(gen), "the generator, not the launcher, until graduation");
    }

    function test_launch_limitIsTheCreatorCapWhenTighterThanTheSpread() public {
        (, BandPool pool) = _launch();
        // A launch opens at Meme volatility: 100 bps = 1% = 1,000,000 on DENOM, inside
        // the fixture's 10% market spread, so the cap is the limit.
        assertEq(pool.pairLimit(true), 1_000_000);
        assertEq(pool.pairLimit(false), 1_000_000);
    }

    function test_setPairTradingConfig_resyncsThePool() public {
        (address coin, BandPool pool) = _launch();
        uint32 fee = gen.MIN_LAUNCH_TAKER_FEE();
        // Before graduation only an admin moves a coin's policy; this contract is admin.
        gen.setPairTradingConfig(coin, 50, fee, fee);
        assertEq(pool.pairLimit(true), 500_000, "50 bps, synced in the same transaction");
        // A launched pool carries the factory's default ladder, 20 / 60 / 100% of the
        // limit, so every band moved with the one write.
        (uint32 t0,) = pool.bandTolerances(0);
        (uint32 t1,) = pool.bandTolerances(1);
        (uint32 t2,) = pool.bandTolerances(2);
        assertEq(t0, 100_000);
        assertEq(t1, 300_000);
        assertEq(t2, 500_000);
    }

    function test_setExistingPairTradingConfig_resyncsThePool() public {
        // The fixture's own pair was not launched here; the admin path configures it.
        uint32 fee = gen.MIN_LAUNCH_TAKER_FEE();
        gen.setExistingPairTradingConfig(address(token1), address(token2), 20, fee, fee);
        assertEq(pool.pairLimit(true), 200_000);
        assertEq(pool.pairLimit(false), 200_000);
    }
}
