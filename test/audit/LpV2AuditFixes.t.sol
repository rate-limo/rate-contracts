// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {ExchangeOrderbook} from "../../src/exchange/libraries/ExchangeOrderbook.sol";
import {AssetGenerator} from "../../src/asset/AssetGenerator.sol";
import {BandPool} from "../../src/swap/BandPool.sol";
import {PresaleLaunch} from "../../src/asset/PresaleLaunch.sol";
import {BandSwapRouter} from "../../src/swap/BandSwapRouter.sol";
import {IBandPositionManager} from "../../src/swap/interfaces/IBandPositionManager.sol";
import {BandBaseSetup} from "../swap/BandBaseSetup.sol";

/// Not a pool: just enough surface for the router -- the real pair's tokens, the real
/// engine, and a "fill" at whatever price it likes.
contract FakePool {
    address public base;
    address public quote;
    address public engine;

    constructor(address b, address q, address e) {
        base = b;
        quote = q;
        engine = e;
    }

    function swap(uint256, bool, address, uint256) external pure returns (uint256, uint256) {
        return (1, 1);
    }
}

/// Answers the router's registry check as its own engine and factory, then names the
/// REAL engine from inside `swap()` -- a normal call, so it can write state -- hoping the
/// report reads `engine()` a second time.
contract FlipPool {
    address public base;
    address public quote;
    address internal realEngine;
    bool internal flipped;

    constructor(address b, address q, address e) {
        base = b;
        quote = q;
        realEngine = e;
    }

    function engine() external view returns (address) {
        return flipped ? realEngine : address(this);
    }

    function poolFactory() external view returns (address) {
        return address(this);
    }

    function getPool(address, address) external view returns (address) {
        return address(this);
    }

    function swap(uint256, bool, address, uint256) external returns (uint256, uint256) {
        flipped = true;
        return (1, 1);
    }

    function reset() external {
        flipped = false;
    }
}

contract PairLookalike {
    address public base;
    address public quote;

    constructor(address b, address q) {
        base = b;
        quote = q;
    }
}

/// A "position manager" that holds nothing and transfers nothing of value.
contract FakeManager {
    address public p;

    constructor(address p_) {
        p = p_;
    }

    function poolOf(uint256) external view returns (address) {
        return p;
    }

    function safeTransferFrom(address, address, uint256, uint256, bytes calldata) external {}
}

/**
 * Regressions for the pre-deploy review of LP v2 (2026-09-26). Each was a working exploit
 * against 102db0c5; each test here is its PoC with the assertion turned around.
 */
contract LpV2AuditFixesTest is BandBaseSetup {
    address internal attacker = makeAddr("attacker");

    function setUp() public override {
        super.setUp();
        matchingEngine.setPoolFeeShare(50_000_000);
        vm.warp(1_000_000);
        vm.roll(1000);
    }

    // ------------------------------------------------------------------------ C-1

    /// A fake pool fed prices to reportSwap through the router, walking lmp -- and so
    /// every band's TWAP anchor -- one spread per block at no cost, then bought the bands
    /// out at the price it made. The router now serves only the factory's pool for a pair.
    function test_C1_theRouterRefusesAPoolTheFactoryDoesNotList() public {
        FakePool fake = new FakePool(address(token1), address(token2), address(matchingEngine));
        uint256 lmpBefore = book.lmp();
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(BandSwapRouter.UnknownPool.selector, address(fake)));
        router.swap(address(fake), 0, false, attacker, 0);
        assertEq(book.lmp(), lmpBefore, "no report landed");
    }

    // ------------------------------------------------------------------------ H-1

    function _mintOne(address who, uint256 amt) internal returns (uint256 id) {
        token1.mint(who, amt);
        vm.startPrank(who);
        token1.approve(address(positionManager), type(uint256).max);
        uint8[] memory bands = new uint8[](1);
        uint256[] memory b = new uint256[](1);
        b[0] = amt;
        (id,) = positionManager.mint(
            IBandPositionManager.MintParams({
                pool: address(pool),
                bands: bands,
                baseAmounts: b,
                quoteAmounts: new uint256[](1),
                minShares: new uint128[](1),
                recipient: who,
                deadline: block.timestamp
            })
        );
        vm.stopPrank();
    }

    function _jitScenario(uint256 collects) internal returns (uint256 jitFees, uint256 honestFees) {
        address honest = makeAddr("honest");
        uint256 hId = _mintOne(honest, 1000e18);
        vm.warp(block.timestamp + 10_000); // long mature
        uint256 jId = _mintOne(attacker, 1000e18);
        for (uint256 i = 0; i < 5; i++) {
            _buy(trader1, 10_000e18);
        }
        vm.warp(block.timestamp + 60); // the JIT slot is 10% vested

        uint256 before = token1.balanceOf(attacker);
        vm.startPrank(attacker);
        uint256[] memory ids = new uint256[](collects);
        for (uint256 i = 0; i < collects; i++) {
            ids[i] = jId;
        }
        if (collects > 0) positionManager.collectMany(ids, attacker);
        (uint256 baseOut,) = positionManager.decreaseLiquidity(jId, 10_000, 0, 0, attacker, block.timestamp);
        vm.stopPrank();
        jitFees = token1.balanceOf(attacker) - before - baseOut;

        uint256 hb = token1.balanceOf(honest);
        vm.prank(honest);
        positionManager.collect(hId, honest);
        honestFees = token1.balanceOf(honest) - hb;
    }

    /// Releasing `num` of the REMAINDER on every call compounded: sixty collects in one
    /// block kept a 10%-vested JIT slot ~10x its share. Release is now the growth of the
    /// ramp since the last release, so repeating a collect at the same moment adds nothing.
    function test_H1_repeatedCollectsReleaseNoMoreThanOne() public {
        uint256 snap = vm.snapshotState();
        (uint256 j0, uint256 h0) = _jitScenario(0);
        vm.revertToState(snap);
        (uint256 j60, uint256 h60) = _jitScenario(60);
        assertGt(j0, 0);
        assertApproxEqRel(j60, j0, 0.01e18, "sixty collects release what one exit does");
        assertApproxEqRel(h60, h0, 0.01e18, "the honest LP keeps the forfeit it is owed");
    }

    // ------------------------------------------------------------------------ C-2

    /// Listing a presale's coin before graduation made `graduate` revert forever and left
    /// every contribution with no exit. The sale now FAILS instead and refunds.
    function test_C2_aSquattedListingFailsTheSaleAndRefunds() public {
        PresaleLaunch launch =
            new PresaleLaunch(address(this), address(matchingEngine), address(positionManager), address(0), address(token2));
        address saleCreator = address(0xA11CE);
        PresaleLaunch.CreateParams memory p = PresaleLaunch.CreateParams({
            name: "White Coin",
            symbol: "WHITE",
            totalSupply: 100_000_000e18,
            presaleAllocation: 10_000_000e18,
            lpTokenAllocation: 2_000_000e18,
            priceQuotePerToken: 10_000,
            targetRaise: 100_000e18,
            minimumRaise: 50_000e18,
            maxPerWallet: 100_000e18,
            creatorTokenAllocation: 20_000_000e18,
            treasuryTokenAllocation: 68_000_000e18,
            startAt: uint64(block.timestamp),
            endAt: uint64(block.timestamp + 1 days),
            creatorCliff: 90 days,
            creatorVestingDuration: 365 days,
            lpBps: 2_000,
            quote: address(token2),
            treasury: address(0xB0B)
        });
        vm.prank(saleCreator);
        (uint256 id, address coin) = launch.createPresale(p);
        vm.startPrank(trader1);
        token2.approve(address(launch), type(uint256).max);
        launch.commit(id, 60_000e18);
        vm.stopPrank();

        vm.prank(attacker);
        matchingEngine.addPair(coin, address(token2), 1, 0, address(0), ExchangeOrderbook.MatchingMode.PriceTimePriority);

        vm.warp(block.timestamp + 1 days);
        launch.finalizeSale(id);
        vm.prank(saleCreator);
        launch.configureGraduation(
            id,
            PresaleLaunch.GraduationConfig({
                listingPrice: 1e8,
                minPrice: 1,
                maxPrice: type(uint256).max,
                lpSlippageLimit: 1_000_000,
                volatilityBps: 100,
                makerFee: 0,
                takerFee: 100_000,
                liquidityLockDuration: 30 days,
                mode: ExchangeOrderbook.MatchingMode.PriceTimePriority
            })
        );

        launch.graduate(id); // does not revert
        assertEq(uint256(launch.statusOf(id)), uint256(PresaleLaunch.Status.Failed), "the sale failed");

        uint256 before = token2.balanceOf(trader1);
        vm.prank(trader1);
        launch.claim(id);
        assertEq(token2.balanceOf(trader1) - before, 60_000e18, "the contribution came back in full");
    }

    // ------------------------------------------------------------------------ M-1

    /// M-1 was a lock over a caller-supplied manager or an emptied position. The launch
    /// now mints no position at all until graduation, from the engine's own manager, so
    /// there is nothing to lock, fake or empty before then.
    function test_M1_aLaunchHoldsNoPositionBeforeGraduation() public {
        AssetGenerator gen = new AssetGenerator(address(this), address(matchingEngine));
        gen.setQuoteOption(
            address(token2), true, 5_000e18, 5e18, 25_000e18, ExchangeOrderbook.MatchingMode.PriceTimePriority, 100_000
        );
        matchingEngine.grantRole(keccak256("MARKET_MAKER_ROLE"), address(gen));
        matchingEngine.setFeeManager(address(gen));
        address launcher = address(0x1A0C);
        token2.mint(launcher, 100e18);
        vm.startPrank(launcher);
        token2.approve(address(gen), type(uint256).max);
        address coin = gen.launch("C", "C", 1_000_000_000e18, address(token2), 5e18, AssetGenerator.LockMode.FeesOnly);
        vm.stopPrank();

        (,,,, address manager, uint256 tokenId) = gen.launchLocks(coin);
        assertEq(manager, address(0));
        assertEq(tokenId, 0);
        assertEq(BandPool(poolFactory.getPool(coin, address(token2))).creator(), address(gen));
    }

    // ------------------------------------------------------------------ rechecks

    /// C-1 recheck: the first fix read the pool twice, and a pool that changes its answers
    /// between the check and the report got its price to the real engine. The router now
    /// reads once and reports to the engine it checked.
    function test_C1_aPoolThatFlipsItsEngineMidSwapReportsNothingReal() public {
        FlipPool fp = new FlipPool(address(token1), address(token2), address(matchingEngine));
        uint256 lmpBefore = book.lmp();
        for (uint256 i = 0; i < 5; i++) {
            vm.roll(block.number + 1);
            fp.reset();
            vm.prank(attacker);
            try router.swap(address(fp), 0, false, attacker, 0) {} catch {}
        }
        assertEq(book.lmp(), lmpBefore, "no report reached the real engine");
    }

    function _laterFees(bool collectFirst) internal returns (uint256 kept) {
        address lp = makeAddr("lp");
        _mintOne(makeAddr("other"), 1000e18);
        uint256 id = _mintOne(lp, 1000e18);
        _buy(trader1, 1_000e18); // fees at age 0
        vm.warp(block.timestamp + 540); // 90% vested
        uint256 b0 = token1.balanceOf(lp);
        if (collectFirst) {
            vm.prank(lp);
            positionManager.collect(id, lp);
        }
        for (uint256 i = 0; i < 5; i++) {
            _buy(trader1, 10_000e18); // more fees, at 90%
        }
        vm.warp(block.timestamp + 6); // 91%
        vm.prank(lp);
        (uint256 principal,) = positionManager.decreaseLiquidity(id, 10_000, 0, 0, lp, block.timestamp);
        kept = token1.balanceOf(lp) - b0 - principal;
    }

    /// H-1 recheck: a single shared release LEVEL made fees earned after a collect vest
    /// from zero, so collecting cost an honest LP ~87% of them. Release now counts against
    /// everything accrued, so collecting along the way keeps exactly what not collecting
    /// does.
    function test_H1_collectingAlongTheWayCostsNothing() public {
        uint256 snap = vm.snapshotState();
        uint256 without = _laterFees(false);
        vm.revertToState(snap);
        uint256 with = _laterFees(true);
        assertGt(without, 0);
        assertApproxEqRel(with, without, 0.001e18, "a collect does not change what an exit keeps");
    }

    /// C-2 recheck: an oversubscribed sale failed by a squatted listing refunds everyone in
    /// full, leaves the contract empty, returns the supply, and cannot then graduate.
    function test_C2_theFailedPathRefundsAnOversubscribedSaleInFull() public {
        PresaleLaunch launch =
            new PresaleLaunch(address(this), address(matchingEngine), address(positionManager), address(0), address(token2));
        address saleCreator = address(0xA11CE);
        PresaleLaunch.CreateParams memory p = PresaleLaunch.CreateParams({
            name: "W",
            symbol: "W",
            totalSupply: 100_000_000e18,
            presaleAllocation: 10_000_000e18,
            lpTokenAllocation: 2_000_000e18,
            priceQuotePerToken: 10_000,
            targetRaise: 100_000e18,
            minimumRaise: 50_000e18,
            maxPerWallet: 100_000e18,
            creatorTokenAllocation: 20_000_000e18,
            treasuryTokenAllocation: 68_000_000e18,
            startAt: uint64(block.timestamp),
            endAt: uint64(block.timestamp + 1 days),
            creatorCliff: 90 days,
            creatorVestingDuration: 365 days,
            lpBps: 2_000,
            quote: address(token2),
            treasury: address(0xB0B)
        });
        vm.prank(saleCreator);
        (uint256 id, address coin) = launch.createPresale(p);
        vm.startPrank(trader1);
        token2.approve(address(launch), type(uint256).max);
        launch.commit(id, 70_000e18);
        vm.stopPrank();
        vm.startPrank(trader2);
        token2.approve(address(launch), type(uint256).max);
        launch.commit(id, 60_000e18);
        vm.stopPrank();
        vm.prank(attacker);
        matchingEngine.addPair(coin, address(token2), 1, 0, address(0), ExchangeOrderbook.MatchingMode.PriceTimePriority);
        vm.warp(block.timestamp + 1 days);
        launch.finalizeSale(id);
        vm.prank(saleCreator);
        launch.configureGraduation(
            id,
            PresaleLaunch.GraduationConfig({
                listingPrice: 1e8,
                minPrice: 1,
                maxPrice: type(uint256).max,
                lpSlippageLimit: 1_000_000,
                volatilityBps: 100,
                makerFee: 0,
                takerFee: 100_000,
                liquidityLockDuration: 30 days,
                mode: ExchangeOrderbook.MatchingMode.PriceTimePriority
            })
        );
        launch.graduate(id);
        uint256 a0 = token2.balanceOf(trader1);
        uint256 b0 = token2.balanceOf(trader2);
        vm.prank(trader1);
        launch.claim(id);
        vm.prank(trader2);
        launch.claim(id);
        assertEq(token2.balanceOf(trader1) - a0, 70_000e18);
        assertEq(token2.balanceOf(trader2) - b0, 60_000e18);
        assertEq(token2.balanceOf(address(launch)), 0, "nothing left behind");
        vm.prank(saleCreator);
        launch.recoverFailedTokens(id);
        (bool ok, bytes memory data) = coin.staticcall(abi.encodeWithSignature("balanceOf(address)", saleCreator));
        require(ok);
        assertEq(abi.decode(data, (uint256)), 100_000_000e18, "the whole supply back to the creator");
        vm.expectRevert();
        launch.graduate(id);
    }
}
