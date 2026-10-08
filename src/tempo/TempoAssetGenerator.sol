// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

// TEMPO COPY of src/asset/AssetGenerator.sol. It differs only in linking TempoAssetLaunchLib
// (the launch fee in the quote token); its ABI is the original's, so the indexer, gateway
// and app read it as an AssetGenerator. scripts/check-tempo-copies.sh keeps it in step.

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {TransferHelper} from "../exchange/libraries/TransferHelper.sol";
import {ExchangeOrderbook} from "../exchange/libraries/ExchangeOrderbook.sol";
import {IMatchingEngine} from "../exchange/interfaces/IMatchingEngine.sol";
import {IProtocol} from "../incentive/interfaces/IProtocol.sol";
import {BandPositionManager} from "../swap/BandPositionManager.sol";
import {IPoolFactory} from "../swap/interfaces/IPoolFactory.sol";
import {BandPool} from "../swap/BandPool.sol";
import {TempoAssetLaunchLib} from "./TempoAssetLaunchLib.sol";
// Unchanged on Tempo, so shared rather than copied.
import {Coin} from "../asset/AssetGenerator.sol";

/**
 * @title TempoAssetGenerator
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
 *
 * KNOWN RISK (accepted 2026-10-02, review finding N-1): a graduated coin's pool -- like every
 * BandPool -- prices fills at a 300-second TWAP of the book's `lmp`, and the engine writes
 * `lmp` when a maker order RESTS, not only when one fills. Placing and cancelling orders
 * therefore walks `lmp` (and, after 300 s, the pool's price) by the limit spread per order,
 * compounding, at the cost of gas. A thin or one-sided pool can be priced away and its
 * opposite side drained -- the locked FeesOnly position included. The ladder itself is
 * unaffected (each ask fills at its own price). Fixing it needs pool pricing that does not
 * trust `lmp` (see BandPool._anchor); until then it is disclosed to users, not defended.
 */
contract TempoAssetGenerator is IProtocol, AccessControl, ReentrancyGuard, ERC1155Holder {
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

    /// @notice Most of a launch's supply a creator may buy at the starting price: 10%.
    uint16 public constant MAX_DEV_BUY_BPS = TempoAssetLaunchLib.MAX_DEV_BUY_BPS;
    /// @notice Share of supply a launch sells as its five-step ladder: 80%.
    uint16 public constant LADDER_BPS = TempoAssetLaunchLib.LADDER_BPS;
    /// @notice A filled ladder graduates this long after it is first reported filled, so
    /// the pool's 300-second TWAP anchor has caught up with the last ladder price before
    /// the pool starts quoting the held-back supply.
    uint64 public constant GRADUATION_DELAY = 300;
    /// @notice A starting price below this many 1e8 units is refused: at 100 units one
    /// price step is already 1%, and below it the book cannot quote the coin sensibly.
    uint256 public constant MIN_LISTING_PRICE = TempoAssetLaunchLib.MIN_LISTING_PRICE;
    /// @dev The engine's "custom" fee class: the pair's fee is whatever this contract set.
    uint8 internal constant ENGINE_FEE_CLASS = 4;

    /// @notice What happens to the graduated pool position, chosen at launch, immutable.
    /// @dev `FeesOnly`: the principal never leaves; the creator collects its fees forever.
    /// `Vest12Months`: the principal vests to the creator linearly over 365 days from
    /// graduation. Neither releases anything before graduation.
    enum LockMode {
        FeesOnly,
        Vest12Months
    }

    /// @notice A launch's lock: graduation timing and the position it ends in.
    struct LaunchLock {
        LockMode mode;
        /// @dev Zero until the ladder is reported filled; then when `graduate` may finish.
        uint64 readyAt;
        uint64 graduatedAt;
        /// @dev Share of the original position already released, under `Vest12Months`.
        uint16 releasedBps;
        address manager;
        uint256 tokenId;
    }

    struct PairPolicy {
        uint16 slippageLimitBps;
        uint32 makerFee;
        uint32 takerFee;
        bool configured;
    }

    /// @notice The terms on which a coin may be listed against one quote token.
    /// @param enabled Whether creators may currently pick this quote.
    /// @param startingMarketCap The market cap, in the quote's base units, every coin
    /// launched against this quote opens at. The starting price is this over the supply,
    /// so a creator choosing a supply does not choose a valuation.
    /// @param minDevBuy Least quote a creator must pay for their own coin at launch.
    /// @param graduationMarketCap The market cap of the ladder's last step. A coin
    /// graduates once all five steps, from `startingMarketCap` up to this, have sold.
    /// @param mode Orderbook matching mode for the new pair.
    /// @param startingTakerFee Taker fee a coin launched against this quote STARTS on, on
    /// the `FEE_DENOM` scale. Per-quote because the risk is per-quote: a coin opening
    /// against a deep stablecoin book is not the same trade as one opening against a
    /// volatile quote, and pricing both at one number prices neither. Required, not
    /// defaulted -- a zero here means free, deliberately, and there is no sentinel for
    /// "unset" precisely so the two cannot be confused.
    struct QuoteOption {
        bool enabled;
        uint256 startingMarketCap;
        uint256 minDevBuy;
        uint256 graduationMarketCap;
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
        /// @dev Creator trading-policy control is locked from launch until `graduate`,
        /// and an admin can set or clear it at any time.
        bool creatorFeeLocked;
        /// @dev One-way: set by `graduate` and never cleared.
        bool graduated;
    }

    /// @notice The engine that lists pairs and prices them. Immutable: rewiring it would
    /// orphan every pair this generator has already listed.
    address public immutable matchingEngine;

    /// @notice Where launch fees are sent.
    address public feeTo;
    /// @notice Native-currency fee charged per launch. Zero means launching is free.
    uint256 public launchFee;
    /// @notice Two-transaction launches: `launch` lists, `placeLadder` places the ladder.
    /// On for chains whose per-transaction gas cap cannot hold a whole launch (Tempo).
    bool public ladderDeferred;
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
    mapping(address coin => TempoAssetLaunchLib.Ladder ladder) internal _ladders;
    mapping(address coin => LaunchLock lock) public launchLocks;
    /// @dev Policies for existing orderbook pairs that were not launched by this generator.
    mapping(address pair => PairPolicy policy) public pairPolicies;
    /// @notice Who listed a pair through `listPair`, and so may retune it within the
    /// creator bounds -- the same capability a coin's creator has over its coin.
    mapping(address pair => address lister) public pairLister;
    /// @notice Admin lock on a lister's control, the `creatorFeeLocked` of a listed pair.
    mapping(address pair => bool locked) public listerFeeLocked;

    event FeeToSet(address indexed feeTo);
    event LaunchFeeSet(uint256 fee);
    event QuoteOptionSet(
        address indexed quote,
        bool enabled,
        uint256 startingMarketCap,
        uint256 minDevBuy,
        uint256 graduationMarketCap,
        ExchangeOrderbook.MatchingMode mode,
        uint32 startingTakerFee
    );
    /// @notice `coin`'s ladder sold out; `graduate` may finish at `readyAt`.
    event GraduationArmed(address indexed coin, uint64 readyAt);
    /// @notice `coin` graduated: `quoteRaised` and `coinsSeeded` became its locked pool position.
    event Graduated(address indexed coin, uint256 quoteRaised, uint256 coinsSeeded);
    event LiquidityReleased(address indexed coin, address indexed recipient, uint16 releasedBps);
    event PairListerSet(address indexed pair, address indexed lister);
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
    /// @notice The creator paid `quoteIn` for `coinsOut` of their own coin at the starting price.
    event DevBuy(address indexed coin, address indexed creator, uint256 quoteIn, uint256 coinsOut);
    event PairListed(
        address indexed pair, address indexed base, address indexed quote, address lister,
        uint16 slippageLimitBps, uint32 takerFee
    );
    event LiquidityLocked(
        address indexed coin, address indexed positionManager, uint256 indexed tokenId, uint64 unlockAt
    );
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
    error DevBuyTooSmall(uint256 quoteIn, uint256 minimum);
    error DevBuyTooLarge(uint256 coinsOut, uint256 cap);
    error ListingPriceTooLow(uint256 price);
    error NoBandPool(address coin, address quote);
    error PairAlreadyListed(address base, address quote);
    error AlreadyGraduated(address coin);
    error LadderNotFilled(uint256 step);
    error GraduationNotReady(uint64 readyAt);
    error NotGraduated(address coin);
    error NotVesting(address coin);
    error NothingToRelease();
    error InvalidRecipient();
    error NotTheLister(address caller);
    error BandCallNotAllowed(bytes4 selector);
    error PairDoesNotExist(address base, address quote);
    error LadderNotPlaced();
    error LadderAlreadyPlaced();

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
    function setLadderDeferred(bool on) external onlyRole(ADMIN_ROLE) {
        ladderDeferred = on;
    }

    function setLaunchFee(uint256 fee) external onlyRole(ADMIN_ROLE) {
        launchFee = fee;
        emit LaunchFeeSet(fee);
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
        if (minFee_ > maxFee_ || maxFee_ > MAX_LAUNCH_TAKER_FEE) revert InvalidFee(maxFee_);
        minSlippageLimitBps = minSlippageBps_;
        maxSlippageLimitBps = maxSlippageBps_;
        minPairFee = minFee_;
        maxPairFee = maxFee_;
        emit PairPolicyBoundsSet(minSlippageBps_, maxSlippageBps_, minFee_, maxFee_);
    }

    /// @notice Revokes (or restores) one creator's control of their coin's taker fee.
    /// @dev Per coin rather than per address: the capability is a property of the launch,
    /// so revoking it for a coin whose creator also launched others leaves those alone.
    /// A listed pair's address is accepted in place of a coin, and locks its lister.
    function setCreatorFeeControl(address coin, bool locked) external onlyRole(ADMIN_ROLE) {
        Launch storage record = launches[coin];
        if (record.creator != address(0)) record.creatorFeeLocked = locked;
        else if (pairLister[coin] != address(0)) listerFeeLocked[coin] = locked;
        else revert CoinNotLaunched(coin);
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

        TempoAssetLaunchLib.checkTakerFee(_bounds(), _configCaller(record, coin), feeNum);

        record.takerFee = feeNum;
        _writeEngineFee(record.pair, record.makerFee, feeNum);
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
        TempoAssetLaunchLib.checkTradingConfig(
            _bounds(),
            _configCaller(record, coin),
            slippageLimitBps,
            makerFee,
            takerFee
        );

        record.slippageLimitBps = slippageLimitBps;
        record.makerFee = makerFee;
        record.takerFee = takerFee;
        _writeEngineFee(record.pair, makerFee, takerFee);
        emit PairTradingConfigSet(
            coin, record.pair, msg.sender, slippageLimitBps, makerFee, takerFee
        );
        _syncPool(coin, record.quote);
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
        address pair = IMatchingEngine(matchingEngine).getPair(base, quote);
        if (pair == address(0)) revert PairDoesNotExist(base, quote);
        // A pair's lister holds the creator capability over it: bounded by the creator
        // cap, revocable by an admin. Everyone else needs the role.
        bool listerPath = pairLister[pair] == msg.sender && !hasRole(PAIR_CONFIG_ROLE, msg.sender);
        if (!listerPath && !hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) _checkRole(PAIR_CONFIG_ROLE, msg.sender);
        TempoAssetLaunchLib.checkExistingConfig(
            _bounds(), listerPath, listerFeeLocked[pair], pair, slippageLimitBps, makerFee, takerFee
        );
        pairPolicies[pair] = PairPolicy(slippageLimitBps, makerFee, takerFee, true);
        _writeEngineFee(pair, makerFee, takerFee);
        emit ExistingPairTradingConfigSet(
            pair, base, quote, msg.sender, slippageLimitBps, makerFee, takerFee
        );
        _syncPool(base, quote);
    }

    /// The engine charges the LOWER of its own pair fee and this contract's `feeOf`, so a
    /// fee above the engine default only takes effect once it is written there too. Needs
    /// this contract to be the engine's `feeManager`.
    function _writeEngineFee(address pair, uint32 makerFee, uint32 takerFee) private {
        IMatchingEngine(matchingEngine).setPairFeeClass(pair, ENGINE_FEE_CLASS, makerFee, takerFee);
    }

    /// Who is calling, for the library's trading-config checks.
    function _configCaller(Launch storage record, address coin)
        private
        view
        returns (TempoAssetLaunchLib.ConfigCaller memory)
    {
        return TempoAssetLaunchLib.ConfigCaller({
            role: hasRole(DEFAULT_ADMIN_ROLE, msg.sender) ? 2 : hasRole(PAIR_CONFIG_ROLE, msg.sender) ? 1 : 0,
            caller: msg.sender,
            creator: record.creator,
            creatorLocked: record.creatorFeeLocked,
            coin: coin,
            maxLaunchFee: MAX_LAUNCH_TAKER_FEE
        });
    }

    /// The generator's policy bounds, for the library checks that take them.
    function _bounds() private view returns (TempoAssetLaunchLib.PairBounds memory) {
        return TempoAssetLaunchLib.PairBounds({
            minSlippageBps: minSlippageLimitBps,
            maxSlippageBps: maxSlippageLimitBps,
            minFee: minPairFee,
            maxFee: maxPairFee,
            creatorCap: maxCreatorTakerFee
        });
    }

    /// The slippage cap is half of every band's limit, so the pool must re-read it now.
    function _syncPool(address base, address quote) private {
        address factory = IMatchingEngine(matchingEngine).poolFactory();
        if (factory != address(0)) IPoolFactory(factory).syncLimit(base, quote);
    }


    /// @notice Sets the IProtocol consulted for pairs this generator did not launch.
    /// WARNING: it answers fees AND slippage caps for every pair this generator did not launch; set it to the PREVIOUS incentive only.
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
        uint256 startingMarketCap,
        uint256 minDevBuy,
        uint256 graduationMarketCap,
        ExchangeOrderbook.MatchingMode mode,
        uint32 startingTakerFee
    ) external onlyRole(ADMIN_ROLE) {
        if (quote == address(0)) revert ZeroAddress();
        if (graduationMarketCap < startingMarketCap) revert InvalidVolatility(0);
        if (startingTakerFee > FEE_DENOM) revert InvalidFee(startingTakerFee);
        // Retuning startingTakerFee reprices FUTURE launches only. Live coins hold their
        // own snapshot (Launch.takerFee), so nobody's trading cost changes under them
        // because an admin adjusted a quote.
        TempoAssetLaunchLib.writeQuoteOption(
            _quoteOptions,
            _knownQuote,
            _quoteTokens,
            quote,
            QuoteOption({
                enabled: enabled,
                startingMarketCap: startingMarketCap,
                minDevBuy: minDevBuy,
                graduationMarketCap: graduationMarketCap,
                mode: mode,
                startingTakerFee: startingTakerFee
            })
        );
        emit QuoteOptionSet(quote, enabled, startingMarketCap, minDevBuy, graduationMarketCap, mode, startingTakerFee);
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
    function enabledQuoteTokens() external view returns (address[] memory) {
        return TempoAssetLaunchLib.enabledQuotes(_quoteTokens, _quoteOptions);
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
        // Mirror feeOf: a pair this generator does not know is the previous generator's
        // to answer, or its coins lose their slippage caps the day this one is wired in.
        if (fallbackIncentive == address(0)) revert NotAGeneratedCoin(base);
        return TempoAssetGenerator(payable(fallbackIncentive)).slippageLimitOf(base, quote);
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
     * @notice Deploys a coin, lists it at the quote's starting market cap, sells its
     * creator `devBuyQuote` worth at that price, and puts 80% of the supply on the book as
     * a five-step ladder up to the graduation market cap. See TempoAssetLaunchLib.
     * @dev Nothing reaches the creator for free, and nobody -- the creator included -- can
     * withdraw anything until `graduate`: the ladder's asks and every unit of quote they
     * raise sit with the coin's escrow, which cannot cancel an order. The listing
     * parameters are fixed (Meme volatility, makers free, the quote's starting taker fee)
     * and the creator controls neither them nor the pool's bands until graduation.
     * @param quote Must be an enabled quote option.
     * @param devBuyQuote Quote the creator pays for their own coins. At least the quote's
     * `minDevBuy`, at most 10% of supply at the starting price. Approve it first.
     * @param lockMode What becomes of the graduated pool position. Immutable.
     * @return coin The deployed token.
     */
    function launch(
        string calldata name,
        string calldata symbol,
        uint256 initialSupply,
        address quote,
        uint256 devBuyQuote,
        LockMode lockMode
    ) external payable nonReentrant returns (address coin) {
        // ---- checks
        if (bytes(name).length == 0 || bytes(symbol).length == 0) revert EmptyMetadata();
        if (initialSupply == 0) revert SupplyIsZero();
        QuoteOption memory option = _quoteOptions[quote];
        if (!option.enabled) revert QuoteNotEnabled(quote);

        // ---- effects
        coin = address(new Coin(name, symbol, initialSupply, address(this)));
        launches[coin] = Launch({
            creator: msg.sender,
            quote: quote,
            pair: address(0),
            launchedAt: uint64(block.timestamp),
            // Meme volatility: a new coin moves fast, and its creator cannot narrow this
            // until it graduates.
            slippageLimitBps: MAX_VOLATILITY_BPS,
            makerFee: 0,
            // Snapshot, not a read-through: see setQuoteOption.
            takerFee: option.startingTakerFee,
            creatorFeeLocked: true,
            graduated: false
        });
        launchLocks[coin].mode = lockMode;

        // ---- interactions
        TempoAssetLaunchLib.Ladder memory l = TempoAssetLaunchLib.settleListing(
            TempoAssetLaunchLib.LaunchArgs({
                engine: matchingEngine,
                coin: coin,
                quote: quote,
                supply: initialSupply,
                devBuyQuote: devBuyQuote,
                launchFee: launchFee,
                feeTo: feeTo,
                deferLadder: ladderDeferred
            }),
            option
        );
        launches[coin].pair = l.pair;
        _ladders[coin] = l;
        _writeEngineFee(l.pair, 0, option.startingTakerFee);

        emit Launched(coin, msg.sender, l.pair, quote, initialSupply);
        // TEMPO: no `payFee`. The fee was taken in the quote token by `settleListing`, and
        // Tempo refuses any transaction carrying value, so there is never anything to refund.
    }

    /**
     * @notice Lists a market for two tokens that already exist, with its own policy.
     * @dev Permissionless, for the pool-launch flow. This contract is the lister of
     * record AND stays the band pool's creator: a pool's creator role can only be handed
     * on by its holder, so a pool given to a lister could never be taken back from one
     * who squats a pair. The lister configures the bands through `listerBandCall`
     * instead, and an admin can reassign or lock the lister. Makers are free.
     */
    function listPair(
        address base,
        address quote,
        uint256 listingPrice,
        uint16 slippageLimitBps,
        uint32 takerFee
    ) external nonReentrant returns (address pair) {
        pair = TempoAssetLaunchLib.listPair(
            matchingEngine,
            base,
            quote,
            listingPrice,
            slippageLimitBps,
            takerFee,
            _bounds()
        );
        pairPolicies[pair] = PairPolicy(slippageLimitBps, 0, takerFee, true);
        pairLister[pair] = msg.sender;
        _writeEngineFee(pair, 0, takerFee);
        // addPair synced the pool while the policy was still unwritten.
        _syncPool(base, quote);
        emit PairListed(pair, base, quote, msg.sender, slippageLimitBps, takerFee);
    }

    /// @notice Hands a listed pair to a new lister -- the remedy for a squatted listing.
    function reassignPairLister(address pair, address lister) external onlyRole(ADMIN_ROLE) {
        if (pairLister[pair] == address(0)) revert PairDoesNotExist(pair, pair);
        // Zero is irreversible: the existence check above reads the same slot, so a pair
        // reassigned to nobody could never be reassigned again.
        if (lister == address(0)) revert ZeroAddress();
        pairLister[pair] = lister;
        emit PairListerSet(pair, lister);
    }

    /**
     * @notice Band configuration for a listed pair's pool, by its lister: one of
     * `configureBands`, `setBandFeeMultiplier` or `setBandOpen`, forwarded as is.
     * @dev Never `transferCreator`: the pool stays this contract's, see `listPair`.
     */
    function listerBandCall(address base, address quote, bytes calldata data) external {
        address pair = IMatchingEngine(matchingEngine).getPair(base, quote);
        if (pair == address(0) || pairLister[pair] != msg.sender) revert NotTheLister(msg.sender);
        if (listerFeeLocked[pair]) revert CreatorFeeControlLocked(pair);
        TempoAssetLaunchLib.bandCall(matchingEngine, base, quote, data);
    }

    /* -------------------------------- graduation ------------------------------- */

    /**
     * @notice Graduates a coin whose ladder has sold out. Permissionless, in two calls.
     * @dev The first call after every ask has filled ARMS it: graduation may finish
     * `GRADUATION_DELAY` later, once the pool's TWAP anchor has caught up with the last
     * ladder price. Without the wait, a buyer who walked the whole ladder in one block
     * could graduate in the next and buy the held-back supply from the pool at the
     * anchor's stale, lower price. The second call, from anyone, finishes: everything
     * the escrow holds becomes one locked pool position, the pair's spread goes back to
     * its default, the bands open, and the creator gets band and fee control. "Filled"
     * is read from the ladder's ORDER STATE, never from reserves, so no deposit fakes it.
     */
    function graduate(address coin) external nonReentrant {
        Launch storage record = launches[coin];
        if (record.creator == address(0)) revert CoinNotLaunched(coin);
        if (record.graduated) revert AlreadyGraduated(coin);
        LaunchLock storage lock = launchLocks[coin];
        TempoAssetLaunchLib.Ladder memory l = _ladders[coin];
        if (lock.readyAt == 0) {
            TempoAssetLaunchLib.requireFilled(l);
            lock.readyAt = uint64(block.timestamp) + GRADUATION_DELAY;
            emit GraduationArmed(coin, lock.readyAt);
            return;
        }
        if (block.timestamp < lock.readyAt) revert GraduationNotReady(lock.readyAt);

        record.graduated = true;
        record.creatorFeeLocked = false;
        lock.graduatedAt = uint64(block.timestamp);
        (address manager, uint256 tokenId, uint256 raised, uint256 coins) =
            TempoAssetLaunchLib.seedPool(matchingEngine, coin, record.quote, l, record.creator);
        lock.manager = manager;
        lock.tokenId = tokenId;
        emit Graduated(coin, raised, coins);
        emit LiquidityLocked(
            coin,
            manager,
            tokenId,
            lock.mode == LockMode.FeesOnly ? type(uint64).max : uint64(block.timestamp) + 365 days
        );
    }

    /// @notice Places the ladder of a launch made while `ladderDeferred` was on. Anyone may
    /// call it, once: the ladder is fixed by the launch, so the caller chooses nothing.
    function placeLadder(address coin) external nonReentrant {
        address quote = launches[coin].quote;
        if (quote == address(0)) revert CoinNotLaunched(coin);
        _ladders[coin] =
            TempoAssetLaunchLib.placeDeferredLadder(matchingEngine, coin, quote, _ladders[coin], _quoteOptions[quote]);
    }

    /// @notice The ladder a launch placed: its pair, escrow, restored spread and ask ids.
    function ladderOf(address coin) external view returns (TempoAssetLaunchLib.Ladder memory) {
        return _ladders[coin];
    }

    /* ---------------------------- liquidity locking --------------------------- */

    /// @notice Pays the graduated position's vested fees to `recipient`. The principal stays.
    function collectLockedFees(address coin, address recipient)
        external
        nonReentrant
        returns (uint256 baseOut, uint256 quoteOut)
    {
        LaunchLock storage lock = _creatorLock(coin, recipient);
        return BandPositionManager(lock.manager).collect(lock.tokenId, recipient);
    }

    /// @notice Under `Vest12Months`, withdraws what has vested since the last release.
    function releaseVested(address coin, address recipient) external nonReentrant {
        LaunchLock storage lock = _creatorLock(coin, recipient);
        if (lock.mode != LockMode.Vest12Months) revert NotVesting(coin);
        uint16 vested = TempoAssetLaunchLib.releaseVested(
            lock.manager, lock.tokenId, lock.graduatedAt, lock.releasedBps, recipient
        );
        lock.releasedBps = vested;
        emit LiquidityReleased(coin, recipient, vested);
    }

    /// The graduated lock on `coin`, if the caller is its creator.
    function _creatorLock(address coin, address recipient) private view returns (LaunchLock storage lock) {
        if (launches[coin].creator != msg.sender) revert NotTheCreator(msg.sender);
        if (recipient == address(0)) revert InvalidRecipient();
        lock = launchLocks[coin];
        if (lock.tokenId == 0) revert NotGraduated(coin);
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
