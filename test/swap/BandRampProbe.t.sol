// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {Test, Vm} from "forge-std/Test.sol";
import {IBandPool} from "../../src/swap/interfaces/IBandPool.sol";
import {IBandPositionManager} from "../../src/swap/interfaces/IBandPositionManager.sol";
import {BandPool} from "../../src/swap/BandPool.sol";
import {BandSwapRouter} from "../../src/swap/BandSwapRouter.sol";
import {BandPoolFactory} from "../../src/swap/BandPoolFactory.sol";
import {BandPositionManager} from "../../src/swap/BandPositionManager.sol";

contract RTok {
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

contract RBook {
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

contract REngine {

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

    function feeOf(address, address, address, bool) external pure returns (uint32) {
        return 100000;
    }
}

/**
 * The vesting ramp, probed at its edges: "who gets a forfeit, and when", answered
 * against the real contract.
 *
 * v2 moved the forfeit. `collect` NEVER forfeits -- it pays the vested part and the
 * rest keeps vesting. Only capital LEAVING (a decrease, or the refunded part of a move)
 * forfeits its unvested fee, to the band's other shares or to the protocol when there
 * are none. Each probe below is restated for that.
 */
contract BandRampProbeTest is Test {
    BandPoolFactory factory;
    BandPositionManager manager;
    BandPool pool;
    BandSwapRouter router;
    RTok baseTok;
    RTok quoteTok;
    RBook book;
    REngine eng;

    address engine;
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address carol = address(0xCA401);
    address taker = address(0xABCD);
    address protocolCreator = address(0xC0FFEE);

    function setUp() public {
        router = new BandSwapRouter();
        baseTok = new RTok();
        quoteTok = new RTok();
        book = new RBook();
        eng = new REngine();
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
        pool.syncLimit();
        vm.warp(1_000_000);
    }

    uint256 public lastShares;

    /// Two-sided into band 0 -- the factory default's tightest band.
    function _mint(address who, uint256 b, uint256 q) internal returns (uint256 tokenId) {
        baseTok.mint(who, b);
        quoteTok.mint(who, q);
        vm.startPrank(who);
        baseTok.approve(address(manager), type(uint256).max);
        quoteTok.approve(address(manager), type(uint256).max);
        uint8[] memory bands = new uint8[](1);
        uint256[] memory ba = new uint256[](1);
        uint256[] memory qa = new uint256[](1);
        ba[0] = b;
        qa[0] = q;
        uint128[] memory shares;
        (tokenId, shares) = manager.mint(
            IBandPositionManager.MintParams({
                pool: address(pool),
                bands: bands,
                baseAmounts: ba,
                quoteAmounts: qa,
                minShares: new uint128[](1),
                recipient: who,
                deadline: block.timestamp
            })
        );
        lastShares = shares[0];
        vm.stopPrank();
    }

    function _exit(address who, uint256 tokenId) internal returns (uint256 baseOut, uint256 quoteOut) {
        vm.prank(who);
        return manager.decreaseLiquidity(tokenId, 10_000, 0, 0, who, block.timestamp);
    }

    function _trade(uint256 amountIn, bool quoteToBase) internal {
        if (quoteToBase) quoteTok.mint(taker, amountIn); else baseTok.mint(taker, amountIn);
        vm.startPrank(taker);
        quoteTok.approve(address(pool), type(uint256).max);
        quoteTok.approve(address(router), type(uint256).max);
        baseTok.approve(address(pool), type(uint256).max);
        baseTok.approve(address(router), type(uint256).max);
        router.swap(address(pool), amountIn, quoteToBase, taker, 0);
        vm.stopPrank();
    }

    /// The forfeit a `DecreaseLiquidity` in the recorded logs reports, and where it went.
    function _forfeitFromLogs() internal returns (uint256 fb, uint256 fq, bool toProtocol, bool seen) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(pool) && logs[i].topics[0] == IBandPool.DecreaseLiquidity.selector) {
                (,,,, fb, fq, toProtocol) =
                    abi.decode(logs[i].data, (uint8[], uint128[], uint256, uint256, uint256, uint256, bool));
                seen = true;
            }
        }
    }

    /**
     * A position's AGE travels with the token. Nothing resets `createdAt` on an
     * ERC-1155 transfer, so a matured position is a bearer instrument that claims at
     * 100% for whoever holds it -- including someone who has borne no inventory risk.
     * Recorded as the design, not a fix: the fees were earned by the capital, and the
     * capital is what was transferred.
     */
    function test_maturityTravelsWithTheToken() public {
        uint256 aliceId = _mint(alice, 1_000e18, 1_000e18);
        _mint(carol, 1_000e18, 1_000e18);
        vm.warp(block.timestamp + 3600); // well past the 10-minute maturity
        _trade(100e18, true);

        // Alice hands the matured position to Bob, who has held nothing.
        vm.prank(alice);
        manager.safeTransferFrom(alice, bob, aliceId, 1, "");

        (IBandPool.BandView[] memory held,,) = pool.positionView(aliceId);
        assertEq(held[0].vestedNum, 1e8, "the new holder sits at a FULL ramp he did not earn");

        uint256 before = baseTok.balanceOf(bob) + quoteTok.balanceOf(bob);
        vm.prank(bob);
        manager.collect(aliceId, bob);
        uint256 gained = baseTok.balanceOf(bob) + quoteTok.balanceOf(bob) - before;
        assertGt(gained, 0, "and claims");
    }

    /**
     * REPRODUCED. A forfeit is credited to whoever holds the band at WITHDRAWAL time,
     * not to whoever held it while the fees were earned.
     *
     * Carol mints AFTER every fee in this test has already accrued, so her checkpoint
     * excludes all of it and she is owed nothing. Bob then exits at age zero and
     * forfeits his whole unvested fee into the band. Carol -- who provided nothing
     * while those fees were earned -- collects a pro-rata slice of it once mature.
     *
     * It makes "deposit in front of a known early exit" a strategy: the capture costs
     * nothing but gas and the maturity it must be held for.
     */
    function test_aLateJoinerCapturesAForfeitItDidNotEarn() public {
        _mint(alice, 1_000e18, 1_000e18);
        vm.warp(block.timestamp + 3600);
        _trade(100e18, true);

        uint256 bobId = _mint(bob, 1_000e18, 1_000e18);
        _trade(100e18, true);

        // Every fee in this test is already accrued before Carol exists.
        uint256 carolId = _mint(carol, 1_000e18, 1_000e18);
        assertGt(lastShares, 0, "Carol is genuinely in the band");

        vm.recordLogs();
        (uint256 bobBase, uint256 bobQuote) = _exit(bob, bobId);
        (uint256 forfeited,, bool toProtocol, bool seen) = _forfeitFromLogs();
        assertTrue(seen);
        assertGt(bobBase + bobQuote, 0, "Bob's principal came back");
        assertFalse(toProtocol, "the band has other holders, so it redistributes");
        assertGt(forfeited, 0, "Bob forfeited something to redistribute");
        (, uint256 bobOwedBase, uint256 bobOwedQuote) = pool.positionView(bobId);
        assertEq(bobOwedBase + bobOwedQuote, 0, "a zero-age exit keeps no fee");

        // Let Carol mature so her own ramp cannot mask what she captured.
        vm.warp(block.timestamp + 3600);
        vm.prank(carol);
        (uint256 carolBase, uint256 carolQuote) = manager.collect(carolId, carol);

        assertEq(carolQuote, 0, "the fee legs are what the swaps produced");
        assertGt(carolBase, 0, "a late arrival captured a forfeit it was not present for");
        // Roughly half -- her share of `others`, Alice holding the rest.
        assertGt(carolBase * 3, forfeited, "and the slice is pro-rata, not dust");
    }

    /**
     * The capture is NOT free: realising it takes a full maturity, the same inventory
     * risk the ramp imposes on an honest provider.
     *
     * In v2 collecting early does not destroy it (collect never forfeits), it just pays
     * nothing yet; the capture keeps vesting on Carol's own clock. Withdrawing early is
     * what destroys it. So a time lock of one maturity adds nothing vesting does not
     * already impose.
     */
    function test_theCaptureCostsAFullMaturityToRealise() public {
        uint256 carolId = _captureSetup();

        // Carol collects IMMEDIATELY instead of waiting: nothing yet, and nothing lost.
        (uint256 capturedRaw,) = _rawBase(carolId);
        assertGt(capturedRaw, 0, "Carol holds a captured slice");
        vm.prank(carol);
        (uint256 nowBase, uint256 nowQuote) = manager.collect(carolId, carol);
        assertEq(nowBase + nowQuote, 0, "an age-zero capture realises nothing");
        (uint256 stillRaw,) = _rawBase(carolId);
        assertEq(stillRaw, capturedRaw, "and collecting early forfeited none of it");

        // Held to maturity, the whole capture is hers.
        vm.warp(block.timestamp + 600);
        vm.prank(carol);
        (uint256 laterBase,) = manager.collect(carolId, carol);
        assertEq(laterBase, capturedRaw, "a full maturity realises the capture");
    }

    function test_withdrawingTheCaptureEarlyForfeitsIt() public {
        uint256 carolId = _captureSetup();
        (uint256 capturedRaw,) = _rawBase(carolId);
        assertGt(capturedRaw, 0);

        vm.recordLogs();
        _exit(carol, carolId);
        (uint256 forfeited,,,) = _forfeitFromLogs();
        assertEq(forfeited, capturedRaw, "exiting at age zero sends the whole capture onward");

        vm.warp(block.timestamp + 3600);
        vm.prank(carol);
        (uint256 laterBase, uint256 laterQuote) = manager.collect(carolId, carol);
        assertEq(laterBase + laterQuote, 0, "nothing of it is left to claim");
    }

    /// Alice matures and earns; Bob joins, earns, exits at age zero; Carol joins between.
    function _captureSetup() internal returns (uint256 carolId) {
        _mint(alice, 1_000e18, 1_000e18);
        vm.warp(block.timestamp + 3600);
        _trade(100e18, true);
        uint256 bobId = _mint(bob, 1_000e18, 1_000e18);
        _trade(100e18, true);
        carolId = _mint(carol, 1_000e18, 1_000e18);
        _exit(bob, bobId); // forfeits into the band; Carol's accrued rises
    }

    function _rawBase(uint256 tokenId) internal view returns (uint256 b, uint256 q) {
        (IBandPool.BandView[] memory held, uint256 ob, uint256 oq) = pool.positionView(tokenId);
        b = ob;
        q = oq;
        for (uint256 i = 0; i < held.length; i++) {
            b += held[i].pendingBase;
            q += held[i].pendingQuote;
        }
    }

    /**
     * A sole LP in a band donates the forfeit to the protocol, not to peers. Opening a
     * fresh band therefore carries the harshest version of the ramp: there is nobody to
     * redistribute to, so an early exit's unvested fee leaves the pool's LPs entirely.
     */
    function test_soleLpForfeitsToTheProtocolNotToPeers() public {
        uint256 aliceId = _mint(alice, 1_000e18, 1_000e18);
        _trade(100e18, true);

        // A collect first: in v2 it forfeits nothing, so the protocol gets nothing yet.
        uint256 before = pool.protocolFeesBase() + pool.protocolFeesQuote();
        vm.prank(alice);
        manager.collect(aliceId, alice);
        assertEq(pool.protocolFeesBase() + pool.protocolFeesQuote(), before, "collect never forfeits");

        // Accrued to the pool, not pushed to feeTo: a token that refuses the protocol's
        // address must not be able to fail an LP's exit.
        vm.recordLogs();
        _exit(alice, aliceId);
        (,, bool toProtocol, bool seen) = _forfeitFromLogs();
        assertTrue(seen && toProtocol, "the event says where it went");
        assertGt(
            pool.protocolFeesBase() + pool.protocolFeesQuote(), before, "sole-LP forfeit leaves the pool"
        );
    }

    /// An exit settles the ramp there and then, so it cannot bank unvested fees for later.
    function test_exitSettlesTheRampAndTheForfeitWithIt() public {
        uint256 aliceId = _mint(alice, 1_000e18, 1_000e18);
        _mint(carol, 1_000e18, 1_000e18);
        _trade(100e18, true);

        _exit(alice, aliceId);

        // Nothing is left to claim later: the exit already ran the ramp.
        vm.warp(block.timestamp + 3600);
        vm.prank(alice);
        (uint256 vb, uint256 vq) = manager.collect(aliceId, alice);
        assertEq(vb + vq, 0, "no second bite");
    }
}
