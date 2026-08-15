// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Coin} from "./AssetGenerator.sol";
import {IMatchingEngine} from "../exchange/interfaces/IMatchingEngine.sol";
import {ExchangeOrderbook} from "../exchange/libraries/ExchangeOrderbook.sol";
import {IPositionManager} from "../swap/interfaces/IPositionManager.sol";
import {IPoolFactory} from "../swap/interfaces/IPoolFactory.sol";
import {IPool} from "../swap/interfaces/IPool.sol";
import {TransferHelper} from "../exchange/libraries/TransferHelper.sol";

interface IAssetGeneratorPolicy {
    function setExistingPairTradingConfig(
        address base,
        address quote,
        uint16 slippageLimitBps,
        uint32 makerFee,
        uint32 takerFee
    ) external;
}

/// @notice Fixed-price, pro-rata presales that graduate into an Iter CLOB market.
///
/// The contract deliberately keeps the presale lifecycle separate from AssetGenerator:
/// AssetGenerator lists a coin immediately, while an auction must not have a market
/// before the sale succeeds. On graduation this contract calls the same MatchingEngine
/// and PositionManager used by the Degen flow, so the post-sale market has the same
/// orderbook and LP semantics.
contract PresaleLaunch is AccessControl, ReentrancyGuard, ERC1155Holder {
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    uint256 public constant BPS = 10_000;
    uint256 public constant PRICE_SCALE = 1e18;
    uint16 public constant MIN_LP_BPS = 2_000;
    uint16 public constant MAX_LP_BPS = 10_000;
    uint64 public constant MAX_SALE_DURATION = 30 days;
    uint64 public constant MAX_VESTING_DURATION = 10 * 365 days;

    enum Status {
        Upcoming,
        Live,
        Successful,
        Failed,
        Graduated
    }

    struct Presale {
        address creator;
        address coin;
        address quote;
        uint256 totalSupply;
        uint256 presaleAllocation;
        uint256 lpTokenAllocation;
        uint256 priceQuotePerToken;
        uint256 targetRaise;
        uint256 minimumRaise;
        uint256 maxPerWallet;
        uint256 totalCommitted;
        uint256 creatorTokenAllocation;
        uint256 treasuryTokenAllocation;
        uint64 startAt;
        uint64 endAt;
        uint64 creatorCliff;
        uint64 creatorVestingDuration;
        uint64 creatorVestingStartAt;
        uint16 lpBps;
        address treasury;
        Status status;
        address pair;
        address pool;
        uint256 positionTokenId;
        uint64 liquidityUnlockAt;
        uint256 acceptedRaise;
        uint256 claimedContributions;
    }

    struct GraduationConfig {
        uint256 listingPrice;
        uint256 minPrice;
        uint256 maxPrice;
        uint32 lpSlippageLimit;
        uint16 volatilityBps;
        uint32 makerFee;
        uint32 takerFee;
        uint64 liquidityLockDuration;
        ExchangeOrderbook.MatchingMode mode;
    }

    struct CreateParams {
        string name;
        string symbol;
        uint256 totalSupply;
        uint256 presaleAllocation;
        uint256 lpTokenAllocation;
        uint256 priceQuotePerToken;
        uint256 targetRaise;
        uint256 minimumRaise;
        uint256 maxPerWallet;
        uint256 creatorTokenAllocation;
        uint256 treasuryTokenAllocation;
        uint64 startAt;
        uint64 endAt;
        uint64 creatorCliff;
        uint64 creatorVestingDuration;
        uint16 lpBps;
        address quote;
        address treasury;
    }

    address public immutable matchingEngine;
    address public immutable positionManager;
    address public immutable assetGenerator;
    uint256 public nextPresaleId;

    mapping(uint256 presaleId => Presale) internal presales;
    mapping(uint256 presaleId => GraduationConfig) public graduationConfigs;
    mapping(uint256 presaleId => mapping(address account => uint256)) public committed;
    mapping(uint256 presaleId => mapping(address account => bool)) public claimed;
    mapping(uint256 presaleId => uint256) public creatorVestedClaimed;

    event PresaleCreated(
        uint256 indexed presaleId,
        address indexed coin,
        address indexed creator,
        address quote,
        uint256 totalSupply,
        uint256 presaleAllocation,
        uint256 lpTokenAllocation,
        uint256 priceQuotePerToken,
        uint256 targetRaise,
        uint256 minimumRaise,
        uint256 maxPerWallet,
        uint64 startAt,
        uint64 endAt,
        uint16 lpBps
    );
    event PresaleTerms(
        uint256 indexed presaleId,
        uint256 creatorTokenAllocation,
        uint256 treasuryTokenAllocation,
        uint64 creatorCliff,
        uint64 creatorVestingDuration,
        address treasury
    );
    event PresaleContribution(uint256 indexed presaleId, address indexed account, uint256 amount, uint256 totalCommitted);
    event PresaleFinalized(uint256 indexed presaleId, Status status, uint256 totalCommitted, uint256 acceptedRaise);
    event PresaleClaimed(uint256 indexed presaleId, address indexed account, uint256 acceptedAmount, uint256 refundAmount, uint256 tokenAmount);
    event GraduationConfigured(uint256 indexed presaleId, address indexed by, uint256 listingPrice, uint256 minPrice, uint256 maxPrice, uint16 volatilityBps, uint32 makerFee, uint32 takerFee, uint64 liquidityLockDuration);
    event PresaleGraduated(
        uint256 indexed presaleId,
        address indexed coin,
        address indexed pair,
        address pool,
        uint256 positionTokenId,
        uint256 acceptedRaise,
        uint256 lpQuoteAmount,
        uint256 lpTokenAmount,
        uint64 liquidityUnlockAt
    );
    event CreatorTokensClaimed(uint256 indexed presaleId, address indexed creator, uint256 amount);
    event FailedPresaleTokensRecovered(uint256 indexed presaleId, address indexed creator, uint256 amount);
    event LiquidityReleased(uint256 indexed presaleId, address indexed recipient, uint256 indexed positionTokenId);
    event SettlementTokenSet(address indexed token, bool enabled, address indexed by);

    error ZeroAddress();
    error InvalidAmount();
    error InvalidSchedule();
    error InvalidAllocation();
    error InvalidRaise();
    error InvalidLiquidityCommitment();
    error NotCreator();
    error NotLive();
    error SaleNotFinished();
    error SaleAlreadyFinalized();
    error MinimumNotReached();
    error MinimumReached();
    error NotSuccessful();
    error NotFailed();
    error AlreadyClaimed();
    error ExceedsWalletCap();
    error InsufficientBalance();
    error GraduationAlreadyConfigured();
    error InvalidGraduationConfig();
    error LiquidityStillLocked(uint64 unlockAt);
    error LiquidityNotCreated();
    error VestingNotStarted();
    error InvalidQuote();

    /// @dev Kept as the initial/default token for backwards-compatible reads. New
    /// presales validate against settlementTokenEnabled, which the admin can update.
    address public settlementToken;
    mapping(address token => bool enabled) public settlementTokenEnabled;
    mapping(address token => bool known) private _settlementTokenKnown;
    address[] private _settlementTokens;

    constructor(address admin, address matchingEngine_, address positionManager_, address assetGenerator_, address settlementToken_) {
        if (admin == address(0) || matchingEngine_ == address(0) || positionManager_ == address(0) || settlementToken_ == address(0)) revert ZeroAddress();
        matchingEngine = matchingEngine_;
        positionManager = positionManager_;
        assetGenerator = assetGenerator_;
        settlementToken = settlementToken_;
        settlementTokenEnabled[settlementToken_] = true;
        _settlementTokenKnown[settlementToken_] = true;
        _settlementTokens.push(settlementToken_);
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(OPERATOR_ROLE, admin);
    }

    /// @notice Enables or disables a settlement token for future presales.
    /// Existing presales keep their snapshotted quote token and are unaffected.
    function setSettlementToken(address token, bool enabled) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (token == address(0)) revert ZeroAddress();
        if (!_settlementTokenKnown[token]) {
            _settlementTokenKnown[token] = true;
            _settlementTokens.push(token);
        }
        settlementTokenEnabled[token] = enabled;
        if (enabled) settlementToken = token;
        emit SettlementTokenSet(token, enabled, msg.sender);
    }

    function settlementTokens() external view returns (address[] memory) {
        return _settlementTokens;
    }

    function createPresale(CreateParams calldata p) external returns (uint256 presaleId, address coin) {
        _validateCreate(p);

        coin = address(new Coin(p.name, p.symbol, p.totalSupply, address(this)));
        presaleId = ++nextPresaleId;
        _storeCreate(presaleId, coin, p);
        _emitPresaleCreated(presaleId);
        emit PresaleTerms(
            presaleId,
            p.creatorTokenAllocation,
            p.treasuryTokenAllocation,
            p.creatorCliff,
            p.creatorVestingDuration,
            p.treasury
        );
    }

    function commit(uint256 presaleId, uint256 amount) external nonReentrant {
        Presale storage sale = _liveSale(presaleId);
        if (amount == 0) revert InvalidAmount();
        uint256 next = committed[presaleId][msg.sender] + amount;
        if (next > sale.maxPerWallet) revert ExceedsWalletCap();
        committed[presaleId][msg.sender] = next;
        sale.totalCommitted += amount;
        TransferHelper.safeTransferFrom(sale.quote, msg.sender, address(this), amount);
        emit PresaleContribution(presaleId, msg.sender, amount, sale.totalCommitted);
    }

    function finalizeSale(uint256 presaleId) external {
        Presale storage sale = presales[presaleId];
        if (sale.status != Status.Upcoming && sale.status != Status.Live) revert SaleAlreadyFinalized();
        if (block.timestamp < sale.endAt) revert SaleNotFinished();
        if (sale.totalCommitted >= sale.minimumRaise) {
            sale.status = Status.Successful;
            sale.acceptedRaise = sale.totalCommitted < sale.targetRaise ? sale.totalCommitted : sale.targetRaise;
        } else {
            sale.status = Status.Failed;
        }
        emit PresaleFinalized(presaleId, sale.status, sale.totalCommitted, sale.acceptedRaise);
    }

    function claim(uint256 presaleId) external nonReentrant {
        Presale storage sale = presales[presaleId];
        if (sale.status != Status.Graduated && sale.status != Status.Failed) revert NotSuccessful();
        if (claimed[presaleId][msg.sender]) revert AlreadyClaimed();
        uint256 contribution = committed[presaleId][msg.sender];
        if (contribution == 0) revert InvalidAmount();
        claimed[presaleId][msg.sender] = true;

        if (sale.status == Status.Failed) {
            TransferHelper.safeTransfer(sale.quote, msg.sender, contribution);
            emit PresaleClaimed(presaleId, msg.sender, 0, contribution, 0);
            return;
        }

        uint256 accepted = contribution * sale.acceptedRaise / sale.totalCommitted;
        uint256 refund = contribution - accepted;
        uint256 tokenAmount = accepted * sale.presaleAllocation / sale.acceptedRaise;
        if (refund > 0) TransferHelper.safeTransfer(sale.quote, msg.sender, refund);
        TransferHelper.safeTransfer(sale.coin, msg.sender, tokenAmount);
        sale.claimedContributions += accepted;
        emit PresaleClaimed(presaleId, msg.sender, accepted, refund, tokenAmount);
    }

    function configureGraduation(uint256 presaleId, GraduationConfig calldata config) external {
        Presale storage sale = presales[presaleId];
        if (msg.sender != sale.creator && !hasRole(OPERATOR_ROLE, msg.sender)) revert NotCreator();
        if (sale.status != Status.Successful) revert NotSuccessful();
        if (graduationConfigs[presaleId].listingPrice != 0) revert GraduationAlreadyConfigured();
        if (config.listingPrice == 0 || config.minPrice == 0 || config.maxPrice < config.minPrice || config.lpSlippageLimit >= 100_000_000) revert InvalidGraduationConfig();
        if (config.volatilityBps == 0 || config.volatilityBps > 10_000 || config.makerFee > 100_000_000 || config.takerFee > 100_000_000) revert InvalidGraduationConfig();
        if (config.liquidityLockDuration == 0) revert InvalidGraduationConfig();
        graduationConfigs[presaleId] = config;
        emit GraduationConfigured(presaleId, msg.sender, config.listingPrice, config.minPrice, config.maxPrice, config.volatilityBps, config.makerFee, config.takerFee, config.liquidityLockDuration);
    }

    /// @notice Creates the pair and commits the configured share of accepted USDC and ABC to the CLOB LP.
    /// @dev Permissionless after the creator has supplied graduation configuration. This prevents a
    /// creator from blocking a successful sale indefinitely while keeping configuration creator-owned.
    function graduate(uint256 presaleId) external nonReentrant {
        Presale storage sale = presales[presaleId];
        if (sale.status != Status.Successful) revert NotSuccessful();
        GraduationConfig memory config = graduationConfigs[presaleId];
        if (config.listingPrice == 0) revert InvalidGraduationConfig();

        uint256 lpQuoteAmount = sale.acceptedRaise * sale.lpBps / BPS;
        uint256 lpTokenAmount = sale.lpTokenAllocation;
        address pair = _createPair(sale, config);
        address pool = _poolFor(sale.coin, sale.quote);
        uint256 positionTokenId = _addLiquidity(sale, config, pool, lpTokenAmount, lpQuoteAmount);
        _setTradingPolicy(sale.coin, sale.quote, config);

        uint64 unlockAt = uint64(block.timestamp) + config.liquidityLockDuration;
        sale.pair = pair;
        sale.pool = pool;
        sale.positionTokenId = positionTokenId;
        sale.liquidityUnlockAt = unlockAt;
        sale.creatorVestingStartAt = uint64(block.timestamp);
        sale.status = Status.Graduated;

        _payTreasury(sale, lpQuoteAmount);
        emit PresaleGraduated(presaleId, sale.coin, pair, pool, positionTokenId, sale.acceptedRaise, lpQuoteAmount, lpTokenAmount, unlockAt);
    }

    function claimCreatorTokens(uint256 presaleId) external nonReentrant {
        Presale storage sale = presales[presaleId];
        if (msg.sender != sale.creator) revert NotCreator();
        if (sale.status != Status.Graduated) revert NotSuccessful();
        uint64 vestingStart = sale.creatorVestingStartAt + sale.creatorCliff;
        if (block.timestamp < vestingStart) revert VestingNotStarted();
        uint256 elapsed = block.timestamp - vestingStart;
        uint256 vested = elapsed >= sale.creatorVestingDuration
            ? sale.creatorTokenAllocation
            : sale.creatorTokenAllocation * elapsed / sale.creatorVestingDuration;
        uint256 amount = vested - creatorVestedClaimed[presaleId];
        if (amount == 0) revert InvalidAmount();
        creatorVestedClaimed[presaleId] += amount;
        TransferHelper.safeTransfer(sale.coin, sale.creator, amount);
        emit CreatorTokensClaimed(presaleId, sale.creator, amount);
    }

    function releaseLiquidity(uint256 presaleId, address recipient) external nonReentrant {
        Presale storage sale = presales[presaleId];
        if (msg.sender != sale.creator) revert NotCreator();
        if (sale.positionTokenId == 0) revert LiquidityNotCreated();
        if (block.timestamp < sale.liquidityUnlockAt) revert LiquidityStillLocked(sale.liquidityUnlockAt);
        if (recipient == address(0)) revert ZeroAddress();
        uint256 tokenId = sale.positionTokenId;
        sale.positionTokenId = 0;
        IERC1155(positionManager).safeTransferFrom(address(this), recipient, tokenId, 1, "");
        emit LiquidityReleased(presaleId, recipient, tokenId);
    }

    function recoverFailedTokens(uint256 presaleId) external nonReentrant {
        Presale storage sale = presales[presaleId];
        if (msg.sender != sale.creator) revert NotCreator();
        if (sale.status != Status.Failed) revert NotFailed();
        uint256 balance = IERC20(sale.coin).balanceOf(address(this));
        if (balance == 0) revert InsufficientBalance();
        TransferHelper.safeTransfer(sale.coin, sale.creator, balance);
        emit FailedPresaleTokensRecovered(presaleId, sale.creator, balance);
    }

    function statusOf(uint256 presaleId) external view returns (Status status) {
        Presale memory sale = presales[presaleId];
        status = sale.status;
        if (status == Status.Upcoming && block.timestamp >= sale.startAt) status = Status.Live;
    }

    function quoteAmountForTokens(uint256 presaleId, uint256 tokenAmount) external view returns (uint256) {
        return tokenAmount * presales[presaleId].priceQuotePerToken / PRICE_SCALE;
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(AccessControl, ERC1155Holder)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }

    function _createPair(Presale storage sale, GraduationConfig memory config) internal returns (address pair) {
        return IMatchingEngine(matchingEngine).addPair(
            sale.coin, sale.quote, config.listingPrice, block.timestamp, address(0), config.mode
        );
    }

    function _validateCreate(CreateParams calldata p) internal view {
        if (p.quote == address(0) || p.treasury == address(0)) revert ZeroAddress();
        if (!settlementTokenEnabled[p.quote]) revert InvalidQuote();
        if (p.totalSupply == 0 || p.presaleAllocation == 0 || p.lpTokenAllocation == 0 || p.priceQuotePerToken == 0) revert InvalidAmount();
        if (p.creatorTokenAllocation + p.treasuryTokenAllocation + p.presaleAllocation + p.lpTokenAllocation > p.totalSupply) revert InvalidAllocation();
        if (p.targetRaise == 0 || p.minimumRaise == 0 || p.minimumRaise > p.targetRaise) revert InvalidRaise();
        if (p.maxPerWallet == 0 || p.startAt < block.timestamp || p.endAt <= p.startAt || p.endAt - p.startAt > MAX_SALE_DURATION) revert InvalidSchedule();
        if (p.lpBps < MIN_LP_BPS || p.lpBps > MAX_LP_BPS) revert InvalidLiquidityCommitment();
        if (p.creatorVestingDuration == 0 || p.creatorVestingDuration > MAX_VESTING_DURATION || p.creatorCliff > p.creatorVestingDuration) revert InvalidSchedule();
        if (bytes(p.name).length == 0 || bytes(p.symbol).length == 0) revert InvalidAmount();
    }

    function _storeCreate(uint256 presaleId, address coin, CreateParams calldata p) internal {
        Presale storage sale = presales[presaleId];
        sale.creator = msg.sender;
        sale.coin = coin;
        sale.quote = p.quote;
        sale.totalSupply = p.totalSupply;
        sale.presaleAllocation = p.presaleAllocation;
        sale.lpTokenAllocation = p.lpTokenAllocation;
        sale.priceQuotePerToken = p.priceQuotePerToken;
        sale.targetRaise = p.targetRaise;
        sale.minimumRaise = p.minimumRaise;
        sale.maxPerWallet = p.maxPerWallet;
        sale.creatorTokenAllocation = p.creatorTokenAllocation;
        sale.treasuryTokenAllocation = p.treasuryTokenAllocation;
        sale.startAt = p.startAt;
        sale.endAt = p.endAt;
        sale.creatorCliff = p.creatorCliff;
        sale.creatorVestingDuration = p.creatorVestingDuration;
        sale.lpBps = p.lpBps;
        sale.treasury = p.treasury;
        sale.status = p.startAt == block.timestamp ? Status.Live : Status.Upcoming;
    }

    function _poolFor(address coin, address quote) internal view returns (address pool) {
        pool = IPoolFactory(IMatchingEngine(matchingEngine).poolFactory()).getPool(coin, quote);
        if (pool == address(0)) revert InvalidGraduationConfig();
    }

    function _addLiquidity(
        Presale storage sale,
        GraduationConfig memory config,
        address pool,
        uint256 tokenAmount,
        uint256 quoteAmount
    ) internal returns (uint256 tokenId) {
        TransferHelper.safeApprove(sale.coin, pool, tokenAmount);
        TransferHelper.safeApprove(sale.quote, pool, quoteAmount);
        tokenId = IPositionManager(positionManager).addLiquidity(
            pool, config.minPrice, config.maxPrice, config.lpSlippageLimit, tokenAmount, quoteAmount
        );
        TransferHelper.safeApprove(sale.coin, pool, 0);
        TransferHelper.safeApprove(sale.quote, pool, 0);
    }

    function _setTradingPolicy(address coin, address quote, GraduationConfig memory config) internal {
        if (assetGenerator != address(0)) {
            IAssetGeneratorPolicy(assetGenerator).setExistingPairTradingConfig(
                coin, quote, config.volatilityBps, config.makerFee, config.takerFee
            );
        }
    }

    function _payTreasury(Presale storage sale, uint256 lpQuoteAmount) internal {
        if (sale.treasuryTokenAllocation > 0) {
            TransferHelper.safeTransfer(sale.coin, sale.treasury, sale.treasuryTokenAllocation);
        }
        uint256 treasuryRaise = sale.acceptedRaise - lpQuoteAmount;
        if (treasuryRaise > 0) TransferHelper.safeTransfer(sale.quote, sale.treasury, treasuryRaise);
    }

    function _liveSale(uint256 presaleId) internal returns (Presale storage sale) {
        sale = presales[presaleId];
        if (sale.creator == address(0)) revert InvalidAmount();
        if (sale.status == Status.Upcoming && block.timestamp >= sale.startAt) sale.status = Status.Live;
        if (sale.status != Status.Live || block.timestamp < sale.startAt || block.timestamp >= sale.endAt) revert NotLive();
    }

    function _emitPresaleCreated(uint256 presaleId) internal {
        Presale memory sale = presales[presaleId];
        emit PresaleCreated(
            presaleId,
            sale.coin,
            sale.creator,
            sale.quote,
            sale.totalSupply,
            sale.presaleAllocation,
            sale.lpTokenAllocation,
            sale.priceQuotePerToken,
            sale.targetRaise,
            sale.minimumRaise,
            sale.maxPerWallet,
            sale.startAt,
            sale.endAt,
            sale.lpBps
        );
    }
}
