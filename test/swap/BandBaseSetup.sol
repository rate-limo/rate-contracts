// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {ExchangeOrderbook} from "../../src/exchange/libraries/ExchangeOrderbook.sol";
import {Test} from "forge-std/Test.sol";
import {MatchingEngine} from "../../src/exchange/MatchingEngine.sol";
import {OrderbookFactory} from "../../src/exchange/orderbooks/OrderbookFactory.sol";
import {Orderbook} from "../../src/exchange/orderbooks/Orderbook.sol";
import {WETH9} from "../../src/mock/WETH9.sol";
import {MockBase} from "../../src/mock/MockBase.sol";
import {MockQuote} from "../../src/mock/MockQuote.sol";
import {BandPool} from "../../src/swap/BandPool.sol";
import {BandPoolFactory} from "../../src/swap/BandPoolFactory.sol";
import {BandPositionManager} from "../../src/swap/BandPositionManager.sol";
import {IBandPositionManager} from "../../src/swap/interfaces/IBandPositionManager.sol";
import {BandSwapRouter} from "../../src/swap/BandSwapRouter.sol";
import {Utils} from "../utils/Utils.sol";

/**
 * The real stack: a genuine MatchingEngine, OrderbookFactory, Orderbook and oracle,
 * with a band pool, factory, manager and router wired the way a deployment wires them.
 *
 * The band suites elsewhere use stubs, which is right for the arithmetic they pin --
 * a stub book cannot drift and cannot fail for reasons unrelated to the case. But two
 * things can only be checked against the real contracts: `Oracle`'s seeding and window
 * behaviour, and the `MatchingLib` rail that clamps what a swap writes to `lmp`. Both
 * ship, both are shared, and both used to be covered only through `Pool`.
 */
contract BandBaseSetup is Test {
    Utils public utils;
    MatchingEngine public matchingEngine;
    WETH9 public weth;
    OrderbookFactory public orderbookFactory;
    BandPoolFactory public poolFactory;
    BandPositionManager public positionManager;
    BandSwapRouter public router;
    MockBase public token1; // base
    MockQuote public token2; // quote
    Orderbook public book;
    BandPool public pool;

    address payable[] public users;
    address public trader1;
    address public trader2;
    address public lp1;
    address public booker;
    address public creator;

    uint256 constant LISTING = 100e8;

    function setUp() public virtual {
        utils = new Utils();
        users = utils.createUsers(5);
        trader1 = users[0];
        trader2 = users[1];
        lp1 = users[2];
        booker = users[3];
        creator = users[4];

        token1 = new MockBase("Base", "BASE");
        token2 = new MockQuote("Quote", "QUOTE");
        weth = new WETH9();
        for (uint256 i = 0; i < 3; i++) {
            token1.mint(users[i], 10_000_000e18);
            token2.mint(users[i], 10_000_000e18);
        }

        matchingEngine = new MatchingEngine();
        orderbookFactory = new OrderbookFactory();
        orderbookFactory.initialize(address(matchingEngine));
        matchingEngine.initialize(address(orderbookFactory), address(booker), address(weth));

        positionManager = new BandPositionManager();
        positionManager.initialize("");
        router = new BandSwapRouter();

        poolFactory = new BandPoolFactory();
        poolFactory.initialize(address(matchingEngine), address(positionManager), address(new BandPool()), creator);
        positionManager.setPoolFactory(address(poolFactory));
        matchingEngine.setPoolFactory(address(poolFactory));
        // One address, both halves: the pool's onlyRouter gate and the engine's
        // reportSwap gate read this same slot.
        matchingEngine.setSwapRouter(address(router));

        // Wide enough that the rail is not the thing under test unless a case says so.
        matchingEngine.setDefaultSpread(10000000, 10000000, true);
        matchingEngine.setDefaultSpread(10000000, 10000000, false);
        matchingEngine.setDefaultFee(true, 100000);
        matchingEngine.setDefaultFee(false, 100000);

        matchingEngine.addPair(
            address(token1), address(token2), LISTING, 0, address(token1),
            ExchangeOrderbook.MatchingMode.PriceTimePriority
        );
        book = Orderbook(payable(matchingEngine.getPair(address(token1), address(token2))));
        pool = BandPool(poolFactory.getPool(address(token1), address(token2)));
        // This contract listed the pair, so it is the pool's creator. Fractions of the
        // 10% limit that reproduce the 0.1 / 0.3 / 0.5% ladder these suites were written
        // against; the creator's `configureBands` is the production path for that.
        uint32[] memory fracs = new uint32[](3);
        uint32[] memory mults = new uint32[](3);
        fracs[0] = 1000000;
        fracs[1] = 3000000;
        fracs[2] = 5000000;
        mults[0] = 100000000;
        mults[1] = 200000000;
        mults[2] = 300000000;
        pool.configureBands(fracs, mults);
    }

    /// The position `_seedBands` minted.
    uint256 public lpToken;

    /// Seed every band equally in ONE position, through the manager, as an LP would.
    function _seedBands(uint256 perBand) internal returns (uint256 tokenId) {
        vm.startPrank(lp1);
        token1.approve(address(positionManager), type(uint256).max);
        token2.approve(address(positionManager), type(uint256).max);
        // Hoisted: re-reading the count in the loop condition keeps an extra value live,
        // and --via-ir inlines this helper into its callers' frames.
        uint8 count = uint8(pool.bandCount());
        uint8[] memory bands = new uint8[](count);
        uint256[] memory baseAmounts = new uint256[](count);
        uint256[] memory quoteAmounts = new uint256[](count);
        uint128[] memory minShares = new uint128[](count);
        for (uint8 i = 0; i < count; i++) {
            bands[i] = i;
            baseAmounts[i] = perBand;
        }
        (tokenId,) = positionManager.mint(
            IBandPositionManager.MintParams({
                pool: address(pool),
                bands: bands,
                baseAmounts: baseAmounts,
                quoteAmounts: quoteAmounts,
                minShares: minShares,
                recipient: lp1,
                deadline: block.timestamp
            })
        );
        vm.stopPrank();
        lpToken = tokenId;
    }

    function _buy(address who, uint256 quoteIn) internal returns (uint256) {
        vm.startPrank(who);
        token2.approve(address(router), type(uint256).max);
        uint256 out = router.swap(address(pool), quoteIn, true, who, 0);
        vm.stopPrank();
        return out;
    }

    function _lmp() internal view returns (uint256) {
        return book.lmp();
    }
}
