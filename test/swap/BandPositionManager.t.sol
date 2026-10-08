// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {Test, Vm} from "forge-std/Test.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {BandPool} from "../../src/swap/BandPool.sol";
import {BandSwapRouter} from "../../src/swap/BandSwapRouter.sol";
import {BandPoolFactory} from "../../src/swap/BandPoolFactory.sol";
import {BandPositionManager} from "../../src/swap/BandPositionManager.sol";
import {IBandPool} from "../../src/swap/interfaces/IBandPool.sol";
import {IBandPositionManager} from "../../src/swap/interfaces/IBandPositionManager.sol";

contract PMTok {
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

contract PMBook {
    uint256 public price = 2e8;

    /// The listing price the pool anchors to until the TWAP can answer.
    function lmp() external view returns (uint256) { return price; }

    function twap(uint32) external view returns (uint256, uint32) {
        return (price, 300);
    }

    function convert(uint256 p, uint256 amount, bool isBid) external pure returns (uint256) {
        return isBid ? (amount * p) / 1e8 : (amount * 1e8) / p;
    }
}

contract PMEngine {

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

    /// Wide by default, so the limit is not what a case is about unless it says so.
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
 * The factory, the manager and the pool wired the way a deployment wires them, so
 * the portfolio read is exercised against positions that were actually minted
 * through the manager rather than poked into the pool.
 *
 * v2: one token holds any subset of the ladder, so "one position per band" cases
 * become one token holding several bands, and the collect-many path is one collect.
 */
contract BandPositionManagerTest is Test {
    BandPoolFactory factory;
    BandPositionManager manager;
    BandPool pool;
    BandSwapRouter router;
    PMTok baseTok;
    PMTok quoteTok;
    PMBook book;
    PMEngine eng;

    address engine;
    address alice = address(0xA11CE);
    address taker = address(0xABCD);
    address protocolCreator = address(0xC0FFEE);

    function setUp() public {
        router = new BandSwapRouter();
        baseTok = new PMTok();
        quoteTok = new PMTok();
        book = new PMBook();
        eng = new PMEngine();
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
        // Fractions of the stub's 10% limit that reproduce the 0.10 / 0.30 / 0.50% ladder
        // these cases were written against.
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

    function _one(uint8 band) internal pure returns (uint8[] memory b) {
        b = new uint8[](1);
        b[0] = band;
    }

    function _amt(uint256 a) internal pure returns (uint256[] memory r) {
        r = new uint256[](1);
        r[0] = a;
    }

    function _mintInto(address who, uint8[] memory bands, uint256[] memory baseAmts, uint256[] memory quoteAmts)
        internal
        returns (uint256 tokenId)
    {
        uint256 bt;
        uint256 qt;
        for (uint256 i = 0; i < bands.length; i++) {
            bt += baseAmts[i];
            qt += quoteAmts[i];
        }
        baseTok.mint(who, bt);
        quoteTok.mint(who, qt);
        vm.startPrank(who);
        baseTok.approve(address(manager), type(uint256).max);
        quoteTok.approve(address(manager), type(uint256).max);
        (tokenId,) = manager.mint(
            IBandPositionManager.MintParams({
                pool: address(pool),
                bands: bands,
                baseAmounts: baseAmts,
                quoteAmounts: quoteAmts,
                minShares: new uint128[](bands.length),
                recipient: who,
                deadline: block.timestamp
            })
        );
        vm.stopPrank();
    }

    function _mint(address who, uint8 band, uint256 baseAmt, uint256 quoteAmt) internal returns (uint256) {
        return _mintInto(who, _one(band), _amt(baseAmt), _amt(quoteAmt));
    }

    function _trade(uint256 amountIn, bool quoteToBase) internal {
        if (quoteToBase) {
            quoteTok.mint(taker, amountIn);
        } else {
            baseTok.mint(taker, amountIn);
        }
        vm.startPrank(taker);
        quoteTok.approve(address(router), type(uint256).max);
        baseTok.approve(address(router), type(uint256).max);
        router.swap(address(pool), amountIn, quoteToBase, taker, 0);
        vm.stopPrank();
    }

    function _only(uint256 id) internal view returns (IBandPool.BandView memory) {
        (IBandPool.BandView[] memory held,,) = pool.positionView(id);
        assertEq(held.length, 1, "a one-band position");
        return held[0];
    }

    function test_theTokenIsMintedToTheDepositorAndNamesItsPool() public {
        uint256 id = _mint(alice, 0, 1_000e18, 2_000e18);
        assertEq(manager.balanceOf(alice, id), 1);
        assertEq(manager.poolOf(id), address(pool));
        assertEq(manager.poolOf(id + 1), address(0), "an unminted id names no pool");
    }

    /**
     * v1 kept a position's shares as uint256 and this test proved a band took liquidity
     * above uint128. v2 packs a slot's shares beside its clock into ONE storage word, so a
     * single position is capped at uint128 shares -- and a deposit past that reverts
     * cleanly on SafeCast rather than truncating. The BAND is still uint256 throughout:
     * reserves and total shares take positions summing past uint128.
     */
    function test_aSinglePositionIsCappedAtUint128SharesAndTheBandIsNot() public {
        uint256 over = uint256(type(uint128).max) + 1;
        baseTok.mint(alice, over);
        quoteTok.mint(alice, over);
        vm.startPrank(alice);
        baseTok.approve(address(manager), type(uint256).max);
        quoteTok.approve(address(manager), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(SafeCast.SafeCastOverflowedUintDowncast.selector, 128, over));
        manager.mint(
            IBandPositionManager.MintParams({
                pool: address(pool),
                bands: _one(0),
                baseAmounts: _amt(over),
                quoteAmounts: _amt(over),
                minShares: new uint128[](1),
                recipient: alice,
                deadline: block.timestamp
            })
        );
        vm.stopPrank();

        uint256 max = type(uint128).max;
        uint256 a = _mint(alice, 0, max, max);
        uint256 b = _mint(address(0xB0B), 0, max, max);
        (uint256 baseReserve, uint256 quoteReserve) = pool.bandReserves(0);
        (, uint256 bandShares,,,) = pool.bands(0);
        assertEq(baseReserve, 2 * max, "the band holds more than uint128");
        assertEq(quoteReserve, 2 * max);
        assertEq(bandShares, 2 * max);
        assertEq(_only(a).shares, max);
        assertEq(_only(b).shares, max);
    }

    function test_aStrangerCannotClaimOrWithdrawSomebodyElsesPosition() public {
        uint256 id = _mint(alice, 0, 1_000e18, 2_000e18);
        bytes memory err = abi.encodeWithSelector(IBandPositionManager.NotOwnerOrApproved.selector, address(0xBAD), id);
        vm.startPrank(address(0xBAD));
        vm.expectRevert(err);
        manager.collect(id, address(0xBAD));
        vm.expectRevert(err);
        manager.decreaseLiquidity(id, 10_000, 0, 0, address(0xBAD), block.timestamp);
        vm.stopPrank();
    }

    /**
     * The whole portfolio in ONE call, which is the pattern the spec names to refuse:
     * list positions, then query the pool once per position for what is owed.
     */
    function test_portfolioReturnsEveryRowInOneCall() public {
        uint256 tight = _mint(alice, 0, 1_000e18, 2_000e18);
        uint256 wide = _mint(alice, 2, 500e18, 1_000e18);
        _trade(50e18, true);
        _trade(20e18, false);

        uint256[] memory ids = new uint256[](2);
        ids[0] = tight;
        ids[1] = wide;
        IBandPositionManager.PositionView[] memory rows = manager.portfolio(ids);

        assertEq(rows.length, 2);
        assertEq(rows[0].pool, address(pool));
        assertEq(rows[0].base, address(baseTok));
        assertEq(rows[0].quote, address(quoteTok));
        assertEq(rows[0].holder, alice);
        assertEq(rows[0].bands.length, 1);
        assertEq(rows[0].bands[0].band, 0);
        assertEq(rows[1].bands[0].band, 2);
        assertEq(rows[0].bands[0].toleranceBuy, 100000, "0.10%");
        assertEq(rows[1].bands[0].toleranceBuy, 500000, "0.50%");

        // A position holds BOTH sides -- the row cannot be one number.
        assertGt(rows[0].bands[0].baseOwned, 0);
        assertGt(rows[0].bands[0].quoteOwned, 0);

        // Only the tight band traded, so only it earned.
        assertGt(rows[0].bands[0].pendingBase, 0, "earned on the base leg");
        assertGt(rows[0].bands[0].pendingQuote, 0, "and on the quote leg");
        assertEq(rows[1].bands[0].pendingBase, 0, "the wide band never filled");
    }

    /**
     * The number the LP is actually deciding on. At mint nothing is vested, so the
     * entire entitlement is what an exit right now would forfeit -- pending minus vested
     * -- and the row says so rather than making the UI derive it from a timestamp.
     * (A collect forfeits nothing in v2; only a withdrawal does.)
     */
    function test_theRowSaysWhatExitingNowWouldForfeit() public {
        uint256 id = _mint(alice, 0, 1_000e18, 2_000e18);
        _trade(50e18, true);

        uint256[] memory ids = new uint256[](1);
        ids[0] = id;

        IBandPool.BandView memory atMint = manager.portfolio(ids)[0].bands[0];
        assertEq(atMint.vestedNum, 0, "nothing vested at age zero");
        assertEq(atMint.vestedBase, 0);
        assertGt(atMint.pendingBase, 0, "all of it is at risk");

        vm.warp(block.timestamp + 300); // half of the 600s ramp
        IBandPool.BandView memory half = manager.portfolio(ids)[0].bands[0];
        assertApproxEqRel(uint256(half.vestedNum), 50000000, 1e15, "half way up the ramp");
        assertApproxEqRel(half.vestedBase, half.pendingBase - half.vestedBase, 1e12, "half kept, half at risk");

        vm.warp(block.timestamp + 301);
        IBandPool.BandView memory mature = manager.portfolio(ids)[0].bands[0];
        assertEq(mature.vestedNum, 100000000, "fully vested");
        assertEq(mature.pendingBase - mature.vestedBase, 0, "nothing left at risk");
    }

    /// v1's `collectMany` over one token per band is, in v2, one collect of one token.
    function test_oneCollectSettlesEveryBandInOneTransaction() public {
        uint8[] memory bands = new uint8[](2);
        bands[1] = 1;
        uint256[] memory b = new uint256[](2);
        uint256[] memory q = new uint256[](2);
        b[0] = 1_000e18;
        b[1] = 1_000e18;
        q[0] = 2_000e18;
        q[1] = 2_000e18;
        uint256 id = _mintInto(alice, bands, b, q);
        // Past band 0's ~2,002 quote of capacity, so band 1 fills too.
        _trade(3_000e18, true);
        vm.warp(block.timestamp + 601);

        (IBandPool.BandView[] memory held,,) = pool.positionView(id);
        assertGt(held[0].vestedBase, 0, "band 0 earned");
        assertGt(held[1].vestedBase, 0, "band 1 earned");

        uint256 before_ = baseTok.balanceOf(alice);
        vm.prank(alice);
        (uint256 paid,) = manager.collect(id, alice);
        assertEq(paid, held[0].vestedBase + held[1].vestedBase, "both bands in one call");
        assertEq(baseTok.balanceOf(alice) - before_, paid);

        (held,,) = pool.positionView(id);
        assertEq(held[0].vestedBase, 0, "settled to zero");
        assertEq(held[1].vestedBase, 0);
    }

    function test_withdrawingReturnsBothSidesAndPaysTheVestedFees() public {
        uint256 id = _mint(alice, 0, 1_000e18, 2_000e18);
        _trade(50e18, true);
        vm.warp(block.timestamp + 601);

        uint256 baseBefore = baseTok.balanceOf(alice);
        uint256 quoteBefore = quoteTok.balanceOf(alice);
        vm.prank(alice);
        (uint256 baseOut, uint256 quoteOut) = manager.decreaseLiquidity(id, 10_000, 0, 0, alice, block.timestamp);

        assertGt(baseOut, 0);
        assertGt(quoteOut, 0);
        // Strictly more than the principal, because the vested fees came out with it.
        assertGt(baseTok.balanceOf(alice) - baseBefore, baseOut, "fees came out with it");
        assertEq(quoteTok.balanceOf(alice) - quoteBefore, quoteOut);
    }

    /**
     * v1 had one manager event carrying `remainingShares`, because the amounts that come
     * OUT cannot distinguish a 10% exit from a total one. v2's pool events carry the
     * shares per band both ways, so what a position still holds is the running sum of
     * IncreaseLiquidity minus DecreaseLiquidity -- and it must match the pool.
     */
    function test_theEventsAloneSayWhatThePositionStillHolds() public {
        vm.recordLogs();
        uint256 id = _mint(alice, 0, 1_000e18, 2_000e18);
        uint256 opened = _sharesFromLogs(vm.getRecordedLogs(), true);
        uint128 third = uint128(_only(id).shares / 3);

        vm.recordLogs();
        vm.prank(alice);
        manager.decreaseBand(id, 0, third, 0, 0, alice, block.timestamp);
        uint256 closed = _sharesFromLogs(vm.getRecordedLogs(), false);

        assertGt(opened - closed, 0, "a partial exit leaves something");
        assertEq(opened - closed, _only(id).shares, "and the log agrees with the pool");

        vm.recordLogs();
        vm.prank(alice);
        manager.decreaseLiquidity(id, 10_000, 0, 0, alice, block.timestamp);
        closed += _sharesFromLogs(vm.getRecordedLogs(), false);
        assertEq(opened - closed, 0, "a close leaves nothing");
        assertEq(pool.bandMaskOf(id), 0);
    }

    /// Shares summed over every band in the pool's Increase- or DecreaseLiquidity logs.
    function _sharesFromLogs(Vm.Log[] memory logs, bool increase) internal view returns (uint256 total) {
        bytes32 sig = increase
            ? keccak256("IncreaseLiquidity(uint256,uint8[],uint128[],uint256,uint256)")
            : keccak256("DecreaseLiquidity(uint256,uint8[],uint128[],uint256,uint256,uint256,uint256,bool)");
        bool seen;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(pool) || logs[i].topics[0] != sig) continue;
            uint128[] memory shares;
            if (increase) (, shares,,) = abi.decode(logs[i].data, (uint8[], uint128[], uint256, uint256));
            else (, shares,,,,,) = abi.decode(logs[i].data, (uint8[], uint128[], uint256, uint256, uint256, uint256, bool));
            for (uint256 j = 0; j < shares.length; j++) {
                total += shares[j];
            }
            seen = true;
        }
        assertTrue(seen, "the pool emitted no liquidity event");
    }

    function test_anEmptiedPositionCanBeBurned() public {
        uint256 id = _mint(alice, 0, 1_000e18, 2_000e18);
        _trade(50e18, true);
        vm.warp(block.timestamp + 601);
        vm.startPrank(alice);
        manager.decreaseLiquidity(id, 10_000, 0, 0, alice, block.timestamp);
        manager.burn(id);
        vm.stopPrank();
        assertEq(manager.balanceOf(alice, id), 0);
    }

    function test_aPositionStillHoldingLiquidityCannotBeBurned() public {
        uint256 id = _mint(alice, 0, 1_000e18, 2_000e18);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IBandPositionManager.PositionNotEmpty.selector, id));
        manager.burn(id);
    }
}
