// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.24;

library ExchangeOrderbook {
    /// Matching discipline applied within a single price level.
    /// PriceTimePriority: strict FIFO — earliest-placed resting order fills first.
    ///
    /// SizePriority was removed 2026-08-06 — see _insertId. It kept a price level sorted
    /// by deposit size over a linear list, making insert and delete O(depth) with no cap,
    /// which ended in an out-of-gas revert carrying no return data.
    ///
    /// The enum is kept with a single member rather than deleted so `addPair`,
    /// `createBook`, `Orderbook.initialize` and CoinGenerator's admin-set QuoteOption all
    /// keep their signatures. NOTE the renumbering: PriceTimePriority is now **0**, where
    /// it used to be 1. Callers that passed 1 will revert on an invalid enum value, and
    /// callers that passed 0 silently get price-time priority instead of size priority —
    /// which is the safe direction, and the only one still implemented.
    enum MatchingMode {
        PriceTimePriority
    }

    // Order struct
    struct Order {
        address owner;
        uint256 price;
        uint256 depositAmount;
    }

    // Order Linked List
    struct OrderStorage {
        /// Hashmap-style linked list of prices to route orders
        // key: price, value: order indices linked hashmap
        mapping(uint256 => mapping(uint32 => uint32)) list;
        mapping(uint32 => Order) orders;
        // Head of the linked list(i.e. lowest ask price / highest bid price)
        mapping(uint256 => uint32) head;
        // Tail of the linked list, maintained for O(1) FIFO append under PriceTimePriority
        mapping(uint256 => uint32) tail;
        // count of the orders, used for array allocation
        uint32 count;
        address engine;
        Order dormantOrder;
    }

    error OrderIdIsZero(uint32 id);
    error PriceIsZero(uint256 price);

    /// Append to the tail of the price level's list — price-time priority, O(1).
    ///
    /// This used to branch on a MatchingMode. SizePriority kept the level sorted by
    /// deposit size with no index into the list, so every insert walked it to find its
    /// slot and every delete walked it to unlink: O(depth), uncapped, and past roughly
    /// 850 resting orders at one price it exceeded a wallet-realistic gas cap and died
    /// out-of-gas returning ZERO bytes — no decodable error for the UI to report.
    /// `maxMatches` never protected against it; that bounds the matching loop, a
    /// different loop, and nothing counted these traversals at all.
    ///
    /// Measured before removal at 300 resting orders on one price: SizePriority went
    /// 154,197 -> 347,589 gas while this path stayed flat at 151,207 -> 151,250. The mode
    /// is gone rather than merely defaulted, because a sorted-by-size book needs a real
    /// index into the queue, not a linear list — and leaving the option reachable leaves
    /// the jam reachable.
    function _insertId(OrderStorage storage self, uint256 price, uint32 id) internal {
        uint32 tail = self.tail[price];
        if (tail == 0) {
            self.head[price] = id;
        } else {
            self.list[price][tail] = id;
        }
        self.tail[price] = id;
    }

    // pop front
    function _fpop(OrderStorage storage self, uint256 price) internal returns (uint256) {
        uint32 first = self.head[price];
        if (first == 0) {
            return 0;
        }
        uint32 next = self.list[price][first];
        self.head[price] = next;
        delete self.list[price][first];
        if (self.tail[price] == first) {
            self.tail[price] = 0;
        }
        return first;
    }

    function _createOrder(OrderStorage storage self, address owner, uint256 price, uint256 depositAmount)
        internal
        returns (uint32 id, bool foundDmt)
    {
        if (price == 0) {
            revert PriceIsZero(price);
        }
        Order memory order = Order({owner: owner, price: price, depositAmount: depositAmount});
        // set foundDmt to false by default
        foundDmt = false;
        // In order to prevent order overflow, order id must start from 1
        self.count = self.count == 0 || self.count == type(uint32).max ? 1 : self.count + 1;
        // check if the order already exists
        if (self.orders[self.count].owner != address(0)) {
            // store canceling order to dormantOrder
            self.dormantOrder = self.orders[self.count];
            // cancel the dormant order and set foundDmt to true
            _deleteOrder(self, self.count);
            foundDmt = true;
        }
        // insert order
        self.orders[self.count] = order;
        return (self.count, foundDmt == true);
    }

    /**
     * @notice Reduce an order, removing it when the match cleared it or nothing is left.
     * @return sendFund amount to pay the taker
     * @return deletePrice nonzero when the price level itself became empty
     * @return deleted whether the order was removed from the book
     *
     * `deleted` is still returned rather than inferred from `clear`: the two agreed
     * once the dust disjunct was removed, but they are different questions and a
     * caller emitting its own `clear` is what left indexers showing deleted orders
     * as open. Report what happened, not what was asked for.
     * See docs/contract/order-clear-observability.md.
     */
    function _decreaseOrder(OrderStorage storage self, uint32 id, uint256 amount, bool clear)
        internal
        returns (uint256 sendFund, uint256 deletePrice, bool deleted)
    {
        uint256 decreased = self.orders[id].depositAmount < amount ? 0 : self.orders[id].depositAmount - amount;
        // Delete when the match cleared the order, or when literally nothing is left.
        //
        // The `decreased <= dust` disjunct that used to be here is GONE. `dust` was
        // `convert(price, 1, isBid)` -- the value of one raw unit, measured in the
        // OPPOSITE direction to the two tests that decide whether an order can fill
        // (MatchingEngine's admission guard and Orderbook.fpop both use `!isBid`).
        // Being a floor-then-scale integer conversion it was either zero (mechanism
        // off) or `decDiff`-scaled to hundreds of whole tokens (mechanism
        // confiscatory, sweeping a maker's remainder to the taker for free), with
        // essentially nothing in between. See docs/contract/dust-threshold.md.
        //
        // "Cannot fill" now has ONE definition, the one the fill itself depends on:
        // `fpop` evicts and refunds when `required == 0`, and says so with
        // OrderDusted. `decreased == 0` is not a threshold -- it is emptiness.
        if (clear || decreased == 0) {
            decreased = self.orders[id].depositAmount;
            deletePrice = _deleteOrder(self, id);
            return (decreased, deletePrice, true);
        } else {
            self.orders[id].depositAmount = decreased;
            return (amount, deletePrice, false);
        }
    }

    function _deleteOrder(OrderStorage storage self, uint32 id) internal returns (uint256 deletePrice) {
        uint256 price = self.orders[id].price;
        uint32 last = 0;
        uint32 head = self.head[price];
        uint32 next;
        bool wasTail = self.tail[price] == id;
        mapping(uint32 => uint32) storage list = self.list[price];
        // delete id in the order linked list
        if (head == id) {
            self.head[price] = list[head];
            delete list[id];
            if (wasTail) {
                self.tail[price] = 0;
            }
        } else {
            // search for the order id in the linked list
            while (head != 0) {
                next = list[head];
                if (next == id) {
                    list[head] = list[next];
                    delete list[id];
                    if (wasTail) {
                        self.tail[price] = head;
                    }
                    break;
                }
                last = head;
                head = next;
            }
        }
        // delete order
        delete self.orders[id];
        return self.head[price] == 0 ? price : 0;
    }

    function _nextMakeId(OrderStorage storage self) internal view returns (uint32) {
        return self.count == 0 || self.count == type(uint32).max ? 1 : self.count + 1;
    }

    // show n order ids at the price in the orderbook
    function _getOrderIds(OrderStorage storage self, uint256 price, uint32 n) internal view returns (uint32[] memory) {
        uint32 head = self.head[price];
        uint32[] memory orders = new uint32[](n);
        uint32 i = 0;
        while (head != 0 && i < n) {
            orders[i] = head;
            head = self.list[price][head];
            i++;
        }
        return orders;
    }

    function _getOrders(OrderStorage storage self, uint256 price, uint32 n) internal view returns (Order[] memory) {
        uint32 head = self.head[price];
        Order[] memory orders = new Order[](n);
        uint32 i = 0;
        while (head != 0 && i < n) {
            orders[i] = self.orders[head];
            head = self.list[price][head];
            i++;
        }
        return orders;
    }

    function _getOrdersPaginated(OrderStorage storage self, uint256 price, uint32 start, uint32 end)
        internal
        view
        returns (Order[] memory)
    {
        uint32 head = self.head[price];
        Order[] memory orders = new Order[](end - start);
        uint32 i = 0;
        while (head != 0 && i < start) {
            head = self.list[price][head];
            i++;
        }
        if (head == 0) {
            return orders;
        }
        while (head != 0 && i < end) {
            orders[i] = self.orders[head];
            head = self.list[price][head];
            i++;
        }
        return orders;
    }

    function _head(OrderStorage storage self, uint256 price) internal view returns (uint32) {
        return self.head[price];
    }

    function _isEmpty(OrderStorage storage self, uint256 price) internal view returns (bool) {
        return self.head[price] == 0;
    }

    function _next(OrderStorage storage self, uint256 price, uint32 curr) internal view returns (uint32) {
        return self.list[price][curr];
    }

    function _getOrder(OrderStorage storage self, uint32 id) internal view returns (Order memory) {
        return self.orders[id];
    }
}
