// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {StopLimitOrderbook} from "./StopLimitOrderbook.sol";
import {CloneFactory} from "../libraries/CloneFactory.sol";

contract StopLimitOrderbookFactory {
    address public immutable engine;
    address public immutable impl;

    error InvalidAccess(address sender, address allowed);

    constructor(address engine_) {
        engine = engine_;
        impl = address(new StopLimitOrderbook());
    }

    function create(address orderbook, address base, address quote) external returns (address stopBook) {
        if (msg.sender != engine) revert InvalidAccess(msg.sender, engine);
        bytes32 salt = keccak256(abi.encodePacked(orderbook));
        stopBook = CloneFactory._createCloneWithSalt(impl, salt);
        StopLimitOrderbook(stopBook).initialize(engine, orderbook, base, quote);
    }

    function predict(address orderbook) external view returns (address) {
        return CloneFactory.predictAddressWithSalt(address(this), impl, keccak256(abi.encodePacked(orderbook)));
    }

    function isClone(address stopBook) external view returns (bool) {
        return CloneFactory._isClone(impl, stopBook);
    }
}
