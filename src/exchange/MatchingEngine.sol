// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.24;

import {IOrderbookFactory} from "./interfaces/IOrderbookFactory.sol";
import {IOrderbook, ExchangeOrderbook} from "./interfaces/IOrderbook.sol";
import {TransferHelper} from "./libraries/TransferHelper.sol";
import {IWETH} from "./interfaces/IWETH.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IMatchingEngine} from "./interfaces/IMatchingEngine.sol";
import {MatchingLib} from "./libraries/MatchingLib.sol";
import {IPoolFactory} from "../swap/interfaces/IPoolFactory.sol";
import {IStopOrderEngine} from "./interfaces/IStopOrderEngine.sol";
import {StopOrderHandoffLib} from "./libraries/StopOrderHandoffLib.sol";
import {MarketMakePriceLib} from "./libraries/MarketMakePriceLib.sol";

interface IProtocol {
    function feeOf(
        address base,
        address quote,
        address account,
        bool isMaker
    ) external view returns (uint32 feeNum);

    function isSubscribed(
        address account
    ) external view returns (bool isSubscribed);

    function terminalName(
        address terminal
    ) external view returns (string memory terminalName);
}

// Onchain Matching engine for the orders
contract MatchingEngine is ReentrancyGuard, AccessControl, IMatchingEngine {
    // Market maker role
    bytes32 private constant MARKET_MAKER_ROLE = keccak256("MARKET_MAKER_ROLE");
    // fee recipient for point storage
    address public feeTo;
    // incentive address
    address public incentive;
    uint32 public constant DENOM = 100000000;
    // Maker fee in numerator for DENOM=100000000. Zero deliberately: on-chain a
    // maker already pays gas to place and to cancel, which is the friction a CEX
    // maker fee substitutes for (there, quoting and cancelling are free). Wash
    // trading still costs the taker fee on every round trip, so the deterrent a
    // maker fee buys elsewhere is already paid for here in gas.
    //
    // Note this is the rate charged TO a maker, not the share paid to one --
    // that is poolFeeShare, applied to the taker fee, and unaffected.
    uint32 private defaultMakerFee = 0;
    // base taker fee in numerator for DENOM=100000000
    uint32 private defaultTakerFee = 100000;
    // Share of maker/taker fee routed to a pair's registered Pool instead of feeTo,
    // for orders whose owner is that pair's Pool. DENOM=1e8 scale. Defaults to 0 (no
    // behavior change) -- see docs/swap/implementation-plan.md Task 4.
    uint32 public poolFeeShare;
    struct PairFeePolicy {
        uint32 makerFee;
        uint32 takerFee;
        uint8 feeClass;
        bool configured;
    }
    // Factories
    address public orderbookFactory;
    address public poolFactory;
    // WETH
    address public WETH;
    // default buy spread
    uint32 dfltMktBuy;
    // default sell spread
    uint32 dfltMktSell;
    // default buy spread
    uint32 dfltLmtBuy;
    // default sell spread
    uint32 dfltLmtSEll;
    // bool on initialization
    bool init;
    /// Max resting orders one taker may consume, set by {setMaxMatches}.
    ///
    /// PUBLIC because a caller cannot obey a bound it cannot read. `n` above this reverts
    /// the whole transaction with {TooManyMatches} rather than clamping, so a client that
    /// sizes an order from visible depth fails outright on exactly the deep books it most
    /// wants to hit — and, without a getter, its only recourse was to hard-code 20 and
    /// hope nobody called setMaxMatches (which has no upper bound and emits no event).
    ///
    /// `public` adds a getter and nothing else: this is a packed slot shared with the
    /// uint32s above and the uint16 below, and visibility does not move storage.
    uint32 public maxMatches;
    // history id count
    uint16 count = 0;

    // Spread limit setting
    mapping(address => DefaultSpread) public mktSpreadLimits;

    // Spread limit setting
    mapping(address => DefaultSpread) public lmtSpreadLimits;

    // Listing Info setting
    mapping(address => uint256) public listingDates;

    event OrderCanceled(
        address pair,
        uint256 id,
        bool isBid,
        address indexed owner,
        uint256 amount
    );

    /**
     * @dev Emitted when a cancel inside a tolerant batch (`cancelOrders`) fails.
     * The failure is surfaced as an event with its revert reason instead of
     * being masked as a silent zero refund, so batch callers can still see
     * which orders could not be cancelled and why.
     */
    event OrderCancelSkipped(
        address pair,
        uint256 id,
        bool isBid,
        address indexed owner,
        bytes reason
    );

    event NewMarketPrice(address pair, uint256 price, bool isBid);

    /**
     * @dev This event is emitted when an order is successfully matched with a counterparty.
     * @param pair The address of the order book contract to get base and quote asset contract address.
     * @param orderHistoryId the unique identifier of order history submitted by the user in a block.
     * @param id The unique identifier of the matched maker order in bid/ask order database.
     * @param isBid A boolean indicating whether the matched order is a bid (true) or ask (false).
     * @param price The price at which the order is matched.
     * @param total The total amount of the asset being traded in the match.
     * @param clear Whether the order is cleared.
     * @param orderMatch The order match result.
     */
    event OrderMatched(
        address pair,
        uint16 orderHistoryId,
        uint256 id,
        bool isBid,
        uint256 price,
        uint256 total,
        bool clear,
        OrderMatch orderMatch
    );

    /// @notice Declared here as well as in MatchingLib so it appears in this
    /// contract's ABI. `matchAt` is a public library function, so the log carries
    /// the engine's address — but an event declared only in the library is absent
    /// from the engine's ABI, and an indexer watching this address would never
    /// decode it. Same reason OrderMatched and NewMarketPrice are duplicated.
    event OrderDusted(
        address pair,
        uint16 orderHistoryId,
        uint256 id,
        bool isBid,
        uint256 price,
        address owner,
        uint256 refunded
    );

    event OrderPlaced(
        address pair,
        uint16 orderHistoryId,
        uint256 id,
        address owner,
        bool isBid,
        uint256 price,
        uint256 withoutFee,
        uint256 placed
    );

    event OrderExpired(
        address indexed pair,
        uint32 indexed orderId,
        address indexed owner,
        bool isBid,
        bool isStop,
        bool isMarket,
        uint64 deadline,
        uint256 refunded
    );

    event PairAdded(
        address indexed pair,
        address indexed creator,
        TransferHelper.TokenInfo base,
        TransferHelper.TokenInfo quote,
        uint256 listingPrice,
        uint256 listingDate,
        string supportedTerminals
    );

    event PairUpdated(
        address pair,
        address base,
        address quote,
        uint256 listingPrice,
        uint256 listingDate
    );

    event PairFeeClassSet(
        address indexed pair,
        uint8 feeClass,
        uint32 makerFee,
        uint32 takerFee
    );
    event DefaultFeePolicySet(
        uint8 indexed feeClass, uint32 makerFee, uint32 takerFee, uint32 poolFeeShare
    );

    event PairCreate2(address deployer, bytes bytecode);

    error TooManyMatches(uint256 n);
    error OrderSizeTooSmall(uint256 amount, uint256 minRequired);
    error InvalidRole(bytes32 role, address sender);
    error InvalidPair(address base, address quote, address pair);
    error InvalidFeePair(address pair);
    error InvalidFeeClass(uint8 feeClass);
    error InvalidFeeRate(uint32 fee, uint256 denom);
    error PairNotListedYet(
        address base,
        address quote,
        uint256 listingDate,
        uint256 timeNow
    );
    error PairDoesNotExist(address base, address quote, address pair);
    error AmountIsZero();
    error FactoryNotInitialized(address factory);
    error AlreadyInitialized(bool init);
    error PoolFeeShareExceedsDenom(uint32 poolFeeShare, uint256 denom);
    error DeadlineExpired(uint64 deadline, uint256 timeNow);
    error OrderNotExpired(uint64 deadline, uint256 timeNow);
    error OrderCancelFailed(
        address orderbook,
        uint32 orderId,
        bool isBid,
        address sender,
        bytes reason
    );

    receive() external payable {
        assert(msg.sender == WETH); // only accept ETH via fallback from the WETH contract
    }

    /// The one SwapRouter allowed to report a swap's price impact, and the address
    /// Pool.onlyRouter checks against so both gates share one source of truth. Unset
    /// (address(0)) by default, so nothing passes until an admin wires it up -- and
    /// while it is unset, `Pool.swap` is closed to everyone. Wire this before listing.
    address public swapRouter;

    /// Separate stop-order lifecycle and matching module. Appended storage.
    address private stopOrderEngine;

    /// Canonical-pair fee policy keyed by the existing orderbook address. Appended
    /// storage: fee is state, never part of CREATE2 identity, so liquidity cannot
    /// fragment into duplicate books for the same base/quote assets.
    mapping(address => PairFeePolicy) public pairFeePolicy;

    /// Optional modular fee-policy controller. Appended storage.
    address public feeManager;

    /// Transient call context used only while a deadline-aware order is being made.
    /// Appended after all pre-existing storage to preserve proxy upgrade layout.
    uint64 private orderDeadlineContext;

    error NotSwapRouter(address caller, address swapRouter);

    /// Emitted alongside NewMarketPrice on a swap report. `reported` is the price the
    /// pool and the swapper actually matched at; `lmpAfter` is what was written, which
    /// differs only when the spread rail clamped it. An indexer can compare the two to
    /// see a swap that hit the circuit breaker.
    event SwapPriceReport(address indexed pair, uint256 lmpBefore, uint256 reported, uint256 lmpAfter, bool isBuy);

    function setSwapRouter(address swapRouter_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        swapRouter = swapRouter_;
    }

    function setStopOrderEngine(address stopOrderEngine_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        stopOrderEngine = stopOrderEngine_;
    }

    function getStopOrderEngine() external view returns (address) {
        return stopOrderEngine;
    }

    /// Records the price a swap actually matched at as the pair's last-matched price,
    /// then writes it through the orderbook -- which records an oracle observation on
    /// the way, so pool volume finally reaches the TWAP.
    ///
    /// `matchedPrice` is a real fill price: the pool and the swapper exchanged tokens at
    /// it. That is precisely what lmp is supposed to hold, and why it is reported rather
    /// than derived. A swap through the pool is a match like any other; the only reason
    /// it needed plumbing at all is that direct settlement bypasses the book, so nothing
    /// on the book's path ever saw it.
    ///
    /// The pair's market spread is applied here as a rail, not as the price: a single
    /// swap still cannot walk lmp further than the exchange's own circuit breaker
    /// allows, no matter what a replaceable router reports. Within the rail the reported
    /// price passes through untouched.
    function reportSwap(address base, address quote, bool isBuy, uint256 matchedPrice) external {
        if (msg.sender != swapRouter) {
            revert NotSwapRouter(msg.sender, swapRouter);
        }
        address pair = IOrderbookFactory(orderbookFactory).getPair(base, quote);
        if (pair == address(0)) return;

        // The rail itself lives in MatchingLib, moved there for EIP-170 headroom -- the
        // full reasoning for the two-sided, block-open-anchored cap is in its docstring.
        // Behaviour is unchanged: it is a delegatecall, so the pair still sees this
        // contract as its caller and both logs still carry this address.
        //
        // The two getSpread reads now happen before the lmp/matchedPrice zero checks
        // rather than after, because the library takes them as arguments. That costs two
        // SLOADs on the early-return path and changes nothing else.
        MatchingLib.reportSwapPrice(
            pair,
            matchedPrice,
            isBuy,
            getSpread(pair, true, true),
            getSpread(pair, false, true),
            DENOM
        );
    }

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(MARKET_MAKER_ROLE, msg.sender);
    }

    /**
     * @dev Initialize the matching engine with orderbook factory and listing requirements.
     * It can be called only once.
     * @param orderbookFactory_ address of orderbook factory
     * @param feeTo_ address to receive fee
     * @param WETH_ address of wrapped ether contract
     *
     * Requirements:
     * - `msg.sender` must have the default admin role.
     */
    function initialize(
        address orderbookFactory_,
        address feeTo_,
        address WETH_
    ) external {
        if (init) {
            revert AlreadyInitialized(init);
        }
        orderbookFactory = orderbookFactory_;
        feeTo = feeTo_;
        WETH = WETH_;
        dfltMktBuy = 100000;
        dfltMktSell = 100000;
        dfltLmtBuy = 3000000;
        dfltLmtSEll = 3000000;
        // get impl address of orderbook contract to predict address
        address impl = IOrderbookFactory(orderbookFactory_).impl();
        // Orderbook factory must be initialized first to locate pairs
        if (impl == address(0)) {
            revert FactoryNotInitialized(orderbookFactory_);
        }
        bytes memory bytecode = IOrderbookFactory(orderbookFactory_)
            .getByteCode();
        init = true;
        maxMatches = 20;
        emit DefaultFeePolicySet(2, defaultMakerFee, defaultTakerFee, poolFeeShare);
        emit PairCreate2(orderbookFactory, bytecode);
    }

    // admin functions
    function setFeeTo(
        address feeTo_
    ) external override onlyRole(DEFAULT_ADMIN_ROLE) returns (bool success) {
        feeTo = feeTo_;
        return true;
    }

    function setIncentive(
        address incentive_
    ) external onlyRole(DEFAULT_ADMIN_ROLE) returns (bool success) {
        incentive = incentive_;
        return true;
    }

    function setDefaultFee(
        bool isMaker,
        uint32 fee_
    ) external onlyRole(DEFAULT_ADMIN_ROLE) returns (bool success) {
        if (isMaker) {
            defaultMakerFee = fee_;
        } else {
            defaultTakerFee = fee_;
        }
        emit DefaultFeePolicySet(2, defaultMakerFee, defaultTakerFee, poolFeeShare);
        return true;
    }

    function setPairFeeClass(
        address pair,
        uint8 feeClass,
        uint32 makerFee,
        uint32 takerFee
    ) external returns (bool success) {
        if (msg.sender != feeManager) _checkRole(DEFAULT_ADMIN_ROLE);
        if (pair == address(0) || pair.code.length == 0) revert InvalidFeePair(pair);
        if (feeClass > 4) revert InvalidFeeClass(feeClass);
        if (makerFee > DENOM || takerFee > DENOM) {
            revert InvalidFeeRate(makerFee > takerFee ? makerFee : takerFee, DENOM);
        }
        pairFeePolicy[pair] = PairFeePolicy(makerFee, takerFee, feeClass, true);
        emit PairFeeClassSet(pair, feeClass, makerFee, takerFee);
        return true;
    }

    function setFeeManager(address feeManager_)
        external onlyRole(DEFAULT_ADMIN_ROLE) returns (bool success)
    {
        feeManager = feeManager_;
        return true;
    }

    function setPoolFeeShare(
        uint32 poolFeeShare_
    ) external onlyRole(DEFAULT_ADMIN_ROLE) returns (bool success) {
        if (poolFeeShare_ > DENOM) {
            revert PoolFeeShareExceedsDenom(poolFeeShare_, DENOM);
        }
        poolFeeShare = poolFeeShare_;
        emit DefaultFeePolicySet(2, defaultMakerFee, defaultTakerFee, poolFeeShare_);
        return true;
    }

    function setPoolFactory(
        address poolFactory_
    ) external onlyRole(DEFAULT_ADMIN_ROLE) returns (bool success) {
        poolFactory = poolFactory_;
        return true;
    }

    function setMaxMatches(
        uint32 n
    ) external onlyRole(DEFAULT_ADMIN_ROLE) returns (bool success) {
        maxMatches = n;
        return true;
    }

    function setDefaultSpread(
        uint32 buy,
        uint32 sell,
        bool isMkt
    ) external override onlyRole(DEFAULT_ADMIN_ROLE) returns (bool success) {
        if (isMkt) {
            dfltMktBuy = buy;
            dfltMktSell = sell;
        } else {
            dfltLmtBuy = buy;
            dfltLmtSEll = sell;
        }
        return true;
    }

    // market maker functions

    function setSpread(
        address base,
        address quote,
        uint32 buy,
        uint32 sell,
        bool isMkt
    ) external override returns (bool success) {
        // get pair
        address pair = IOrderbookFactory(orderbookFactory).getPair(base, quote);
        if (pair == address(0)) {
            revert PairDoesNotExist(base, quote, pair);
        }

        if (!hasRole(MARKET_MAKER_ROLE, _msgSender())) {
            if (!hasRole(bytes32(abi.encodePacked(pair)), _msgSender())) {
                revert InvalidRole(
                    bytes32(abi.encodePacked(pair)),
                    _msgSender()
                );
            }
        }

        _setSpread(pair, buy, sell, isMkt);
        return true;
    }

    // user functions
    function _nextHistoryId() internal view returns (uint16) {
        return count == 0 || count == type(uint16).max ? 1 : count + 1;
    }

    function _marketBuy(
        address base,
        address quote,
        uint256 quoteAmount,
        bool isMaker,
        uint32 n,
        address recipient,
        uint32 slippageLimit,
        uint16 orderHistoryId
    ) internal returns (OrderResult memory result) {
        OrderData memory orderData;

        // reuse quoteAmount variable as minRequired from _deposit to avoid stack too deep error
        (orderData.withoutFee, orderData.pair, orderData.lmp) = _deposit(
            base,
            quote,
            0,
            quoteAmount,
            true
        );

        // get spread limits
        slippageLimit = _pairSlippageLimit(base, quote, slippageLimit);
        orderData.spreadLimit = slippageLimit <=
            getSpread(orderData.pair, true, true)
            ? slippageLimit
            : getSpread(orderData.pair, true, true);

        orderData.lmp = mktPrice(base, quote);

        // reuse quoteAmount for storing amount after taking fees
        quoteAmount = orderData.withoutFee;

        // reuse withoutFee variable for storing remaining amount due to stack too deep error
        (
            orderData.withoutFee,
            orderData.bidHead,
            orderData.askHead
        ) = _limitOrder(
            orderData.pair,
            orderData.withoutFee,
            quote,
            recipient,
            true,
            (orderData.lmp * (DENOM + orderData.spreadLimit)) / DENOM,
            n,
            orderHistoryId
        );

        // reuse orderData.bidHead argument for storing make price
        orderData.bidHead = _detMarketBuyMakePrice(
            orderData.pair,
            orderData.bidHead,
            orderData.askHead,
            orderData.spreadLimit
        );

        // add make order on market price, reuse orderData.ls for storing placed Order id
        orderData.makeId = _detMake(
            base,
            quote,
            orderData.pair,
            orderData.withoutFee,
            orderData.bidHead,
            true,
            isMaker,
            recipient
        );

        // check if order id is made
        if (orderData.makeId > 0) {
            //if made, set last market price to orderData.bidHead only if orderData.bidHead is greater than lmp
            if (orderData.bidHead > orderData.lmp) {
                IOrderbook(orderData.pair).setLmp(orderData.bidHead);
                emit NewMarketPrice(orderData.pair, orderData.bidHead, true);
            }
            emit OrderPlaced(
                orderData.pair,
                orderHistoryId,
                orderData.makeId,
                recipient,
                true,
                orderData.bidHead,
                quoteAmount,
                orderData.withoutFee
            );
            result.makePrice = orderData.bidHead;
            result.placed = orderData.withoutFee;
            result.id = orderData.makeId;
        } else {
            result.makePrice = orderData.bidHead;
            result.placed = 0;
            result.id = 0;
        }

        return result;
    }
    /**
     * @dev Executes a market buy order, with spread limit of 1% for price actions.
     * buys the base asset using the quote asset at the best available price in the orderbook up to `n` orders,
     * and make an order at the market price.
     * @param input Order parameters. `amount` is the quote asset spent and `slippageLimit`
     * is in basis points. Use `createOrder` for a deadline. See IMatchingEngine.MarketOrderInput.
     * @return result Result of the order, makePrice is the next price to be set if placed and id is 0
     */
    function marketBuy(MarketOrderInput calldata input)
        external
        override
        nonReentrant
        returns (OrderResult memory result)
    {
        count = _nextHistoryId();
        result = _marketBuy(
            input.base,
            input.quote,
            input.amount,
            input.isMaker,
            input.n,
            input.recipient,
            input.slippageLimit,
            count
        );
    }


    function _detMarketBuyMakePrice(
        address orderbook,
        uint256 bidHead,
        uint256 askHead,
        uint32 spread
    ) internal view returns (uint256 price) {
        uint256 lmp = IOrderbook(orderbook).lmp();
        return MarketMakePriceLib.buy(lmp, bidHead, askHead, spread);
    }

    function _marketSell(
        address base,
        address quote,
        uint256 baseAmount,
        bool isMaker,
        uint32 n,
        address recipient,
        uint32 slippageLimit,
        uint16 orderHistoryId
    ) internal returns (OrderResult memory result) {
        OrderData memory orderData;
        (orderData.withoutFee, orderData.pair, orderData.lmp) = _deposit(
            base,
            quote,
            0,
            baseAmount,
            false
        );

        // get spread limits
        slippageLimit = _pairSlippageLimit(base, quote, slippageLimit);
        orderData.spreadLimit = slippageLimit <=
            getSpread(orderData.pair, false, true)
            ? slippageLimit
            : getSpread(orderData.pair, false, true);

        orderData.lmp = mktPrice(base, quote);

        // reuse baseAmount for storing without fee
        baseAmount = orderData.withoutFee;

        // reuse withoutFee variable for storing remaining amount after matching due to stack too deep error
        (
            orderData.withoutFee,
            orderData.bidHead,
            orderData.askHead
        ) = _limitOrder(
            orderData.pair,
            orderData.withoutFee,
            base,
            recipient,
            false,
            (orderData.lmp * (DENOM - orderData.spreadLimit)) / DENOM,
            n,
            orderHistoryId
        );

        // reuse orderData.askHead argument for storing make price
        orderData.askHead = _detMarketSellMakePrice(
            orderData.pair,
            orderData.bidHead,
            orderData.askHead,
            orderData.spreadLimit
        );

        orderData.makeId = _detMake(
            base,
            quote,
            orderData.pair,
            orderData.withoutFee,
            orderData.askHead,
            false,
            isMaker,
            recipient
        );

        // check if order id is made
        if (orderData.makeId > 0) {
            //if made, set last market price to orderData.askHead only if askHead is smaller than lmp
            if (orderData.askHead < orderData.lmp) {
                IOrderbook(orderData.pair).setLmp(orderData.askHead);
                emit NewMarketPrice(orderData.pair, orderData.askHead, false);
            }
            emit OrderPlaced(
                orderData.pair,
                orderHistoryId,
                orderData.makeId,
                recipient,
                false,
                orderData.askHead,
                baseAmount,
                orderData.withoutFee
            );
            result.makePrice = orderData.askHead;
            result.placed = orderData.withoutFee;
            result.id = orderData.makeId;
        } else {
            result.makePrice = orderData.askHead;
            result.placed = 0;
            result.id = 0;
        }

        return result;
    }
    /**
     * @dev Executes a market sell order, with spread limit of 1% for price actions.
     * sells the base asset for the quote asset at the best available price in the orderbook up to `n` orders,
     * and make an order at the market price.
     * @param input Order parameters. `amount` is the base asset sold and `slippageLimit`
     * is in basis points. Use `createOrder` for a deadline. See IMatchingEngine.MarketOrderInput.
     * @return result Result of the order, makePrice is the next price to be set if placed and id is 0
     */
    function marketSell(MarketOrderInput calldata input)
        external
        override
        nonReentrant
        returns (OrderResult memory result)
    {
        count = _nextHistoryId();
        result = _marketSell(
            input.base,
            input.quote,
            input.amount,
            input.isMaker,
            input.n,
            input.recipient,
            input.slippageLimit,
            count
        );
    }


    function _detMarketSellMakePrice(
        address orderbook,
        uint256 bidHead,
        uint256 askHead,
        uint32 spread
    ) internal view returns (uint256 price) {
        uint256 lmp = IOrderbook(orderbook).lmp();
        return MarketMakePriceLib.sell(lmp, bidHead, askHead, spread);
    }





    function _limitBuy(
        address base,
        address quote,
        uint256 price,
        uint256 quoteAmount,
        bool isMaker,
        uint32 n,
        address recipient,
        uint16 orderHistoryId
    ) internal returns (OrderResult memory result) {
        OrderData memory orderData;
        (orderData.withoutFee, orderData.pair, orderData.lmp) = _deposit(
            base,
            quote,
            price,
            quoteAmount,
            true
        );

        // get spread limits
        orderData.spreadLimit = getSpread(orderData.pair, true, false);

        // reuse quoteAmount for storing amount without fee
        quoteAmount = orderData.withoutFee;

        // reuse withoutFee variable for storing remaining amount after matching due to stack too deep error
        (
            orderData.withoutFee,
            orderData.bidHead,
            orderData.askHead
        ) = _limitOrder(
            orderData.pair,
            orderData.withoutFee,
            quote,
            recipient,
            true,
            price >= (orderData.lmp * (DENOM + orderData.spreadLimit)) / DENOM
                ? (orderData.lmp * (DENOM + orderData.spreadLimit)) / DENOM
                : price,
            n,
            orderHistoryId
        );

        // reuse price variable for storing make price, determine
        (price, orderData.lmp) = _detLimitBuyMakePrice(
            orderData.pair,
            price,
            orderData.bidHead,
            orderData.askHead,
            orderData.spreadLimit
        );

        orderData.makeId = _detMake(
            base,
            quote,
            orderData.pair,
            orderData.withoutFee,
            price,
            true,
            isMaker,
            recipient
        );

        // check if order id is made
        if (orderData.makeId > 0) {
            // if made, set last market price to price only if price is higher than lmp
            if (price > orderData.lmp) {
                IOrderbook(orderData.pair).setLmp(price);

                emit NewMarketPrice(orderData.pair, price, true);
            }
            emit OrderPlaced(
                orderData.pair,
                orderHistoryId,
                orderData.makeId,
                recipient,
                true,
                price,
                quoteAmount,
                orderData.withoutFee
            );
            result.makePrice = price;
            result.placed = orderData.withoutFee;
            result.id = orderData.makeId;
        } else {
            result.makePrice = price;
            result.placed = 0;
            result.id = 0;
        }

        return result;
    }
    /**
     * @dev Executes a limit buy order, buying the base asset with the quote asset at a price
     * at or below `price`, matching up to `n` resting orders and resting the remainder.
     * @param input Order parameters. `amount` is the quote asset spent. Limit orders read the
     * pair's spread, so there is no slippage field; use `createOrder` for a deadline. See
     * IMatchingEngine.LimitOrderInput.
     * @return result Result of the order, makePrice is the next price to be set if placed and id is 0
     */
    function limitBuy(LimitOrderInput calldata input)
        external
        override
        nonReentrant
        returns (OrderResult memory result)
    {
        count = _nextHistoryId();
        result = _limitBuy(
            input.base,
            input.quote,
            input.price,
            input.amount,
            input.isMaker,
            input.n,
            input.recipient,
            count
        );
    }


    function _detLimitBuyMakePrice(
        address orderbook,
        uint256 lp,
        uint256 bidHead,
        uint256 askHead,
        uint32 spread
    ) internal view returns (uint256 price, uint256 lmp) {
        lmp = IOrderbook(orderbook).lmp();
        return (MarketMakePriceLib.limitBuy(lmp, lp, bidHead, askHead, spread), lmp);
    }

    function _limitSell(
        address base,
        address quote,
        uint256 price,
        uint256 baseAmount,
        bool isMaker,
        uint32 n,
        address recipient,
        uint16 orderHistoryId
    ) internal returns (OrderResult memory result) {
        OrderData memory orderData;
        (orderData.withoutFee, orderData.pair, orderData.lmp) = _deposit(
            base,
            quote,
            price,
            baseAmount,
            false
        );

        // get spread limit
        orderData.spreadLimit = getSpread(orderData.pair, false, false);

        // reuse baseAmount for storing amount without fee
        baseAmount = orderData.withoutFee;

        // reuse withoutFee variable for storing remaining amount after matching due to stack too deep error
        (
            orderData.withoutFee,
            orderData.bidHead,
            orderData.askHead
        ) = _limitOrder(
            orderData.pair,
            orderData.withoutFee,
            base,
            recipient,
            false,
            price <= (orderData.lmp * (DENOM - orderData.spreadLimit)) / DENOM
                ? (orderData.lmp * (DENOM - orderData.spreadLimit)) / DENOM
                : price,
            n,
            orderHistoryId
        );

        // reuse price variable for make price
        (price, orderData.lmp) = _detLimitSellMakePrice(
            orderData.pair,
            price,
            orderData.bidHead,
            orderData.askHead,
            orderData.spreadLimit
        );

        orderData.makeId = _detMake(
            base,
            quote,
            orderData.pair,
            orderData.withoutFee,
            price,
            false,
            isMaker,
            recipient
        );

        if (orderData.makeId > 0) {
            // if made, set last market price to price only if price is lower than lmp
            if (price < orderData.lmp) {
                IOrderbook(orderData.pair).setLmp(price);

                emit NewMarketPrice(orderData.pair, price, false);
            }
            emit OrderPlaced(
                orderData.pair,
                orderHistoryId,
                orderData.makeId,
                recipient,
                false,
                price,
                baseAmount,
                orderData.withoutFee
            );
            result.makePrice = price;
            result.placed = orderData.withoutFee;
            result.id = orderData.makeId;
        } else {
            result.makePrice = price;
            result.placed = 0;
            result.id = 0;
        }

        return result;
    }
    /**
     * @dev Executes a limit sell order, selling the base asset for the quote asset at a price
     * at or above `price`, matching up to `n` resting orders and resting the remainder.
     * @param input Order parameters. `amount` is the base asset sold. Limit orders read the
     * pair's spread, so there is no slippage field; use `createOrder` for a deadline. See
     * IMatchingEngine.LimitOrderInput.
     * @return result Result of the order, makePrice is the next price to be set if placed and id is 0
     */
    function limitSell(LimitOrderInput calldata input)
        external
        override
        nonReentrant
        returns (OrderResult memory result)
    {
        count = _nextHistoryId();
        // NOTE: passes a literal 1 as the order-history id where every sibling passes
        // `count`, which still assigns `count` above and then ignores it. Preserved
        // verbatim through this refactor rather than corrected — it predates it, and
        // changing what a live entrypoint writes is not a signature change's business.
        result = _limitSell(
            input.base,
            input.quote,
            input.price,
            input.amount,
            input.isMaker,
            input.n,
            input.recipient,
            1
        );
    }


    function _detLimitSellMakePrice(
        address orderbook,
        uint256 lp,
        uint256 bidHead,
        uint256 askHead,
        uint32 spread
    ) internal view returns (uint256 price, uint256 lmp) {
        lmp = IOrderbook(orderbook).lmp();
        return (MarketMakePriceLib.limitSell(lmp, lp, bidHead, askHead, spread), lmp);
    }





    /**
     * @dev Creates an orderbook for a new trading pair and returns its address
     * @param base The address of the base asset for the trading pair
     * @param quote The address of the quote asset for the trading pair
     * @param listingPrice The initial market price for the trading pair
     * @param listingDate The listing Date for the trading pair
     * @return pair The address of the newly created orderbook
     */
    function addPair(
        address base,
        address quote,
        uint256 listingPrice,
        uint256 listingDate,
        address payment,
        ExchangeOrderbook.MatchingMode mode
    ) public override returns (address pair) {
        // Pair creation is permissionless and protocol-fee-free. `payment` is
        // retained in the ABI so existing integrations do not need a new call.
        payment;
        string memory terminalName = "permissionless";

        // create orderbook for the pair
        pair = IOrderbookFactory(orderbookFactory).createBook(base, quote, mode);
        IOrderbook(pair).setLmp(listingPrice);
        if (stopOrderEngine != address(0)) {
            IStopOrderEngine(stopOrderEngine).createBook(pair, base, quote);
            IOrderbook(pair).setOperator(stopOrderEngine);
        }
        // Skip Pool creation for a WETH-linked pair -- Orderbook._sendFunds unconditionally
        // unwraps WETH to native ETH on settlement, which Pool.swap's ERC20-balance-delta
        // accounting cannot observe, silently misreporting a filled WETH leg as amountOut=0
        // (found in the swap module's final review; tracked as a real limitation, not yet
        // supported -- see docs/swap/design.md Sec10). This only skips the swap module's
        // Pool for this pair; the orderbook/CLOB pair above lists and trades normally,
        // completely unaffected -- WETH pairs have always worked fine through
        // limitBuy/limitSell/marketBuy/etc., this guard only prevents Pool.swap/SwapRouter
        // from being used against a pair where their accounting would silently misbehave.
        if (poolFactory != address(0) && base != WETH && quote != WETH) {
            address pool = IPoolFactory(poolFactory).createPool(base, quote, pair);
            IOrderbook(pair).setPool(pool);
        }
        // set buy/sell spread to default suspension rate in basis point(bps)
        _setSpread(pair, dfltMktBuy, dfltMktSell, true);
        _setSpread(pair, dfltLmtBuy, dfltLmtSEll, false);

        _setListingDate(pair, listingDate);

        TransferHelper.TokenInfo memory baseInfo = TransferHelper.getTokenInfo(
            base
        );
        TransferHelper.TokenInfo memory quoteInfo = TransferHelper.getTokenInfo(
            quote
        );
        emit PairAdded(
            pair,
            msg.sender,
            baseInfo,
            quoteInfo,
            listingPrice,
            listingDate,
            terminalName
        );
        emit NewMarketPrice(pair, listingPrice, true);
        return pair;
    }

    /**
     * @dev Update the market price of a trading pair.`
     * @param base The address of the base asset for the trading pair
     * @param quote The address of the quote asset for the trading pair
     * @param listingPrice The initial market price for the trading pair
     * @param listingDate The listing Date for the trading pair
     */
    function updatePair(
        address base,
        address quote,
        uint256 listingPrice,
        uint256 listingDate
    ) external override returns (address pair) {
        // check if the list request is done by
        if (!hasRole(MARKET_MAKER_ROLE, _msgSender())) {
            revert InvalidRole(MARKET_MAKER_ROLE, _msgSender());
        }
        // create orderbook for the pair
        pair = getPair(base, quote);
        IOrderbook(pair).setLmp(listingPrice);
        emit PairUpdated(pair, base, quote, listingPrice, listingDate);
        emit NewMarketPrice(pair, listingPrice, true);
        return pair;
    }

    /**
     * @dev Cancels a single order on its orderbook.
     * @param tolerant When false (single cancels and single order updates) any
     * failure reverts with {OrderCancelFailed} so the caller learns why the
     * cancel failed instead of receiving a silent zero. When true (batch cancels
     * and batch updates) the failure is surfaced via {OrderCancelSkipped} and
     * the item is skipped, so one bad order does not revert the whole batch.
     * @return refunded Amount refunded from the cancelled order (0 when skipped).
     * @return canceled True if the order was actually cancelled; false only in
     * tolerant mode when the cancel failed (e.g. the order was already filled).
     * Callers must not act on a refund when this is false.
     */
    function _cancelOrder(
        address base,
        address quote,
        bool isBid,
        uint32 orderId,
        address sender,
        bool tolerant
    ) internal returns (uint256 refunded, bool canceled) {
        address orderbook = IOrderbookFactory(orderbookFactory).getPair(
            base,
            quote
        );

        if (orderbook == address(0)) {
            revert InvalidPair(base, quote, orderbook);
        }
        try IOrderbook(orderbook).cancelOrder(isBid, orderId, sender) returns (
            uint256 _refunded
        ) {
            emit OrderCanceled(orderbook, orderId, isBid, sender, _refunded);
            return (_refunded, true);
        } catch (bytes memory reason) {
            if (tolerant) {
                emit OrderCancelSkipped(orderbook, orderId, isBid, sender, reason);
                return (0, false);
            }
            revert OrderCancelFailed(orderbook, orderId, isBid, sender, reason);
        }
    }

    function _createOrder(
        CreateOrderInput calldata createOrderData,
        uint256 nativeValue
    ) internal returns (OrderResult memory result, uint256 leftover) {
        // Mirrors the WithDeadline overloads: _checkDeadline is a no-op at 0, and the
        // context is what makes the resting order record its own expiry. Cleared at the
        // end so a later order in a createOrders() batch cannot inherit this one's.
        _checkDeadline(createOrderData.deadline);
        orderDeadlineContext = createOrderData.deadline;
        count = _nextHistoryId();
        leftover = nativeValue;
        if (createOrderData.isBid) {
            if (createOrderData.quote == WETH) {
                // Convert ETH to WETH for internal call
                IWETH(WETH).deposit{value: createOrderData.amount}();
                leftover -= createOrderData.amount;
            }
            if (createOrderData.isLimit) {
                result = _limitBuy(
                    createOrderData.base,
                    createOrderData.quote,
                    createOrderData.price,
                    createOrderData.amount,
                    createOrderData.isMaker,
                    createOrderData.n,
                    createOrderData.recipient,
                    count
                );
            } else {
                result = _marketBuy(
                    createOrderData.base,
                    createOrderData.quote,
                    createOrderData.amount,
                    createOrderData.isMaker,
                    createOrderData.n,
                    createOrderData.recipient,
                    // 0 means the venue default, NOT zero tolerance. _pairSlippageLimit
                    // passes a request through untouched, and _marketBuy then clamps
                    // spreadLimit to min(request, spread) — so forwarding a literal 0
                    // would set spreadLimit to 0 and match nothing.
                    createOrderData.slippageLimit == 0
                        ? dfltMktBuy
                        : createOrderData.slippageLimit,
                    count
                );
            }
        } else {
            if (createOrderData.base == WETH) {
                // Convert ETH to WETH for internal call
                IWETH(WETH).deposit{value: createOrderData.amount}();
                leftover -= createOrderData.amount;
            }
            if (createOrderData.isLimit) {
                result = _limitSell(
                    createOrderData.base,
                    createOrderData.quote,
                    createOrderData.price,
                    createOrderData.amount,
                    createOrderData.isMaker,
                    createOrderData.n,
                    createOrderData.recipient,
                    count
                );
            } else {
                result = _marketSell(
                    createOrderData.base,
                    createOrderData.quote,
                    createOrderData.amount,
                    createOrderData.isMaker,
                    createOrderData.n,
                    createOrderData.recipient,
                    // See the buy branch: 0 is the venue default, not zero tolerance.
                    createOrderData.slippageLimit == 0
                        ? dfltMktSell
                        : createOrderData.slippageLimit,
                    count
                );
            }
        }
        orderDeadlineContext = 0;
        return (result, leftover);
    }

    /**
     * @dev Creates an order in an orderbook for the given trading pair. When creating the order using ETH, make sure the total amount and msg.value is same.
     * @param createOrderData The input data for creating an order
     * @return result The result of the order
     */
    function createOrder(
        CreateOrderInput calldata createOrderData
    ) public payable override nonReentrant returns (OrderResult memory result) {
        uint256 leftover = msg.value;
        (result, leftover) = _createOrder(createOrderData, leftover);
        if (leftover > 0) {
            TransferHelper.safeTransferETH(msg.sender, leftover);
        }
        return result;
    }

    function createOrders(
        CreateOrderInput[] calldata createOrderData
    ) external payable override returns (OrderResult[] memory results) {
        results = new OrderResult[](createOrderData.length);
        uint256 leftover = msg.value;
        for (uint32 i = 0; i < createOrderData.length; i++) {
            (results[i], leftover) = _createOrder(
                createOrderData[i],
                leftover
            );
        }
        if (leftover > 0) {
            TransferHelper.safeTransferETH(msg.sender, leftover);
        }
        return results;
    }

    function _updateOrder(
        CreateOrderInput calldata updateOrderData,
        bool tolerant
    ) internal returns (OrderResult memory result) {
        address orderbook = IOrderbookFactory(orderbookFactory).getPair(
            updateOrderData.base,
            updateOrderData.quote
        );

        if (orderbook == address(0)) {
            revert InvalidPair(
                updateOrderData.base,
                updateOrderData.quote,
                orderbook
            );
        }

        // Cancel the existing order first. In non-tolerant (single) mode a failed
        // cancel reverts. In tolerant (batch) mode it returns canceled == false;
        // we must then skip recreating so one already-filled order neither
        // reverts the whole batch nor leaves a duplicate order behind.
        (, bool canceled) = _cancelOrder(
            updateOrderData.base,
            updateOrderData.quote,
            updateOrderData.isBid,
            updateOrderData.orderId,
            _msgSender(),
            tolerant
        );
        if (!canceled) {
            result.makePrice = 0;
            result.placed = 0;
            result.id = 0;
            return result;
        }

        if (updateOrderData.amount == 0) {
            result.makePrice = 0;
            result.placed = 0;
            result.id = 0;
            return result;
        }

        uint256 leftover = msg.value;
        (result, leftover) = _createOrder(updateOrderData, leftover);
        if (leftover > 0) {
            TransferHelper.safeTransferETH(msg.sender, leftover);
        }
        return result;
    }

    function updateOrder(
        CreateOrderInput calldata updateOrderData
    ) external nonReentrant returns (OrderResult memory result) {
        return _updateOrder(updateOrderData, false);
    }

    function updateOrders(
        CreateOrderInput[] calldata updateOrderData
    ) external payable returns (OrderResult[] memory results) {
        results = new OrderResult[](updateOrderData.length);
        for (uint32 i = 0; i < updateOrderData.length; i++) {
            // tolerant: an order that was already filled between submission and
            // execution is skipped, not reverted, so the rest of the batch runs.
            results[i] = _updateOrder(updateOrderData[i], true);
        }
        return results;
    }

    /**
     * @dev Cancels an order in an orderbook by the given order ID and order type.
     * @param base The address of the base asset for the trading pair
     * @param quote The address of the quote asset for the trading pair
     * @param isBid Boolean indicating if the order to cancel is an ask order
     * @param orderId The ID of the order to cancel
     * @return refunded Refunded amount from order
     */
    function cancelOrder(
        address base,
        address quote,
        bool isBid,
        uint32 orderId
    ) public nonReentrant returns (uint256) {
        (uint256 refunded, ) = _cancelOrder(
            base,
            quote,
            isBid,
            orderId,
            _msgSender(),
            false
        );
        return refunded;
    }

    function cancelOrders(
        CancelOrderInput[] memory cancelOrderData
    ) external returns (uint256[] memory refunded) {
        refunded = new uint256[](cancelOrderData.length);
        for (uint32 i = 0; i < cancelOrderData.length; i++) {
            (refunded[i], ) = _cancelOrder(
                cancelOrderData[i].base,
                cancelOrderData[i].quote,
                cancelOrderData[i].isBid,
                cancelOrderData[i].orderId,
                _msgSender(),
                true
            );
        }
        return refunded;
    }

    /// @notice Removes an expired resting order and refunds its remaining deposit.
    /// Anyone may call this so stale liquidity can be cleared without relying on its owner.
    function expireOrder(
        address base,
        address quote,
        bool isBid,
        uint32 orderId
    ) external nonReentrant returns (uint256 refunded) {
        address pair = getPair(base, quote);
        if (pair == address(0)) revert PairDoesNotExist(base, quote, pair);
        ExchangeOrderbook.Order memory order = IOrderbook(pair).getOrder(isBid, orderId);
        if (order.deadline == 0 || block.timestamp <= order.deadline) {
            revert OrderNotExpired(order.deadline, block.timestamp);
        }
        (address owner, uint256 amount, uint64 deadline) =
            IOrderbook(pair).expireOrder(isBid, orderId);
        emit OrderExpired(pair, orderId, owner, isBid, false, false, deadline, amount);
        return amount;
    }

    /**
     * @dev Returns an order in the ask/bid orderbook for the given trading pair with order id.
     * @param base The address of the base asset for the trading pair.
     * @param quote The address of the quote asset for the trading pair.
     * @param isBid Boolean indicating if the orderbook to retrieve orders from is an ask orderbook.
     * @param orderId The order id to retrieve.
     */
    function getOrder(
        address base,
        address quote,
        bool isBid,
        uint32 orderId
    ) public view override returns (ExchangeOrderbook.Order memory) {
        address orderbook = getPair(base, quote);
        return IOrderbook(orderbook).getOrder(isBid, orderId);
    }

    function feeOf(
        address base,
        address quote,
        address account,
        bool isMaker
    ) external view returns (uint32 feeNum) {
        address pair = IOrderbookFactory(orderbookFactory).getPair(base, quote);
        PairFeePolicy memory policy = pairFeePolicy[pair];
        uint32 pairFee = policy.configured
            ? (isMaker ? policy.makerFee : policy.takerFee)
            : _dfltFee(isMaker);
        address incentive_ = incentive;
        if (incentive_ == address(0)) return pairFee;

        // OG Pass pricing is a discount, never a surcharge. The pair policy remains
        // the ceiling for this exact market; an OG account receives the lower of the
        // pair's maker/taker rate and its account-specific rate. A reverting or absent
        // incentive simply leaves the pair fee unchanged.
        try IProtocol(incentive_).feeOf(base, quote, account, isMaker) returns (uint32 accountFee) {
            return accountFee < pairFee ? accountFee : pairFee;
        } catch {
            return pairFee;
        }
    }

    /// @dev AssetGenerator exposes its launch limit in basis points while the engine uses
    /// DENOM-scaled numerators. A missing/reverting hook leaves ordinary pairs unchanged.
    /// Traders may always submit a stricter limit; a looser one is capped by the creator's
    /// policy for the exact generated pair.
    function _pairSlippageLimit(address base, address quote, uint32 requested)
        internal
        view
        returns (uint32)
    {
        address policy = incentive;
        if (policy == address(0)) return requested;
        (bool ok, bytes memory data) = policy.staticcall(
            abi.encodeWithSignature("slippageLimitOf(address,address)", base, quote)
        );
        if (!ok || data.length < 32) return requested;
        uint256 basisPoints = abi.decode(data, (uint256));
        uint256 scaled = basisPoints * 10_000;
        if (scaled > type(uint32).max) return requested;
        uint32 cap = uint32(scaled);
        return requested <= cap ? requested : cap;
    }

    /**
     * @dev Returns the address of the orderbook for the given base and quote asset addresses.
     * @param base The address of the base asset for the trading pair.
     * @param quote The address of the quote asset for the trading pair.
     * @return book The address of the orderbook.
     */
    function getPair(
        address base,
        address quote
    ) public view returns (address book) {
        return IOrderbookFactory(orderbookFactory).getPair(base, quote);
    }

    function heads(
        address base,
        address quote
    ) external view returns (uint256 bidHead, uint256 askHead) {
        address orderbook = getPair(base, quote);
        return IOrderbook(orderbook).heads();
    }

    function mktPrice(
        address base,
        address quote
    ) public view returns (uint256) {
        address orderbook = getPair(base, quote);
        return IOrderbook(orderbook).mktPrice();
    }

    /**
     * @dev return converted amount from base to quote or vice versa
     * @param base address of base asset
     * @param quote address of quote asset
     * @param amount amount of base or quote asset
     * @param isBid if true, amount is quote asset, otherwise base asset
     * @return converted converted amount from base to quote or vice versa.
     * if true, amount is quote asset, otherwise base asset
     * reverts with PairDoesNotExist if the orderbook does not exist
     */
    function convert(
        address base,
        address quote,
        uint256 amount,
        bool isBid
    ) public view returns (uint256 converted) {
        address orderbook = getPair(base, quote);
        if (base == quote) {
            return amount;
        } else if (orderbook == address(0)) {
            // Previously returned 0, which silently masked a missing pair:
            // an estimate would look like a legitimate "you receive 0" on the
            // UI instead of surfacing that the pair does not exist. Revert so
            // the error is visible to callers estimating a transaction.
            revert PairDoesNotExist(base, quote, orderbook);
        } else {
            return IOrderbook(orderbook).assetValue(amount, isBid);
        }
    }

    function _setListingDate(
        address book,
        uint256 listingDate
    ) internal returns (bool success) {
        listingDates[book] = listingDate;
        return true;
    }

    function _setSpread(
        address pair,
        uint32 buy,
        uint32 sell,
        bool isMkt
    ) internal returns (bool success) {
        if (isMkt) {
            mktSpreadLimits[pair] = DefaultSpread(buy, sell);
        } else {
            lmtSpreadLimits[pair] = DefaultSpread(buy, sell);
        }
        return true;
    }

    function getSpread(
        address pair,
        bool isBuy,
        bool isMkt
    ) public view returns (uint32 spreadLimit) {
        DefaultSpread memory spread;
        spread = isMkt ? mktSpreadLimits[pair] : lmtSpreadLimits[pair];
        if (isBuy) {
            return spread.buy;
        } else {
            return spread.sell;
        }
    }

    /**
     * @dev Internal function which makes an order on the orderbook.
     * @param pair The address of the orderbook contract for the trading pair
     * @param withoutFee The remaining amount of the asset after the market order has been executed
     * @param price The price, base/quote regardless of decimals of the assets in the pair represented with 8 decimals (if 1000, base is 1000x quote)
     * @param isBid Boolean indicating if the order is a buy (false) or a sell (true)
     * @param recipient The address of the recipient to receive traded asset and claim ownership of made order
     */
    function _makeOrder(
        address pair,
        uint256 withoutFee,
        uint256 price,
        bool isBid,
        address recipient
    ) internal returns (uint32 id) {
        bool foundDmt;
        // create order
        if (isBid) {
            (id, foundDmt) = IOrderbook(pair).placeBid(
                recipient,
                price,
                withoutFee,
                orderDeadlineContext
            );
        } else {
            (id, foundDmt) = IOrderbook(pair).placeAsk(
                recipient,
                price,
                withoutFee,
                orderDeadlineContext
            );
        }
        if (foundDmt) {
            // emit canceling dormant order
            ExchangeOrderbook.Order memory order = IOrderbook(pair).removeDmt(
                isBid
            );
            emit OrderCanceled(
                pair,
                id,
                isBid,
                order.owner,
                order.depositAmount
            );
        }
        return id;
    }

    function _checkDeadline(uint64 deadline) private view {
        if (deadline != 0 && block.timestamp > deadline) {
            revert DeadlineExpired(deadline, block.timestamp);
        }
    }

    /**
     * @dev Executes limit order by matching orders in the orderbook based on the provided limit price.
     * @param pair The address of the orderbook to execute the limit order on.
     * @param amount The amount of asset to trade.
     * @param give The address of the asset to be traded.
     * @param recipient The address to receive asset after matching a trade
     * @param isBid True if the order is an ask (sell) order, false if it is a bid (buy) order.
     * @param limitPrice The maximum price at which the order can be executed.
     * @param n The maximum number of matches to execute.
     * @return remaining The remaining amount of asset that was not traded.
     */
    function _limitOrder(
        address pair,
        uint256 amount,
        address give,
        address recipient,
        bool isBid,
        uint256 limitPrice,
        uint32 n,
        uint16 orderHistoryId
    ) internal returns (uint256 remaining, uint256 bidHead, uint256 askHead) {
        uint32 used;
        MatchingLib.LimitOrderInput memory input = MatchingLib.LimitOrderInput(
            pair, amount, give, recipient, isBid, limitPrice, n, orderHistoryId
        );
        (remaining, bidHead, askHead, used) = MatchingLib.limitOrder(input, maxMatches);
        return StopOrderHandoffLib.handoff(stopOrderEngine, input, remaining, bidHead, askHead, used);
    }

    /**
     * @dev Determines if an order can be made at the market price,
     * and if so, makes the an order on the orderbook.
     * If an order cannot be made, transfers the remaining asset to either the orderbook or the user.
     * @param base The address of the base asset for the trading pair
     * @param quote The address of the quote asset for the trading pair
     * @param pair The address of the orderbook contract for the trading pair
     * @param remaining The remaining amount of the asset after the market order has been taken
     * @param price The price used to determine if an order can be made
     * @param isBid Boolean indicating if the order was a buy (true) or a sell (false)
     * @param isMaker Boolean indicating if an order is for storing in orderbook or just take profit after matching trades
     * @param recipient The address to receive asset after matching a trade and making an order
     * @return id placed order id
     */
    function _detMake(
        address base,
        address quote,
        address pair,
        uint256 remaining,
        uint256 price,
        bool isBid,
        bool isMaker,
        address recipient
    ) internal returns (uint32 id) {
        if (remaining > 0) {
            // If isMaker but remaining converts to zero (dust after partial matching),
            // refund to recipient silently rather than placing an unexecutable maker order.
            if (isMaker && _convert(pair, price, remaining, !isBid) > 0) {
                TransferHelper.safeTransfer(isBid ? quote : base, pair, remaining);
                id = _makeOrder(pair, remaining, price, isBid, recipient);
                return id;
            } else {
                TransferHelper.safeTransfer(isBid ? quote : base, recipient, remaining);
            }
        }
    }

    /**
     * @dev Deposit amount of asset to the contract with the given asset information and subtracts the fee.
     * @param base The address of the base asset.
     * @param quote The address of the quote asset.
     * @param amount The amount of asset to deposit.
     * @param isBid Whether it is an ask order or not.
     * If ask, the quote asset is transferred to the contract.
     * @return withoutFee The amount of asset without the fee.
     * @return pair The address of the orderbook for the given asset pair.
     */
    function _deposit(
        address base,
        address quote,
        uint256 price,
        uint256 amount,
        bool isBid
    ) internal returns (uint256 withoutFee, address pair, uint256 lmp) {
        // check if amount is zero
        if (amount == 0) {
            revert AmountIsZero();
        }
        // get orderbook address from the base and quote asset
        pair = getPair(base, quote);
        // check infalid pair

        if (pair == address(0)) {
            revert InvalidPair(base, quote, pair);
        }
        // check if the pair is listed
        if (listingDates[pair] > block.timestamp) {
            revert PairNotListedYet(
                base,
                quote,
                listingDates[pair],
                block.timestamp
            );
        }

        // check if amount is valid in case of both market and limit
        uint256 converted = _convert(pair, price, amount, !isBid);
        uint256 minRequired = _convert(pair, price, 1, !isBid);

        if (converted <= minRequired) {
            revert OrderSizeTooSmall(converted, minRequired);
        }

        if (isBid) {
            // transfer input asset give user to this contract
            if (quote != WETH) {
                TransferHelper.safeTransferFrom(
                    quote,
                    msg.sender,
                    address(this),
                    amount
                );
            } else {
                if (msg.value == 0) {
                    TransferHelper.safeTransferFrom(
                        quote,
                        msg.sender,
                        address(this),
                        amount
                    );
                }
            }
        } else {
            // transfer input asset give user to this contract
            if (base != WETH) {
                TransferHelper.safeTransferFrom(
                    base,
                    msg.sender,
                    address(this),
                    amount
                );
            } else {
                if (msg.value == 0) {
                    TransferHelper.safeTransferFrom(
                        quote,
                        msg.sender,
                        address(this),
                        amount
                    );
                }
            }
        }

        lmp = IOrderbook(pair).lmp();

        return (amount, pair, lmp);
    }

    function _dfltFee(bool isMaker) internal view returns (uint32) {
        return isMaker ? defaultMakerFee : defaultTakerFee;
    }

    /**
     * @dev return converted amount from base to quote or vice versa
     * @param pair address of orderbook
     * @param price price of base/quote regardless of decimals of the assets in the pair represented with 8 decimals (if 1000, base is 1000x quote) proposed by a trader
     * @param amount amount of base or quote asset
     * @param isBid if true, amount is quote asset, otherwise base asset
     * @return converted converted amount from base to quote or vice versa.
     * if true, amount is quote asset, otherwise base asset
     * if orderbook does not exist, return 0
     */
    function _convert(
        address pair,
        uint256 price,
        uint256 amount,
        bool isBid
    ) internal view returns (uint256 converted) {
        if (pair == address(0)) {
            return 0;
        } else {
            return
                price == 0
                    ? IOrderbook(pair).assetValue(amount, isBid)
                    : IOrderbook(pair).convert(price, amount, isBid);
        }
    }
}
