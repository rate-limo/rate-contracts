// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.24;

import {IPerpEngine} from "./interfaces/IPerpEngine.sol";
import {IPerpPoolFactory} from "./interfaces/IPerpPoolFactory.sol";
import {IPerpPool} from "./interfaces/IPerpPool.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

interface IMatchingEngineForEngine {
    function getPair(address base, address quote) external view returns (address book);
}

contract PerpEngine is IPerpEngine, ReentrancyGuard, AccessControl {
    bytes32 private constant MARKET_MAKER_ROLE = keccak256("MARKET_MAKER_ROLE");

    address public perpPoolFactory;
    address public matchingEngine;
    address public feeTo;
    bool init;

    mapping(address => bool) public isStablecoin;

    event PoolAdded(address indexed pool, address indexed base, address indexed quote, uint32 maxLeverage);
    event StablecoinSet(address indexed token, bool accepted);
    event PoolSeeded(address indexed pool, address indexed token, address indexed funder, uint256 amount);

    error AlreadyInitialized(bool init);
    error InvalidRole(bytes32 role, address sender);
    error QuoteNotStablecoin(address quote);
    error NoSpotMarket(address base, address quote);

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(MARKET_MAKER_ROLE, msg.sender);
    }

    function initialize(address perpPoolFactory_, address matchingEngine_, address feeTo_) external {
        if (init) {
            revert AlreadyInitialized(init);
        }
        perpPoolFactory = perpPoolFactory_;
        matchingEngine = matchingEngine_;
        feeTo = feeTo_;
        init = true;
    }

    function setFeeTo(address feeTo_) external returns (bool success) {
        if (!hasRole(DEFAULT_ADMIN_ROLE, _msgSender())) {
            revert InvalidRole(DEFAULT_ADMIN_ROLE, _msgSender());
        }
        feeTo = feeTo_;
        return true;
    }

    function setStablecoin(address token, bool accepted) external {
        if (!hasRole(MARKET_MAKER_ROLE, _msgSender())) {
            revert InvalidRole(MARKET_MAKER_ROLE, _msgSender());
        }
        isStablecoin[token] = accepted;
        emit StablecoinSet(token, accepted);
    }

    function addPool(
        address base,
        address quote,
        address[] calldata collateralTokens,
        uint32 maxLeverage,
        uint32 maxUtilizationBps,
        uint256 minSpotLiquidity
    ) external returns (address pool) {
        if (!isStablecoin[quote]) {
            revert QuoteNotStablecoin(quote);
        }
        address spotBook = IMatchingEngineForEngine(matchingEngine).getPair(base, quote);
        if (spotBook == address(0)) {
            revert NoSpotMarket(base, quote);
        }

        pool = IPerpPoolFactory(perpPoolFactory).createPerpPool(
            base, quote, collateralTokens, maxLeverage, maxUtilizationBps, minSpotLiquidity
        );

        emit PoolAdded(pool, base, quote, maxLeverage);
        return pool;
    }

    // Production seeding passthrough: PerpPool.seedReserve is onlyPerpEngine-gated, so a
    // market maker cannot fund a pool's reserve directly. This routes the call through the
    // engine on their behalf -- the caller is the funder and must have approved the POOL
    // (not this engine) for `amount` beforehand, since PerpPool.seedReserve pulls funds via
    // safeTransferFrom(token, funder, pool, amount) with funder == msg.sender here.
    //
    // WARNING: seeded capital is NON-REDEEMABLE in Phase 1 -- no withdrawal path exists until
    // LP share accounting lands. Do not seed funds you cannot lock indefinitely.
    function seedPool(address pool, address token, uint256 amount) external returns (bool) {
        if (!hasRole(MARKET_MAKER_ROLE, _msgSender())) {
            revert InvalidRole(MARKET_MAKER_ROLE, _msgSender());
        }
        IPerpPool(pool).seedReserve(token, amount, msg.sender);
        emit PoolSeeded(pool, token, msg.sender, amount);
        return true;
    }

    // Production passthrough for PerpPool.setLiquidationFeeBps / setLiquidationFeeRecipient,
    // which are onlyPerpEngine-gated so a market maker cannot configure a pool's liquidation
    // fee split directly. Without this, liquidationFeeBps/liquidationFeeRecipient are
    // permanently unset in production (final-branch review I4).
    function setPoolLiquidationFee(address pool, uint32 feeBps, address recipient) external returns (bool) {
        if (!hasRole(MARKET_MAKER_ROLE, _msgSender())) {
            revert InvalidRole(MARKET_MAKER_ROLE, _msgSender());
        }
        IPerpPool(pool).setLiquidationFeeBps(feeBps);
        IPerpPool(pool).setLiquidationFeeRecipient(recipient);
        return true;
    }

    function getPool(address base, address quote) external view returns (address pool) {
        return IPerpPoolFactory(perpPoolFactory).getPool(base, quote);
    }

    function long(address pool, address collateralToken, uint256 collateralAmount, uint32 leverage)
        external
        nonReentrant
        returns (uint256 positionId)
    {
        return IPerpPool(pool).openPosition(true, collateralToken, collateralAmount, leverage, msg.sender);
    }

    function short(address pool, address collateralToken, uint256 collateralAmount, uint32 leverage)
        external
        nonReentrant
        returns (uint256 positionId)
    {
        return IPerpPool(pool).openPosition(false, collateralToken, collateralAmount, leverage, msg.sender);
    }

    function closePosition(address pool, uint256 positionId) external nonReentrant returns (int256 pnl, uint256 payout) {
        return IPerpPool(pool).closePosition(positionId, msg.sender);
    }

    function liquidate(address pool, uint256 positionId) external nonReentrant returns (uint256 feeFund, uint256 poolFund) {
        return IPerpPool(pool).liquidate(positionId);
    }
}
