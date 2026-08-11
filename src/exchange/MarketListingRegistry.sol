// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IListingMatchingEngine {
    function getPair(address base, address quote) external view returns (address pair);
}

/// @notice Optional verification and discovery layer for permissionlessly-created markets.
/// Pair creation remains free in MatchingEngine; this contract never controls whether a pair trades.
contract MarketListingRegistry is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    enum Status {
        Unverified,
        Pending,
        Verified,
        Rejected
    }

    struct Verification {
        address applicant;
        uint96 bondAmount;
        uint64 unlockAt;
        uint8 tier;
        Status status;
    }

    address public immutable matchingEngine;
    IERC20 public immutable bondToken;
    address public treasury;
    uint64 public reviewPeriod;

    mapping(uint8 => uint96) public tierBond;
    mapping(address => Verification) public verification;
    mapping(address => uint64) public featuredUntil;

    event VerificationRequested(
        address indexed pair, address indexed applicant, uint8 indexed tier, uint256 bondAmount
    );
    event VerificationApproved(address indexed pair, address indexed applicant, uint64 unlockAt);
    event VerificationRejected(
        address indexed pair, address indexed applicant, bool slashed, bytes32 indexed reasonHash
    );
    event VerificationCancelled(address indexed pair, address indexed applicant, uint256 refunded);
    event VerificationRevoked(
        address indexed pair, bool slashed, bytes32 indexed reasonHash, uint256 bondAmount
    );
    event BondWithdrawn(address indexed pair, address indexed applicant, uint256 amount);
    event TierBondSet(uint8 indexed tier, uint256 amount);
    event FeaturedMarketSet(address indexed pair, uint64 featuredUntil, bytes32 indexed campaignId);
    event TreasurySet(address indexed treasury);
    event ReviewPeriodSet(uint64 reviewPeriod);
    event ListingRegistryInitialized(
        address indexed matchingEngine,
        address indexed bondToken,
        address indexed treasury,
        uint64 reviewPeriod
    );

    error InvalidAddress();
    error InvalidTier(uint8 tier);
    error PairDoesNotExist(address base, address quote);
    error InvalidStatus(address pair, Status status);
    error InvalidApplicant(address sender, address applicant);
    error BondLocked(uint64 unlockAt, uint64 currentTime);
    error AmountOverflow(uint256 amount);

    constructor(
        address matchingEngine_,
        address bondToken_,
        address treasury_,
        uint64 reviewPeriod_,
        uint96[3] memory initialTierBonds
    ) {
        if (matchingEngine_ == address(0) || bondToken_ == address(0) || treasury_ == address(0)) {
            revert InvalidAddress();
        }
        matchingEngine = matchingEngine_;
        bondToken = IERC20(bondToken_);
        treasury = treasury_;
        reviewPeriod = reviewPeriod_;
        for (uint8 i; i < 3; ++i) {
            tierBond[i] = initialTierBonds[i];
        }
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        emit ListingRegistryInitialized(matchingEngine_, bondToken_, treasury_, reviewPeriod_);
        for (uint8 i; i < 3; ++i) emit TierBondSet(i, initialTierBonds[i]);
    }

    function requestVerification(address base, address quote, uint8 tier)
        external nonReentrant returns (address pair)
    {
        if (tier > 2) revert InvalidTier(tier);
        pair = IListingMatchingEngine(matchingEngine).getPair(base, quote);
        if (pair == address(0)) revert PairDoesNotExist(base, quote);
        Status current = verification[pair].status;
        if (current == Status.Pending || current == Status.Verified) revert InvalidStatus(pair, current);

        uint256 amount = tierBond[tier];
        if (amount > type(uint96).max) revert AmountOverflow(amount);
        verification[pair] = Verification(msg.sender, uint96(amount), 0, tier, Status.Pending);
        if (amount != 0) bondToken.safeTransferFrom(msg.sender, address(this), amount);
        emit VerificationRequested(pair, msg.sender, tier, amount);
    }

    function approve(address pair) external onlyRole(DEFAULT_ADMIN_ROLE) {
        Verification storage item = verification[pair];
        if (item.status != Status.Pending) revert InvalidStatus(pair, item.status);
        item.status = Status.Verified;
        item.unlockAt = uint64(block.timestamp) + reviewPeriod;
        emit VerificationApproved(pair, item.applicant, item.unlockAt);
    }

    function reject(address pair, bool slash, bytes32 reasonHash)
        external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant
    {
        Verification storage item = verification[pair];
        if (item.status != Status.Pending) revert InvalidStatus(pair, item.status);
        address applicant = item.applicant;
        uint256 amount = item.bondAmount;
        item.status = Status.Rejected;
        item.bondAmount = 0;
        if (amount != 0) bondToken.safeTransfer(slash ? treasury : applicant, amount);
        emit VerificationRejected(pair, applicant, slash, reasonHash);
    }

    function cancelRequest(address pair) external nonReentrant {
        Verification storage item = verification[pair];
        if (item.status != Status.Pending) revert InvalidStatus(pair, item.status);
        if (msg.sender != item.applicant) revert InvalidApplicant(msg.sender, item.applicant);
        uint256 amount = item.bondAmount;
        item.status = Status.Unverified;
        item.bondAmount = 0;
        if (amount != 0) bondToken.safeTransfer(msg.sender, amount);
        emit VerificationCancelled(pair, msg.sender, amount);
    }

    function withdrawBond(address pair) external nonReentrant returns (uint256 amount) {
        Verification storage item = verification[pair];
        if (item.status != Status.Verified) revert InvalidStatus(pair, item.status);
        if (msg.sender != item.applicant) revert InvalidApplicant(msg.sender, item.applicant);
        if (block.timestamp < item.unlockAt) revert BondLocked(item.unlockAt, uint64(block.timestamp));
        amount = item.bondAmount;
        item.bondAmount = 0;
        if (amount != 0) bondToken.safeTransfer(msg.sender, amount);
        emit BondWithdrawn(pair, msg.sender, amount);
    }

    function revoke(address pair, bool slash, bytes32 reasonHash)
        external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant
    {
        Verification storage item = verification[pair];
        if (item.status != Status.Verified) revert InvalidStatus(pair, item.status);
        uint256 amount = item.bondAmount;
        address applicant = item.applicant;
        item.status = Status.Unverified;
        item.bondAmount = 0;
        if (amount != 0) bondToken.safeTransfer(slash ? treasury : applicant, amount);
        emit VerificationRevoked(pair, slash, reasonHash, amount);
    }

    function setFeatured(address pair, uint64 until, bytes32 campaignId)
        external onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (verification[pair].status != Status.Verified) {
            revert InvalidStatus(pair, verification[pair].status);
        }
        featuredUntil[pair] = until;
        emit FeaturedMarketSet(pair, until, campaignId);
    }

    function isVerified(address pair) external view returns (bool) {
        return verification[pair].status == Status.Verified;
    }

    function isFeatured(address pair) external view returns (bool) {
        return verification[pair].status == Status.Verified && featuredUntil[pair] >= block.timestamp;
    }

    function setTierBond(uint8 tier, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (tier > 2) revert InvalidTier(tier);
        if (amount > type(uint96).max) revert AmountOverflow(amount);
        tierBond[tier] = uint96(amount);
        emit TierBondSet(tier, amount);
    }

    function setTreasury(address treasury_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (treasury_ == address(0)) revert InvalidAddress();
        treasury = treasury_;
        emit TreasurySet(treasury_);
    }

    function setReviewPeriod(uint64 reviewPeriod_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        reviewPeriod = reviewPeriod_;
        emit ReviewPeriodSet(reviewPeriod_);
    }
}
