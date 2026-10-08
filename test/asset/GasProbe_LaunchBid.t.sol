// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LadderBuyerTest} from "./LadderBuyer.t.sol";
import {BandPool} from "../../src/swap/BandPool.sol";
import {IBandPositionManager} from "../../src/swap/interfaces/IBandPositionManager.sol";
import {IMatchingEngine} from "../../src/exchange/interfaces/IMatchingEngine.sol";
import {IOrderbook} from "../../src/exchange/interfaces/IOrderbook.sol";

/**
 * What it would cost to support a launch from its own proceeds.
 *
 * The proposal: as the ladder sells, the quote the escrow collects is deposited into
 * BAND 0 -- the tightest band -- as a one-sided wall, so a seller has something to hit
 * before graduation. This measures the parts, so the decision is made against numbers.
 *
 * A probe, not a test: it asserts almost nothing and prints. The one thing it DOES
 * assert is the question I could not answer by reading -- whether a SECOND one-sided
 * deposit into a band that already holds quote can be priced at all, given the band
 * pool's anchor is a 300-second TWAP and a launch pool has never traded.
 */
contract GasProbe_LaunchBidTest is LadderBuyerTest {
    uint256 private constant SUPPORT = 200e6; // a slice of one step's proceeds

    function _band0(uint256 quoteAmount)
        private
        view
        returns (uint8[] memory bands, uint256[] memory base, uint256[] memory quote, uint128[] memory minShares)
    {
        bands = new uint8[](1);
        base = new uint256[](1);
        quote = new uint256[](1);
        minShares = new uint128[](1);
        quote[0] = quoteAmount;
    }

    function test_gas_whatSupportingTheLaunchWouldCost() public {
        address coin = _launch(address(usdc), MIN6);
        BandPool pool = _pool(coin, address(usdc));
        _fund(alice, 20_000e6);

        // ---------------------------------------------------------- the baseline
        vm.prank(alice);
        uint256 g = gasleft();
        buyer.buy(coin, address(usdc), 800e6, 2500, 0, alice, block.timestamp);
        uint256 oneStep = g - gasleft();

        vm.prank(alice);
        g = gasleft();
        buyer.buy(coin, address(usdc), 11_000e6, 2500, 0, alice, block.timestamp);
        uint256 restOfLadder = g - gasleft();

        console.log("BASELINE, as it ships today");
        console.log("  buy, one step        ", oneStep);
        console.log("  buy, the rest        ", restOfLadder);

        // --------------------------------------------------- what support adds
        // The generator is the pool's creator until graduation, so only it can open a band.
        vm.prank(address(gen));
        g = gasleft();
        pool.setBandOpen(0, true);
        uint256 openBand = g - gasleft();

        // The escrow's sweep is an ordinary ERC-20 transfer; measure one.
        usdc.mint(address(this), 10_000e6);
        g = gasleft();
        usdc.transfer(address(0xBEEF), SUPPORT);
        uint256 sweep = g - gasleft();

        // An EOA stands in for the generator as the position's holder: this test
        // contract is no ERC-1155 receiver, and the holder is irrelevant to the cost.
        address supporter = address(0x5577);
        usdc.mint(supporter, 10_000e6);
        vm.prank(supporter);
        usdc.approve(address(positionManager), type(uint256).max);
        (uint8[] memory bands, uint256[] memory base, uint256[] memory quote, uint128[] memory minShares) =
            _band0(SUPPORT);

        // FIRST support deposit: a new position, a new slot, an ERC-1155 mint.
        vm.prank(supporter);
        g = gasleft();
        (uint256 tokenId,) = positionManager.mint(
            IBandPositionManager.MintParams({
                pool: address(pool),
                bands: bands,
                baseAmounts: base,
                quoteAmounts: quote,
                minShares: minShares,
                recipient: supporter,
                deadline: block.timestamp
            })
        );
        uint256 firstDeposit = g - gasleft();

        console.log("WHAT SUPPORT ADDS");
        console.log("  setBandOpen(0,true)  ", openBand, "(once per coin)");
        console.log("  escrow sweep         ", sweep);
        console.log("  first deposit, mint  ", firstDeposit);

        // EVERY LATER deposit: topping the same token up. This is the one that repeats,
        // and the one whose pricing I could not settle by reading.
        vm.prank(supporter);
        g = gasleft();
        try positionManager.increaseLiquidity(tokenId, bands, base, quote, minShares, block.timestamp) {
            uint256 topUp = g - gasleft();
            console.log("  later deposit, top-up", topUp);
            console.log("PER BUY, AFTER THE FIRST");
            console.log("  added to a buy       ", sweep + topUp);
            console.log("  as a share of a step ", ((sweep + topUp) * 100) / oneStep, "% of one-step buy gas");
        } catch (bytes memory err) {
            console.log("  later deposit REVERTS -- a one-sided top-up cannot be priced here");
            console.logBytes(err);
            // Not a failure of the probe: this is the finding.
        }

        // The support wall must not make the BUY itself dearer: a ladder order is sized
        // to the book, so it never reaches the pool fallback. Measured, not assumed.
        address coin2 = _launch(address(usdc), MIN6);
        _fund(alice, 2_000e6);
        vm.prank(alice);
        g = gasleft();
        buyer.buy(coin2, address(usdc), 800e6, 2500, 0, alice, block.timestamp);
        uint256 withWallElsewhere = g - gasleft();
        console.log("CONTROL");
        console.log("  one-step buy, again  ", withWallElsewhere);
    }

    /// A wall exists to be HIT. Once a seller does, band 0 holds base as well as quote --
    /// and a one-sided top-up into a TWO-SIDED band is the case priced by value against
    /// the pool's 300-second anchor, which a launch pool has never fed. This is the case
    /// the other probe cannot reach, and the one the design actually depends on.
    function test_gas_topUpAfterTheWallIsHit() public {
        address coin = _launch(address(usdc), MIN6);
        BandPool pool = _pool(coin, address(usdc));
        _fund(alice, 20_000e6);
        vm.prank(alice);
        buyer.buy(coin, address(usdc), 800e6, 2500, 0, alice, block.timestamp);

        vm.prank(address(gen));
        pool.setBandOpen(0, true);

        address supporter = address(0x5577);
        usdc.mint(supporter, 10_000e6);
        vm.startPrank(supporter);
        usdc.approve(address(positionManager), type(uint256).max);
        uint256 tokenId = _mintWall(address(pool), supporter);
        vm.stopPrank();

        _sellInto(coin);

        (uint256 b0base, uint256 b0quote) = _band0Reserves(pool);
        console.log("AFTER THE SELL, band 0 holds");
        console.log("  base ", b0base);
        console.log("  quote", b0quote);

        (uint8[] memory bands, uint256[] memory base, uint256[] memory quote, uint128[] memory minShares) =
            _band0(SUPPORT);
        vm.prank(supporter);
        uint256 g = gasleft();
        try positionManager.increaseLiquidity(tokenId, bands, base, quote, minShares, block.timestamp) {
            console.log("  top-up into a TWO-SIDED band", g - gasleft());
        } catch (bytes memory err) {
            console.log("  top-up into a two-sided band REVERTS");
            console.logBytes(err);
        }
    }

    function _mintWall(address pool, address to) private returns (uint256 tokenId) {
        (uint8[] memory bands, uint256[] memory base, uint256[] memory quote, uint128[] memory minShares) =
            _band0(SUPPORT);
        (tokenId,) = positionManager.mint(
            IBandPositionManager.MintParams({
                pool: pool,
                bands: bands,
                baseAmounts: base,
                quoteAmounts: quote,
                minShares: minShares,
                recipient: to,
                deadline: block.timestamp
            })
        );
    }

    function _sellInto(address coin) private {
        uint256 sold = IERC20(coin).balanceOf(alice) / 50;
        vm.startPrank(alice);
        IERC20(coin).approve(address(buyer), type(uint256).max);
        try buyer.sell(coin, address(usdc), sold, 0, 0, alice, block.timestamp) returns (uint256 out, uint256) {
            console.log("THE WALL WAS HIT: quote received", out);
        } catch {
            console.log("THE SELL DID NOT REACH THE WALL (the ladder path never routes to the pool)");
        }
        vm.stopPrank();
    }

    function _band0Reserves(BandPool pool) private view returns (uint256 baseR, uint256 quoteR) {
        return pool.bandReserves(0);
    }

    /// The wall is only worth funding if a seller can REACH it. LadderBuyer cannot --
    /// it sizes every order to the book and its own docblock says nothing reaches the
    /// pool fallback. A market sell straight at the engine is the path that can.
    function test_gas_doesAMarketSellReachTheWall() public {
        address coin = _launch(address(usdc), MIN6);
        BandPool pool = _pool(coin, address(usdc));
        _fund(alice, 20_000e6);
        vm.prank(alice);
        buyer.buy(coin, address(usdc), 800e6, 2500, 0, alice, block.timestamp);

        vm.prank(address(gen));
        pool.setBandOpen(0, true);
        address supporter = address(0x5577);
        usdc.mint(supporter, 10_000e6);
        vm.startPrank(supporter);
        usdc.approve(address(positionManager), type(uint256).max);
        _tid = _mintWall(address(pool), supporter);
        vm.stopPrank();

        uint256 sell = IERC20(coin).balanceOf(alice) / 50;
        uint256 before = usdc.balanceOf(alice);
        vm.startPrank(alice);
        IERC20(coin).approve(address(matchingEngine), type(uint256).max);
        uint256 g = gasleft();
        try matchingEngine.marketSell(
            IMatchingEngine.MarketOrderInput({
                base: coin,
                quote: address(usdc),
                amount: sell,
                isMaker: false,
                n: 2,
                recipient: alice,
                slippageLimit: 0
            })
        ) {
            console.log("A MARKET SELL REACHES THE WALL");
            console.log("  gas                  ", g - gasleft());
            console.log("  quote received       ", usdc.balanceOf(alice) - before);
        } catch (bytes memory err) {
            console.log("A MARKET SELL DOES NOT REACH IT");
            console.logBytes(err);
        }
        vm.stopPrank();
        (uint256 b, uint256 q) = _band0Reserves(pool);
        console.log("  band 0 after: base", b);
        console.log("  band 0 after: quote", q);

        // NOW the band holds both sides, which is the case priced BY VALUE against the
        // pool's 300-second anchor. A launch pool has never fed that anchor.
        (uint8[] memory bands, uint256[] memory base, uint256[] memory quote, uint128[] memory minShares) =
            _band0(SUPPORT);
        vm.prank(supporter);
        uint256 g2 = gasleft();
        try positionManager.increaseLiquidity(_tid, bands, base, quote, minShares, block.timestamp) {
            console.log("  TOP-UP into the two-sided band", g2 - gasleft());
        } catch (bytes memory e2) {
            console.log("  TOP-UP into the two-sided band REVERTS");
            console.logBytes(e2);
        }
    }

    uint256 private _tid;

    /// Could LadderBuyer.sell be MADE to reach the wall? It sends taker LIMIT orders.
    /// If one of those routes to the pool when the book has nothing, the fix is small.
    function test_canATakerLimitSellReachTheWall() public {
        address coin = _launch(address(usdc), MIN6);
        BandPool pool = _pool(coin, address(usdc));
        _fund(alice, 20_000e6);
        vm.prank(alice);
        buyer.buy(coin, address(usdc), 800e6, 2500, 0, alice, block.timestamp);

        vm.prank(address(gen));
        pool.setBandOpen(0, true);
        address supporter = address(0x5577);
        usdc.mint(supporter, 10_000e6);
        vm.startPrank(supporter);
        usdc.approve(address(positionManager), type(uint256).max);
        _mintWall(address(pool), supporter);
        vm.stopPrank();

        uint256 sell = IERC20(coin).balanceOf(alice) / 50;
        uint256 before = usdc.balanceOf(alice);
        vm.startPrank(alice);
        IERC20(coin).approve(address(matchingEngine), type(uint256).max);
        uint256 g = gasleft();
        try matchingEngine.limitSell(
            IMatchingEngine.LimitOrderInput({
                base: coin,
                quote: address(usdc),
                price: 1,              // priced to cross anything: a pure taker
                amount: sell,
                isMaker: false,        // never rest
                n: 2,
                recipient: alice
            })
        ) {
            console.log("A TAKER LIMIT SELL REACHES THE WALL");
            console.log("  gas            ", g - gasleft());
            console.log("  quote received ", usdc.balanceOf(alice) - before);
        } catch (bytes memory err) {
            console.log("A TAKER LIMIT SELL DOES NOT REACH IT");
            console.logBytes(err);
        }
        vm.stopPrank();
        (uint256 b, uint256 q) = _band0Reserves(pool);
        console.log("  band 0 base ", b);
        console.log("  band 0 quote", q);
    }

    /// WHY the ladder sell missed the wall, read off the chain rather than the source.
    function test_whyTheLadderSellMissedTheWall() public {
        address coin = _launch(address(usdc), MIN6);
        BandPool pool = _pool(coin, address(usdc));
        _fund(alice, 20_000e6);
        vm.prank(alice);
        buyer.buy(coin, address(usdc), 800e6, 2500, 0, alice, block.timestamp);

        vm.prank(address(gen));
        pool.setBandOpen(0, true);
        address supporter = address(0x5577);
        usdc.mint(supporter, 10_000e6);
        vm.startPrank(supporter);
        usdc.approve(address(positionManager), type(uint256).max);
        _mintWall(address(pool), supporter);
        vm.stopPrank();

        IOrderbook book = IOrderbook(matchingEngine.getPair(coin, address(usdc)));
        console.log("WHAT THE SELL LOOKS AT");
        console.log("  book bidHead         ", book.bidHead(), "<- the only thing _reachable reads");
        console.log("  book askHead         ", book.askHead(), "<- the ladder, untouchable by a seller");
        (uint256 wb, uint256 wq) = _band0Reserves(pool);
        console.log("  band 0 base          ", wb);
        console.log("  band 0 quote         ", wq, "<- real liquidity, not on the book");

        uint256 sell = IERC20(coin).balanceOf(alice) / 50;
        uint256 coinsBefore = IERC20(coin).balanceOf(alice);
        vm.startPrank(alice);
        IERC20(coin).approve(address(buyer), type(uint256).max);
        (uint256 out, uint256 refunded) = buyer.sell(coin, address(usdc), sell, 0, 0, alice, block.timestamp);
        vm.stopPrank();

        console.log("WHAT CAME BACK");
        console.log("  offered              ", sell);
        console.log("  quote received       ", out);
        console.log("  coins refunded       ", refunded);
        console.log("  coins actually spent ", coinsBefore - IERC20(coin).balanceOf(alice));

        assertEq(out, 0, "no fill");
        assertEq(refunded, sell, "every coin came back: not one order was sent");
        (uint256 b2, uint256 q2) = _band0Reserves(pool);
        assertEq(b2, wb, "band 0 base untouched");
        assertEq(q2, wq, "band 0 quote untouched");
    }

    /// The engine's rule for reaching the pool is isMaker, not limit-vs-market.
    /// Same order, same price, same wall -- only the flag differs.
    function test_theEnginesRuleIsIsMaker_notLimitVsMarket() public {
        address coin = _launch(address(usdc), MIN6);
        BandPool pool = _pool(coin, address(usdc));
        _fund(alice, 20_000e6);
        vm.prank(alice);
        buyer.buy(coin, address(usdc), 800e6, 2500, 0, alice, block.timestamp);

        vm.prank(address(gen));
        pool.setBandOpen(0, true);
        address supporter = address(0x5577);
        usdc.mint(supporter, 10_000e6);
        vm.startPrank(supporter);
        usdc.approve(address(positionManager), type(uint256).max);
        _mintWall(address(pool), supporter);
        vm.stopPrank();

        uint256 half = IERC20(coin).balanceOf(alice) / 100;
        vm.startPrank(alice);
        IERC20(coin).approve(address(matchingEngine), type(uint256).max);

        // isMaker TRUE -- the remainder is meant to rest, so detMake returns before the pool
        uint256 q0 = usdc.balanceOf(alice);
        matchingEngine.limitSell(IMatchingEngine.LimitOrderInput({
            base: coin, quote: address(usdc), price: 1, amount: half,
            isMaker: true, n: 2, recipient: alice
        }));
        console.log("LIMIT SELL, isMaker TRUE");
        console.log("  quote received ", usdc.balanceOf(alice) - q0);
        (uint256 b1, uint256 q1b) = _band0Reserves(pool);
        console.log("  band 0 base    ", b1);
        console.log("  band 0 quote   ", q1b);

        // isMaker FALSE -- the taker path, which is the one that routes to the pool
        uint256 q2 = usdc.balanceOf(alice);
        matchingEngine.limitSell(IMatchingEngine.LimitOrderInput({
            base: coin, quote: address(usdc), price: 1, amount: half,
            isMaker: false, n: 2, recipient: alice
        }));
        console.log("LIMIT SELL, isMaker FALSE");
        console.log("  quote received ", usdc.balanceOf(alice) - q2);
        (uint256 b3, uint256 q3) = _band0Reserves(pool);
        console.log("  band 0 base    ", b3);
        console.log("  band 0 quote   ", q3);
        vm.stopPrank();
    }
}
