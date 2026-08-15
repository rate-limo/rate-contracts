// contracts/test/exchange/orderbook/PriceOracle.t.sol
pragma solidity >=0.8;

import {ExchangeOrderbook} from "../../../src/exchange/libraries/ExchangeOrderbook.sol";
import {BaseSetup} from "../OrderbookBaseSetup.sol";
import {Orderbook} from "../../../src/exchange/orderbooks/Orderbook.sol";
import {Oracle} from "../../../src/exchange/libraries/Oracle.sol";
import {IMatchingEngine} from "../../../src/exchange/interfaces/IMatchingEngine.sol";

/// @notice Integration-level tests for `Orderbook.twap()` against the *real* MatchingEngine/
/// Orderbook, using actual trades rather than the isolated ring-buffer unit tests in
/// `Oracle.t.sol`. This is the test that demonstrates the actual fix: `lmp()` alone reflects a
/// single manipulated trade at 100% weight, `twap()` does not.
contract PriceOracleTest is BaseSetup {
    function setUp() public override {
        super.setUp();
        matchingEngine.addPair(address(token1), address(token2), 100e8, 0, address(token1), ExchangeOrderbook.MatchingMode.PriceTimePriority);
        book = Orderbook(payable(orderbookFactory.getPair(address(token1), address(token2))));
    }

    /// @dev Crosses a fresh ask/bid pair at `price`, moving `lmp()` (and writing a TWAP
    /// observation) to exactly `price`.
    function _tradeAt(uint256 price) internal {
        vm.prank(trader1);
        matchingEngine.limitSell(
            IMatchingEngine.LimitOrderInput({
                base: address(token1),
                quote: address(token2),
                price: price,
                amount: 1e18,
                isMaker: true,
                n: 2,
                recipient: trader1
            })
        );
        vm.prank(trader2);
        matchingEngine.limitBuy(
            IMatchingEngine.LimitOrderInput({
                base: address(token1),
                quote: address(token2),
                price: price,
                amount: 1e18,
                isMaker: true,
                n: 2,
                recipient: trader2
            })
        );
    }

    function testTwapRevertsRightAfterListing() public {
        // Listing itself calls setLmp(100e8), seeding the buffer -- but zero time has passed,
        // so there's no valid window yet.
        vm.expectRevert(
            abi.encodeWithSelector(Oracle.InsufficientHistory.selector, uint32(1), uint32(0))
        );
        book.twap(1);
    }

    function testTwapTracksStablePriceWithNoTrades() public {
        // No trades at all after listing -- twap() must still work by extrapolating the live
        // (unchanged) lmp forward across the whole gap.
        vm.warp(block.timestamp + 500);
        (uint256 price, uint32 window) = book.twap(400);
        assertEq(price, 100e8);
        assertGe(window, 400);
    }

    /// @notice The core scenario: a stable, listed price with no trading for 600 seconds, then
    /// a single manipulative trade that crosses at the maximum a single trade can reach under
    /// this pair's spread bound (2%, per BaseSetup's default spread -- see `_limitBuy`'s
    /// `getSpread` bound at `MatchingEngine.sol:746`). `lmp()` reflects that trade's price
    /// entirely and immediately; `twap()` over the preceding 600s barely moves, because one
    /// second of elevated price is a vanishingly small fraction of a 601-second window.
    function testTwapResistsManipulationFromARealCrossingTrade() public {
        vm.warp(block.timestamp + 600); // 600s of no trading at the listed price, 100e8
        assertEq(book.lmp(), 100e8);

        uint256 attackPrice = (book.lmp() * 102_000_000) / 100_000_000; // lmp * (1 + 2%) -- the
        // same bound _limitBuy itself computes to cap how far a single order can walk the book
        _tradeAt(attackPrice);
        assertEq(book.lmp(), 102e8); // lmp() reflects the manipulated trade immediately, in full

        vm.warp(block.timestamp + 1); // a subsequent tx reads twap() one second later
        (uint256 twapPrice, uint32 window) = book.twap(600);
        // (100e8*600 + 102e8*1) / 601 ~= 100.0033e8 -- versus lmp()'s 102e8 (a full, undiluted 2%).
        assertApproxEqAbs(twapPrice, 100e8, 1e7); // within ~0.1% of the pre-attack price
        assertLt(twapPrice, 101e8); // stays far below the manipulated lmp()
        assertEq(window, 601);
    }

    function testTwapRevertsWhenRequestedWindowExceedsHistory() public {
        vm.warp(block.timestamp + 100);
        _tradeAt(100e8);

        vm.expectRevert(
            abi.encodeWithSelector(Oracle.InsufficientHistory.selector, uint32(1000), uint32(100))
        );
        book.twap(1000);
    }
}
