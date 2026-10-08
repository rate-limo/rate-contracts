// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {V2Base} from "./V2Base.sol";
import {BandPositionManager} from "../../../src/swap/BandPositionManager.sol";
import {BandPool} from "../../../src/swap/BandPool.sol";
import {MockBase} from "../../../src/mock/MockBase.sol";
import {ExchangeOrderbook} from "../../../src/exchange/libraries/ExchangeOrderbook.sol";
import {PositionDescriptor} from "../../../src/swap/PositionDescriptor.sol";
import {IBandPool} from "../../../src/swap/interfaces/IBandPool.sol";
import {IBandPositionManager} from "../../../src/swap/interfaces/IBandPositionManager.sol";

/// @dev A token whose metadata calls revert, to exercise the descriptor's fallbacks.
contract SilentToken {
    function symbol() external pure returns (string memory) {
        revert("no symbol");
    }

    function decimals() external pure returns (uint8) {
        revert("no decimals");
    }
}

/// @dev A token whose symbol would break out of the JSON string and inject markup.
contract InjectingToken {
    function symbol() external pure returns (string memory) {
        return '"><script>x';
    }

    function decimals() external pure returns (uint8) {
        return 18;
    }
}

contract DeadOrderbook {
    function twap(uint32) external pure returns (uint256, uint32) {
        revert("no history");
    }
}

/// @dev The two reads the descriptor makes of a pool itself. Everything else comes
///      through the manager's `positionOf`.
contract StubPool {
    address public orderbook;
    uint256 public seedPrice;

    constructor(address ob, uint256 seed) {
        orderbook = ob;
        seedPrice = seed;
    }
}

/// @dev A manager answering `positionOf` with a position the real stack cannot produce.
///      Built in memory on every call: a struct holding a `BandView[]` cannot be copied
///      into storage on the legacy pipeline.
contract StubManager {
    address public pool;
    address public base;
    address public quote;

    constructor(address p, address b, address q) {
        pool = p;
        base = b;
        quote = q;
    }

    function positionOf(uint256 tokenId) external view returns (IBandPositionManager.PositionView memory v) {
        v.tokenId = tokenId;
        v.pool = pool;
        v.base = base;
        v.quote = quote;
        v.holder = address(0xA11CE);
        v.mintedAt = 1_700_000_000;
        v.bandMask = 1;
        v.bands = new IBandPool.BandView[](1);
        v.bands[0].band = 0;
        v.bands[0].spreadFrac = 1000000;
        v.bands[0].toleranceBuy = 100000;
        v.bands[0].toleranceSell = 100000;
        v.bands[0].feeMultiplier = 100000000;
        v.bands[0].open = true;
        v.bands[0].shares = 1e18;
        v.bands[0].bandShares = 4e18;
        v.bands[0].baseOwned = 4.218e18;
        v.bands[0].quoteOwned = 9_640.51e18;
        v.bands[0].pendingBase = 0.04e18;
        v.bands[0].vestedBase = 0.0271e18;
        v.bands[0].vestedNum = 68_000_000;
    }
}

contract RevertingDescriptor {
    function tokenURI(address, uint256) external pure returns (string memory) {
        revert("renderer is broken");
    }
}

/**
 * The v2 descriptor, against the real stack.
 *
 * One token is one position holding the whole ladder, so the card draws one ROW per band
 * the token holds, and the JSON carries one "Band i" trait per band. The suite decodes
 * the base64 rather than asserting on its length: a card that renders 4kB of the wrong
 * thing passes a length check, and every regression this file is meant to catch is a
 * content regression.
 *
 * `PositionDescriptor` is inherited so its pure formatters (`_fixed`, `_pct`,
 * `_shortAddress`) build the expected strings the same way the contract does.
 *
 * Replaces the v1 BandPositionDescriptor suite, whose card (one band, a bid/ask pair,
 * a forfeit cell, a ladder of rungs) no longer exists.
 */
contract V2DescriptorTest is V2Base, PositionDescriptor {
    PositionDescriptor internal renderer;
    uint256 internal id;

    /// Matches `POSITION_URI` in script/swap/RiseTestnetSwap.s.sol.
    string internal constant BASE_URI = "ipfs://iter-position/{id}.json";

    function setUp() public override {
        super.setUp();
        renderer = new PositionDescriptor();
        positionManager.setDescriptor(address(renderer));
        id = _mintBase(alice, _b(0, 1, 2), 500e18);
    }

    // ------------------------------------------------------------------ decoding

    function _jsonOf(uint256 tokenId) internal view returns (string memory) {
        return _decodeUri(positionManager.uri(tokenId));
    }

    function _decodeUri(string memory uri) internal pure returns (string memory) {
        return string(_b64(_after(uri, "data:application/json;base64,")));
    }

    function _svgOf(uint256 tokenId) internal view returns (string memory) {
        return _svgIn(_jsonOf(tokenId));
    }

    function _svgIn(string memory json) internal pure returns (string memory) {
        return string(_b64(_upTo(_after(json, "data:image/svg+xml;base64,"), '"')));
    }

    /// @dev Everything after the first occurrence of `marker`. Reverts if absent, so a
    ///      missing marker fails as a missing marker rather than as an empty decode.
    function _after(string memory hay, string memory marker) internal pure returns (string memory) {
        bytes memory h = bytes(hay);
        bytes memory m = bytes(marker);
        uint256 at = _indexOf(h, m);
        require(at != type(uint256).max, "marker not found");
        bytes memory out = new bytes(h.length - at - m.length);
        for (uint256 i = 0; i < out.length; i++) {
            out[i] = h[at + m.length + i];
        }
        return string(out);
    }

    function _upTo(string memory hay, string memory stop) internal pure returns (string memory) {
        bytes memory h = bytes(hay);
        uint256 at = _indexOf(h, bytes(stop));
        require(at != type(uint256).max, "terminator not found");
        bytes memory out = new bytes(at);
        for (uint256 i = 0; i < at; i++) {
            out[i] = h[i];
        }
        return string(out);
    }

    function _indexOf(bytes memory h, bytes memory n) internal pure returns (uint256) {
        if (n.length == 0 || n.length > h.length) return type(uint256).max;
        for (uint256 i = 0; i <= h.length - n.length; i++) {
            bool hit = true;
            for (uint256 j = 0; j < n.length; j++) {
                if (h[i + j] != n[j]) {
                    hit = false;
                    break;
                }
            }
            if (hit) return i;
        }
        return type(uint256).max;
    }

    function _count(string memory hay, string memory needle) internal pure returns (uint256 n) {
        bytes memory h = bytes(hay);
        bytes memory m = bytes(needle);
        for (uint256 i = 0; i + m.length <= h.length; i++) {
            bool hit = true;
            for (uint256 j = 0; j < m.length; j++) {
                if (h[i + j] != m[j]) {
                    hit = false;
                    break;
                }
            }
            if (hit) n++;
        }
    }

    function _has(string memory hay, string memory needle) internal pure returns (bool) {
        return _indexOf(bytes(hay), bytes(needle)) != type(uint256).max;
    }

    function _assertHas(string memory hay, string memory needle) internal pure {
        require(_has(hay, needle), string(abi.encodePacked("missing: ", needle)));
    }

    /// @dev Test-only base64 decoder. The contract encodes; nothing on-chain decodes.
    function _b64(string memory data) internal pure returns (bytes memory) {
        bytes memory d = bytes(data);
        if (d.length < 4) return new bytes(0);
        uint256 outLen = (d.length / 4) * 3;
        if (d[d.length - 1] == "=") outLen--;
        if (d[d.length - 2] == "=") outLen--;
        bytes memory out = new bytes(outLen);
        uint256 j;
        for (uint256 i = 0; i + 3 < d.length; i += 4) {
            uint256 n = (_sextet(d[i]) << 18) | (_sextet(d[i + 1]) << 12) | (_sextet(d[i + 2]) << 6)
                | _sextet(d[i + 3]);
            if (j < outLen) out[j++] = bytes1(uint8(n >> 16));
            if (j < outLen) out[j++] = bytes1(uint8((n >> 8) & 0xFF));
            if (j < outLen) out[j++] = bytes1(uint8(n & 0xFF));
        }
        return out;
    }

    function _sextet(bytes1 c) private pure returns (uint256) {
        uint8 x = uint8(c);
        if (x >= 65 && x <= 90) return x - 65; // A-Z
        if (x >= 97 && x <= 122) return uint256(x) - 71; // a-z
        if (x >= 48 && x <= 57) return uint256(x) + 4; // 0-9
        if (x == 43) return 62; // +
        if (x == 47) return 63; // /
        return 0; // padding
    }

    function _row(uint8 band) internal pure returns (string memory) {
        return string(abi.encodePacked(">B", vm.toString(uint256(band)), "</text>"));
    }

    // ---------------------------------------------------------------------- shape

    function test_uri_isASelfContainedDataUri() public view {
        _assertHas(positionManager.uri(id), "data:application/json;base64,");
        string memory json = _jsonOf(id);
        _assertHas(json, '{"name":"ITER LP ');
        _assertHas(json, '"image":"data:image/svg+xml;base64,');
        assertFalse(_has(json, "http"), "metadata reaches off-chain");
        _assertHas(_svgOf(id), "<svg xmlns=");
    }

    /// The fields `PositionDescriptor._json` writes, read back through a JSON parser.
    function test_uri_jsonCarriesTheDocumentedFields() public view {
        string memory json = _jsonOf(id);
        assertEq(vm.parseJsonString(json, ".name"), "ITER LP BASE/QUOTE #1");
        _assertHas(vm.parseJsonString(json, ".description"), "A 3-band liquidity position on BASE/QUOTE");
        _assertHas(vm.parseJsonString(json, ".image"), "data:image/svg+xml;base64,");

        string[12] memory traits = [
            "Pair", "Pool", "Bands", "Band 0", "Band 1", "Band 2",
            "Base owned", "Quote owned", "Claimable", "Vesting", "Vested", "Status"
        ];
        for (uint256 i = 0; i < traits.length; i++) {
            string memory key = string(abi.encodePacked(".attributes[", vm.toString(i), "].trait_type"));
            assertEq(vm.parseJsonString(json, key), traits[i]);
        }
        assertEq(vm.parseJsonString(json, ".attributes[0].value"), "BASE/QUOTE");
        assertEq(vm.parseJsonString(json, ".attributes[2].value"), "3");
        assertEq(vm.parseJsonString(json, ".attributes[6].value"), "1500 BASE", "base owned, summed over bands");
        assertEq(vm.parseJsonString(json, ".attributes[11].value"), "VESTING");
    }

    // ---------------------------------------------------------------------- rows

    function test_uri_drawsOneRowPerHeldBand() public view {
        string memory svg = _svgOf(id);
        for (uint8 i = 0; i < 3; i++) {
            assertEq(_count(svg, _row(i)), 1, "one row per band");
        }
        assertEq(_count(svg, _row(3)), 0);
        _assertHas(svg, "3 BANDS");
    }

    function test_uri_aRowNamesItsLiveToleranceAndMultiplier() public view {
        string memory svg = _svgOf(id);
        for (uint8 i = 0; i < 3; i++) {
            (uint32 tb,) = pool.bandTolerances(i);
            string memory terms = string(
                abi.encodePacked(
                    unicode"±", _pct(tb, 4), unicode" · ", _fixed(pool.bandFeeMultiplier(i), 8, 2), unicode"×"
                )
            );
            _assertHas(svg, terms);
        }
        _assertHas(svg, unicode"±0.1%");
    }

    /// Equal value in three bands: each row is a third.
    function test_uri_aRowsShareIsItsValueOverTheTokens() public view {
        string memory svg = _svgOf(id);
        assertEq(_count(svg, ">33.33%</text>"), 3);
    }

    /// Only the bands the token holds, not the pool's whole ladder.
    function test_uri_aTokenHoldingTwoOfThreeBandsDrawsTwoRows() public {
        uint256 two = _mintBase(bob, _b(0, 2), 1e18);
        string memory svg = _svgOf(two);
        assertEq(_count(svg, _row(0)), 1);
        assertEq(_count(svg, _row(1)), 0);
        assertEq(_count(svg, _row(2)), 1);
        _assertHas(svg, "2 BANDS");
    }

    /// `MAX_BANDS` is 8 and the row pitch is chosen so all eight fit.
    function test_uri_eightBandsFit() public {
        uint32[] memory fracs = new uint32[](8);
        uint32[] memory mults = new uint32[](8);
        uint8[] memory bands = new uint8[](8);
        for (uint8 i = 0; i < 8; i++) {
            fracs[i] = uint32(i + 1) * 1000000;
            mults[i] = 100000000;
            bands[i] = i;
        }
        pool.configureBands(fracs, mults);
        (uint256 eight,) = _mint(bob, bands, _fill(8, 1e18), _fill(8, 0));

        string memory json = _jsonOf(eight);
        assertEq(vm.parseJsonString(json, ".attributes[2].value"), "8");
        assertEq(vm.parseJsonString(json, ".attributes[10].trait_type"), "Band 7");
        string memory svg = _svgOf(eight);
        for (uint8 i = 0; i < 8; i++) {
            assertEq(_count(svg, _row(i)), 1, "every band drawn");
        }
        _assertHas(svg, "8 BANDS");
        // The eighth row sits above the amounts box: pitch 22 from y=205.
        _assertHas(svg, string(abi.encodePacked('y="', vm.toString(uint256(205 + 7 * 22)), '"')));
    }

    // ------------------------------------------------------------------- anchor

    /// The fixture's pair was listed long before `setUp`'s warp, so its oracle answers.
    function test_uri_labelsTheTwapAnchor() public view {
        string memory svg = _svgOf(id);
        _assertHas(svg, "TWAP 300s");
        _assertHas(svg, _fixed(pool.anchorPrice(), 8, 6));
    }

    /// A pair listed THIS block has no TWAP history, so the pool anchors on its listing
    /// price -- and the card has to say which of the two it drew.
    function test_uri_labelsTheListingPriceFallback() public {
        MockBase b = new MockBase("FRESH", "FRESH");
        matchingEngine.addPair(address(b), address(token2), 3e8, 0, address(b), ExchangeOrderbook.MatchingMode.PriceTimePriority);
        BandPool fresh = BandPool(poolFactory.getPool(address(b), address(token2)));
        b.mint(alice, 10e18);
        vm.startPrank(alice);
        b.approve(address(positionManager), type(uint256).max);
        IBandPositionManager.MintParams memory p = _params(_b(0), _u(10e18), _u(0), alice);
        p.pool = address(fresh);
        (uint256 freshId,) = positionManager.mint(p);
        vm.stopPrank();

        string memory svg = _svgOf(freshId);
        _assertHas(svg, "LISTING");
        _assertHas(svg, _fixed(fresh.seedPrice(), 8, 6));
        assertFalse(_has(svg, "TWAP"), "claimed a TWAP that does not exist");
    }

    // -------------------------------------------------------------- the ramp

    function test_uri_vestingThenActive() public {
        _assertHas(_svgOf(id), "VESTING");
        vm.warp(block.timestamp + 601);
        string memory json = _jsonOf(id);
        assertEq(vm.parseJsonString(json, ".attributes[11].value"), "ACTIVE");
        assertEq(vm.parseJsonString(json, ".attributes[10].value"), "100%");
    }

    function test_uri_noFeesSaysSoRatherThanDrawingThem() public {
        vm.warp(block.timestamp + 300); // the ramp moved, and nothing has accrued
        string memory svg = _svgOf(id);
        _assertHas(svg, "nothing accrued yet");
        assertFalse(_has(svg, "CLAIMABLE "), "drew a fee stack with nothing in it");
    }

    /// Claimable and vesting, each valued in quote at the anchor, as the card shows them.
    function test_uri_showsClaimableAndVestingFees() public {
        _buy(trader1, 10_000e18);
        vm.warp(block.timestamp + 380); // mid-ramp: the two halves render differently
        (uint256 cb, uint256 cq) = _claimable(id);
        (uint256 ab, uint256 aq) = _accrued(id);
        assertGt(cb, 0, "the ramp moved");
        assertGt(ab - cb, 0, "and some is still vesting");

        uint256 anchor = pool.anchorPrice();
        uint256 claim = cq + book.convert(anchor, cb, true);
        uint256 vest = (aq - cq) + book.convert(anchor, ab - cb, true);
        string memory svg = _svgOf(id);
        _assertHas(svg, string(abi.encodePacked("CLAIMABLE ", _fixed(claim, 18, 6))));
        _assertHas(svg, string(abi.encodePacked("VESTING ", _fixed(vest, 18, 6))));
    }

    // ------------------------------------------------------------------- states

    function test_uri_bandClosedTakesThePill() public {
        pool.setBandOpen(1, false); // this contract listed the pair, so it is the creator
        _assertHas(_svgOf(id), "BAND CLOSED");
    }

    /// Fully withdrawn but NOT burnt: the token still names its pool, so it renders the EMPTY card.
    function test_uri_emptyAfterAFullWithdrawal() public {
        _decreaseAll(alice, id, 10_000);
        string memory svg = _svgOf(id);
        _assertHas(svg, "EMPTY");
        _assertHas(svg, "0 BANDS");
    }

    /// Burnt: the manager forgets the pool, and the descriptor returns nothing at all.
    function test_uri_aBurntTokenRendersNothing() public {
        _decreaseAll(alice, id, 10_000);
        vm.prank(alice);
        positionManager.burn(id);
        assertEq(renderer.tokenURI(address(positionManager), id), "");
        assertEq(positionManager.uri(id), "");
    }

    /// Never minted: the same empty answer.
    function test_uri_anUnmintedIdRendersNothing() public view {
        assertEq(renderer.tokenURI(address(positionManager), 9_999), "");
    }

    // ------------------------------------------------------------------- wiring

    /// @dev `BandBaseSetup` initializes the manager with an EMPTY base URI, so both
    ///      fallback tests run against a manager carrying a real one.
    function _managerWithBaseUri() internal returns (BandPositionManager m) {
        m = new BandPositionManager();
        m.initialize(BASE_URI);
    }

    function test_uri_fallsBackToTheBaseUriWithNoDescriptor() public {
        BandPositionManager m = _managerWithBaseUri();
        assertEq(m.descriptor(), address(0));
        assertEq(m.uri(1), BASE_URI);
    }

    /// A reverting `uri()` renders as a blank tile on every marketplace, so the base URI
    /// is the better failure.
    function test_uri_survivesARevertingDescriptor() public {
        BandPositionManager m = _managerWithBaseUri();
        m.setDescriptor(address(new RevertingDescriptor()));
        assertEq(m.uri(1), BASE_URI);
    }

    function test_setDescriptor_isOwnerOnly() public {
        vm.prank(trader1);
        vm.expectRevert();
        positionManager.setDescriptor(address(1));
    }

    // ----------------------------------------- degradation the real stack cannot produce

    function _stubUri(address base_, address quote_, address book_, uint256 seed) internal returns (string memory) {
        StubPool p = new StubPool(book_, seed);
        return renderer.tokenURI(address(new StubManager(address(p), base_, quote_)), 42);
    }

    /// Neither a TWAP nor a listing price: a normal state for a fresh pair, not a reason
    /// to serve a blank tile.
    function test_uri_noAnchorDegradesInsteadOfReverting() public {
        string memory json = _decodeUri(_stubUri(address(token1), address(token2), address(new DeadOrderbook()), 0));
        vm.parseJson(json);
        assertEq(vm.parseJsonString(json, ".attributes[9].value"), "NO ANCHOR"); // one band: Status is the tenth trait
        _assertHas(_svgIn(json), ">--</text>");
    }

    /// A token whose `symbol()`/`decimals()` revert must not brick `tokenURI`.
    function test_uri_silentTokenFallsBackToItsAddress() public {
        address bad = address(new SilentToken());
        string memory json = _decodeUri(_stubUri(bad, address(token2), address(new DeadOrderbook()), 100e8));
        vm.parseJson(json);
        _assertHas(json, _shortAddress(bad));
    }

    /// An attacker-chosen symbol must not escape the JSON string or reach the SVG as
    /// markup. This is the assertion the sanitiser exists for.
    function test_uri_hostileSymbolIsSanitised() public {
        address evil = address(new InjectingToken());
        string memory json = _decodeUri(_stubUri(evil, address(token2), address(new DeadOrderbook()), 100e8));
        vm.parseJson(json); // parses, which it would not if the quote had escaped
        assertFalse(_has(json, "<script"), "markup reached the metadata");
        assertFalse(_has(_svgIn(json), "<script"), "markup reached the card");
        // What survives the allowlist is the bare letters of `"><script>x`.
        assertEq(vm.parseJsonString(json, ".attributes[0].value"), "scriptx/QUOTE");
    }
}
