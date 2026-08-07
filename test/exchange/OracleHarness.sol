// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8;

import {Oracle, ORACLE_CARDINALITY} from "../../src/exchange/libraries/Oracle.sol";

/// @notice Thin wrapper exposing `Oracle`'s internal functions externally so Foundry tests can
/// exercise the ring buffer directly, without needing a full Orderbook/MatchingEngine setup.
contract OracleHarness {
    Oracle.Observation[ORACLE_CARDINALITY] public observations;
    uint16 public index;

    function initialize(uint32 blockTimestamp) external {
        Oracle.initialize(observations, blockTimestamp);
    }

    function write(uint32 blockTimestamp, uint256 priceBeforeUpdate) external {
        index = Oracle.write(observations, index, blockTimestamp, priceBeforeUpdate);
    }

    function twap(uint32 blockTimestamp, uint256 currentPrice, uint32 minSecondsAgo)
        external
        view
        returns (uint256 price, uint32 actualWindow)
    {
        return Oracle.twap(observations, index, blockTimestamp, currentPrice, minSecondsAgo);
    }

    function observationAt(uint16 i) external view returns (uint32 blockTimestamp, uint256 priceCumulative, bool initialized) {
        Oracle.Observation memory o = observations[i];
        return (o.blockTimestamp, o.priceCumulative, o.initialized);
    }
}
