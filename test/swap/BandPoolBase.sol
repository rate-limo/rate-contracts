// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {BandPool} from "../../src/swap/BandPool.sol";
import {IBandPool} from "../../src/swap/interfaces/IBandPool.sol";
import {BandSwapRouter} from "../../src/swap/BandSwapRouter.sol";

contract StubToken {
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

/// Prices 1:1 at any bound, so band tolerance does not distort the fee arithmetic
/// under test. Bound-dependent pricing belongs to the inventory work, not here.
contract StubOrderbook {
    uint256 public price = 100e8;

    /// The listing price the pool anchors to until the TWAP can answer.

    function lmp() external view returns (uint256) { return price; }


    function twap(uint32) external view returns (uint256, uint32) {
        return (price, 300);
    }

    function convert(uint256, uint256 amount, bool) external pure returns (uint256) {
        return amount;
    }
}

contract StubEngine {

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
    /// No slippage policy: the limit is the market spread alone, as on a pair the
    /// generator did not launch.
    address public incentive;
    address public feeTo = address(0xFEE);
    uint32 public poolFeeShare = 50000000; // 50%, the production value

    function feeOf(address, address, address, bool) external pure returns (uint32) {
        return 100000;
    } // 0.10%
}

abstract contract BandPoolBase is Test {
    BandPool pool;
    BandSwapRouter router;
    StubToken baseTok;
    StubToken quoteTok;
    StubOrderbook book;
    StubEngine eng;

    address creator = address(0xC0FFEE);
    address pm = address(0xBEEF);
    address taker = address(0xABCD);

    function setUp() public virtual {
        router = new BandSwapRouter();
        baseTok = new StubToken();
        quoteTok = new StubToken();
        book = new StubOrderbook();
        eng = new StubEngine();
        eng.setSwapRouter(address(router));
        pool = new BandPool();
        uint32[] memory t = new uint32[](2);
        uint32[] memory fm = new uint32[](2);
        for (uint256 _f = 0; _f < 2; _f++) fm[_f] = 100000000; // 1x, unless a test says otherwise
        // Fractions of the stub's 10% limit: 1% and 3% of it are 0.1% and 0.3%, the
        // absolute tolerances these suites were written against.
        t[0] = 1000000;
        t[1] = 3000000;
        pool.initialize(
            BandPool.InitParams({
                id: 1,
                base: address(baseTok),
                quote: address(quoteTok),
                orderbook: address(book),
                engine: address(eng),
                positionManager: pm,
                creator: creator,
                maturity: 600,
                spreadFracs: t,
                feeMultipliers: fm
            })
        );
        pool.syncLimit();
        eng.listPool(address(pool));

        quoteTok.mint(taker, 1_000_000e18);
        vm.startPrank(taker);
        quoteTok.approve(address(pool), type(uint256).max);
        quoteTok.approve(address(router), type(uint256).max);
        vm.stopPrank();
        vm.warp(1_000_000);
    }

    /// Token ids stand in for the manager's: the pool takes whatever id it is handed.
    uint256 internal _nextId = 1;

    /// A fresh position holding `liq` base in `band`, deposited as the manager would.
    function _addTo(uint8 band, uint256 liq) internal returns (uint256 id) {
        id = _nextId++;
        _topUp(id, band, liq);
    }

    /// A deposit into an existing position -- the v2 top-up, same token.
    function _topUp(uint256 id, uint8 band, uint256 liq) internal {
        baseTok.mint(pm, liq);
        vm.startPrank(pm);
        baseTok.approve(address(pool), type(uint256).max);
        baseTok.approve(address(router), type(uint256).max);
        vm.stopPrank();
        _increase(pool, id, band, liq, 0);
    }

    function _increase(BandPool p, uint256 id, uint8 band, uint256 baseAmt, uint256 quoteAmt)
        internal
        returns (uint128 shares)
    {
        uint8[] memory b = new uint8[](1);
        uint256[] memory ba = new uint256[](1);
        uint256[] memory qa = new uint256[](1);
        b[0] = band;
        ba[0] = baseAmt;
        qa[0] = quoteAmt;
        vm.prank(pm);
        (uint128[] memory minted,,) = p.increase(id, b, ba, qa);
        shares = minted[0];
    }

    /// Claim as the position manager: every position call on the pool is manager-only.
    function _collect(uint256 id, address recipient) internal returns (uint256 vestedBase, uint256 vestedQuote) {
        vm.prank(pm);
        return pool.collect(id, recipient);
    }

    /// Withdraw `bps` of every band the position holds.
    function _decrease(uint256 id, uint16 bps, address recipient) internal returns (uint256 b, uint256 q) {
        vm.prank(pm);
        return pool.decrease(id, bps, recipient);
    }

    /// The position's one band, for suites that hold a single band per id.
    function _view(uint256 id) internal view returns (IBandPool.BandView memory v) {
        (IBandPool.BandView[] memory all,,) = pool.positionView(id);
        if (all.length > 0) v = all[0];
    }

    /// What `collect` would pay now, per currency: vested owed plus the vested part of pending.
    function _claimable(uint256 id) internal view returns (uint256 cb, uint256 cq) {
        (IBandPool.BandView[] memory all, uint256 ob, uint256 oq) = pool.positionView(id);
        cb = ob;
        cq = oq;
        for (uint256 i = 0; i < all.length; i++) {
            cb += all[i].vestedBase;
            cq += all[i].vestedQuote;
        }
    }

    /// Everything accrued, vested or not.
    function _accrued(uint256 id) internal view returns (uint256 ab, uint256 aq) {
        (IBandPool.BandView[] memory all, uint256 ob, uint256 oq) = pool.positionView(id);
        ab = ob;
        aq = oq;
        for (uint256 i = 0; i < all.length; i++) {
            ab += all[i].pendingBase;
            aq += all[i].pendingQuote;
        }
    }

    function _swap(uint256 amountIn) internal {
        vm.prank(taker);
        router.swap(address(pool), amountIn, true, taker, 0);
    }

    function _positionHash(uint256 id) internal view returns (bytes32) {
        (IBandPool.BandView[] memory all, uint256 ob, uint256 oq) = pool.positionView(id);
        return keccak256(abi.encode(all, ob, oq));
    }

    /// Fees on a quote-to-base swap land in base, so these read the base leg.
    function _owedBase(uint256 id) internal view returns (uint256 v) {
        (v,) = _claimable(id);
    }

    function _rawOwedBase(uint256 id) internal view returns (uint256 v) {
        (v,) = _accrued(id);
    }

    /// A brand-new pool with `lps` positions in band 0, then one swap, returning its gas.
    function _freshPoolSwapGas(uint256 lps) internal returns (uint256) {
        BandPool p2 = new BandPool();
        uint32[] memory t = new uint32[](1);
        uint32[] memory fm = new uint32[](1);
        for (uint256 _f = 0; _f < 1; _f++) fm[_f] = 100000000; // 1x, unless a test says otherwise
        t[0] = 1000000;
        p2.initialize(
            BandPool.InitParams({
                id: 2,
                base: address(baseTok),
                quote: address(quoteTok),
                orderbook: address(book),
                engine: address(eng),
                positionManager: pm,
                creator: creator,
                maturity: 600,
                spreadFracs: t,
                feeMultipliers: fm
            })
        );
        p2.syncLimit();
        eng.listPool(address(p2));

        baseTok.mint(pm, 1_000e18 * lps);
        vm.startPrank(pm);
        baseTok.approve(address(p2), type(uint256).max);
        baseTok.approve(address(router), type(uint256).max);
        vm.stopPrank();
        for (uint256 i = 0; i < lps; i++) {
            _increase(p2, 1_000 + i, 0, 1_000e18, 0);
        }
        quoteTok.mint(taker, 1_000e18);
        vm.startPrank(taker);
        quoteTok.approve(address(p2), type(uint256).max);
        quoteTok.approve(address(router), type(uint256).max);
        vm.stopPrank();
        vm.prank(taker);
        uint256 g0 = gasleft();
        router.swap(address(p2), 1e18, true, taker, 0);
        return g0 - gasleft();
    }

    function _feeToBalance() internal view returns (uint256) {
        return baseTok.balanceOf(address(0xFEE));
    }
}
