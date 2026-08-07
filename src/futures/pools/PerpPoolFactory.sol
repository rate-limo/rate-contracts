// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {PerpPool, IPerpPool} from "./PerpPool.sol";
import {CloneFactory} from "../libraries/CloneFactory.sol";
import {IPerpPoolFactory} from "../interfaces/IPerpPoolFactory.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

contract PerpPoolFactory is IPerpPoolFactory, Initializable {
    address[] public allPools;
    address public override engine;
    address public override perp;
    uint32 public version;
    address public impl;
    mapping(address => uint256) public listingCosts;

    error InvalidAccess(address sender, address allowed);
    error PoolAlreadyExists(address base, address quote, address pair);
    error SameBaseQuote(address base, address quote);

    constructor() {}

    function createPerpPool(
        address base_,
        address quote_,
        address[] calldata collateralTokens_,
        uint32 maxLeverage_,
        uint32 maxUtilizationBps_,
        uint256 minSpotLiquidity_
    ) external override returns (address pool) {
        if (msg.sender != perp) {
            revert InvalidAccess(msg.sender, perp);
        }
        if (base_ == quote_) {
            revert SameBaseQuote(base_, quote_);
        }

        address predicted = _predictAddress(base_, quote_);

        uint32 size;
        assembly {
            size := extcodesize(predicted)
        }
        if (size > 0 || CloneFactory._isClone(impl, predicted)) {
            revert PoolAlreadyExists(base_, quote_, predicted);
        }

        address proxy = CloneFactory._createCloneWithSalt(impl, _getSalt(base_, quote_));
        IPerpPool(proxy).initialize(
            allPoolsLength(), base_, quote_, engine, perp, collateralTokens_, maxLeverage_, maxUtilizationBps_, minSpotLiquidity_
        );
        allPools.push(proxy);
        return proxy;
    }

    function isClone(address vault) external view returns (bool cloned) {
        cloned = CloneFactory._isClone(impl, vault);
    }

    function getPoolById(uint256 poolId_) external view returns (address) {
        return allPools[poolId_];
    }

    function getPool(address base, address quote) external view override returns (address pool) {
        pool = _predictAddress(base, quote);
        return address(pool).code.length > 0 ? pool : address(0);
    }

    function initialize(address engine_, address perp_) public initializer returns (address) {
        engine = engine_;
        perp = perp_;
        _createImpl();
        return impl;
    }

    function allPoolsLength() public view returns (uint256) {
        return allPools.length;
    }

    function _createImpl() internal {
        address addr;
        bytes memory bytecode = type(PerpPool).creationCode;
        bytes32 salt = keccak256(abi.encodePacked("perppool", version));
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

    function getByteCode() external view returns (bytes memory bytecode) {
        return CloneFactory.getBytecode(impl);
    }

    function getListingCost(address token) external view returns (uint256) {
        return listingCosts[token];
    }

    function setListingCost(address payment, uint256 amount) external returns (uint256) {
        if (msg.sender != perp) {
            revert InvalidAccess(msg.sender, perp);
        }
        listingCosts[payment] = amount;
        return amount;
    }
}
