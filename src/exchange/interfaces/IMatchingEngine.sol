// SPDX-License-Identifier: BUSL-1.1
import {ExchangeOrderbook} from "../libraries/ExchangeOrderbook.sol";

pragma solidity ^0.8.24;

interface IMatchingEngine {

    struct OrderData {
        /// Amount after removing fee
        uint256 withoutFee;
        /// Orderbook contract address
        address pair;
        /// Head price on bid orderbook, the highest bid price
        uint256 bidHead;
        /// Head price on ask orderbook, the lowest ask price
        uint256 askHead;
        /// Market price on pair
        uint256 lmp;
        /// Spread(volatility) limit on limit/market | buy/sell for market suspensions(e.g. circuit breaker, tick)
        uint32 spreadLimit;
        /// Make order id
        uint32 makeId;
        /// Whether an order deposit has been cleared
        bool clear;
    }

    struct DefaultSpread {
        /// Buy spread limit
        uint32 buy;
        /// Sell spread limit
        uint32 sell;
    }


    struct OrderMatch {
        address sender;
        address owner;
        uint256 baseAmount;
        uint256 quoteAmount;
        uint256 baseFee;
        uint256 quoteFee;
        uint64 tradeId;
    }

    struct OrderResult {
        uint256 makePrice;
        uint256 placed;
        uint32 id;
    }

    struct CancelOrderInput {
        address base;
        address quote;
        bool isBid;
        uint32 orderId;
    }

    /**
     * @notice The single EOA-facing order input.
     * @dev Passed as `calldata` from the frontend. This struct is the whole public
     * order API: `isLimit` selects limit vs market, `isBid` selects buy vs sell, and
     * a `base`/`quote` of WETH with matching `msg.value` selects the ETH path, so the
     * scalar limitBuy/limitSell/marketBuy/marketSell overloads (and their ETH and
     * WithDeadline variants) are all expressible here.
     *
     * The last three fields were added when this became the frontend's entry point:
     * `_createOrder` previously hardcoded `isMaker = true` and used the venue default
     * spread, so a caller could express neither a taker order nor its own slippage.
     * They are appended rather than ordered by packing because a calldata struct pads
     * every field to 32 bytes regardless — ordering here is diff size, not gas.
     */
    struct CreateOrderInput {
        address base;
        address quote;
        bool isBid;
        bool isLimit;
        uint32 orderId;
        uint256 price;
        uint256 amount;
        uint32 n;
        address recipient;
        bool isMaker;
        /// @dev Market orders only. Limit orders read the pair's spread instead.
        uint32 slippageLimit;
        /// @dev 0 means no deadline, matching the bare (non-WithDeadline) overloads.
        uint64 deadline;
    }

    /**
     * @notice One calldata struct per shape of order entry, matching `CreateOrderInput`.
     * @dev These exist for the CALL SITE, not for the chain: a positional list of seven
     * arguments, three of which are addresses and two of which are booleans, is a shape
     * wagmi/viem callers get silently wrong — swap `isMaker` and the two 32-bit numbers and
     * it still encodes. A named object cannot be mis-ordered.
     *
     * Neither carries a `deadline`, and that is a size decision as much as a design one.
     * `createOrder` already expresses every shape of order INCLUDING a deadline
     * (`isLimit` selects limit vs market, `isBid` selects side), so a deadline here would
     * be a second path to a capability that already has a home. It is not free: wiring
     * `_checkDeadline` + `orderDeadlineContext` through these four entrypoints measured
     * **+331 bytes**, against 180 bytes of EIP-170 headroom. Deadline-bearing orders go
     * through `createOrder`, which is where this branch already sends them.
     *
     * Field order follows main's shape rather than packing order: a calldata struct pads
     * every field to 32 bytes regardless, so ordering here is diff size, not gas.
     */
    struct MarketOrderInput {
        address base;
        address quote;
        uint256 amount;
        bool isMaker;
        uint32 n;
        address recipient;
        uint32 slippageLimit;
    }

    /// @dev Limit orders read the pair's spread, so there is no `slippageLimit` here.
    struct LimitOrderInput {
        address base;
        address quote;
        uint256 price;
        uint256 amount;
        bool isMaker;
        uint32 n;
        address recipient;
    }

    struct StopMarketInput {
        address base;
        address quote;
        bool isBid;
        uint256 stopPrice;
        uint256 amount;
        uint32 n;
        uint32 slippageLimit;
        uint64 deadline;
        address recipient;
    }

    struct MatchAtInput {
        address pair;
        address give;
        address recipient;
        bool isBid;
        uint256 amount;
        uint256 total;
        uint256 price;
        uint32 i;
        uint32 n;
        uint16 orderHistoryId;
    }

    struct LimitOrderState {
        uint256 lmp;
        uint32 i;
        uint32 prevI;
    }

    // admin functions
    function setFeeTo(address feeTo_) external returns (bool success);

    function setDefaultFee(bool isMaker, uint32 fee_) external returns (bool success);

    function setPairFeeClass(address pair, uint8 feeClass, uint32 makerFee, uint32 takerFee)
        external
        returns (bool success);

    function setFeeManager(address feeManager) external returns (bool success);

    function setPoolFeeShare(uint32 poolFeeShare_) external returns (bool success);

    function poolFeeShare() external view returns (uint32);

    function setPoolFactory(address poolFactory_) external returns (bool success);

    function poolFactory() external view returns (address);

    function setDefaultSpread(uint32 buy, uint32 sell, bool isMkt) external returns (bool success);

    function setSpread(address base, address quote, uint32 buy, uint32 sell, bool isMkt)
        external
        returns (bool success);

    function updatePair(address base, address quote, uint256 listingPrice, uint256 listingDate)
        external
        returns (address pair);

    // user functions
    function marketBuy(MarketOrderInput calldata input) external returns (OrderResult memory result);

    function marketSell(MarketOrderInput calldata input) external returns (OrderResult memory result);

    function limitBuy(LimitOrderInput calldata input) external returns (OrderResult memory result);

    function limitSell(LimitOrderInput calldata input) external returns (OrderResult memory result);

    function addPair(
        address base,
        address quote,
        uint256 listingPrice,
        uint256 listingDate,
        address payment,
        ExchangeOrderbook.MatchingMode mode
    ) external returns (address pair);

    function createOrder(CreateOrderInput calldata createOrderData)
        external
        payable
        returns (OrderResult memory result);

    function createOrders(CreateOrderInput[] calldata createOrderData) external payable returns (OrderResult[] memory results);

    function updateOrders(CreateOrderInput[] calldata createOrderData) external payable returns (OrderResult[] memory results);

    function cancelOrder(address base, address quote, bool isBid, uint32 orderId) external returns (uint256 refunded);

    function expireOrder(address base, address quote, bool isBid, uint32 orderId)
        external returns (uint256 refunded);

    function cancelOrders(CancelOrderInput[] memory cancelOrders) external returns (uint256[] memory refunded);

    function setStopOrderEngine(address stopOrderEngine_) external;

    function getOrder(address base, address quote, bool isBid, uint32 orderId)
        external
        view
        returns (ExchangeOrderbook.Order memory);

    function getPair(address base, address quote) external view returns (address book);

    function heads(address base, address quote) external view returns (uint256 bidHead, uint256 askHead);

    function mktPrice(address base, address quote) external view returns (uint256);

    function convert(address base, address quote, uint256 amount, bool isBid)
        external
        view
        returns (uint256 converted);

    function feeTo() external view returns (address);

    function incentive() external view returns (address);

    function feeOf(address base, address quote, address account, bool isMaker) external view returns (uint32 feeNum);

    /// The pair's spread bound, DENOM-scaled. `isMkt` selects the market bound (taker
    /// actions, tighter) from the limit bound (orders that can rest).
    function getSpread(address pair, bool isBuy, bool isMkt) external view returns (uint32 spreadLimit);

    /// The one router allowed to call `reportSwap`, and the address `Pool.onlyRouter`
    /// checks against. address(0) until an admin wires one up.
    function swapRouter() external view returns (address);

    /// Reports the price a swap actually matched at, so the pair's lmp reflects real
    /// trades through the pool the same way it reflects trades on the book. Router-only.
    /// Clamped to the pair's market spread on the way in -- a bound on how far one swap
    /// may move the price, not the thing that determines it. Writing lmp records an
    /// oracle observation, which is how pool volume reaches the TWAP at all.
    function reportSwap(address base, address quote, bool isBuy, uint256 matchedPrice) external;
}
