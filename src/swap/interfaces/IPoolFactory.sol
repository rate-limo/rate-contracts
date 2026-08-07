// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

interface IPoolFactory {
    function engine() external view returns (address);

    function positionManager() external view returns (address);

    function impl() external view returns (address);

    function createPool(address base_, address quote_, address orderbook_) external returns (address pool);

    function getPool(address base, address quote) external view returns (address pool);

    function isClone(address vault) external view returns (bool cloned);
}
