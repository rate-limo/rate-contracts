// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {IBandPool} from "./IBandPool.sol";

/**
 * @title IBandPositionManager
 * @notice One ERC-1155 token (amount 1) per LP position. The token carries the whole
 * band ladder: a deposit across three bands is one token, and a later deposit into the
 * same position tops that token up rather than minting another.
 *
 * @dev Every mutating call except `mint`/`mintSingleSided` requires the holder or an
 * address the holder approved for all. Every call that moves value takes a deadline.
 */
interface IBandPositionManager {
    struct MintParams {
        address pool;
        /// @notice Strictly ascending band indices.
        uint8[] bands;
        uint256[] baseAmounts;
        uint256[] quoteAmounts;
        /// @notice Per-band floor on shares minted.
        uint128[] minShares;
        address recipient;
        uint256 deadline;
    }

    /// @notice A position as a wallet sees it: which pool, and every band it holds.
    struct PositionView {
        uint256 tokenId;
        address pool;
        address base;
        address quote;
        address holder;
        uint64 mintedAt;
        uint8 bandMask;
        IBandPool.BandView[] bands;
        uint256 owedBase;
        uint256 owedQuote;
    }

    /// @notice A redistribution request, as the manager solved it into moves.
    event Redistributed(uint256 indexed tokenId, uint8[] bands, uint16[] targetBps);

    error DeadlinePassed(uint256 deadline, uint256 nowTs);
    error NotOwnerOrApproved(address caller, uint256 tokenId);
    error UnknownPool(address pool);
    error LengthMismatch();
    error BandsNotAscending();
    error SharesBelowMinimum(uint8 band, uint128 minted, uint128 minimum);
    error AmountBelowMinimum(uint256 baseOut, uint256 quoteOut);
    error TargetsNotWhole(uint256 sumBps);
    error PositionNotEmpty(uint256 tokenId);
    error BadBps(uint16 bps);

    /// @notice Opens a position across `p.bands` and mints its token to `p.recipient`.
    /// @dev Pulls the offered totals, refunds whatever the bands' ratios did not use.
    function mint(MintParams calldata p) external returns (uint256 tokenId, uint128[] memory shares);

    /// @notice Opens a position from ONE token: half of each band's amount is swapped
    /// through the router first, then both legs are deposited.
    function mintSingleSided(
        address pool,
        uint8[] calldata bands,
        uint256[] calldata amountsIn,
        bool inputIsBase,
        uint128[] calldata minShares,
        address recipient,
        uint256 deadline
    ) external returns (uint256 tokenId, uint128[] memory shares);

    /// @notice Tops up an existing position. May add bands it does not hold yet.
    function increaseLiquidity(
        uint256 tokenId,
        uint8[] calldata bands,
        uint256[] calldata baseAmounts,
        uint256[] calldata quoteAmounts,
        uint128[] calldata minShares,
        uint256 deadline
    ) external returns (uint128[] memory shares);

    /// @notice Withdraws `bps` of every band, and every vested fee, in one transaction.
    /// @dev 10,000 bps is a full exit. Unvested fees forfeit in proportion to the shares
    /// removed; nothing else forfeits.
    function decreaseLiquidity(
        uint256 tokenId,
        uint16 bps,
        uint256 minBase,
        uint256 minQuote,
        address recipient,
        uint256 deadline
    ) external returns (uint256 baseOut, uint256 quoteOut);

    /// @notice Withdraws from one band only. The advanced path.
    function decreaseBand(
        uint256 tokenId,
        uint8 band,
        uint128 shares,
        uint256 minBase,
        uint256 minQuote,
        address recipient,
        uint256 deadline
    ) external returns (uint256 baseOut, uint256 quoteOut);

    /// @notice Moves shares from one band to another inside the pool. No tokens come in;
    /// only what the receiving band's ratio cannot absorb is refunded.
    function moveLiquidity(
        uint256 tokenId,
        uint8 fromBand,
        uint8 toBand,
        uint128 shares,
        uint128 minSharesIn,
        address refundTo,
        uint256 deadline
    ) external returns (uint128 sharesIn, uint256 baseRefund, uint256 quoteRefund);

    struct RedistributeParams {
        uint256 tokenId;
        /// @notice Strictly ascending. A held band left out is emptied.
        uint8[] bands;
        /// @notice Target share of the position's value per band; must sum to 10,000.
        uint16[] targetBps;
        /// @notice Per-band floor on the shares each band holds afterwards (0 = no floor).
        uint128[] minSharesAfter;
        address refundTo;
        uint256 deadline;
    }

    /// @notice Sets the position's distribution to `targetBps` of its value at the anchor.
    /// @dev Solved here into `move`s against the pool, so the capital never leaves it.
    function redistribute(RedistributeParams calldata p) external returns (uint256 baseRefund, uint256 quoteRefund);

    /// @notice Pays every vested fee. Never forfeits.
    function collect(uint256 tokenId, address recipient) external returns (uint256 base, uint256 quote);

    /// @notice `collect` for several tokens in one transaction -- the profile's "claim all".
    /// @dev Each id must be the caller's or approved; one that is not reverts the batch.
    function collectMany(uint256[] calldata tokenIds, address recipient)
        external
        returns (uint256[] memory base, uint256[] memory quote);

    /// @notice Destroys an empty token. Reverts while any band or owed fee remains.
    function burn(uint256 tokenId) external;

    function positionOf(uint256 tokenId) external view returns (PositionView memory);

    function portfolio(uint256[] calldata tokenIds) external view returns (PositionView[] memory);

    /// @notice The pool a token belongs to. Zero for a token that does not exist.
    function poolOf(uint256 tokenId) external view returns (address);

    function holderOf(uint256 tokenId) external view returns (address);

    /// @notice The id the next mint will take. Ids start at 1.
    function nextTokenId() external view returns (uint256);
}
