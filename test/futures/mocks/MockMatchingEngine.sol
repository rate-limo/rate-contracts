// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

// Minimal mock standing in for MatchingEngine's price-lookup surface, plus a fake spot pool
// whose token balance PerpPool reads for the spot-liquidity gate.
//
// Shared across futures/perppool test files (OpenPosition.t.sol, ClosePosition.t.sol, ...) so
// each test only needs one canonical mock implementation. Originally lived inline in
// OpenPosition.t.sol; moved here so it can be imported directly instead of relying on
// vm.getDeployedCode cross-file artifact lookups, which proved brittle (artifact resolution
// failed at runtime -- "no matching artifact found").
contract MockMatchingEngine {
    mapping(bytes32 => uint256) public prices;
    mapping(bytes32 => address) public pairs;

    function setPrice(address base, address quote, uint256 price) external {
        prices[keccak256(abi.encodePacked(base, quote))] = price;
    }

    function mktPrice(address base, address quote) external view returns (uint256) {
        return prices[keccak256(abi.encodePacked(base, quote))];
    }

    function setPair(address base, address quote, address book) external {
        pairs[keccak256(abi.encodePacked(base, quote))] = book;
    }

    function getPair(address base, address quote) external view returns (address) {
        return pairs[keccak256(abi.encodePacked(base, quote))];
    }
}

contract MockOrderbook {
    address public pool;

    constructor(address pool_) {
        pool = pool_;
    }

    function getPool() external view returns (address) {
        return pool;
    }
}
