// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {IPool} from "./interfaces/IPool.sol";
import {IPositionManager} from "./interfaces/IPositionManager.sol";
import {IOrderbook} from "../exchange/interfaces/IOrderbook.sol";
import {PositionSVG} from "./libraries/PositionSVG.sol";

/// @dev `IPool` exposes neither `orderbook()` nor the ERC20 metadata this needs,
///      but `Pool` declares `address public orderbook`, so a narrow local view
///      interface reaches it without touching the shared interface file.
interface IPoolOrderbook {
    function orderbook() external view returns (address);
}

interface IERC20Meta {
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
}

/// @title PositionDescriptor
/// @notice Fully on-chain `tokenURI` for off-grid swap liquidity positions.
/// @dev Deployed once and pointed at by `PositionManager`, so artwork can be
///      revised without redeploying the NFT itself.
///
///      Every external read is wrapped: a `tokenURI` that reverts renders as a
///      blank tile on every marketplace, so a dead oracle or a non-standard
///      ERC20 degrades to a labelled fallback instead of bricking the token.
contract PositionDescriptor {
    /// @dev Orderbook prices are 1e8-scaled — see `Orderbook.sol` (`amount * price / 1e8`).
    ///      Deliberately NOT `DENOM`: that 1e8 is the *slippage* denominator and the two
    ///      only coincide by accident.
    uint8 internal constant PRICE_DECIMALS = 8;
    /// @dev `slippageLimit` is a fraction of `Pool.DENOM` (1e8); as a percentage that is
    ///      value / 1e6.
    uint8 internal constant SLIPPAGE_PCT_DECIMALS = 6;
    uint32 internal constant TWAP_WINDOW = 600;

    /// @dev Bundled so `tokenURI` stays inside the EVM stack limit: this repo compiles
    ///      without `viaIR` (see `foundry.toml`), the same constraint documented in
    ///      `Pool.swap`.
    struct Ctx {
        address pool;
        uint256 positionId;
        address base;
        address quote;
        uint8 baseDecimals;
        uint8 quoteDecimals;
        uint256 market;
        bool hasMarket;
        uint8 source; // 0 none, 1 TWAP, 2 last matched price
    }

    function tokenURI(address manager, uint256 tokenId) external view returns (string memory) {
        Ctx memory c;
        (c.pool, c.positionId) = IPositionManager(manager).tokenPosition(tokenId);
        // Never-minted or burnt id: `tokenPosition` returns the zero address, and calling
        // into it would revert on the empty return data rather than on anything useful.
        // ERC1155 has no `_requireOwned`, so the guard belongs here.
        if (c.pool == address(0)) return "";
        (c.base, c.quote) = IPool(c.pool).getBaseQuote();
        c.baseDecimals = _decimals(c.base);
        c.quoteDecimals = _decimals(c.quote);
        (c.market, c.source) = _marketPrice(c.pool);
        c.hasMarket = c.source != 0;

        IPool.Position memory p = IPool(c.pool).getPosition(c.positionId);
        PositionSVG.Params memory v = _params(c, p, tokenId);

        string memory image = Base64.encode(bytes(PositionSVG.render(v)));
        return string(
            abi.encodePacked(
                "data:application/json;base64,",
                Base64.encode(bytes(_json(v, image)))
            )
        );
    }

    // ------------------------------------------------------------------
    // assembly of the render params
    // ------------------------------------------------------------------
    /// @dev Filled through small mutating helpers rather than one long assignment run:
    ///      sixteen live strings in a single frame overruns the stack without `viaIR`.
    function _params(Ctx memory c, IPool.Position memory p, uint256 tokenId)
        internal
        view
        returns (PositionSVG.Params memory v)
    {
        _fillSymbols(v, c);
        _fillPrices(v, c, p);
        _fillAmounts(v, c, p);
        _fillStatus(v, c, p, tokenId);
    }

    /// @dev `LABEL_TAG_LEN` caps the symbol used in the stat labels only. Two labels share
    ///      the 282px stat row growing toward each other from opposite anchors, and at the
    ///      label's 8.5px size a 7-character tag plus " FEES OWED" stays inside its half.
    ///      The title and the JSON keep the full symbol.
    uint256 internal constant LABEL_TAG_LEN = 7;

    function _fillSymbols(PositionSVG.Params memory v, Ctx memory c) private view {
        v.baseSymbol = _symbol(c.base);
        v.quoteSymbol = _symbol(c.quote);
        v.pair = string(abi.encodePacked(v.baseSymbol, " / ", v.quoteSymbol));
        v.baseTag = _truncate(v.baseSymbol, LABEL_TAG_LEN);
        v.quoteTag = _truncate(v.quoteSymbol, LABEL_TAG_LEN);
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

    function _fillPrices(PositionSVG.Params memory v, Ctx memory c, IPool.Position memory p)
        private
        pure
    {
        // Full 8 fractional digits: truncating to 6 would render a sub-cent range like
        // 0.00000823 -> 0.00000914 as "0.000008" at both bounds, i.e. a range that looks
        // like a point.
        v.minPrice = _fixed(p.minPrice, PRICE_DECIMALS, PRICE_DECIMALS);
        v.maxPrice = _fixed(p.maxPrice, PRICE_DECIMALS, PRICE_DECIMALS);
        v.marketPrice = c.hasMarket ? _fixed(c.market, PRICE_DECIMALS, PRICE_DECIMALS) : "--";
        v.priceSource = _sourceLabel(c.source);
        v.slippage =
            string(abi.encodePacked(_fixed(p.slippageLimit, SLIPPAGE_PCT_DECIMALS, 3), "%"));
    }

    function _fillAmounts(PositionSVG.Params memory v, Ctx memory c, IPool.Position memory p)
        private
        pure
    {
        v.baseAmount = _fixed(p.baseAmount, c.baseDecimals, 4);
        v.quoteAmount = _fixed(p.quoteAmount, c.quoteDecimals, 4);
        v.baseFees = _fixed(p.feeOwedBase, c.baseDecimals, 6);
        v.quoteFees = _fixed(p.feeOwedQuote, c.quoteDecimals, 6);
    }

    function _fillStatus(
        PositionSVG.Params memory v,
        Ctx memory c,
        IPool.Position memory p,
        uint256 tokenId
    ) private pure {
        v.tokenId = Strings.toString(tokenId);
        v.poolShort = _shortAddress(c.pool);
        v.hasMarket = c.hasMarket && p.active;
        v.state = _state(p, c.market, c.hasMarket);
        v.markerBps = v.hasMarket ? markerBps(p.minPrice, p.maxPrice, c.market) : 5000;
    }

    /// @dev 0 in-range, 1 near-edge, 2 out-of-range, 3 no-oracle, 4 closed.
    function _state(IPool.Position memory p, uint256 market, bool hasMarket)
        internal
        pure
        returns (uint8)
    {
        if (!p.active) return PositionSVG.STATE_CLOSED;
        if (!hasMarket) return PositionSVG.STATE_NO_ORACLE;
        if (market < p.minPrice || market > p.maxPrice) return PositionSVG.STATE_OUT_OF_RANGE;
        uint256 span = p.maxPrice - p.minPrice;
        uint256 edge = span / 10;
        if (market - p.minPrice <= edge || p.maxPrice - market <= edge) {
            return PositionSVG.STATE_NEAR_EDGE;
        }
        return PositionSVG.STATE_IN_RANGE;
    }

    /// @notice Maps `market` onto the drawn track, where the position's own range is
    ///         pinned to 2000..8000 bps. Anchoring the band rather than the window keeps
    ///         the geometry exact even for a range whose lower bound is near zero.
    function markerBps(uint256 minPrice, uint256 maxPrice, uint256 market)
        public
        pure
        returns (uint256)
    {
        if (maxPrice <= minPrice) {
            // Degenerate range: a single point. Nothing to interpolate across, so show
            // the marker at the band and let the status pill carry the meaning.
            return market < minPrice ? 0 : (market > maxPrice ? 10_000 : 5_000);
        }
        uint256 span = maxPrice - minPrice;
        if (market >= minPrice) {
            uint256 up = _scale(market - minPrice, span);
            return up >= 8_000 ? 10_000 : 2_000 + up;
        }
        uint256 down = _scale(minPrice - market, span);
        return down >= 2_000 ? 0 : 2_000 - down;
    }

    /// @dev `delta * 6000 / span` without ever reverting on overflow — a revert here
    ///      would take the whole `tokenURI` down for an unreachable price.
    function _scale(uint256 delta, uint256 span) private pure returns (uint256) {
        if (delta > type(uint256).max / 6_000) return type(uint256).max;
        return (delta * 6_000) / span;
    }

    // ------------------------------------------------------------------
    // metadata
    // ------------------------------------------------------------------
    function _json(PositionSVG.Params memory v, string memory image)
        internal
        pure
        returns (string memory)
    {
        string memory head = string(
            abi.encodePacked(
                '{"name":"off-grid LP ', v.pair, " #", v.tokenId, '","description":"', _description(v)
            )
        );
        return string(
            abi.encodePacked(
                head,
                '","image":"data:image/svg+xml;base64,',
                image,
                '","attributes":[',
                _attributes(v),
                "]}"
            )
        );
    }

    function _description(PositionSVG.Params memory v) internal pure returns (string memory) {
        string memory head = string(
            abi.encodePacked(
                "Liquidity position on the off-grid ",
                v.pair,
                " pool, providing between ",
                v.minPrice,
                " and ",
                v.maxPrice
            )
        );
        return string(
            abi.encodePacked(
                head,
                " ",
                v.quoteSymbol,
                " per ",
                v.baseSymbol,
                ". Artwork and every value shown are rendered on-chain."
            )
        );
    }

    function _attributes(PositionSVG.Params memory v) internal pure returns (string memory) {
        return string(
            abi.encodePacked(
                _trait("Pair", v.pair, true),
                _trait("Status", PositionSVG.stateLabel(v.state), true),
                _trait("Min Price", v.minPrice, true),
                _trait("Max Price", v.maxPrice, true),
                _trait("Slippage Limit", v.slippage, true),
                _trait("Pool", v.poolShort, false)
            )
        );
    }

    function _trait(string memory key, string memory value, bool comma)
        private
        pure
        returns (string memory)
    {
        return string(
            abi.encodePacked(
                '{"trait_type":"', key, '","value":"', value, comma ? '"},' : '"}'
            )
        );
    }

    // ------------------------------------------------------------------
    // safe external reads
    // ------------------------------------------------------------------
    /// @return price The reference price, 1e8-scaled.
    /// @return source 0 unavailable, 1 TWAP, 2 last matched price.
    function _marketPrice(address pool) internal view returns (uint256 price, uint8 source) {
        try IPoolOrderbook(pool).orderbook() returns (address book) {
            if (book == address(0)) return (0, 0);
            try IOrderbook(book).twap(TWAP_WINDOW) returns (uint256 twap, uint32) {
                if (twap != 0) return (twap, 1);
            } catch {}
            // A pool with no TWAP history yet still has a last-matched price worth showing.
            // The card labels which of the two it drew, so a holder can tell a settled
            // reference from a single recent print.
            try IOrderbook(book).lmp() returns (uint256 last) {
                if (last != 0) return (last, 2);
            } catch {}
        } catch {}
        return (0, 0);
    }

    function _sourceLabel(uint8 source) internal pure returns (string memory) {
        if (source == 1) return string(abi.encodePacked("TWAP ", Strings.toString(TWAP_WINDOW), "s"));
        if (source == 2) return "LAST MATCH";
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
        try IERC20Meta(token).symbol() returns (string memory s) {
            string memory clean = _sanitize(s);
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
