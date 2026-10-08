// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

library MarketMakePriceLib {
    uint256 internal constant DENOM = 100_000_000;

    /// `price × (1 + spread)`, rounded UP. The buy-side rail used to floor, which on a low
    /// price erased the spread entirely: at 500 (0.000005 on the 1e8 grid) a 0.1% spread
    /// floors back to 500, so no buy could ever rest or match above the last price -- one
    /// tick there is 0.2%. Rounding up guarantees a nonzero spread moves at least one
    /// tick, and is exact whenever the product is whole. The sell side already floors,
    /// which is its own favour-of-filling direction, so it has no twin.
    function _up(uint256 price, uint32 spread) private pure returns (uint256) {
        return (price * (DENOM + spread) + DENOM - 1) / DENOM;
    }

    function buy(uint256 lmp, uint256 bidHead, uint256 askHead, uint32 spread)
        public pure returns (uint256 price)
    {
        uint256 up;
        if (askHead == 0 && bidHead == 0) {
            if (lmp != 0) return _up(lmp, spread);
        } else if (askHead == 0) {
            if (lmp != 0) return _up(bidHead >= lmp ? bidHead : lmp, spread);
            return _up(bidHead, spread);
        } else if (bidHead == 0) {
            if (lmp != 0) {
                up = _up(lmp, spread);
                return askHead >= up ? up : askHead;
            }
            return askHead;
        } else {
            if (lmp != 0) {
                up = _up(bidHead >= lmp ? bidHead : lmp, spread);
                return askHead >= up ? up : askHead;
            }
            return askHead;
        }
    }

    function sell(uint256 lmp, uint256 bidHead, uint256 askHead, uint32 spread)
        public pure returns (uint256 price)
    {
        uint256 down;
        if (askHead == 0 && bidHead == 0) {
            if (lmp != 0) {
                down = (lmp * (DENOM - spread)) / DENOM;
                return down == 0 ? 1 : down;
            }
        } else if (askHead == 0) {
            if (lmp != 0) {
                down = (lmp * (DENOM - spread)) / DENOM;
                down = down <= bidHead ? bidHead : down;
                return down == 0 ? 1 : down;
            }
            return bidHead;
        } else if (bidHead == 0) {
            if (lmp != 0) {
                down = ((lmp <= askHead ? lmp : askHead) * (DENOM - spread)) / DENOM;
                return down == 0 ? 1 : down;
            }
            down = (askHead * (DENOM - spread)) / DENOM;
            return down == 0 ? 1 : down;
        } else {
            if (lmp != 0) {
                down = ((lmp <= askHead ? lmp : askHead) * (DENOM - spread)) / DENOM;
                down = down <= bidHead ? bidHead : down;
                return down == 0 ? 1 : down;
            }
            return bidHead;
        }
    }

    function limitBuy(uint256 lmp, uint256 lp, uint256 bidHead, uint256 askHead, uint32 spread)
        public pure returns (uint256 price)
    {
        uint256 up;
        if (askHead == 0 && bidHead == 0) {
            if (lmp != 0) {
                up = _up(lmp, spread);
                return lp >= up ? up : lp;
            }
            return lp;
        } else if (askHead == 0) {
            up = _up(lmp != 0 ? lmp : bidHead, spread);
            return lp >= up ? up : lp;
        } else if (bidHead == 0) {
            up = _up(lmp != 0 ? lmp : askHead, spread);
            up = lp >= up ? up : lp;
            return up >= askHead ? askHead : up;
        } else {
            if (lmp != 0) {
                up = _up(lmp, spread);
                up = lp >= up ? up : lp;
                return up >= askHead ? askHead : up;
            }
            return lp >= askHead ? askHead : lp;
        }
    }

    function limitSell(uint256 lmp, uint256 lp, uint256 bidHead, uint256 askHead, uint32 spread)
        public pure returns (uint256 price)
    {
        uint256 down;
        if (askHead == 0 && bidHead == 0) {
            if (lmp != 0) {
                down = (lmp * (DENOM - spread)) / DENOM;
                return lp <= down ? down : lp;
            }
            return lp;
        } else if (askHead == 0) {
            down = ((lmp != 0 ? lmp : bidHead) * (DENOM - spread)) / DENOM;
            down = lp <= down ? down : lp;
            return down <= bidHead ? bidHead : down;
        } else if (bidHead == 0) {
            down = ((lmp != 0 ? lmp : askHead) * (DENOM - spread)) / DENOM;
            return lp <= down ? down : lp;
        } else {
            if (lmp != 0) {
                down = (lmp * (DENOM - spread)) / DENOM;
                return lp <= down ? down : lp;
            }
            return bidHead;
        }
    }
}
