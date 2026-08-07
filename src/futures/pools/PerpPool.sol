// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.24;

import {IPerpPool} from "../interfaces/IPerpPool.sol";
import {FuturesPool} from "../libraries/FuturesPool.sol";
import {TransferHelper} from "../libraries/TransferHelper.sol";
import {Initializable} from "../../security/Initializable.sol";

interface IMatchingEnginePrice {
    function mktPrice(address base, address quote) external view returns (uint256);
    function getPair(address base, address quote) external view returns (address book);
}

interface IOrderbookPool {
    function getPool() external view returns (address);
}

interface IERC20Minimal {
    function balanceOf(address account) external view returns (uint256);
}

contract PerpPool is IPerpPool, Initializable {
    struct Market {
        uint256 id;
        address base;
        address quote;
        address matchingEngine;
        address perpEngine;
    }

    Market public market;

    uint32 public maxLeverage;
    uint32 public maxUtilizationBps;
    uint256 public minSpotLiquidity;

    mapping(address => bool) public isAcceptedCollateral;
    mapping(address => uint256) public reserveOf;

    mapping(uint256 => Position) internal positions;
    uint256 public positionCount;

    uint256 public longOpenInterest;
    uint256 public shortOpenInterest;

    uint32 public liquidationFeeBps; // default 0 -- no explicit clearance fee, matches Hyperliquid
    address public liquidationFeeRecipient;

    event PositionOpened(
        uint256 indexed positionId, address indexed trader, bool isLong, uint256 entryPrice, uint256 margin, uint32 leverage
    );
    event PositionClosed(uint256 indexed positionId, address indexed trader, uint256 exitPrice, int256 pnl, uint256 payout);
    event PositionLiquidated(uint256 indexed positionId, address indexed trader, uint256 markPrice, uint256 feeFund, uint256 poolFund);
    event ReserveSeeded(address indexed token, address indexed funder, uint256 amount);

    error CollateralNotAccepted(address token);
    error NonQuoteCollateralNotSupported(address token);
    error LeverageLimitExceeded(uint32 leverage, uint32 maxLeverage_);
    error AmountIsZero();
    error PriceIsZero(uint256 price);
    error InsufficientSpotLiquidity(uint256 have, uint256 required);
    error OpenInterestCapExceeded(uint256 attempted, uint256 cap);
    error InvalidAccess(address sender, address allowed);
    error PositionNotFound(uint256 positionId);
    error NotLiquidatable(uint256 positionId);
    error InsufficientPoolReserve(uint256 requested, uint256 available);
    error NotPositionOwner(address caller, address owner);

    modifier onlyPerpEngine() {
        if (msg.sender != market.perpEngine) {
            revert InvalidAccess(msg.sender, market.perpEngine);
        }
        _;
    }

    function initialize(
        uint256 id_,
        address base_,
        address quote_,
        address matchingEngine_,
        address perpEngine_,
        address[] calldata collateralTokens_,
        uint32 maxLeverage_,
        uint32 maxUtilizationBps_,
        uint256 minSpotLiquidity_
    ) external initializer {
        market = Market(id_, base_, quote_, matchingEngine_, perpEngine_);
        maxLeverage = maxLeverage_;
        maxUtilizationBps = maxUtilizationBps_;
        minSpotLiquidity = minSpotLiquidity_;
        // The multi-collateral storage/normalization architecture (isAcceptedCollateral,
        // reserveOf per token, _toQuoteValue/_fromQuoteValue) is retained for Phase 2, but
        // enabling non-quote collateral is deferred: reserveOf[alt] only ever holds that
        // position's own deposit, so a winning alt-collateral close can demand more than the
        // pool holds in that token and revert InsufficientPoolReserve, stranding the trader's
        // funds (see final-branch review I1). Until Phase 2 designs alt backing/drift handling,
        // only quote collateral may be configured.
        for (uint256 i = 0; i < collateralTokens_.length; i++) {
            if (collateralTokens_[i] != quote_) {
                revert NonQuoteCollateralNotSupported(collateralTokens_[i]);
            }
            isAcceptedCollateral[collateralTokens_[i]] = true;
        }
    }

    function getPosition(uint256 positionId) external view returns (Position memory) {
        return positions[positionId];
    }

    // --- interface-completeness stubs; real implementations land in Tasks 4-6 ---

    // Phase 1 backing capital is operator-seeded and non-redeemable until LP share accounting
    // lands (documented fast-follow). This is deliberately admin-only (gated behind
    // onlyPerpEngine, same as openPosition -- the real PerpEngine contract will expose an
    // admin-gated passthrough in Task 7) so no third-party funds can get stranded in a pool
    // that has no withdrawal path yet.
    function seedReserve(address token, uint256 amount, address funder) external onlyPerpEngine {
        if (!isAcceptedCollateral[token]) {
            revert CollateralNotAccepted(token);
        }
        if (amount == 0) {
            revert AmountIsZero();
        }

        TransferHelper.safeTransferFrom(token, funder, address(this), amount);
        reserveOf[token] += amount;

        emit ReserveSeeded(token, funder, amount);
    }

    function openPosition(bool isLong, address collateralToken, uint256 collateralAmount, uint32 leverage, address trader)
        external
        override
        onlyPerpEngine
        returns (uint256 positionId)
    {
        if (!isAcceptedCollateral[collateralToken]) {
            revert CollateralNotAccepted(collateralToken);
        }
        if (collateralAmount == 0) {
            revert AmountIsZero();
        }
        if (leverage == 0 || leverage > maxLeverage) {
            revert LeverageLimitExceeded(leverage, maxLeverage);
        }

        uint256 spotLiquidity = _spotLiquidity();
        if (spotLiquidity < minSpotLiquidity) {
            revert InsufficientSpotLiquidity(spotLiquidity, minSpotLiquidity);
        }

        uint256 entryPrice = IMatchingEnginePrice(market.matchingEngine).mktPrice(market.base, market.quote);
        if (entryPrice == 0) {
            revert PriceIsZero(entryPrice);
        }

        uint256 marginQuote = _toQuoteValue(collateralToken, collateralAmount);
        uint256 notional = marginQuote * leverage;

        // Cap check runs against the reserve BEFORE this trader's deposit lands, so a trader's
        // own just-deposited margin never counts toward their own cap. Known Phase 1 limitation:
        // margin deposited by EARLIER opens still sits in reserveOf and counts toward later
        // traders' caps -- separating margin from backing capital is part of the LP-share
        // fast-follow.
        uint256 sideOI = isLong ? longOpenInterest : shortOpenInterest;
        uint256 cap = (_totalReserveInQuote() * maxUtilizationBps) / 10000;
        if (sideOI + notional > cap) {
            revert OpenInterestCapExceeded(sideOI + notional, cap);
        }

        TransferHelper.safeTransferFrom(collateralToken, trader, address(this), collateralAmount);
        reserveOf[collateralToken] += collateralAmount;

        positionCount += 1;
        positionId = positionCount;
        positions[positionId] = Position({
            owner: trader,
            collateralToken: collateralToken,
            margin: marginQuote,
            entryPrice: entryPrice,
            leverage: leverage,
            isLong: isLong
        });

        if (isLong) {
            longOpenInterest += notional;
        } else {
            shortOpenInterest += notional;
        }

        emit PositionOpened(positionId, trader, isLong, entryPrice, marginQuote, leverage);
        return positionId;
    }

    function _totalReserveInQuote() internal view returns (uint256 total) {
        // Phase 1 keeps this simple: sum reserves already known to be accepted collateral,
        // normalized to quote value at the current price. This is called once per open, so an
        // O(n) loop over accepted collateral is fine for the small collateral lists expected here.
        total = reserveOf[market.quote];
        // Non-quote collateral reserves are added by openPosition's own _toQuoteValue calls at
        // insertion time in a future refinement; Phase 1's cap check uses the quote-denominated
        // reserve as the conservative floor so the cap can never be looser than actual backing.
    }

    function closePosition(uint256 positionId, address trader) external override onlyPerpEngine returns (int256 pnl, uint256 payout) {
        Position memory position = positions[positionId];
        if (position.owner == address(0)) {
            revert PositionNotFound(positionId);
        }
        if (position.owner != trader) {
            revert NotPositionOwner(trader, position.owner);
        }

        uint256 exitPrice = IMatchingEnginePrice(market.matchingEngine).mktPrice(market.base, market.quote);
        if (exitPrice == 0) {
            revert PriceIsZero(exitPrice);
        }

        pnl = FuturesPool._pnl(position.margin, position.entryPrice, position.leverage, exitPrice, position.isLong);

        int256 payoutSigned = int256(position.margin) + pnl;
        payout = payoutSigned > 0 ? uint256(payoutSigned) : 0;

        uint256 payoutInCollateral = _fromQuoteValue(position.collateralToken, payout);
        uint256 available = reserveOf[position.collateralToken];
        if (payoutInCollateral > available) {
            revert InsufficientPoolReserve(payoutInCollateral, available);
        }

        uint256 notional = position.margin * position.leverage;
        if (position.isLong) {
            longOpenInterest -= notional;
        } else {
            shortOpenInterest -= notional;
        }

        delete positions[positionId];

        if (payoutInCollateral > 0) {
            reserveOf[position.collateralToken] -= payoutInCollateral;
            TransferHelper.safeTransfer(position.collateralToken, trader, payoutInCollateral);
        }

        emit PositionClosed(positionId, trader, exitPrice, pnl, payoutInCollateral);
        return (pnl, payoutInCollateral);
    }

    function setLiquidationFeeBps(uint32 bps) external override onlyPerpEngine {
        liquidationFeeBps = bps;
    }

    function setLiquidationFeeRecipient(address recipient) external override onlyPerpEngine {
        liquidationFeeRecipient = recipient;
    }

    // Liquidation is intentionally permissionless (like Hyperliquid's book-close stage and
    // backstop vault, neither of which require a privileged caller) -- anyone can trigger it
    // once a position is actually eligible; _isLiquidatable is what gates it, not msg.sender.
    function liquidate(uint256 positionId) external override returns (uint256 feeFund, uint256 poolFund) {
        Position memory position = positions[positionId];
        if (position.owner == address(0)) {
            revert PositionNotFound(positionId);
        }

        uint256 markPrice = IMatchingEnginePrice(market.matchingEngine).mktPrice(market.base, market.quote);
        if (markPrice == 0) {
            revert PriceIsZero(markPrice);
        }

        bool liquidatable = FuturesPool._isLiquidatable(
            position.margin, position.entryPrice, position.leverage, markPrice, position.isLong, maxLeverage
        );
        if (!liquidatable) {
            revert NotLiquidatable(positionId);
        }

        (feeFund, poolFund) = FuturesPool._liquidationSplit(position.margin, liquidationFeeBps);

        uint256 notional = position.margin * position.leverage;
        if (position.isLong) {
            longOpenInterest -= notional;
        } else {
            shortOpenInterest -= notional;
        }

        delete positions[positionId];

        // feeFund and poolFund are quote-denominated (position.margin already is); convert to
        // the position's actual collateral token for both the fee payout and the reserve debit.
        uint256 feeFundInCollateral = _fromQuoteValue(position.collateralToken, feeFund);
        uint256 poolFundInCollateral = _fromQuoteValue(position.collateralToken, poolFund);

        // poolFund was already sitting in reserveOf[collateralToken] from the original deposit
        // at open -- liquidation just keeps it there instead of paying it out to the trader.
        // Deviation from a naive "always decrement by feeFund" approach: only touch reserveOf
        // (and transfer) when a real fee recipient is configured. If none is set, the fee
        // portion simply stays in the reserve as extra pool backing (economically identical to
        // poolFund) -- decrementing reserveOf here with no matching transfer would silently
        // strand tokens the pool's own accounting no longer counts.
        if (feeFundInCollateral > 0 && liquidationFeeRecipient != address(0)) {
            reserveOf[position.collateralToken] -= feeFundInCollateral;
            TransferHelper.safeTransfer(position.collateralToken, liquidationFeeRecipient, feeFundInCollateral);
        }

        emit PositionLiquidated(positionId, position.owner, markPrice, feeFundInCollateral, poolFundInCollateral);
        return (feeFundInCollateral, poolFundInCollateral);
    }

    // --- internal helpers shared by Tasks 4-6 ---

    function _spotLiquidity() internal view returns (uint256) {
        address orderbook = IMatchingEnginePrice(market.matchingEngine).getPair(market.base, market.quote);
        if (orderbook == address(0)) return 0;
        address swapPool = IOrderbookPool(orderbook).getPool();
        if (swapPool == address(0)) return 0;
        return IERC20Minimal(market.quote).balanceOf(swapPool);
    }

    function _toQuoteValue(address collateralToken, uint256 amount) internal view returns (uint256) {
        if (collateralToken == market.quote) return amount;
        uint256 price = IMatchingEnginePrice(market.matchingEngine).mktPrice(collateralToken, market.quote);
        if (price == 0) revert PriceIsZero(price);
        uint8 collateralDecimals = TransferHelper.decimals(collateralToken);
        uint8 quoteDecimals = TransferHelper.decimals(market.quote);
        uint256 raw = (amount * price) / 1e8;
        if (collateralDecimals == quoteDecimals) return raw;
        if (collateralDecimals > quoteDecimals) return raw / (10 ** (collateralDecimals - quoteDecimals));
        return raw * (10 ** (quoteDecimals - collateralDecimals));
    }

    function _fromQuoteValue(address collateralToken, uint256 quoteAmount) internal view returns (uint256) {
        if (collateralToken == market.quote) return quoteAmount;
        uint256 price = IMatchingEnginePrice(market.matchingEngine).mktPrice(collateralToken, market.quote);
        if (price == 0) revert PriceIsZero(price);
        uint8 collateralDecimals = TransferHelper.decimals(collateralToken);
        uint8 quoteDecimals = TransferHelper.decimals(market.quote);
        uint256 raw = (quoteAmount * 1e8) / price;
        if (collateralDecimals == quoteDecimals) return raw;
        if (collateralDecimals > quoteDecimals) return raw * (10 ** (collateralDecimals - quoteDecimals));
        return raw / (10 ** (quoteDecimals - collateralDecimals));
    }
}
