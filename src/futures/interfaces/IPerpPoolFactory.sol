// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.24;

interface IPerpPoolFactory {
    function engine() external view returns (address);

    function perp() external view returns (address);

    function createPerpPool(
        address base_,
        address quote_,
        address[] calldata collateralTokens_,
        uint32 maxLeverage_,
        uint32 maxUtilizationBps_,
        uint256 minSpotLiquidity_
    ) external returns (address pool);

    function getPool(address base, address quote) external view returns (address pool);

    function getListingCost(address token) external view returns (uint256);

    function setListingCost(address payment, uint256 amount) external returns (uint256);
}
