// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.24;

library ExchangeLinkedList {
    error NoMatchPrice(uint256 askHead, uint256 bidHead, uint256 lmp);

    struct PriceLinkedList {
        /// Hashmap-style linked list of prices to route orders
        // key: price, value: next_price (next_price > price)
        mapping(uint256 => uint256) askPrices;
        // key: price, value: next_price (next_price < price)
        mapping(uint256 => uint256) bidPrices;
        // Head of the bid price linked list(i.e. highest bid price)
        uint256 askHead;
        // Head of the ask price linked list(i.e. lowest ask price)
        uint256 bidHead;
        // Last matched price
        uint256 lmp;
    }

    error ZeroPrice(uint256 price);
    error NoHeadBelow(bool isBid, uint256 head);
    error PriceOutOfRange(uint256 price, uint256 np);
    error PriceNoneInRange(uint256 price, uint256 np);

    function _setLmp(PriceLinkedList storage self, uint256 lmp_) internal {
        self.lmp = lmp_;
    }

    function _heads(PriceLinkedList storage self) internal view returns (uint256, uint256) {
        return (self.bidHead, self.askHead);
    }

    function _askHead(PriceLinkedList storage self) internal view returns (uint256) {
        return self.askHead;
    }

    function _bidHead(PriceLinkedList storage self) internal view returns (uint256) {
        return self.bidHead;
    }

    function _mktPrice(PriceLinkedList storage self) internal view returns (uint256) {
        if (self.bidHead == 0 && self.askHead == 0) {
            if (self.lmp == 0) {
                revert NoMatchPrice(self.bidHead, self.askHead, self.lmp);
            }
            return self.lmp;
        } else if (self.bidHead != 0 && self.askHead == 0) {
            if (self.lmp != 0) {
                return self.lmp >= self.bidHead ? self.lmp : self.bidHead;
            }
            return self.bidHead;
        } else if (self.bidHead == 0 && self.askHead != 0) {
            if (self.lmp != 0) {
                return self.lmp <= self.askHead ? self.lmp : self.askHead;
            }
            return self.askHead;
        } else {
            return self.lmp;
        }
    }

    function _next(PriceLinkedList storage self, bool isBid, uint256 price) internal view returns (uint256) {
        if (isBid) {
            return self.bidPrices[price];
        } else {
            return self.askPrices[price];
        }
    }

    // for bidPrices, lower ones are next, for askPrices, higher ones are next
    function _insert(PriceLinkedList storage self, bool isBid, uint256 price) internal {
        if (isBid) {
            uint256 last = 0;
            uint256 head = self.bidHead;
            // insert bid price to the linked list
            // if the list is empty
            if (head == 0 || price > head) {
                self.bidHead = price;
                self.bidPrices[price] = head;
                return;
            }
            while (head != 0) {
                uint256 next = self.bidPrices[head];
                if (price < next) {
                    // Keep traversing
                    head = self.bidPrices[head];
                    last = next;
                } else if (price > next) {
                    if (next == 0) {
                        // Insert price at the end of the list
                        self.bidPrices[head] = price;
                        self.bidPrices[price] = 0;
                        return;
                    }
                    // Insert price in the middle of the list
                    self.bidPrices[head] = price;
                    self.bidPrices[price] = next;
                    return;
                } else {
                    // price is already included in the queue as it is equal to next
                    // End traversal as there is no need to traverse further
                    return;
                }
            }
        }
        // insert ask price to the linked list
        else {
            uint256 last = 0;
            uint256 head = self.askHead;
            // insert order to the linked list
            // if the list is empty and price is the lowest ask
            if (head == 0 || price < head) {
                self.askHead = price;
                self.askPrices[price] = head;
                return;
            }
            // traverse the list
            while (head != 0) {
                uint256 next = self.askPrices[head];
                // Keep traversing
                if (price > next) {
                    if (next == 0) {
                        // Insert price in the middle of the list
                        self.askPrices[head] = price;
                        self.askPrices[price] = 0;
                        return;
                    }
                    head = self.askPrices[head];
                    last = next;
                } else if (price < next) {
                    // Insert price in the middle of the list
                    self.askPrices[head] = price;
                    self.askPrices[price] = next;
                    return;
                } else {
                    // price is already included in the queue as it is equal to next
                    // End traversal as there is no need to traverse further
                    return;
                }
            }
        }
    }

    function _clearHead(PriceLinkedList storage self, bool isBid) internal returns (uint256 newHead) {
        if (isBid) {
            self.bidHead = self.bidPrices[self.bidHead];
        } else {
            self.askHead = self.askPrices[self.askHead];
        }
        return isBid ? self.bidHead : self.askHead;
    }

    function _delete(PriceLinkedList storage self, bool isBid, uint256 price) internal returns (bool) {
        if (price == 0) {
            return false;
        }

        if (isBid) {
            uint256 last = 0;
            uint256 head = self.bidHead;
            // Bid list is descending (bidHead is highest). price must be <= bidHead.
            if (head == 0 || price > head) {
                return false;
            }
            // Delete head node
            if (head == price) {
                self.bidHead = self.bidPrices[head];
                delete self.bidPrices[head];
                return true;
            }
            // Traverse descending list to find price
            last = head;
            head = self.bidPrices[head];
            while (head != 0) {
                if (head == price) {
                    self.bidPrices[last] = self.bidPrices[head];
                    delete self.bidPrices[head];
                    return true;
                }
                // Descended below target — price not in list
                if (head < price) {
                    return false;
                }
                last = head;
                head = self.bidPrices[head];
            }
            return false;
        } else {
            uint256 last = 0;
            uint256 head = self.askHead;
            // Ask list is ascending (askHead is lowest). price must be >= askHead.
            if (head == 0 || price < head) {
                return false;
            }
            // Delete head node
            if (head == price) {
                self.askHead = self.askPrices[head];
                delete self.askPrices[head];
                return true;
            }
            // Traverse ascending list to find price
            last = head;
            head = self.askPrices[head];
            while (head != 0) {
                if (head == price) {
                    self.askPrices[last] = self.askPrices[head];
                    delete self.askPrices[head];
                    return true;
                }
                // Ascended past target — price not in list
                if (head > price) {
                    return false;
                }
                last = head;
                head = self.askPrices[head];
            }
            return false;
        }
    }

    // show n prices shown in the orderbook
    function _getPrices(PriceLinkedList storage self, bool isBid, uint256 n) internal view returns (uint256[] memory) {
        uint256 i = 0;
        uint256[] memory prices = new uint256[](n);
        for (
            uint256 price = isBid ? self.bidHead : self.askHead;
            price != 0 && i < n;
            price = isBid ? self.bidPrices[price] : self.askPrices[price]
        ) {
            prices[i] = price;
            i++;
        }
        return prices;
    }

    function _getPricesPaginated(PriceLinkedList storage self, bool isBid, uint256 start, uint256 end)
        internal
        view
        returns (uint256[] memory)
    {
        uint256 i = 0;
        uint256[] memory prices = new uint256[](end - start);
        uint256 price = isBid ? self.bidHead : self.askHead;
        for (price; price != 0 && i < start; price = isBid ? self.bidPrices[price] : self.askPrices[price]) {
            i++;
        }
        if (price == 0) {
            return prices;
        }
        for (price; price != 0 && i < end; price = isBid ? self.bidPrices[price] : self.askPrices[price]) {
            prices[i] = price;
            i++;
        }
        return prices;
    }

    function _checkPriceExists(PriceLinkedList storage self, bool isBid, uint256 price) internal view returns (bool) {
        // traverse the list
        if (price == 0) {
            revert ZeroPrice(price);
            //return false;
        }

        if (isBid) {
            uint256 last = 0;
            uint256 head = self.bidHead;
            // insert bid price to the linked list
            // if the list is empty
            if (head == 0 || price > head) {
                revert NoHeadBelow(isBid, head);
            } else if (head == price) {
                return true;
            }

            while (head != 0 && price > head) {
                uint256 next = self.bidPrices[head];
                if (price < next) {
                    // Keep traversing
                    head = self.bidPrices[head];
                    last = next;
                }
                // within the price range
                else if (price > next) {
                    // if next is end of the list
                    if (next == 0) {
                        // if there is only one price left, check if it is the price we are looking for
                        if (head == price) {
                            return true;
                        }
                        // Price does not exist in price list
                        revert PriceOutOfRange(head, price);
                    }
                    // if next is lower bid than the price
                    else {
                        if (head == price) {
                            return true;
                        }
                        // Price does not exist within range of prices
                        revert PriceNoneInRange(head, price);
                    }
                } else {
                    // price is already included in the queue as it is equal to next. price exists in the orderbook
                    // End traversal as there is no need to traverse further
                    return true;
                }
            }
        }
        // insert ask price to the linked list
        else {
            uint256 last = 0;
            uint256 head = self.askHead;
            // insert order to the linked list
            // if the list is empty and price is the lowest ask
            if (head == 0 || price < head) {
                revert NoHeadBelow(isBid, head);
            } else if (head == price) {
                return true;
            }
            // traverse the list
            while (head != 0) {
                uint256 next = self.askPrices[head];
                // Keep traversing
                if (price > next) {
                    if (next == 0) {
                        // if there is only one price left, check if it is the price we are looking for
                        if (head == price) {
                            return true;
                        }
                        // Price does not exist in price list
                        revert PriceOutOfRange(head, price);
                    }
                    head = self.askPrices[head];
                    last = next;
                } else if (price < next) {
                    if (head == price) {
                        return true;
                    }
                    // Price does not exist within range of prices
                    revert PriceNoneInRange(head, price);
                } else {
                    // price is already included in the queue as it is equal to next
                    // End traversal as there is no need to traverse further
                    return true;
                }
            }
        }

        return true;
    }
}
