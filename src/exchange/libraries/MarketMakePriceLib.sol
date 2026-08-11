// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

library MarketMakePriceLib {
    uint256 internal constant DENOM = 100_000_000;

    function buy(uint256 lmp, uint256 bidHead, uint256 askHead, uint32 spread)
        public pure returns (uint256 price)
    {
        uint256 up;
        if (askHead == 0 && bidHead == 0) {
            if (lmp != 0) return (lmp * (DENOM + spread)) / DENOM;
        } else if (askHead == 0) {
            if (lmp != 0) return ((bidHead >= lmp ? bidHead : lmp) * (DENOM + spread)) / DENOM;
            return (bidHead * (DENOM + spread)) / DENOM;
        } else if (bidHead == 0) {
            if (lmp != 0) {
                up = (lmp * (DENOM + spread)) / DENOM;
                return askHead >= up ? up : askHead;
            }
            return askHead;
        } else {
            if (lmp != 0) {
                up = ((bidHead >= lmp ? bidHead : lmp) * (DENOM + spread)) / DENOM;
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
                up = (lmp * (DENOM + spread)) / DENOM;
                return lp >= up ? up : lp;
            }
            return lp;
        } else if (askHead == 0) {
            up = ((lmp != 0 ? lmp : bidHead) * (DENOM + spread)) / DENOM;
            return lp >= up ? up : lp;
        } else if (bidHead == 0) {
            up = ((lmp != 0 ? lmp : askHead) * (DENOM + spread)) / DENOM;
            up = lp >= up ? up : lp;
            return up >= askHead ? askHead : up;
        } else {
            if (lmp != 0) {
                up = (lmp * (DENOM + spread)) / DENOM;
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
