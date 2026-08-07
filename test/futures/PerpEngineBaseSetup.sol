// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8;

import {BaseSetup} from "../exchange/OrderbookBaseSetup.sol";
import {MockToken} from "../../src/mock/MockToken.sol";
import {ExchangeOrderbook} from "../../src/exchange/libraries/ExchangeOrderbook.sol";
import {PerpEngine} from "../../src/futures/PerpEngine.sol";
import {PerpPoolFactory} from "../../src/futures/pools/PerpPoolFactory.sol";

contract PerpEngineBaseSetup is BaseSetup {
    PerpEngine public perpEngine;
    PerpPoolFactory public perpPoolFactory;
    MockToken public stablecoin;

    function perpEngineSetUp() public {
        super.setUp();

        stablecoin = new MockToken("Stablecoin", "STBC", 18);

        perpEngine = new PerpEngine();
        perpPoolFactory = new PerpPoolFactory();
        perpPoolFactory.initialize(address(matchingEngine), address(perpEngine));
        perpEngine.initialize(address(perpPoolFactory), address(matchingEngine), booker);

        // NOTE: deviating from the brief's `vm.prank(booker)` here -- PerpEngine's constructor
        // only grants MARKET_MAKER_ROLE to its deployer (this test contract), not to `booker`.
        // Pranking as booker would revert with InvalidRole. Calling directly as the deployer
        // preserves the intent (allowlisting the stablecoin) under the actual role model.
        perpEngine.setStablecoin(address(stablecoin), true);

        stablecoin.mint(trader1, 100000e18);
        stablecoin.mint(trader2, 100000e18);

        // list a real spot pair so PerpEngine.addPool's spot-liquidity requirement is satisfiable.
        // addPair now takes a MatchingMode argument (this branch's current signature); the
        // brief's 5-arg call is stale. This test contract deployed matchingEngine, so it holds
        // MARKET_MAKER_ROLE and addPair's listing-deposit path is a no-op for it.
        matchingEngine.addPair(
            address(token1), address(stablecoin), 100e8, 0, address(token1), ExchangeOrderbook.MatchingMode.PriceTimePriority
        );
    }
}
