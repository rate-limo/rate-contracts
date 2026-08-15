/// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {TransferHelper} from "../exchange/libraries/TransferHelper.sol";
import {ExchangeOrderbook} from "../exchange/libraries/ExchangeOrderbook.sol";
import {IMatchingEngine} from "../exchange/interfaces/IMatchingEngine.sol";
import {IProtocol} from "../incentive/interfaces/IProtocol.sol";
import {IPositionManager} from "../swap/interfaces/IPositionManager.sol";
import {IPool} from "../swap/interfaces/IPool.sol";
import {AssetLaunchLib} from "./libraries/AssetLaunchLib.sol";

/// @notice A fixed-supply ERC-20 minted once at construction.
/// @dev No mint function, no owner, no burn hook: the supply the generator mints is
/// the supply forever. The launch UI states these three properties as facts about the
/// contract, so anything added here has to be reflected there.
contract Coin is ERC20 {
    constructor(string memory name_, string memory symbol_, uint256 totalSupply_, address recipient)
        ERC20(name_, symbol_)
    {
        _mint(recipient, totalSupply_);
    }
}

/**
 * @title AssetGenerator
 * @notice Deploys a fixed-supply coin, lists it against an admin-approved quote token,
 * and custodies any launch liquidity position the creator elects to lock.
 *
 * @dev Three things are admin-controlled, all behind `ADMIN_ROLE`:
 *  - the launch fee and its recipient,
 *  - which quote tokens a coin may list against (and on what terms),
 * Graduation is deliberately off-chain: the backend measures cumulative purchases in
 * the selected quote token and controls discovery/listing state. This contract neither
 * computes market value nor exposes a graduation transaction.
 *
 * It also implements `IProtocol` so the engine can source a launched coin's taker fee from
 * it. See `feeOf` for how that is wired and what has to be true for it to take effect.
 */
contract AssetGenerator is IProtocol, AccessControl, ReentrancyGuard, ERC1155Holder {
    /// @notice Configures fees and quote options.
    /// @dev Deliberately distinct from DEFAULT_ADMIN_ROLE, which only grants/revokes roles.
    /// An operator key that can retune fees is not the same key that should be able to
    /// hand out that power.
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    /// @notice Dedicated operator role for pair-scoped trading policy updates.
    bytes32 public constant PAIR_CONFIG_ROLE = keccak256("PAIR_CONFIG_ROLE");

    /// @notice Fee scale, mirroring `MatchingEngine.DENOM`. 1% is 1_000_000, 0.1% is 100_000.
    /// @dev Must equal the engine's DENOM. The engine hands the numerator straight to the
    /// orderbook, so a mismatch here silently misprices every fill rather than reverting.
    uint32 public constant FEE_DENOM = 100_000_000;
    uint16 public constant MIN_VOLATILITY_BPS = 5;
    uint16 public constant MAX_VOLATILITY_BPS = 100;
    uint32 public constant MIN_LAUNCH_TAKER_FEE = 50_000;
    uint32 public constant MAX_LAUNCH_TAKER_FEE = 3_000_000;
    uint16 public minSlippageLimitBps = MIN_VOLATILITY_BPS;
    uint16 public maxSlippageLimitBps = MAX_VOLATILITY_BPS;
    uint32 public minPairFee = MIN_LAUNCH_TAKER_FEE;
    uint32 public maxPairFee = MAX_LAUNCH_TAKER_FEE;

    enum Preset {
        Stable,
        Standard,
        Uniswap,
        Meme,
        Custom
    }

    struct LaunchSettings {
        Preset volatilityPreset;
        uint16 volatilityBps;
        Preset feePreset;
        uint32 makerFee;
        uint32 takerFee;
        address paymentToken;
        uint64 liquidityLockDuration;
    }

    struct PaymentOption {
        bool enabled;
        uint256 amount;
    }

    struct LiquidityLock {
        address positionManager;
        uint256 tokenId;
        uint64 unlockAt;
        bool released;
    }

    struct LaunchRuntime {
        QuoteOption option;
        uint256 paymentAmount;
        address feeRecipient;
        address pair;
    }

    struct PairPolicy {
        uint16 slippageLimitBps;
        uint32 makerFee;
        uint32 takerFee;
        bool configured;
    }

    /// @notice The terms on which a coin may be listed against one quote token.
    /// @param enabled Whether creators may currently pick this quote.
    /// @param listingPrice Initial market price for the new pair, as the engine's 1e8-scaled rate.
    /// @param listingPayment Token the MatchingEngine charges the listing cost in. The coin
    /// itself when it should come out of the new supply, which is the default the launch
    /// flow assumes.
    /// @param mode Orderbook matching mode for the new pair.
    /// @param startingTakerFee Taker fee a coin launched against this quote STARTS on, on
    /// the `FEE_DENOM` scale. Per-quote because the risk is per-quote: a coin opening
    /// against a deep stablecoin book is not the same trade as one opening against a
    /// volatile quote, and pricing both at one number prices neither. Required, not
    /// defaulted -- a zero here means free, deliberately, and there is no sentinel for
    /// "unset" precisely so the two cannot be confused.
    struct QuoteOption {
        bool enabled;
        uint256 listingPrice;
        address listingPayment;
        ExchangeOrderbook.MatchingMode mode;
        uint32 startingTakerFee;
    }

    /// @notice What the generator remembers about a coin it deployed.
    /// @dev `creator` doubles as the existence check -- it is never zero for a real launch.
    struct Launch {
        address creator;
        address quote;
        /// @dev Exact orderbook created by this launch. Creator policy can never be
        /// redirected to another pair, even when the creator launched several assets.
        address pair;
        uint64 launchedAt;
        /// @dev Maximum execution slippage for this pair, in basis points.
        uint16 slippageLimitBps;
        uint32 makerFee;
        /// @dev The live taker fee for this coin's pairs. Seeded from the quote option at
        /// launch and adjustable by its creator within `maxCreatorTakerFee`, unless an
        /// admin has locked creator control. Snapshotted rather than
        /// read through to the quote option so that retuning a quote reprices future
        /// launches, never live ones.
        uint32 takerFee;
        /// @dev Emergency admin gate for creator trading-policy control.
        bool creatorFeeLocked;
    }

    /// @notice The engine that lists pairs and prices them. Immutable: rewiring it would
    /// orphan every pair this generator has already listed.
    address public immutable matchingEngine;

    /// @notice Where launch fees are sent.
    address public feeTo;
    /// @notice Native-currency fee charged per launch. Zero means launching is free.
    uint256 public launchFee;
    /**
     * @notice Ceiling on what a creator may set their own coin's taker fee to. 1.00%.
     *
     * @dev This bound is the whole safety story for creator fee control, so it is not
     * optional and it is not cosmetic. Without it a creator could raise the taker fee to
     * 100% and take the next taker's entire order -- in the same block as an incoming
     * trade, since nothing here is timelocked. The cap is what makes the worst case
     * "traders paid up to 1%" instead of "traders were robbed".
     *
     * Set it to 0 to make creator control effectively read-only (they may only ever move
     * the fee to zero), which is the safe way to disable the feature venue-wide without
     * touching per-coin flags.
     */
    uint32 public maxCreatorTakerFee = 1_000_000;

    /// @notice IProtocol this contract defers to for pairs it did not launch.
    /// @dev Set this to the incentive contract the engine used before, or every non-generated
    /// pair loses its terminal registration. address(0) is valid and means "no delegate":
    /// fee lookups revert (the engine falls back to its defaults) and terminal lookups
    /// return empty.
    address public fallbackIncentive;

    mapping(address quote => QuoteOption option) private _quoteOptions;
    /// @dev Every quote ever configured, for enumeration. Never shrinks; disabling flips
    /// the flag rather than removing the entry, so the array cannot be griefed into a gap.
    address[] private _quoteTokens;
    /// @dev Membership of `_quoteTokens`. An explicit flag rather than inferring "new" from
    /// the option being all-defaults: a quote configured to defaults, then to real values,
    /// would otherwise be appended twice.
    mapping(address quote => bool known) private _knownQuote;

    /// @notice Launch record per deployed coin.
    mapping(address coin => Launch record) public launches;
    mapping(address coin => LaunchSettings settings) public launchSettings;
    mapping(address paymentToken => PaymentOption option) public paymentOptions;
    mapping(address coin => LiquidityLock lock) public liquidityLocks;
    /// @dev Policies for existing orderbook pairs that were not launched by this generator.
    mapping(address pair => PairPolicy policy) public pairPolicies;

    event FeeToSet(address indexed feeTo);
    event LaunchFeeSet(uint256 fee);
    event QuoteOptionSet(
        address indexed quote,
        bool enabled,
        uint256 listingPrice,
        address listingPayment,
        ExchangeOrderbook.MatchingMode mode,
        uint32 startingTakerFee
    );
    /**
     * @notice A coin was deployed and its first market listed.
     * @dev Indexed slots go to the three identifiers something downstream actually filters
     * on: the coin, the wallet that launched it, and the pair. `quote` moved to the data
     * section -- there are only a handful of quote tokens, so filtering by one is nearly
     * a full scan, and the third topic is better spent on the pair the broker joins every
     * later order and trade against.
     *
     * Emitted AFTER the engine's own `PairAdded`, in the same transaction. The broker
     * relies on that ordering: `PairAdded` creates the `spotTokens` row, this one fills in
     * who owns it.
     */
    event Launched(
        address indexed coin, address indexed creator, address indexed pair, address quote, uint256 totalSupply
    );
    event MaxCreatorTakerFeeSet(uint32 feeNum);
    event PairPolicyBoundsSet(uint16 minSlippageBps, uint16 maxSlippageBps, uint32 minFee, uint32 maxFee);
    /// @param by The caller — an admin, or a creator whose control has been unlocked.
    event PairTakerFeeSet(address indexed coin, address indexed by, uint32 feeNum);
    event CreatorFeeControlSet(address indexed coin, bool locked);
    event FallbackIncentiveSet(address indexed incentive);
    event PaymentOptionSet(address indexed token, bool enabled, uint256 amount);
    event LaunchSettingsRecorded(
        address indexed coin,
        Preset volatilityPreset,
        uint16 volatilityBps,
        Preset feePreset,
        uint32 makerFee,
        uint32 takerFee,
        address indexed paymentToken,
        uint64 liquidityLockDuration
    );
    event LiquidityLocked(
        address indexed coin, address indexed positionManager, uint256 indexed tokenId, uint64 unlockAt
    );
    event LiquidityLockExtended(address indexed coin, uint64 previousUnlockAt, uint64 unlockAt);
    event LiquidityReleased(address indexed coin, address indexed recipient, uint256 indexed tokenId);
    event PairTradingConfigSet(
        address indexed coin,
        address indexed pair,
        address indexed by,
        uint16 slippageLimitBps,
        uint32 makerFee,
        uint32 takerFee
    );
    event ExistingPairTradingConfigSet(
        address indexed pair,
        address indexed base,
        address indexed quote,
        address by,
        uint16 slippageLimitBps,
        uint32 makerFee,
        uint32 takerFee
    );

    error ZeroAddress();
    error FeeToNotSet();
    error InsufficientFee(uint256 sent, uint256 required);
    error QuoteNotEnabled(address quote);
    error EmptyMetadata();
    error SupplyIsZero();
    error CoinNotLaunched(address coin);
    error RefundFailed();
    error InvalidFee(uint32 feeNum);
    error NotAGeneratedCoin(address base);
    error NotTheCreator(address caller);
    error CreatorFeeControlLocked(address coin);
    error FeeAboveCreatorCap(uint32 feeNum, uint32 cap);
    error FeeOutsidePairRange(uint32 feeNum, uint32 minFee, uint32 maxFee);
    error InvalidVolatility(uint16 volatilityBps);
    error InvalidPresetValue(Preset preset, uint256 value);
    error PaymentNotEnabled(address token);
    error UnexpectedNativePayment(uint256 sent);
    error LiquidityLockNotConfigured(address coin);
    error LiquidityAlreadyLocked(address coin);
    error InvalidLiquidityPosition(address coin, address pool);
    error LiquidityStillLocked(uint64 unlockAt);
    error LiquidityAlreadyReleased(address coin);
    error InvalidRecipient();
    error PairDoesNotExist(address base, address quote);

    /// @param admin Receives both DEFAULT_ADMIN_ROLE and ADMIN_ROLE.
    /// @param matchingEngine_ The MatchingEngine this generator lists against.
    constructor(address admin, address matchingEngine_) {
        if (admin == address(0) || matchingEngine_ == address(0)) {
            revert ZeroAddress();
        }
        matchingEngine = matchingEngine_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ADMIN_ROLE, admin);
        _grantRole(PAIR_CONFIG_ROLE, admin);
    }

    /* ---------------------------------- admin --------------------------------- */

    function setFeeTo(address feeTo_) external onlyRole(ADMIN_ROLE) {
        if (feeTo_ == address(0)) revert ZeroAddress();
        feeTo = feeTo_;
        emit FeeToSet(feeTo_);
    }

    /// @notice Sets the per-launch fee. Zero is a valid setting -- free launches.
    function setLaunchFee(uint256 fee) external onlyRole(ADMIN_ROLE) {
        launchFee = fee;
        emit LaunchFeeSet(fee);
    }

    /// @notice Enables an ERC-20 as an alternative way to pay the launch fee.
    /// @dev Native ETH remains configured through `setLaunchFee`; address(0) is therefore
    /// rejected here so there is one source of truth for the native amount.
    function setPaymentOption(address token, bool enabled, uint256 amount) external onlyRole(ADMIN_ROLE) {
        if (token == address(0)) revert ZeroAddress();
        paymentOptions[token] = PaymentOption({enabled: enabled, amount: amount});
        emit PaymentOptionSet(token, enabled, amount);
    }

    /// @notice Sets the ceiling a creator may raise their own coin's taker fee to.
    /// @dev Lowering this does NOT claw back fees already set above it — existing values
    /// stand until someone moves them, and a creator's next write is then bounded by the
    /// new cap. `setPairTakerFee` from an admin is the tool for forcing one down.
    function setMaxCreatorTakerFee(uint32 feeNum) external onlyRole(ADMIN_ROLE) {
        if (feeNum > FEE_DENOM) revert InvalidFee(feeNum);
        maxCreatorTakerFee = feeNum;
        emit MaxCreatorTakerFeeSet(feeNum);
    }

    /// @notice Changes the creator-facing pair policy ranges for future updates.
    /// @dev Existing pair values are not forcibly rewritten. DEFAULT_ADMIN can use
    /// `setPairTradingConfig` to update any live pair after changing these bounds.
    function setPairPolicyBounds(
        uint16 minSlippageBps_,
        uint16 maxSlippageBps_,
        uint32 minFee_,
        uint32 maxFee_
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (minSlippageBps_ > maxSlippageBps_ || maxSlippageBps_ > 10_000) {
            revert InvalidVolatility(maxSlippageBps_);
        }
        if (minFee_ > maxFee_ || maxFee_ > FEE_DENOM) revert InvalidFee(maxFee_);
        minSlippageLimitBps = minSlippageBps_;
        maxSlippageLimitBps = maxSlippageBps_;
        minPairFee = minFee_;
        maxPairFee = maxFee_;
        emit PairPolicyBoundsSet(minSlippageBps_, maxSlippageBps_, minFee_, maxFee_);
    }

    /// @notice Revokes (or restores) one creator's control of their coin's taker fee.
    /// @dev Per coin rather than per address: the capability is a property of the launch,
    /// so revoking it for a coin whose creator also launched others leaves those alone.
    function setCreatorFeeControl(address coin, bool locked) external onlyRole(ADMIN_ROLE) {
        Launch storage record = launches[coin];
        if (record.creator == address(0)) revert CoinNotLaunched(coin);
        record.creatorFeeLocked = locked;
        emit CreatorFeeControlSet(coin, locked);
    }

    /**
     * @notice Sets the taker fee for one launched coin's pairs.
     *
     * @dev Two callers, deliberately different rules:
     *
     * - **An admin** may set any fee up to `FEE_DENOM` at any time.
     *   This is the lever for forcing a hostile fee back down.
     * - **The creator** may set a fee only on their own coin, up to
     *   `maxCreatorTakerFee`, unless an admin has locked creator control.
     *
     * Graduation is evaluated by the backend from purchases in the quote token. Keeping
     * the permission as an explicit admin-controlled lock lets that off-chain decision
     * grant creator control without duplicating graduation state in this contract.
     *
     * There is no timelock. A creator can raise the fee in the same block as an incoming
     * trade, so the cap is doing all the work — see `maxCreatorTakerFee`.
     */
    function setPairTakerFee(address coin, uint32 feeNum) external {
        Launch storage record = launches[coin];
        address creator = record.creator;
        if (creator == address(0)) revert CoinNotLaunched(coin);

        if (hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) {
            if (feeNum > FEE_DENOM) revert InvalidFee(feeNum);
        } else if (hasRole(PAIR_CONFIG_ROLE, msg.sender)) {
            if (feeNum < minPairFee || feeNum > maxPairFee) {
                revert FeeOutsidePairRange(feeNum, minPairFee, maxPairFee);
            }
        } else {
            if (msg.sender != creator) revert NotTheCreator(msg.sender);
            if (record.creatorFeeLocked) revert CreatorFeeControlLocked(coin);
            uint32 cap = maxCreatorTakerFee;
            if (feeNum < minPairFee || feeNum > maxPairFee) {
                revert FeeOutsidePairRange(feeNum, minPairFee, maxPairFee);
            }
            if (feeNum > cap) revert FeeAboveCreatorCap(feeNum, cap);
        }

        record.takerFee = feeNum;
        emit PairTakerFeeSet(coin, msg.sender, feeNum);
    }

    /// @notice Updates execution and fee policy only for the pair created with `coin`.
    /// @dev The caller supplies the launched coin, never an arbitrary pair address. The
    /// recorded pair is therefore the immutable scope of this capability.
    function setPairTradingConfig(
        address coin,
        uint16 slippageLimitBps,
        uint32 makerFee,
        uint32 takerFee
    ) external {
        Launch storage record = launches[coin];
        address creator = record.creator;
        if (creator == address(0)) revert CoinNotLaunched(coin);
        if (slippageLimitBps < minSlippageLimitBps || slippageLimitBps > maxSlippageLimitBps) {
            revert InvalidVolatility(slippageLimitBps);
        }

        bool policyAdmin = hasRole(DEFAULT_ADMIN_ROLE, msg.sender);
        if (policyAdmin || hasRole(PAIR_CONFIG_ROLE, msg.sender)) {
            if (!policyAdmin && (makerFee < minPairFee || takerFee < minPairFee || makerFee > maxPairFee || takerFee > maxPairFee)) {
                revert InvalidFee(makerFee < minPairFee || makerFee > maxPairFee ? makerFee : takerFee);
            }
            if (makerFee > FEE_DENOM || takerFee > FEE_DENOM) {
                revert InvalidFee(makerFee > takerFee ? makerFee : takerFee);
            }
        } else {
            if (msg.sender != creator) revert NotTheCreator(msg.sender);
            if (record.creatorFeeLocked) revert CreatorFeeControlLocked(coin);
            uint32 cap = maxCreatorTakerFee;
            if (makerFee < minPairFee || makerFee > cap) revert FeeAboveCreatorCap(makerFee, cap);
            if (takerFee < minPairFee || takerFee > cap) revert FeeAboveCreatorCap(takerFee, cap);
        }

        record.slippageLimitBps = slippageLimitBps;
        record.makerFee = makerFee;
        record.takerFee = takerFee;
        emit PairTradingConfigSet(
            coin, record.pair, msg.sender, slippageLimitBps, makerFee, takerFee
        );
    }

    /// @notice Configures an already-created MatchingEngine pair.
    /// @dev This is intentionally role-gated: existing pairs have no creator recorded in
    /// this contract. The engine resolves the canonical pair address from base/quote, so a
    /// caller cannot attach policy to an arbitrary address or to a nonexistent market.
    function setExistingPairTradingConfig(
        address base,
        address quote,
        uint16 slippageLimitBps,
        uint32 makerFee,
        uint32 takerFee
    ) external {
        if (!hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) _checkRole(PAIR_CONFIG_ROLE, msg.sender);
        address pair = IMatchingEngine(matchingEngine).getPair(base, quote);
        if (pair == address(0)) revert PairDoesNotExist(base, quote);
        if (slippageLimitBps < minSlippageLimitBps || slippageLimitBps > maxSlippageLimitBps) {
            revert InvalidVolatility(slippageLimitBps);
        }
        // Makers are intentionally free across Iter. `minPairFee` protects the
        // taker-fee floor; applying it to makers makes the documented 0 fee
        // impossible for graduated markets.
        if (makerFee != 0 && (makerFee < minPairFee || makerFee > maxPairFee)) {
            revert FeeOutsidePairRange(makerFee, minPairFee, maxPairFee);
        }
        if (takerFee < minPairFee || takerFee > maxPairFee) {
            revert FeeOutsidePairRange(takerFee, minPairFee, maxPairFee);
        }
        pairPolicies[pair] = PairPolicy(slippageLimitBps, makerFee, takerFee, true);
        emit ExistingPairTradingConfigSet(
            pair, base, quote, msg.sender, slippageLimitBps, makerFee, takerFee
        );
    }

    /// @notice Sets the IProtocol consulted for pairs this generator did not launch.
    function setFallbackIncentive(address incentive) external onlyRole(ADMIN_ROLE) {
        fallbackIncentive = incentive;
        emit FallbackIncentiveSet(incentive);
    }

    /// @notice Adds, retunes or disables a quote token creators may list against.
    /// @dev Disabling leaves the entry in place so `quoteTokens()` stays stable and a
    /// re-enable does not append a duplicate.
    function setQuoteOption(
        address quote,
        bool enabled,
        uint256 listingPrice,
        address listingPayment,
        ExchangeOrderbook.MatchingMode mode,
        uint32 startingTakerFee
    ) external onlyRole(ADMIN_ROLE) {
        if (quote == address(0)) revert ZeroAddress();
        if (startingTakerFee > FEE_DENOM) revert InvalidFee(startingTakerFee);
        if (!_knownQuote[quote]) {
            _knownQuote[quote] = true;
            _quoteTokens.push(quote);
        }
        QuoteOption storage option = _quoteOptions[quote];
        option.enabled = enabled;
        option.listingPrice = listingPrice;
        option.listingPayment = listingPayment;
        option.mode = mode;
        // Retuning this reprices FUTURE launches only. Live coins hold their own snapshot
        // (Launch.takerFee), so nobody's trading cost changes under them because an admin
        // adjusted a quote.
        option.startingTakerFee = startingTakerFee;
        emit QuoteOptionSet(quote, enabled, listingPrice, listingPayment, mode, startingTakerFee);
    }

    /* ---------------------------------- views --------------------------------- */

    function quoteOption(address quote) external view returns (QuoteOption memory) {
        return _quoteOptions[quote];
    }

    /// @notice Every quote token ever configured, enabled or not.
    function quoteTokens() external view returns (address[] memory) {
        return _quoteTokens;
    }

    /// @notice Only the quote tokens a creator may currently pick.
    function enabledQuoteTokens() external view returns (address[] memory enabled) {
        uint256 total = _quoteTokens.length;
        // Explicitly zeroed rather than leaning on the default: slither flags the
        // implicit form, and the triage is cheaper than the annotation.
        uint256 count = 0;
        for (uint256 i; i < total; ++i) {
            if (_quoteOptions[_quoteTokens[i]].enabled) ++count;
        }
        enabled = new address[](count);
        uint256 j = 0;
        for (uint256 i; i < total; ++i) {
            address quote = _quoteTokens[i];
            if (_quoteOptions[quote].enabled) {
                enabled[j] = quote;
                ++j;
            }
        }
    }

    /* ------------------------------- fee schedule ------------------------------ */

    /**
     * @notice The taker fee that applies to a launched coin right now.
     * @dev Seeded from the launch's quote configuration and thereafter changed only by an
     * admin or an unlocked creator. Reverts for a coin this generator did not launch.
     */
    function takerFeeOf(address coin) public view returns (uint32) {
        Launch memory record = launches[coin];
        if (record.creator == address(0)) revert CoinNotLaunched(coin);
        return record.takerFee;
    }

    function pairTradingConfig(address coin)
        external
        view
        returns (address pair, uint16 slippageLimitBps, uint32 makerFee, uint32 takerFee)
    {
        Launch memory record = launches[coin];
        if (record.creator == address(0)) revert CoinNotLaunched(coin);
        return (record.pair, record.slippageLimitBps, record.makerFee, record.takerFee);
    }

    /// @notice Pair-scoped slippage policy consumed by MatchingEngine.
    function slippageLimitOf(address base, address quote) external view returns (uint16) {
        Launch memory record = launches[base];
        if (record.creator != address(0) && record.quote == quote) return record.slippageLimitBps;
        address pair = IMatchingEngine(matchingEngine).getPair(base, quote);
        PairPolicy memory policy = pairPolicies[pair];
        if (pair != address(0) && policy.configured) return policy.slippageLimitBps;
        revert NotAGeneratedCoin(base);
    }

    /**
     * @notice IProtocol hook: the fee numerator for a pair, on the engine's DENOM scale.
     *
     * @dev This only takes effect once an engine admin calls
     * `MatchingEngine.setIncentive(address(this))`. Until then the engine charges its own
     * defaults and the tiers below are inert.
     *
     * Two behaviours are load-bearing:
     *
     * 1. **Reverting for a foreign pair is correct, not a failure.** `MatchingEngine.feeOf`
     *    wraps this call in try/catch and falls back to its own defaults when it reverts.
     *    Returning zero instead would silently make every pair on the venue free -- which
     *    is exactly what the stub `Incentive.feeOf` does today, and why pointing the engine
     *    at that contract would zero all fees.
     * 2. **Makers pay nothing**, matching the engine's deliberate `defaultMakerFee = 0`.
     *    A maker already pays gas to place and to cancel, so only takers are charged.
     *
     * `quote` and `account` are unused for generated coins. An account-tier ladder belongs
     * in the delegate, which is why one exists.
     */
    function feeOf(address base, address quote, address account, bool isMaker)
        external
        view
        returns (uint32 feeNum)
    {
        Launch memory record = launches[base];
        if (record.creator != address(0) && record.quote == quote) {
            return isMaker ? record.makerFee : record.takerFee;
        }
        address pair = IMatchingEngine(matchingEngine).getPair(base, quote);
        PairPolicy memory policy = pairPolicies[pair];
        if (pair != address(0) && policy.configured) return isMaker ? policy.makerFee : policy.takerFee;
        if (fallbackIncentive == address(0)) revert NotAGeneratedCoin(base);
        return IProtocol(fallbackIncentive).feeOf(base, quote, account, isMaker);
    }

    /// @inheritdoc IProtocol
    function isSubscribed(address account) external view returns (bool) {
        if (fallbackIncentive == address(0)) return false;
        return IProtocol(fallbackIncentive).isSubscribed(account);
    }

    /// @inheritdoc IProtocol
    /// @dev Returns empty rather than reverting when there is no delegate: the engine calls
    /// this outside a try/catch during listing, and an empty name is already its "not a
    /// registered terminal" answer. Reverting here would break listing venue-wide.
    function terminalName(address terminal) external view returns (string memory) {
        if (fallbackIncentive == address(0)) return "";
        return IProtocol(fallbackIncentive).terminalName(terminal);
    }

    /* --------------------------------- launch --------------------------------- */

    /**
     * @notice Deploys a coin and lists it against `quote`.
     * @dev Supply is minted to this contract, not the creator, because the MatchingEngine
     * pulls the listing cost from `msg.sender` -- which is this contract. Whatever the
     * listing does not consume goes to the creator afterwards, so the creator receives the
     * supply net of the listing cost rather than a balance the generator cannot cover.
     * @param quote Must be an enabled quote option.
     * @return coin The deployed token.
     */
    function launch(string calldata name, string calldata symbol, uint256 initialSupply, address quote)
        external
        payable
        nonReentrant
        returns (address coin)
    {
        QuoteOption memory option = _quoteOptions[quote];
        LaunchSettings memory settings = LaunchSettings({
            volatilityPreset: Preset.Standard,
            volatilityBps: 10,
            feePreset: Preset.Custom,
            makerFee: MIN_LAUNCH_TAKER_FEE,
            takerFee: option.startingTakerFee,
            paymentToken: address(0),
            liquidityLockDuration: 0
        });
        return _launch(name, symbol, initialSupply, quote, settings, false);
    }

    /// @notice Launches an asset with the volatility, fee, payment and liquidity-lock
    /// choices made in the launch flow. Preset labels are validated against their exact
    /// values; `Custom` accepts any value inside the published slider bounds.
    function launchAsset(
        string calldata name,
        string calldata symbol,
        uint256 initialSupply,
        address quote,
        LaunchSettings calldata settings
    ) external payable nonReentrant returns (address coin) {
        return _launch(name, symbol, initialSupply, quote, settings, true);
    }

    /// @dev Validation (`AssetLaunchLib.validateLaunchSettings`) and the listing +
    /// payment interactions (`AssetLaunchLib.settleListing`) live in AssetLaunchLib --
    /// moved out purely for EIP-170 headroom. Both are `public` library functions, so
    /// these calls are DELEGATECALLs: storage access, `msg.sender`, `msg.value` and the
    /// Coin's deployer address are all unchanged from direct execution. Mapping reads
    /// and writes stay here rather than crossing into the library -- see
    /// AssetLaunchLib's docstring for why.
    function _launch(
        string calldata name,
        string calldata symbol,
        uint256 initialSupply,
        address quote,
        LaunchSettings memory settings,
        bool enforceLaunchFlowBounds
    ) internal returns (address coin) {
        // ---- checks
        if (bytes(name).length == 0 || bytes(symbol).length == 0) revert EmptyMetadata();
        if (initialSupply == 0) revert SupplyIsZero();
        QuoteOption memory option = _quoteOptions[quote];
        if (!option.enabled) revert QuoteNotEnabled(quote);
        if (enforceLaunchFlowBounds) {
            AssetLaunchLib.validateLaunchSettings(
                settings, minSlippageLimitBps, maxSlippageLimitBps, minPairFee, maxPairFee
            );
        } else if (settings.takerFee > FEE_DENOM) {
            revert InvalidFee(settings.takerFee);
        }

        // ---- effects
        coin = address(new Coin(name, symbol, initialSupply, address(this)));
        launches[coin] = Launch({
            creator: msg.sender,
            quote: quote,
            pair: address(0),
            launchedAt: uint64(block.timestamp),
            slippageLimitBps: settings.volatilityBps,
            makerFee: settings.makerFee,
            // Snapshot, not a read-through: see setQuoteOption.
            takerFee: settings.takerFee,
            creatorFeeLocked: false
        });
        launchSettings[coin] = settings;

        // ---- interactions
        PaymentOption memory feePayment = paymentOptions[settings.paymentToken];
        address pair = AssetLaunchLib.settleListing(
            matchingEngine,
            coin,
            quote,
            option,
            AssetLaunchLib.PaymentInfo({
                token: settings.paymentToken,
                launchFee: launchFee,
                tokenEnabled: feePayment.enabled,
                tokenAmount: feePayment.amount,
                feeTo: feeTo
            })
        );
        launches[coin].pair = pair;

        emit Launched(coin, msg.sender, pair, quote, initialSupply);
        emit LaunchSettingsRecorded(
            coin,
            settings.volatilityPreset,
            settings.volatilityBps,
            settings.feePreset,
            settings.makerFee,
            settings.takerFee,
            settings.paymentToken,
            settings.liquidityLockDuration
        );
    }

    /* ---------------------------- liquidity locking --------------------------- */

    /// @notice Custodies the ERC-1155 position for the duration selected at launch.
    /// @dev The position is verified against the generated coin and its listing quote;
    /// an unrelated NFT cannot be used to make a launch appear liquidity-backed.
    function lockLiquidity(address coin, address positionManager, uint256 tokenId) external nonReentrant {
        Launch memory record = launches[coin];
        if (record.creator == address(0)) revert CoinNotLaunched(coin);
        if (msg.sender != record.creator) revert NotTheCreator(msg.sender);
        uint64 duration = launchSettings[coin].liquidityLockDuration;
        if (duration == 0) revert LiquidityLockNotConfigured(coin);
        LiquidityLock storage current = liquidityLocks[coin];
        if (current.positionManager != address(0) && !current.released) revert LiquidityAlreadyLocked(coin);

        (address pool,) = IPositionManager(positionManager).tokenPosition(tokenId);
        if (pool == address(0)) revert InvalidLiquidityPosition(coin, pool);
        (address base, address quote) = IPool(pool).getBaseQuote();
        bool correctPair =
            (base == coin && quote == record.quote) || (base == record.quote && quote == coin);
        if (!correctPair) revert InvalidLiquidityPosition(coin, pool);

        uint64 unlockAt = uint64(block.timestamp) + duration;
        liquidityLocks[coin] = LiquidityLock({
            positionManager: positionManager,
            tokenId: tokenId,
            unlockAt: unlockAt,
            released: false
        });
        IERC1155(positionManager).safeTransferFrom(msg.sender, address(this), tokenId, 1, "");
        emit LiquidityLocked(coin, positionManager, tokenId, unlockAt);
    }

    /// @notice Extends a live lock. A lock can never be shortened.
    function extendLiquidityLock(address coin, uint64 additionalDuration) external {
        Launch memory record = launches[coin];
        if (record.creator == address(0)) revert CoinNotLaunched(coin);
        if (msg.sender != record.creator) revert NotTheCreator(msg.sender);
        LiquidityLock storage lock = liquidityLocks[coin];
        if (lock.positionManager == address(0)) revert LiquidityLockNotConfigured(coin);
        if (lock.released) revert LiquidityAlreadyReleased(coin);
        uint64 previousUnlockAt = lock.unlockAt;
        lock.unlockAt = previousUnlockAt + additionalDuration;
        emit LiquidityLockExtended(coin, previousUnlockAt, lock.unlockAt);
    }

    /// @notice Releases the position NFT after the lock expires.
    function releaseLiquidity(address coin, address recipient) external nonReentrant {
        Launch memory record = launches[coin];
        if (record.creator == address(0)) revert CoinNotLaunched(coin);
        if (msg.sender != record.creator) revert NotTheCreator(msg.sender);
        if (recipient == address(0)) revert InvalidRecipient();
        LiquidityLock storage lock = liquidityLocks[coin];
        if (lock.positionManager == address(0)) revert LiquidityLockNotConfigured(coin);
        if (lock.released) revert LiquidityAlreadyReleased(coin);
        if (block.timestamp < lock.unlockAt) revert LiquidityStillLocked(lock.unlockAt);
        lock.released = true;
        IERC1155(lock.positionManager).safeTransferFrom(address(this), recipient, lock.tokenId, 1, "");
        emit LiquidityReleased(coin, recipient, lock.tokenId);
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(AccessControl, ERC1155Holder)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }

}
