// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {Pool, IPool} from "./Pool.sol";
import {CloneFactory} from "./libraries/CloneFactory.sol";
import {IPoolFactory} from "./interfaces/IPoolFactory.sol";

contract PoolFactory is IPoolFactory, Initializable, AccessControl {
    address[] public allPools;
    address public override engine;
    address public override positionManager;
    uint32 public version;
    address public override impl;

    error InvalidAccess(address sender, address allowed);
    error PoolAlreadyExists(address base, address quote, address pool);

    // The one place a pool address is ever bound to its (base, quote) pair -- an indexer that
    // watches this singleton has the full pool-address -> pair mapping without enumerating
    // factory-deployed Pool addresses; PositionManager/SwapRouter events can then carry just
    // the pool address and stay small.
    event PoolCreated(address indexed pool, address indexed base, address indexed quote, uint256 poolId, address orderbook);

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    function initialize(address engine_) public initializer onlyRole(DEFAULT_ADMIN_ROLE) returns (address) {
        engine = engine_;
        _createImpl();
        return impl;
    }

    function setPositionManager(address positionManager_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        positionManager = positionManager_;
    }

    function createPool(address base_, address quote_, address orderbook_)
        external
        override
        returns (address pool)
    {
        if (msg.sender != engine) {
            revert InvalidAccess(msg.sender, engine);
        }

        address predicted = _predictAddress(base_, quote_);
        uint32 size;
        assembly {
            size := extcodesize(predicted)
        }
        if (size > 0 || CloneFactory._isClone(impl, predicted)) {
            revert PoolAlreadyExists(base_, quote_, predicted);
        }

        pool = CloneFactory._createCloneWithSalt(impl, _getSalt(base_, quote_));
        IPool(pool).initialize(allPools.length, base_, quote_, orderbook_, engine, positionManager);
        allPools.push(pool);

        emit PoolCreated(pool, base_, quote_, allPools.length - 1, orderbook_);

        return pool;
    }

    function getPool(address base, address quote) external view override returns (address pool) {
        pool = _predictAddress(base, quote);
        return address(pool).code.length > 0 ? pool : address(0);
    }

    function isClone(address vault) external view override returns (bool cloned) {
        cloned = CloneFactory._isClone(impl, vault);
    }

    function _createImpl() internal {
        address addr;
        bytes memory bytecode = type(Pool).creationCode;
        bytes32 salt = keccak256(abi.encodePacked("pool", version));
        assembly {
            addr := create2(0, add(bytecode, 0x20), mload(bytecode), salt)
            if iszero(extcodesize(addr)) { revert(0, 0) }
        }
        impl = addr;
    }

    function _predictAddress(address base_, address quote_) internal view returns (address) {
        bytes32 salt = _getSalt(base_, quote_);
        return CloneFactory.predictAddressWithSalt(address(this), impl, salt);
    }

    function _getSalt(address base_, address quote_) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(base_, quote_));
    }
}
