// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.24;

interface IPerpPool {
    struct Position {
        address owner;
        address collateralToken;
        // margin, in `quote`-denominated value, fixed at open (normalized via a MatchingEngine
        // price lookup at open time if collateralToken != quote)
        uint256 margin;
        uint256 entryPrice;
        uint32 leverage;
        bool isLong;
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
    ) external;

    function openPosition(bool isLong, address collateralToken, uint256 collateralAmount, uint32 leverage, address trader)
        external
        returns (uint256 positionId);

    function seedReserve(address token, uint256 amount, address funder) external;

    function closePosition(uint256 positionId, address trader) external returns (int256 pnl, uint256 payout);

    function liquidate(uint256 positionId) external returns (uint256 feeFund, uint256 poolFund);

    function setLiquidationFeeBps(uint32 bps) external;

    function setLiquidationFeeRecipient(address recipient) external;

    function getPosition(uint256 positionId) external view returns (Position memory);

    function isAcceptedCollateral(address token) external view returns (bool);

    function reserveOf(address token) external view returns (uint256);
}
