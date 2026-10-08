// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {BandEthUsdcTest} from "./BandEthUsdc.t.sol";
import {ExchangeOrderbook} from "../../src/exchange/libraries/ExchangeOrderbook.sol";
import {MockToken} from "../../src/mock/MockToken.sol";

/**
 * CAN ANYONE LIST THE SAME TWO TOKENS TWICE?
 *
 * `addPair` is permissionless by design. `OrderbookFactory.createBook` guards it
 * with a CREATE2 address check -- but the salt is
 * `keccak256(abi.encodePacked(base, quote))`, which is ORDER SENSITIVE. These
 * measure what that actually permits.
 */
contract BandMirrorPairTest is BandEthUsdcTest {
    /// A token against itself is refused outright.
    function test_aTokenCannotBeListedAgainstItself() public {
        vm.expectRevert();
        engine.addPair(
            address(eth), address(eth), MID, 0, address(eth),
            ExchangeOrderbook.MatchingMode.PriceTimePriority
        );
    }

    /// The same ordered pair twice is refused: PairAlreadyExists.
    function test_theSameOrderedPairCannotBeListedTwice() public {
        vm.expectRevert();
        engine.addPair(
            address(eth), address(usdc), MID, 0, address(eth),
            ExchangeOrderbook.MatchingMode.PriceTimePriority
        );
    }

    /**
     * THE REVERSED PAIR IS A DIFFERENT MARKET, and anyone can create it.
     *
     * ETH/USDC exists from the fixture. Listing USDC/ETH is not caught by the
     * duplicate guard, because the salt hashes the two addresses in order. The
     * result is a second orderbook and a second band pool over the same two
     * tokens, with its own price, its own depth and its own LPs.
     */
    function test_theReversedPairIsASecondMarketAnyoneCanList() public {
        address original = engine.getPair(address(eth), address(usdc));
        assertTrue(original != address(0), "the fixture listed ETH/USDC");

        address stranger = address(0xBAD5EED);
        vm.prank(stranger);
        address mirror = engine.addPair(
            address(usdc), address(eth), 1e8 / 2000, 0, address(usdc),
            ExchangeOrderbook.MatchingMode.PriceTimePriority
        );

        assertTrue(mirror != address(0), "USDC/ETH listed");
        assertTrue(mirror != original, "and it is NOT the same book");
        emit log_named_address("ETH/USDC", original);
        emit log_named_address("USDC/ETH", mirror);

        // Two pools too, over the same pair of tokens.
        address poolA = poolFactory.getPool(address(eth), address(usdc));
        address poolB = poolFactory.getPool(address(usdc), address(eth));
        emit log_named_address("pool ETH/USDC", poolA);
        emit log_named_address("pool USDC/ETH", poolB);
        assertTrue(poolB != address(0), "the mirror got its own band pool");
        assertTrue(poolA != poolB, "which is not the original's");

        // And the lister chose its price, unconstrained by the original's.
        emit log_named_uint("original lmp", IOrderbookLmp(original).lmp());
        emit log_named_uint("mirror   lmp", IOrderbookLmp(mirror).lmp());
    }

    /// The mirror's creator is the stranger, so they configure its bands.
    function test_theMirrorsCreatorIsWhoeverListedIt() public {
        address stranger = address(0xBAD5EED);
        vm.prank(stranger);
        engine.addPair(
            address(usdc), address(eth), 1e8 / 2000, 0, address(usdc),
            ExchangeOrderbook.MatchingMode.PriceTimePriority
        );
        address poolB = poolFactory.getPool(address(usdc), address(eth));
        emit log_named_address("mirror pool creator", IPoolCreator(poolB).creator());
        assertEq(IPoolCreator(poolB).creator(), stranger, "the lister owns the mirror's bands");
    }
}

interface IOrderbookLmp { function lmp() external view returns (uint256); }
interface IPoolCreator { function creator() external view returns (address); }
