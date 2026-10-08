// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/// @title PositionSVG
/// @notice Pure on-chain renderer for ITER band-pool LP tokens.
/// @dev One token is one position and holds the WHOLE band ladder, so the card draws
///      every band the token holds: a stacked distribution bar, then one row per band
///      with its live tolerance, fee multiplier and share of the position's value.
///
///      Shares cannot be summed across bands -- each band is its own share pool -- so a
///      band's percentage is its VALUE at the anchor over the token's total value, and
///      the stacked bar uses the same widths. The descriptor computes those; this file
///      only lays them out.
///
///      Row pitch is `min(34, 176 / n)`, which fits all `MAX_BANDS` (8) above the fee
///      block. Per-band bid/ask is not drawn: eight pairs of prices do not fit.
///
///      Colors are the Monet dark ramp from `apps/web/app/globals.css`. NFT viewers do
///      not honour `prefers-color-scheme`, so the card commits to one ground.
///
///      `render` is `public` so this is a separately deployed, linked library: inlined,
///      its builders would push `PositionDescriptor` past EIP-170. Every
///      `abi.encodePacked` chain stays short, because this repo compiles without via-ir.
library PositionSVG {
    string internal constant BG = "#09111D";
    string internal constant SURFACE_2 = "#172437";
    string internal constant BORDER = "#23364A";
    string internal constant MINT = "#4ADE9E";
    string internal constant GOLD = "#E0B85B";
    string internal constant ROSE = "#D06A6A";
    string internal constant TEXT = "#EEF3F8";
    string internal constant TEXT_2 = "#9EB2C7";
    string internal constant TEXT_3 = "#70839A";

    string internal constant SANS = "Inter,system-ui,-apple-system,Helvetica,Arial,sans-serif";
    string internal constant MONO = "ui-monospace,SFMono-Regular,Menlo,monospace";

    uint256 internal constant X = 22;
    uint256 internal constant W = 286;
    uint256 internal constant ROW0_Y = 205;
    uint256 internal constant ROWS_H = 176;
    uint256 internal constant MAX_PITCH = 34;
    uint256 internal constant BOX_MIN_Y = 312;
    uint256 internal constant BPS = 10_000;

    uint8 internal constant STATE_MATURE = 0;
    uint8 internal constant STATE_VESTING = 1;
    uint8 internal constant STATE_BAND_CLOSED = 2;
    uint8 internal constant STATE_NO_ANCHOR = 3;
    uint8 internal constant STATE_EMPTY = 4;

    struct Row {
        uint8 band;
        string terms; // "±0.020% · 1×"
        string pct; // "33.33%"
        uint256 bps; // share of the token's value, 0..10000
    }

    struct Params {
        string tokenId;
        string pair; // "BASE / QUOTE"
        string poolLine; // "0xdc36…96bb · 3 BANDS"
        string anchor; // "1.02 · TWAP 300s" or "--"
        Row[] rows;
        string baseTag;
        string quoteTag;
        string baseOwned;
        string quoteOwned;
        string feesTotal; // "≈ 1.23 USDC"
        string claimable;
        string vesting;
        uint256 claimBps; // claimable share of the fee total, 0..10000
        bool hasFees;
        string vestedPct;
        uint256 vestedBps;
        uint8 state;
        string since; // "2026-09-25"
    }

    function render(Params memory p) public pure returns (string memory) {
        string memory head = string(
            abi.encodePacked(
                '<svg xmlns="http://www.w3.org/2000/svg" width="330" height="560" viewBox="0 0 330 560">',
                '<rect x="0.5" y="0.5" width="329" height="559" rx="18" fill="',
                BG,
                '" stroke="',
                BORDER,
                '"/>',
                _header(p)
            )
        );
        uint256 boxY = _boxY(p.rows.length);
        return string(
            abi.encodePacked(head, _distribution(p), _rows(p), _amounts(p, boxY), _fees(p, boxY + 64), _footer(p), "</svg>")
        );
    }

    // ------------------------------------------------------------------ layout

    function pitch(uint256 n) internal pure returns (uint256) {
        if (n == 0) return MAX_PITCH;
        uint256 h = ROWS_H / n;
        return h < MAX_PITCH ? h : MAX_PITCH;
    }

    function _boxY(uint256 n) private pure returns (uint256) {
        if (n == 0) return BOX_MIN_Y;
        uint256 y = ROW0_Y + (n - 1) * pitch(n) + 19;
        return y > BOX_MIN_Y ? y : BOX_MIN_Y;
    }

    /// Band i's tint: the primary blue, darkening down the ladder.
    function bandColor(uint8 i) internal pure returns (string memory) {
        if (i == 0) return "#5F93D6";
        if (i == 1) return "#4F80BE";
        if (i == 2) return "#426FA7";
        if (i == 3) return "#375F90";
        if (i == 4) return "#2E517B";
        if (i == 5) return "#274567";
        if (i == 6) return "#213A56";
        return "#1C3147";
    }

    // ------------------------------------------------------------------ blocks

    function _header(Params memory p) private pure returns (string memory) {
        string memory top = string(
            abi.encodePacked(
                _text(X, 34, TEXT_3, "10", false, "ITER LP"),
                _text(X + W, 34, TEXT_3, "10", true, string(abi.encodePacked("#", p.tokenId))),
                _title(p.pair),
                _text(X, 90, TEXT_3, "10", false, p.poolLine)
            )
        );
        return string(
            abi.encodePacked(
                top,
                _rect(X, 104, W, 30, 8, SURFACE_2),
                _text(34, 123, TEXT_2, "10", false, "ANCHOR"),
                _text(296, 123, TEXT, "10.5", true, p.anchor),
                _text(X, 160, TEXT_3, "10", false, "DISTRIBUTION")
            )
        );
    }

    function _title(string memory pair) private pure returns (string memory) {
        uint256 len = bytes(pair).length;
        string memory size = len <= 16 ? "24" : len <= 21 ? "19" : "15";
        return string(
            abi.encodePacked(
                '<text x="22" y="70" fill="', TEXT, '" font-size="', size, '" font-family="', SANS,
                '" font-weight="700">', pair, "</text>"
            )
        );
    }

    /// The stacked bar: one segment per band, 2px gaps, clipped to a pill.
    function _distribution(Params memory p) private pure returns (string memory out) {
        out = string(
            abi.encodePacked(
                '<clipPath id="d"><rect x="22" y="168" width="286" height="10" rx="5"/></clipPath>',
                _rect(X, 168, W, 10, 5, SURFACE_2),
                '<g clip-path="url(#d)">'
            )
        );
        uint256 n = p.rows.length;
        uint256 gaps = n > 1 ? (n - 1) * 2 : 0;
        uint256 x = X;
        for (uint256 i = 0; i < n; i++) {
            uint256 w = ((W - gaps) * p.rows[i].bps) / BPS;
            // The last segment takes whatever flooring left over, so the bar fills its
            // track instead of stopping a few pixels short.
            if (i == n - 1 && X + W > x) w = X + W - x;
            if (w > 0) out = string(abi.encodePacked(out, _rect(x, 168, w, 10, 0, bandColor(p.rows[i].band))));
            x += w + 2;
        }
        out = string(abi.encodePacked(out, "</g>"));
    }

    function _rows(Params memory p) private pure returns (string memory out) {
        uint256 h = pitch(p.rows.length);
        for (uint256 i = 0; i < p.rows.length; i++) {
            out = string(abi.encodePacked(out, _row(p.rows[i], ROW0_Y + i * h)));
        }
    }

    function _row(Row memory r, uint256 y) private pure returns (string memory) {
        string memory label = string(abi.encodePacked("B", Strings.toString(r.band)));
        string memory texts = string(
            abi.encodePacked(
                _text(X, y, TEXT, "10", false, label),
                _text(48, y, TEXT_2, "10", false, r.terms),
                _text(X + W, y, TEXT, "10", true, r.pct)
            )
        );
        return string(
            abi.encodePacked(
                texts, _rect(X, y + 5, W, 4, 2, SURFACE_2), _rect(X, y + 5, (W * r.bps) / BPS, 4, 2, bandColor(r.band))
            )
        );
    }

    function _amounts(Params memory p, uint256 y) private pure returns (string memory) {
        return string(
            abi.encodePacked(
                _cell(X, y, p.baseTag, p.baseOwned), _cell(169, y, p.quoteTag, p.quoteOwned)
            )
        );
    }

    function _cell(uint256 x, uint256 y, string memory label, string memory value)
        private
        pure
        returns (string memory)
    {
        return string(
            abi.encodePacked(
                _rect(x, y, 139, 44, 10, SURFACE_2),
                _text(x + 12, y + 17, TEXT_3, "9.5", false, label),
                _text(x + 12, y + 35, TEXT, "13", false, value)
            )
        );
    }

    /// Fee stack (claimable in mint over vesting in gold), then the vesting ramp.
    function _fees(Params memory p, uint256 y) private pure returns (string memory) {
        string memory stack;
        uint256 vestY;
        if (p.hasFees) {
            stack = string(
                abi.encodePacked(
                    _text(X, y, TEXT_3, "10", false, "FEES"),
                    _text(X + W, y, TEXT, "10", true, p.feesTotal),
                    _rect(X, y + 8, W, 6, 3, GOLD),
                    _rect(X, y + 8, (W * p.claimBps) / BPS, 6, 3, MINT),
                    _text(X, y + 30, MINT, "9.5", false, string(abi.encodePacked("CLAIMABLE ", p.claimable))),
                    _text(X + W, y + 30, GOLD, "9.5", true, string(abi.encodePacked("VESTING ", p.vesting)))
                )
            );
            vestY = y + 54;
        } else {
            stack = string(
                abi.encodePacked(
                    _text(X, y, TEXT_3, "10", false, "FEES"),
                    _text(X + W, y, TEXT_3, "10", true, "nothing accrued yet"),
                    _rect(X, y + 8, W, 6, 3, SURFACE_2)
                )
            );
            vestY = y + 38;
        }
        string memory tone = p.vestedBps >= BPS ? MINT : GOLD;
        return string(
            abi.encodePacked(
                stack,
                _text(X, vestY, TEXT_3, "10", false, "VESTED"),
                _text(X + W, vestY, tone, "10", true, p.vestedPct),
                _rect(X, vestY + 8, W, 6, 3, SURFACE_2),
                _rect(X, vestY + 8, (W * p.vestedBps) / BPS, 6, 3, tone)
            )
        );
    }

    function _footer(Params memory p) private pure returns (string memory) {
        string memory label = stateLabel(p.state);
        string memory tone = stateColor(p.state);
        // Mono at 9.5px is ~5.8px per glyph; 22px of padding either side of the label.
        uint256 w = bytes(label).length * 6 + 22;
        return string(
            abi.encodePacked(
                '<rect x="22" y="520" width="', Strings.toString(w), '" height="18" rx="9" fill="', tone,
                '" fill-opacity="0.14"/>',
                _textMid(X + w / 2, tone, label),
                _text(X + W, 532, TEXT_3, "9.5", true, string(abi.encodePacked("SINCE ", p.since)))
            )
        );
    }

    // ------------------------------------------------------------------ builders

    function _rect(uint256 x, uint256 y, uint256 w, uint256 h, uint256 rx, string memory fill)
        private
        pure
        returns (string memory)
    {
        string memory pos = string(
            abi.encodePacked('<rect x="', Strings.toString(x), '" y="', Strings.toString(y), '" width="', Strings.toString(w))
        );
        return string(
            abi.encodePacked(
                pos, '" height="', Strings.toString(h), '" rx="', Strings.toString(rx), '" fill="', fill, '"/>'
            )
        );
    }

    function _text(uint256 x, uint256 y, string memory fill, string memory size, bool right, string memory content)
        private
        pure
        returns (string memory)
    {
        string memory attrs = string(
            abi.encodePacked(
                '<text x="', Strings.toString(x), '" y="', Strings.toString(y), '" fill="', fill, '" font-size="', size
            )
        );
        return string(
            abi.encodePacked(
                attrs, '" font-family="', MONO, right ? '" text-anchor="end">' : '">', content, "</text>"
            )
        );
    }

    function _textMid(uint256 x, string memory fill, string memory content) private pure returns (string memory) {
        return string(
            abi.encodePacked(
                '<text x="', Strings.toString(x), '" y="532" fill="', fill, '" font-size="9.5" font-family="', MONO,
                '" text-anchor="middle">', content, "</text>"
            )
        );
    }

    function stateColor(uint8 s) internal pure returns (string memory) {
        if (s == STATE_MATURE) return MINT;
        if (s == STATE_VESTING) return GOLD;
        if (s == STATE_BAND_CLOSED) return ROSE;
        return TEXT_3;
    }

    function stateLabel(uint8 s) public pure returns (string memory) {
        if (s == STATE_MATURE) return "ACTIVE";
        if (s == STATE_VESTING) return "VESTING";
        if (s == STATE_BAND_CLOSED) return "BAND CLOSED";
        if (s == STATE_NO_ANCHOR) return "NO ANCHOR";
        return "EMPTY";
    }
}
