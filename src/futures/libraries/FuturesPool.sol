// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.24;

// Pure math library for futures margin, PnL, and liquidation calculations.
// Holds no storage -- PerpPool owns the position ledger directly (see IPerpPool.Position).
library FuturesPool {
    // fee/margin values are expressed in basis points out of this denominator
    uint32 public constant feeDenom = 10000;

    error PoolMaxLeverageIsZero();

    // Number of contracts (position size in base-asset-equivalent units) implied by a given
    // margin, entry price, and leverage: notional = margin * leverage; size = notional / price.
    function _contracts(uint256 margin, uint256 entryPrice, uint32 leverage) internal pure returns (uint256) {
        uint256 notional = margin * leverage;
        return notional / entryPrice;
    }

    function _priceDiff(uint256 entryPrice, uint256 mktPrice, bool isLong) internal pure returns (int256) {
        return isLong ? int256(mktPrice) - int256(entryPrice) : int256(entryPrice) - int256(mktPrice);
    }

    // Position size * (mktPrice - entryPrice), sign-adjusted for direction.
    function _pnl(uint256 margin, uint256 entryPrice, uint32 leverage, uint256 mktPrice, bool isLong)
        internal
        pure
        returns (int256 pnl)
    {
        uint256 positionSize = _contracts(margin, entryPrice, leverage);
        return _priceDiff(entryPrice, mktPrice, isLong) * int256(positionSize);
    }

    /**
     * @dev Maintenance margin, in bps of notional, fixed per pool. Per Hyperliquid's margining
     * model this is half of the initial margin AT THE POOL'S CONFIGURED MAX LEVERAGE -- it does
     * NOT vary with any individual position's own chosen leverage. Example: pool max leverage
     * 20x -> maintenance margin is always 2.5% (250 bps), whether a specific trader chose 2x or
     * 20x for their own position.
     * @param poolMaxLeverage the pool's configured maximum leverage for this side
     */
    function _maintenanceMarginBps(uint32 poolMaxLeverage) internal pure returns (uint256) {
        if (poolMaxLeverage == 0) revert PoolMaxLeverageIsZero();
        return feeDenom / (2 * uint256(poolMaxLeverage));
    }

    // Positions are liquidatable when account value (margin + unrealized pnl) is less than the
    // maintenance margin requirement (pool's fixed maintenanceMarginBps * open notional at mkt).
    function _isLiquidatable(
        uint256 margin,
        uint256 entryPrice,
        uint32 leverage,
        uint256 mktPrice,
        bool isLong,
        uint32 poolMaxLeverage
    ) internal pure returns (bool) {
        uint256 positionSize = _contracts(margin, entryPrice, leverage);
        uint256 openNotional = positionSize * mktPrice;

        uint256 maintenanceMarginBps = _maintenanceMarginBps(poolMaxLeverage);
        int256 pnl = _pnl(margin, entryPrice, leverage, mktPrice, isLong);
        int256 accountValue = int256(margin) + pnl;
        int256 requiredMargin = int256((openNotional * maintenanceMarginBps) / feeDenom);

        return accountValue < requiredMargin;
    }

    // Splits a liquidated position's remaining margin between an explicit protocol fee and the
    // pool. Hyperliquid charges no explicit clearance fee (liqFeeBps=0 is the expected default)
    // -- the maintenance-margin buffer simply isn't returned to the trader, which is exactly
    // poolFund here.
    function _liquidationSplit(uint256 margin, uint32 liqFeeBps) internal pure returns (uint256 feeFund, uint256 poolFund) {
        feeFund = (margin * liqFeeBps) / feeDenom;
        poolFund = margin - feeFund;
    }
}
