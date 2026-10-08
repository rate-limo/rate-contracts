// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {BandPool} from "./BandPool.sol";
import {IBandPool} from "./interfaces/IBandPool.sol";
import {IBandPositionManager} from "./interfaces/IBandPositionManager.sol";
import {IOrderbook} from "../exchange/interfaces/IOrderbook.sol";
import {PositionSVG} from "./libraries/PositionSVG.sol";

interface IERC20Meta {
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
}

/// @title PositionDescriptor
/// @notice Fully on-chain `uri` for ITER band-pool LP tokens.
/// @dev One token is one position holding the whole band ladder, so the card and the
///      JSON describe every band the token holds -- never one band as if it were the
///      position. Pointed at by `BandPositionManager.setDescriptor`, so the artwork can
///      be revised without redeploying the token.
///
///      Every external read that crosses a trust boundary is wrapped: a `uri` that
///      reverts renders as a blank tile on every marketplace, so a dead oracle or a
///      non-standard ERC20 degrades to a labelled fallback instead.
contract PositionDescriptor {
    uint8 internal constant PRICE_DECIMALS = 8;
    /// @dev Fractions of `PoolBands.DENOM` (1e8); as a percentage that is value / 1e6.
    uint8 internal constant PCT_DECIMALS = 6;
    /// @dev Must equal `BandPool.TWAP_WINDOW`. Only the LABEL depends on it.
    uint32 internal constant TWAP_WINDOW = 300;
    uint256 internal constant DENOM = 1e8;
    uint256 internal constant BPS = 10_000;
    /// @dev Symbols in the two amount cells are capped so the label stays in its cell.
    uint256 internal constant LABEL_TAG_LEN = 10;

    /// @dev Bundled so no frame overruns the stack: this repo compiles without via-ir.
    struct Ctx {
        address pool;
        address book;
        string baseSymbol;
        string quoteSymbol;
        uint8 baseDecimals;
        uint8 quoteDecimals;
        uint256 anchor;
        uint8 source; // 0 none, 1 TWAP, 2 listing price
    }

    /// @dev Per-token totals, summed across the bands the token holds.
    struct Totals {
        uint256[] values; // per band, in quote units at the anchor
        uint256 value;
        uint256 baseOwned;
        uint256 quoteOwned;
        uint256 claimBase;
        uint256 claimQuote;
        uint256 vestBase;
        uint256 vestQuote;
        uint256 vestedWeighted; // sum of vestedNum x value
        bool anyClosed;
    }

    function tokenURI(address manager, uint256 tokenId) external view returns (string memory) {
        IBandPositionManager.PositionView memory pv = IBandPositionManager(manager).positionOf(tokenId);
        // Never minted, or burnt: ERC1155 has no `_requireOwned`, so the guard lives here.
        if (pv.pool == address(0)) return "";

        Ctx memory c;
        c.pool = pv.pool;
        c.baseSymbol = _symbol(pv.base);
        c.quoteSymbol = _symbol(pv.quote);
        c.baseDecimals = _decimals(pv.base);
        c.quoteDecimals = _decimals(pv.quote);
        (c.anchor, c.source, c.book) = _anchorPrice(pv.pool);

        Totals memory t = _totals(c, pv);
        PositionSVG.Params memory s = _params(c, pv, t, tokenId);
        string memory image = Base64.encode(bytes(PositionSVG.render(s)));
        return string(
            abi.encodePacked("data:application/json;base64,", Base64.encode(bytes(_json(c, pv, t, s, image))))
        );
    }

    // ------------------------------------------------------------------
    // totals
    // ------------------------------------------------------------------

    function _totals(Ctx memory c, IBandPositionManager.PositionView memory pv)
        internal
        view
        returns (Totals memory t)
    {
        uint256 n = pv.bands.length;
        t.values = new uint256[](n);
        t.claimBase = pv.owedBase;
        t.claimQuote = pv.owedQuote;
        for (uint256 i = 0; i < n; i++) {
            _addBand(c, t, pv.bands[i], i);
        }
    }

    function _addBand(Ctx memory c, Totals memory t, IBandPool.BandView memory b, uint256 i) internal view {
        uint256 v = b.quoteOwned + _toQuote(c, b.baseOwned);
        t.values[i] = v;
        t.value += v;
        t.baseOwned += b.baseOwned;
        t.quoteOwned += b.quoteOwned;
        t.claimBase += b.vestedBase;
        t.claimQuote += b.vestedQuote;
        t.vestBase += b.pendingBase - b.vestedBase;
        t.vestQuote += b.pendingQuote - b.vestedQuote;
        t.vestedWeighted += uint256(b.vestedNum) * v;
        if (!b.open) t.anyClosed = true;
    }

    /// Base amount in quote units at the anchor, through the orderbook's own conversion.
    /// Zero when there is no anchor or the book cannot convert.
    function _toQuote(Ctx memory c, uint256 baseAmount) internal view returns (uint256) {
        if (baseAmount == 0 || c.source == 0 || c.book == address(0)) return 0;
        try IOrderbook(c.book).convert(c.anchor, baseAmount, true) returns (uint256 q) {
            return q;
        } catch {
            return 0;
        }
    }

    /// A band's share of the token, in bps. Equal split when nothing could be valued.
    function _shareBps(Totals memory t, uint256 i) internal pure returns (uint256) {
        if (t.value == 0) return t.values.length == 0 ? 0 : BPS / t.values.length;
        return (t.values[i] * BPS) / t.value;
    }

    /// Value-weighted position along the vesting ramp, over DENOM.
    function _vestedNum(IBandPositionManager.PositionView memory pv, Totals memory t)
        internal
        pure
        returns (uint256 num)
    {
        if (t.value > 0) {
            num = t.vestedWeighted / t.value;
        } else if (pv.bands.length > 0) {
            for (uint256 i = 0; i < pv.bands.length; i++) {
                num += pv.bands[i].vestedNum;
            }
            num /= pv.bands.length;
        }
        if (num > DENOM) num = DENOM;
    }

    // ------------------------------------------------------------------
    // render params
    // ------------------------------------------------------------------

    function _params(
        Ctx memory c,
        IBandPositionManager.PositionView memory pv,
        Totals memory t,
        uint256 tokenId
    ) internal view returns (PositionSVG.Params memory s) {
        s.tokenId = Strings.toString(tokenId);
        s.pair = string(abi.encodePacked(c.baseSymbol, " / ", c.quoteSymbol));
        s.poolLine = _poolLine(c.pool, pv.bands.length);
        s.anchor = c.source == 0
            ? "--"
            : string(abi.encodePacked(_fixed(c.anchor, PRICE_DECIMALS, 6), unicode" · ", _sourceLabel(c.source)));
        s.rows = _rows(pv, t);
        s.baseTag = _truncate(c.baseSymbol, LABEL_TAG_LEN);
        s.quoteTag = _truncate(c.quoteSymbol, LABEL_TAG_LEN);
        s.baseOwned = _fixed(t.baseOwned, c.baseDecimals, 4);
        s.quoteOwned = _fixed(t.quoteOwned, c.quoteDecimals, 4);
        _fillFees(s, c, t);
        uint256 num = _vestedNum(pv, t);
        s.vestedPct = _pct(num, 2);
        s.vestedBps = (num * BPS) / DENOM;
        s.state = _state(pv, t, c.source != 0, num);
        s.since = _date(pv.mintedAt);
    }

    function _poolLine(address pool, uint256 n) internal pure returns (string memory) {
        return string(
            abi.encodePacked(_shortAddress(pool), unicode" · ", Strings.toString(n), n == 1 ? " BAND" : " BANDS")
        );
    }

    function _rows(IBandPositionManager.PositionView memory pv, Totals memory t)
        internal
        pure
        returns (PositionSVG.Row[] memory rows)
    {
        rows = new PositionSVG.Row[](pv.bands.length);
        for (uint256 i = 0; i < rows.length; i++) {
            uint256 bps = _shareBps(t, i);
            // bps x 10,000 puts the share on the DENOM scale `_pct` formats.
            rows[i] = PositionSVG.Row({band: pv.bands[i].band, terms: _terms(pv.bands[i]), pct: _pct(bps * 10_000, 2), bps: bps});
        }
    }

    /// "±0.02% · 1×", or "+0.02% / -0.03% · 1×" when the two sides differ.
    function _terms(IBandPool.BandView memory b) internal pure returns (string memory) {
        string memory tol = b.toleranceBuy == b.toleranceSell
            ? string(abi.encodePacked(unicode"±", _pct(b.toleranceBuy, 4)))
            : string(abi.encodePacked("+", _pct(b.toleranceBuy, 4), " / -", _pct(b.toleranceSell, 4)));
        return string(abi.encodePacked(tol, unicode" · ", _fixed(b.feeMultiplier, PRICE_DECIMALS, 2), unicode"×"));
    }

    /// Fees valued in quote at the anchor for the card; the JSON keeps both currencies.
    function _fillFees(PositionSVG.Params memory s, Ctx memory c, Totals memory t) internal view {
        uint256 claim = t.claimQuote + _toQuote(c, t.claimBase);
        uint256 vest = t.vestQuote + _toQuote(c, t.vestBase);
        s.hasFees = t.claimBase + t.claimQuote + t.vestBase + t.vestQuote > 0;
        s.claimBps = claim + vest == 0 ? 0 : (claim * BPS) / (claim + vest);
        s.feesTotal = string(abi.encodePacked(unicode"≈ ", _fixed(claim + vest, c.quoteDecimals, 6), " ", s.quoteTag));
        s.claimable = _fixed(claim, c.quoteDecimals, 6);
        s.vesting = _fixed(vest, c.quoteDecimals, 6);
    }

    /// @dev 0 active, 1 vesting, 2 a band closed, 3 no anchor, 4 empty -- ordered by
    ///      what the holder can still act on.
    function _state(IBandPositionManager.PositionView memory pv, Totals memory t, bool hasAnchor, uint256 num)
        internal
        pure
        returns (uint8)
    {
        if (pv.bands.length == 0) return PositionSVG.STATE_EMPTY;
        if (t.anyClosed) return PositionSVG.STATE_BAND_CLOSED;
        if (!hasAnchor) return PositionSVG.STATE_NO_ANCHOR;
        if (num < DENOM) return PositionSVG.STATE_VESTING;
        return PositionSVG.STATE_MATURE;
    }

    /// "YYYY-MM-DD" in UTC (Howard Hinnant's days-to-civil).
    function _date(uint64 ts) internal pure returns (string memory) {
        if (ts == 0) return "--";
        int256 z = int256(uint256(ts) / 86400) + 719468;
        int256 era = z / 146097;
        int256 doe = z - era * 146097;
        int256 yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
        int256 doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
        int256 mp = (5 * doy + 2) / 153;
        int256 d = doy - (153 * mp + 2) / 5 + 1;
        int256 m = mp < 10 ? mp + 3 : mp - 9;
        int256 y = yoe + era * 400 + (m <= 2 ? int256(1) : int256(0));
        // forge-lint: disable-next-line(unsafe-typecast)
        return string(abi.encodePacked(Strings.toString(uint256(y)), "-", _two(uint256(m)), "-", _two(uint256(d))));
    }

    function _two(uint256 v) private pure returns (string memory) {
        return v < 10 ? string(abi.encodePacked("0", Strings.toString(v))) : Strings.toString(v);
    }

    // ------------------------------------------------------------------
    // metadata
    // ------------------------------------------------------------------

    function _json(
        Ctx memory c,
        IBandPositionManager.PositionView memory pv,
        Totals memory t,
        PositionSVG.Params memory s,
        string memory image
    ) internal pure returns (string memory) {
        string memory pair = string(abi.encodePacked(c.baseSymbol, "/", c.quoteSymbol));
        string memory head = string(
            abi.encodePacked(
                '{"name":"ITER LP ', pair, " #", s.tokenId, '","description":"', _description(pair, pv.bands.length)
            )
        );
        return string(
            abi.encodePacked(
                head,
                '","image":"data:image/svg+xml;base64,',
                image,
                '","attributes":[',
                _headTraits(pair, s, pv.bands.length),
                _bandTraits(s),
                _tailTraits(c, t, s),
                "]}"
            )
        );
    }

    function _description(string memory pair, uint256 n) internal pure returns (string memory) {
        return string(
            abi.encodePacked(
                "A ",
                Strings.toString(n),
                "-band liquidity position on ",
                pair,
                ". Each band quotes a fraction of the pair's slippage limit around the orderbook's 300s TWAP; this token holds all of them.",
                " Fees vest on a ramp: collecting pays the vested part and never forfeits the rest. Rendered on-chain."
            )
        );
    }

    function _headTraits(string memory pair, PositionSVG.Params memory s, uint256 n)
        internal
        pure
        returns (string memory)
    {
        return string(
            abi.encodePacked(
                _trait("Pair", pair, true),
                _trait("Pool", _firstWord(s.poolLine), true),
                _trait("Bands", Strings.toString(n), true)
            )
        );
    }

    function _bandTraits(PositionSVG.Params memory s) internal pure returns (string memory out) {
        for (uint256 i = 0; i < s.rows.length; i++) {
            PositionSVG.Row memory r = s.rows[i];
            out = string(
                abi.encodePacked(
                    out,
                    _trait(
                        string(abi.encodePacked("Band ", Strings.toString(r.band))),
                        string(abi.encodePacked(r.terms, unicode" · ", r.pct)),
                        true
                    )
                )
            );
        }
    }

    function _tailTraits(Ctx memory c, Totals memory t, PositionSVG.Params memory s)
        internal
        pure
        returns (string memory)
    {
        string memory owned = string(
            abi.encodePacked(
                _trait("Base owned", _amount(t.baseOwned, c.baseDecimals, c.baseSymbol), true),
                _trait("Quote owned", _amount(t.quoteOwned, c.quoteDecimals, c.quoteSymbol), true)
            )
        );
        string memory fees = string(
            abi.encodePacked(
                _trait("Claimable", _pairAmount(c, t.claimBase, t.claimQuote), true),
                _trait("Vesting", _pairAmount(c, t.vestBase, t.vestQuote), true)
            )
        );
        return string(
            abi.encodePacked(
                owned, fees, _trait("Vested", s.vestedPct, true), _trait("Status", PositionSVG.stateLabel(s.state), false)
            )
        );
    }

    function _amount(uint256 v, uint8 decimals_, string memory sym) internal pure returns (string memory) {
        return string(abi.encodePacked(_fixed(v, decimals_, 6), " ", sym));
    }

    function _pairAmount(Ctx memory c, uint256 b, uint256 q) internal pure returns (string memory) {
        return string(
            abi.encodePacked(
                _amount(b, c.baseDecimals, c.baseSymbol), unicode" · ", _amount(q, c.quoteDecimals, c.quoteSymbol)
            )
        );
    }

    /// The pool's short address, i.e. `poolLine` up to its first space.
    function _firstWord(string memory s) internal pure returns (string memory) {
        bytes memory b = bytes(s);
        uint256 n;
        while (n < b.length && b[n] != " ") n++;
        bytes memory out = new bytes(n);
        for (uint256 i; i < n; ++i) {
            out[i] = b[i];
        }
        return string(out);
    }

    function _trait(string memory key, string memory value, bool comma) private pure returns (string memory) {
        return string(abi.encodePacked('{"trait_type":"', key, '","value":"', value, comma ? '"},' : '"}'));
    }

    // ------------------------------------------------------------------
    // safe external reads
    // ------------------------------------------------------------------
    /// @notice The price the pool's bands hang off, mirroring `BandPool._anchor`.
    /// @dev That function is `private`, so this reproduces its ladder rather than calling
    ///      it: the TWAP first, then the listing price the pool was seeded with, then
    ///      nothing. It differs in one deliberate way — `_anchor` reverts with
    ///      `NoAnchorPrice` when both are empty, and here that must be a labelled "--"
    ///      instead, because a pool that cannot yet price is a normal state for a fresh
    ///      pair and not a reason to render a blank tile.
    /// @return price The anchor, 1e8-scaled.
    /// @return source 0 unavailable, 1 TWAP, 2 listing price.
    /// @return book The pair's orderbook, which also values base in quote.
    function _anchorPrice(address pool) internal view returns (uint256 price, uint8 source, address book) {
        try BandPool(pool).orderbook() returns (address b) {
            book = b;
        } catch {
            return (0, 0, address(0));
        }
        if (book != address(0)) {
            try IOrderbook(book).twap(TWAP_WINDOW) returns (uint256 twap, uint32) {
                if (twap != 0) return (twap, 1, book);
            } catch {}
        }
        try BandPool(pool).seedPrice() returns (uint256 seed) {
            if (seed != 0) return (seed, 2, book);
        } catch {}
        return (0, 0, book);
    }

    function _sourceLabel(uint8 source) internal pure returns (string memory) {
        if (source == 1) return string(abi.encodePacked("TWAP ", Strings.toString(TWAP_WINDOW), "s"));
        if (source == 2) return "LISTING";
        return "--";
    }

    function _decimals(address token) internal view returns (uint8) {
        try IERC20Meta(token).decimals() returns (uint8 d) {
            return d > 36 ? 36 : d;
        } catch {
            return 18;
        }
    }

    /// @dev `symbol()` is optional in ERC20 and is `bytes32` on some legacy tokens, so a
    ///      failed read falls back to a truncated address. The result is also sanitised:
    ///      an attacker-chosen symbol containing `"` or `<` would otherwise break out of
    ///      the JSON string or inject markup into the SVG.
    function _symbol(address token) internal view returns (string memory) {
        try IERC20Meta(token).symbol() returns (string memory sym) {
            string memory clean = _sanitize(sym);
            if (bytes(clean).length != 0) return clean;
        } catch {}
        return _shortAddress(token);
    }

    function _sanitize(string memory s) internal pure returns (string memory) {
        bytes memory input = bytes(s);
        uint256 n = input.length > 12 ? 12 : input.length;
        bytes memory buf = new bytes(n);
        uint256 k;
        for (uint256 i; i < n; ++i) {
            if (_isSafeChar(input[i])) {
                buf[k] = input[i];
                ++k;
            }
        }
        bytes memory out = new bytes(k);
        for (uint256 i; i < k; ++i) {
            out[i] = buf[i];
        }
        return string(out);
    }

    function _isSafeChar(bytes1 ch) private pure returns (bool) {
        return (ch >= 0x30 && ch <= 0x39) // 0-9
            || (ch >= 0x41 && ch <= 0x5A) // A-Z
            || (ch >= 0x61 && ch <= 0x7A) // a-z
            || ch == 0x20 || ch == 0x2E || ch == 0x2D || ch == 0x5F; // space . - _
    }

    function _truncate(string memory s, uint256 max) internal pure returns (string memory) {
        bytes memory input = bytes(s);
        if (input.length <= max) return s;
        bytes memory out = new bytes(max);
        for (uint256 i; i < max; ++i) {
            out[i] = input[i];
        }
        return string(out);
    }

    function _shortAddress(address a) internal pure returns (string memory) {
        bytes memory full = bytes(Strings.toHexString(a)); // "0x" + 40 chars
        bytes memory out = new bytes(13);
        for (uint256 i; i < 6; ++i) {
            out[i] = full[i];
        }
        out[6] = ".";
        out[7] = ".";
        out[8] = ".";
        for (uint256 i; i < 4; ++i) {
            out[9 + i] = full[38 + i];
        }
        return string(out);
    }

    // ------------------------------------------------------------------
    // number formatting
    // ------------------------------------------------------------------
    /// @notice A DENOM-scaled fraction as a percentage string, e.g. 750000 -> "0.750%".
    function _pct(uint256 denomScaled, uint8 maxFrac) internal pure returns (string memory) {
        return string(abi.encodePacked(_fixed(denomScaled, PCT_DECIMALS, maxFrac), "%"));
    }

    /// @notice Renders `value` scaled by `10**decimals_` with at most `maxFrac`
    ///         fractional digits and no trailing zeros.
    function _fixed(uint256 value, uint8 decimals_, uint8 maxFrac)
        internal
        pure
        returns (string memory)
    {
        if (decimals_ > 36) decimals_ = 36;
        if (decimals_ == 0) return Strings.toString(value);
        uint256 unit = 10 ** uint256(decimals_);
        string memory whole = Strings.toString(value / unit);
        string memory frac = _frac(value % unit, decimals_, maxFrac);
        if (bytes(frac).length == 0) return whole;
        return string(abi.encodePacked(whole, ".", frac));
    }

    /// @dev Fractional digits, zero-padded on the left to `decimals_` places and stripped
    ///      of trailing zeros. Trailing zeros are removed arithmetically (dividing the
    ///      value and the place count together) so the padding stays correct without any
    ///      buffer surgery: 0.050 at 3 places becomes 5 at 2 places, i.e. "05".
    function _frac(uint256 frac, uint8 decimals_, uint8 maxFrac)
        private
        pure
        returns (string memory)
    {
        if (frac == 0 || maxFrac == 0) return "";
        if (decimals_ > maxFrac) {
            frac /= 10 ** uint256(decimals_ - maxFrac);
            decimals_ = maxFrac;
        }
        if (frac == 0) return "";
        while (frac % 10 == 0) {
            frac /= 10;
            --decimals_;
        }
        bytes memory digits = bytes(Strings.toString(frac));
        bytes memory out = new bytes(decimals_);
        uint256 pad = out.length - digits.length;
        for (uint256 i; i < pad; ++i) {
            out[i] = "0";
        }
        for (uint256 i; i < digits.length; ++i) {
            out[pad + i] = digits[i];
        }
        return string(out);
    }
}
