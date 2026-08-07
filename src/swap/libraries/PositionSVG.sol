// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/// @title PositionSVG
/// @notice Pure on-chain renderer for ITER swap liquidity positions.
/// @dev Follows the house idiom of `src/svg/libraries/NFTSVG.sol`: a library of
///      `internal pure` builders taking a struct of pre-formatted strings, so the
///      descriptor contract owns every external read and this file can never
///      revert on a bad oracle.
///
///      Colors are the Monet **dark** ramp from `apps/web/app/globals.css`. NFT
///      viewers do not honour `prefers-color-scheme`, so the card commits to one
///      ground rather than shipping a media query that silently never fires.
///
///      Everything is assembled from the small `_text` / `_attr` builders below.
///      These are `internal`, so they inline into whatever contract calls
///      `render` — and this repo compiles without `viaIR` (`foundry.toml`), the
///      same constraint documented in `Pool.swap`. Long `abi.encodePacked` chains
///      that compile fine in isolation overrun the stack once inlined, so every
///      chain here stays short by construction.
library PositionSVG {
    // --- Monet dark tokens (globals.css `.dark`) ---
    string internal constant BG = "#09111D"; // --m-background
    string internal constant SURFACE_2 = "#172437"; // --m-surface-2
    string internal constant BORDER = "#23364A"; // --m-border
    string internal constant PRIMARY = "#5F93D6"; // --m-primary
    string internal constant MINT = "#4ADE9E"; // --m-logo
    string internal constant GOLD = "#E0B85B"; // --m-accent
    string internal constant ROSE = "#D06A6A"; // --m-error
    string internal constant TEXT = "#EEF3F8"; // --m-text-primary
    string internal constant TEXT_2 = "#9EB2C7"; // --m-text-secondary
    string internal constant TEXT_3 = "#70839A"; // --m-text-secondary-2

    string internal constant SANS = "Inter,system-ui,-apple-system,Helvetica,Arial,sans-serif";
    string internal constant MONO = "ui-monospace,SFMono-Regular,Menlo,monospace";

    // Range-bar geometry. The bar is a fixed window: the position's own range
    // always occupies the middle 60% of the track, so the band never changes
    // size and the eye reads the *marker* — where the market sits relative to
    // the range — which is the only thing that actually moves.
    uint256 internal constant BAR_X = 24;
    uint256 internal constant BAR_W = 282;

    uint8 internal constant STATE_IN_RANGE = 0;
    uint8 internal constant STATE_NEAR_EDGE = 1;
    uint8 internal constant STATE_OUT_OF_RANGE = 2;
    uint8 internal constant STATE_NO_ORACLE = 3;
    uint8 internal constant STATE_CLOSED = 4;

    struct Params {
        string pair; // "WETH / USDC"
        string baseSymbol;
        string quoteSymbol;
        // Symbols capped short for the stat labels. The 282px stat row holds two labels
        // that grow toward each other from opposite anchors, so an uncapped symbol makes
        // them collide in the middle. The title and the JSON keep the full symbol.
        string baseTag;
        string quoteTag;
        string minPrice;
        string maxPrice;
        string marketPrice;
        string baseAmount;
        string quoteAmount;
        string baseFees;
        string quoteFees;
        string slippage; // "0.5%"
        string tokenId;
        string poolShort; // "0x1234...cdef"
        string priceSource; // "TWAP 600s" | "LAST MATCH" | "--"
        uint8 state;
        uint256 markerBps; // 0..10000 across the drawn track
        bool hasMarket; // false => oracle unavailable, marker suppressed
    }

    function render(Params memory p) internal pure returns (string memory) {
        string memory head = string(
            abi.encodePacked(
                '<svg xmlns="http://www.w3.org/2000/svg" width="330" height="520"',
                ' viewBox="0 0 330 520" font-family="',
                SANS,
                '">',
                _defs(stateColor(p.state)),
                _ground()
            )
        );
        string memory body = string(abi.encodePacked(_header(p), _range(p), _stats(p)));
        return string(abi.encodePacked(head, body, _footer(p), "</svg>"));
    }

    // ------------------------------------------------------------------
    // defs + ground
    // ------------------------------------------------------------------
    function _defs(string memory tone) private pure returns (string memory) {
        return string(
            abi.encodePacked("<defs>", _bandGradient(), _glow(tone), _fade(), _grid(), "</defs>")
        );
    }

    function _bandGradient() private pure returns (string memory) {
        return string(
            abi.encodePacked(
                '<linearGradient id="band" x1="0" y1="0" x2="1" y2="0"><stop offset="0" stop-color="',
                MINT,
                '"/><stop offset="1" stop-color="',
                PRIMARY,
                '"/></linearGradient>'
            )
        );
    }

    function _glow(string memory tone) private pure returns (string memory) {
        return string(
            abi.encodePacked(
                '<radialGradient id="glow" cx="0.16" cy="0.05" r="0.85"><stop offset="0" stop-color="',
                tone,
                '" stop-opacity="0.18"/><stop offset="1" stop-color="',
                tone,
                '" stop-opacity="0"/></radialGradient>'
            )
        );
    }

    function _fade() private pure returns (string memory) {
        return string(
            abi.encodePacked(
                '<linearGradient id="fade" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="',
                BG,
                '" stop-opacity="0"/><stop offset="1" stop-color="',
                BG,
                '"/></linearGradient>'
            )
        );
    }

    /// @dev A survey grid, drawn only across the top of the card and then faded
    ///      out. The motif named the protocol before it was ITER; it is kept as
    ///      artwork, not as a reference to the old name.
    function _grid() private pure returns (string memory) {
        return string(
            abi.encodePacked(
                '<pattern id="grid" width="22" height="22" patternUnits="userSpaceOnUse">',
                '<path d="M22 0H0V22" fill="none" stroke="',
                BORDER,
                '" stroke-width="1"/></pattern>',
                '<clipPath id="card"><rect width="330" height="520" rx="26"/></clipPath>'
            )
        );
    }

    function _ground() private pure returns (string memory) {
        string memory inner = string(
            abi.encodePacked(
                '<g clip-path="url(#card)"><rect width="330" height="520" fill="',
                BG,
                '"/><rect width="330" height="300" fill="url(#grid)"/>',
                '<rect width="330" height="300" fill="url(#fade)"/>',
                '<rect width="330" height="520" fill="url(#glow)"/></g>'
            )
        );
        return string(
            abi.encodePacked(
                inner,
                '<rect x="0.5" y="0.5" width="329" height="519" rx="25.5" fill="none" stroke="',
                BORDER,
                '"/>'
            )
        );
    }

    // ------------------------------------------------------------------
    // header
    // ------------------------------------------------------------------
    function _header(Params memory p) private pure returns (string memory) {
        string memory eyebrow = string(
            abi.encodePacked('fill="', TEXT_3, '" font-size="9" letter-spacing="2.4"')
        );
        string memory title = string(
            abi.encodePacked(
                'fill="', TEXT, '" font-size="', _titleSize(bytes(p.pair).length), '" font-weight="600"'
            )
        );
        return string(
            abi.encodePacked(
                _text(24, 42, eyebrow, "ITER LIQUIDITY"),
                _text(24, 76, title, p.pair),
                _pill(stateColor(p.state), stateLabel(p.state))
            )
        );
    }

    /// @dev The title is anchored left with 282px of room. Measured against the rendered
    ///      output, this face runs about 0.62em per character, so the widest string that
    ///      fits is 282 / (0.62 * size). The tiers below hold that bound at every step;
    ///      worst case is two 13-char address fallbacks (29 chars), which clears at 15px.
    ///      A realistic pair ("WETH / USDC", 11 chars) stays at the full 23px.
    function _titleSize(uint256 len) private pure returns (string memory) {
        if (len <= 18) return "23";
        if (len <= 22) return "19";
        if (len <= 26) return "17";
        return "15";
    }

    function _pill(string memory tone, string memory label) private pure returns (string memory) {
        string memory shape = string(
            abi.encodePacked(
                '<rect x="24" y="94" width="120" height="24" rx="12" fill="',
                tone,
                '" fill-opacity="0.14" stroke="',
                tone,
                '" stroke-opacity="0.45"/><circle cx="40" cy="106" r="3.5" fill="',
                tone,
                '"/>'
            )
        );
        string memory attrs = string(
            abi.encodePacked(
                'fill="',
                tone,
                '" font-size="9.5" font-weight="600" letter-spacing="1.1" text-anchor="middle"'
            )
        );
        return string(abi.encodePacked(shape, _text(91, 110, attrs, label)));
    }

    // ------------------------------------------------------------------
    // price range
    // ------------------------------------------------------------------
    function _range(Params memory p) private pure returns (string memory) {
        string memory labels = string(
            abi.encodePacked(
                _text(24, 158, _labelAttr(false), "MIN PRICE"),
                _text(306, 158, _labelAttr(true), "MAX PRICE")
            )
        );
        string memory values = string(
            abi.encodePacked(
                _text(24, 180, _valueAttr(TEXT, "15", false), p.minPrice),
                _text(306, 180, _valueAttr(TEXT, "15", true), p.maxPrice)
            )
        );
        return string(abi.encodePacked(labels, values, _bar(p)));
    }

    function _bar(Params memory p) private pure returns (string memory) {
        string memory track = string(
            abi.encodePacked(
                '<rect x="24" y="214" width="282" height="10" rx="5" fill="',
                SURFACE_2,
                '"/><rect x="80" y="214" width="170" height="10" rx="5" fill="url(#band)"/>'
            )
        );
        return string(abi.encodePacked(track, _marker(p)));
    }

    function _marker(Params memory p) private pure returns (string memory) {
        if (!p.hasMarket) {
            string memory muted = string(
                abi.encodePacked('fill="', TEXT_3, '" font-size="10" text-anchor="middle"')
            );
            return _text(165, 250, muted, "market price unavailable");
        }
        uint256 x = BAR_X + (BAR_W * p.markerBps) / 10_000;
        string memory tone = stateColor(p.state);
        string memory needle = string(
            abi.encodePacked(
                '<g transform="translate(',
                Strings.toString(x),
                ',0)"><path d="M-5 200L5 200L0 208Z" fill="',
                tone,
                '"/><rect x="-1" y="206" width="2" height="26" rx="1" fill="',
                tone,
                '"/></g>'
            )
        );
        string memory caption = string(
            abi.encodePacked(
                'fill="', TEXT_2, '" font-size="10.5" font-family="', MONO, '" text-anchor="middle"'
            )
        );
        // Keep the caption inside the card even when the marker is pinned to an edge.
        uint256 labelX = x < 62 ? 62 : (x > 268 ? 268 : x);
        return string(abi.encodePacked(needle, _text(labelX, 250, caption, p.marketPrice)));
    }

    // ------------------------------------------------------------------
    // stats + footer
    // ------------------------------------------------------------------
    function _stats(Params memory p) private pure returns (string memory) {
        string memory rule =
            string(abi.encodePacked('<path d="M24 276H306" stroke="', BORDER, '"/>'));
        string memory deposits = string(
            abi.encodePacked(
                _cell(306, false, string(abi.encodePacked(p.baseTag, " DEPOSITED")), p.baseAmount),
                _cell(306, true, string(abi.encodePacked(p.quoteTag, " DEPOSITED")), p.quoteAmount)
            )
        );
        string memory fees = string(
            abi.encodePacked(
                _cell(360, false, string(abi.encodePacked(p.baseTag, " FEES OWED")), p.baseFees),
                _cell(360, true, string(abi.encodePacked(p.quoteTag, " FEES OWED")), p.quoteFees)
            )
        );
        string memory band = string(
            abi.encodePacked(
                _cell(414, false, "SLIPPAGE LIMIT", p.slippage),
                _cell(414, true, "PRICE SOURCE", p.priceSource)
            )
        );
        return string(abi.encodePacked(rule, deposits, fees, band));
    }

    function _cell(uint256 y, bool right, string memory label, string memory value)
        private
        pure
        returns (string memory)
    {
        uint256 x = right ? 306 : 24;
        return string(
            abi.encodePacked(
                _text(x, y, _labelAttr(right), label),
                _text(x, y + 21, _valueAttr(TEXT, "13.5", right), value)
            )
        );
    }

    function _footer(Params memory p) private pure returns (string memory) {
        string memory rule =
            string(abi.encodePacked('<path d="M24 462H306" stroke="', BORDER, '"/>'));
        string memory id =
            _text(24, 488, _valueAttr(TEXT_2, "10.5", false), string(abi.encodePacked("POSITION #", p.tokenId)));
        return string(
            abi.encodePacked(rule, id, _text(306, 488, _valueAttr(TEXT_3, "10.5", true), p.poolShort))
        );
    }

    // ------------------------------------------------------------------
    // primitives
    // ------------------------------------------------------------------
    function _text(uint256 x, uint256 y, string memory attrs, string memory content)
        private
        pure
        returns (string memory)
    {
        return string(
            abi.encodePacked(
                '<text x="',
                Strings.toString(x),
                '" y="',
                Strings.toString(y),
                '" ',
                attrs,
                ">",
                content,
                "</text>"
            )
        );
    }

    function _labelAttr(bool right) private pure returns (string memory) {
        return string(
            abi.encodePacked(
                'fill="',
                TEXT_3,
                '" font-size="8.5" letter-spacing="1.6"',
                right ? ' text-anchor="end"' : ""
            )
        );
    }

    function _valueAttr(string memory fill, string memory size, bool right)
        private
        pure
        returns (string memory)
    {
        return string(
            abi.encodePacked(
                'fill="',
                fill,
                '" font-size="',
                size,
                '" font-family="',
                MONO,
                right ? '" text-anchor="end"' : '"'
            )
        );
    }

    function stateColor(uint8 s) internal pure returns (string memory) {
        if (s == STATE_IN_RANGE) return MINT;
        if (s == STATE_NEAR_EDGE) return GOLD;
        if (s == STATE_OUT_OF_RANGE) return ROSE;
        return TEXT_3; // NO ORACLE / CLOSED
    }

    function stateLabel(uint8 s) internal pure returns (string memory) {
        if (s == STATE_IN_RANGE) return "IN RANGE";
        if (s == STATE_NEAR_EDGE) return "NEAR EDGE";
        if (s == STATE_OUT_OF_RANGE) return "OUT OF RANGE";
        if (s == STATE_NO_ORACLE) return "NO ORACLE";
        return "CLOSED";
    }
}
