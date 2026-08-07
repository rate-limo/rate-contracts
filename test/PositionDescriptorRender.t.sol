// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {PositionDescriptor} from "../src/swap/PositionDescriptor.sol";
import {PositionSVG} from "../src/swap/libraries/PositionSVG.sol";
import {IPool} from "../src/swap/interfaces/IPool.sol";

contract MockToken {
    string public symbol;
    uint8 public decimals;

    constructor(string memory s, uint8 d) {
        symbol = s;
        decimals = d;
    }
}

/// @dev A token that reverts on both metadata calls, to exercise the fallbacks.
contract HostileToken {
    function symbol() external pure returns (string memory) {
        revert("no symbol");
    }

    function decimals() external pure returns (uint8) {
        revert("no decimals");
    }
}

contract MockOrderbook {
    uint256 public price;
    bool public twapWorks;

    constructor(uint256 p, bool w) {
        price = p;
        twapWorks = w;
    }

    function twap(uint32) external view returns (uint256, uint32) {
        require(twapWorks, "no history");
        return (price, 600);
    }

    function lmp() external view returns (uint256) {
        require(price != 0, "no last price");
        return price;
    }
}

contract MockPool {
    address public base;
    address public quote;
    address public orderbook;
    IPool.Position internal _p;

    constructor(address b, address q, address ob, IPool.Position memory p) {
        base = b;
        quote = q;
        orderbook = ob;
        _p = p;
    }

    function getBaseQuote() external view returns (address, address) {
        return (base, quote);
    }

    function getPosition(uint256) external view returns (IPool.Position memory) {
        return _p;
    }
}

contract MockManager {
    address public pool;

    constructor(address p) {
        pool = p;
    }

    /// @dev Mirrors the real manager: an unknown id maps to the zero pool.
    function tokenPosition(uint256 tokenId) external view returns (address, uint256) {
        if (tokenId == 0) return (address(0), 0);
        return (pool, 1);
    }
}

contract PositionDescriptorRenderTest is Test {
    PositionDescriptor internal descriptor;
    MockToken internal weth;
    MockToken internal usdc;

    // Prices are 1e8-scaled, per Orderbook.sol (`amount * price / 1e8`).
    uint256 internal constant P_1800 = 1800e8;
    uint256 internal constant P_2600 = 2600e8;

    function setUp() public {
        descriptor = new PositionDescriptor();
        weth = new MockToken("WETH", 18);
        usdc = new MockToken("USDC", 6);
    }

    function _position(uint256 minPrice, uint256 maxPrice)
        internal
        pure
        returns (IPool.Position memory p)
    {
        p.minPrice = minPrice;
        p.maxPrice = maxPrice;
        p.slippageLimit = 500_000; // 0.5% of DENOM (1e8)
        p.baseAmount = 4.218e18;
        p.quoteAmount = 9_640.51e6;
        p.feeOwedBase = 0.0271e18;
        p.feeOwedQuote = 61.4832e6;
        p.active = true;
    }

    function _render(IPool.Position memory p, uint256 market, bool twapWorks)
        internal
        returns (string memory)
    {
        MockOrderbook ob = new MockOrderbook(market, twapWorks);
        MockPool pool = new MockPool(address(weth), address(usdc), address(ob), p);
        MockManager mgr = new MockManager(address(pool));
        return descriptor.tokenURI(address(mgr), 42);
    }

    function _dump(string memory tag, string memory uri) internal pure {
        console2.log(string.concat("<<<", tag, ">>>"));
        console2.log(uri);
        console2.log(string.concat("<<<END ", tag, ">>>"));
    }

    function test_render_inRange() public {
        string memory uri = _render(_position(P_1800, P_2600), 2214.37e8, true);
        _dump("IN_RANGE", uri);
        assertGt(bytes(uri).length, 1000);
    }

    function test_render_nearEdge() public {
        // 60 above the lower bound, on an 800-wide range => inside the 10% edge band.
        string memory uri = _render(_position(P_1800, P_2600), 1860e8, true);
        _dump("NEAR_EDGE", uri);
        assertGt(bytes(uri).length, 1000);
    }

    function test_render_outOfRange() public {
        string memory uri = _render(_position(P_1800, P_2600), 3120.5e8, true);
        _dump("OUT_OF_RANGE", uri);
        assertGt(bytes(uri).length, 1000);
    }

    /// @notice A pool with no TWAP history must still render, falling back to `lmp()`.
    function test_render_fallsBackToLastMatchedPrice() public {
        string memory uri = _render(_position(P_1800, P_2600), 2500e8, false);
        _dump("LMP_FALLBACK", uri);
        assertGt(bytes(uri).length, 1000);
    }

    /// @notice No oracle at all: the card degrades instead of reverting.
    function test_render_noOracle() public {
        string memory uri = _render(_position(P_1800, P_2600), 0, false);
        _dump("NO_ORACLE", uri);
        assertGt(bytes(uri).length, 1000);
    }

    function test_render_closedPosition() public {
        IPool.Position memory p = _position(P_1800, P_2600);
        p.active = false;
        p.baseAmount = 0;
        p.quoteAmount = 0;
        p.feeOwedBase = 0;
        p.feeOwedQuote = 0;
        string memory uri = _render(p, 2214.37e8, true);
        _dump("CLOSED", uri);
        assertGt(bytes(uri).length, 1000);
    }

    // ------------------------------------------------------------------
    // revert-safety edge cases
    // ------------------------------------------------------------------

    /// @notice Degenerate range (min == max) must not divide by zero.
    function test_render_degenerateRange() public {
        string memory uri = _render(_position(P_1800, P_1800), 1800e8, true);
        assertGt(bytes(uri).length, 1000);
    }

    /// @notice A token whose `symbol()`/`decimals()` revert must not brick `tokenURI`.
    function test_render_hostileToken() public {
        HostileToken bad = new HostileToken();
        IPool.Position memory p = _position(P_1800, P_2600);
        MockOrderbook ob = new MockOrderbook(2214.37e8, true);
        MockPool pool = new MockPool(address(bad), address(usdc), address(ob), p);
        MockManager mgr = new MockManager(address(pool));
        string memory uri = descriptor.tokenURI(address(mgr), 42);
        _dump("HOSTILE", uri);
        assertGt(bytes(uri).length, 1000);
    }

    /// @notice Worst case for the stat labels: both symbols at the 12-char sanitiser cap,
    ///         which is what actually decides whether the two columns collide.
    function test_render_longSymbols() public {
        MockToken longBase = new MockToken("WSTETHWETH12", 18);
        MockToken longQuote = new MockToken("USDCUSDTDAI9", 6);
        MockOrderbook ob = new MockOrderbook(2214.37e8, true);
        MockPool pool =
            new MockPool(address(longBase), address(longQuote), address(ob), _position(P_1800, P_2600));
        MockManager mgr = new MockManager(address(pool));
        string memory uri = descriptor.tokenURI(address(mgr), 42);
        _dump("LONG_SYMBOLS", uri);
        assertGt(bytes(uri).length, 1000);
    }

    /// @notice Sub-cent pairs must not collapse min and max to the same rendered string.
    function test_render_subCentPrices() public {
        string memory uri = _render(_position(823, 914), 870, true);
        _dump("SUB_CENT", uri);
        assertGt(bytes(uri).length, 1000);
    }

    /// @notice An unknown token id returns empty rather than reverting on empty return data.
    function test_render_unknownTokenId() public {
        MockOrderbook ob = new MockOrderbook(2214.37e8, true);
        MockPool pool = new MockPool(address(weth), address(usdc), address(ob), _position(P_1800, P_2600));
        MockManager mgr = new MockManager(address(pool));
        assertEq(descriptor.tokenURI(address(mgr), 0), "");
    }

    /// @notice An absurd price must clamp the marker rather than overflow.
    function test_render_extremePrice() public {
        string memory uri = _render(_position(P_1800, P_2600), type(uint256).max, true);
        assertGt(bytes(uri).length, 1000);
    }

    // ------------------------------------------------------------------
    // marker geometry
    // ------------------------------------------------------------------
    function test_markerBps_anchorsBandAt2000And8000() public view {
        // Exposed via the rendered params indirectly; assert the pure helper's contract
        // through a position whose market sits exactly on each bound.
        assertEq(_bps(1800e8, 2600e8, 1800e8), 2000);
        assertEq(_bps(1800e8, 2600e8, 2600e8), 8000);
        assertEq(_bps(1800e8, 2600e8, 2200e8), 5000);
        assertEq(_bps(1800e8, 2600e8, 0), 0);
        assertEq(_bps(1800e8, 2600e8, type(uint256).max), 10000);
    }

    function _bps(uint256 lo, uint256 hi, uint256 mkt) internal view returns (uint256) {
        return descriptor.markerBps(lo, hi, mkt);
    }
}
