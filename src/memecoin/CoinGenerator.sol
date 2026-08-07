/// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {TransferHelper} from "../exchange/libraries/TransferHelper.sol";
import {ExchangeOrderbook} from "../exchange/libraries/ExchangeOrderbook.sol";
import {IMatchingEngine} from "../exchange/interfaces/IMatchingEngine.sol";
import {IProtocol} from "../incentive/interfaces/IProtocol.sol";

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
 * @title CoinGenerator
 * @notice Deploys a fixed-supply coin, lists it against an admin-approved quote token,
 * and tracks whether it has met the USD graduation requirement.
 *
 * @dev Three things are admin-controlled, all behind `ADMIN_ROLE`:
 *  - the launch fee and its recipient,
 *  - which quote tokens a coin may list against (and on what terms),
 *  - the graduation requirement, denominated in the stablecoin's own units.
 *
 * Market value is never computed here. It is read from the MatchingEngine, which is the
 * only thing that knows what the book says a coin is worth -- see `usdValueOf`.
 *
 * It also implements `IProtocol` so the engine can source a launched coin's taker fee from
 * it: 1.00% before graduation, 0.10% after. See `feeOf` for how that is wired and what has
 * to be true for it to take effect.
 */
contract CoinGenerator is IProtocol, AccessControl, ReentrancyGuard {
    /// @notice Configures fees, quote options and the graduation requirement.
    /// @dev Deliberately distinct from DEFAULT_ADMIN_ROLE, which only grants/revokes roles.
    /// An operator key that can retune fees is not the same key that should be able to
    /// hand out that power.
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    /// @notice Fee scale, mirroring `MatchingEngine.DENOM`. 1% is 1_000_000, 0.1% is 100_000.
    /// @dev Must equal the engine's DENOM. The engine hands the numerator straight to the
    /// orderbook, so a mismatch here silently misprices every fill rather than reverting.
    uint32 public constant FEE_DENOM = 100_000_000;

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
        uint64 launchedAt;
        bool graduated;
        /// @dev The live taker fee for this coin's pairs. Seeded from the quote option at
        /// launch, reset to `postGraduationTakerFee` on graduation, and thereafter
        /// adjustable by the creator within `maxCreatorTakerFee`. Snapshotted rather than
        /// read through to the quote option so that retuning a quote reprices future
        /// launches, never live ones.
        uint32 takerFee;
        /// @dev Admin kill switch for this coin's creator control. False by default (the
        /// creator has it); an admin flips it when a fee is being used against traders.
        bool creatorFeeLocked;
    }

    /// @notice The engine that lists pairs and prices them. Immutable: rewiring it would
    /// orphan every pair this generator has already listed.
    address public immutable matchingEngine;

    /// @notice The token graduation is denominated in.
    address public stablecoin;
    /// @notice Where launch fees are sent.
    address public feeTo;
    /// @notice Native-currency fee charged per launch. Zero means launching is free.
    uint256 public launchFee;
    /// @notice Market cap a coin must reach to graduate, in `stablecoin` base units.
    /// @dev Zero means graduation is not configured and `graduate` reverts, rather than
    /// letting every coin clear a threshold nobody set.
    uint256 public graduationUsd;

    /// @notice Taker fee a coin is reset to when it graduates. 0.10% -- the engine's own
    /// default. Per-venue rather than per-quote: graduation is the point where a coin stops
    /// being a launch and starts being a market like any other.
    uint32 public postGraduationTakerFee = 100_000;

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

    event FeeToSet(address indexed feeTo);
    event LaunchFeeSet(uint256 fee);
    event StablecoinSet(address indexed stablecoin);
    event GraduationUsdSet(uint256 graduationUsd);
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
    event Graduated(address indexed coin, address indexed creator, uint256 timestamp);
    event PostGraduationTakerFeeSet(uint32 feeNum);
    event MaxCreatorTakerFeeSet(uint32 feeNum);
    /// @param by The caller — an admin, or the coin's creator exercising post-graduation control.
    event PairTakerFeeSet(address indexed coin, address indexed by, uint32 feeNum);
    event CreatorFeeControlSet(address indexed coin, bool locked);
    event FallbackIncentiveSet(address indexed incentive);

    error ZeroAddress();
    error FeeToNotSet();
    error InsufficientFee(uint256 sent, uint256 required);
    error QuoteNotEnabled(address quote);
    error EmptyMetadata();
    error SupplyIsZero();
    error CoinNotLaunched(address coin);
    error AlreadyGraduated(address coin);
    error NotCreatorOrAdmin(address caller);
    error GraduationRequirementNotSet();
    error GraduationRequirementNotMet(uint256 valueUsd, uint256 requiredUsd);
    error RefundFailed();
    error InvalidFee(uint32 feeNum);
    error NotAGeneratedCoin(address base);
    error NotTheCreator(address caller);
    error NotGraduatedYet(address coin);
    error CreatorFeeControlLocked(address coin);
    error FeeAboveCreatorCap(uint32 feeNum, uint32 cap);

    /// @param admin Receives both DEFAULT_ADMIN_ROLE and ADMIN_ROLE.
    /// @param matchingEngine_ The MatchingEngine this generator lists against.
    /// @param stablecoin_ The token graduation is measured in.
    constructor(address admin, address matchingEngine_, address stablecoin_) {
        if (admin == address(0) || matchingEngine_ == address(0) || stablecoin_ == address(0)) {
            revert ZeroAddress();
        }
        matchingEngine = matchingEngine_;
        stablecoin = stablecoin_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ADMIN_ROLE, admin);
        emit StablecoinSet(stablecoin_);
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

    function setStablecoin(address stablecoin_) external onlyRole(ADMIN_ROLE) {
        if (stablecoin_ == address(0)) revert ZeroAddress();
        stablecoin = stablecoin_;
        emit StablecoinSet(stablecoin_);
    }

    /// @notice Sets the market cap a coin must reach before it can graduate.
    /// @param graduationUsd_ Threshold in `stablecoin` base units -- for a 6-decimal
    /// stablecoin, $69,420 is `69_420 * 10 ** 6`, not `69_420 * 6`.
    function setGraduationUsd(uint256 graduationUsd_) external onlyRole(ADMIN_ROLE) {
        graduationUsd = graduationUsd_;
        emit GraduationUsdSet(graduationUsd_);
    }

    /// @notice Sets the taker fee every coin is reset to when it graduates.
    /// @dev Applies to future graduations only; a coin that already graduated keeps the fee
    /// it has, which may since have been moved by its creator. Bounded by FEE_DENOM, because
    /// a numerator above the denominator is a fee over 100% and would make fills unpayable.
    /// @param feeNum Numerator on the `FEE_DENOM` scale (100_000 = 0.10%).
    function setPostGraduationTakerFee(uint32 feeNum) external onlyRole(ADMIN_ROLE) {
        if (feeNum > FEE_DENOM) revert InvalidFee(feeNum);
        postGraduationTakerFee = feeNum;
        emit PostGraduationTakerFeeSet(feeNum);
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
     * - **An admin** may set any fee up to `FEE_DENOM`, at any time, graduated or not.
     *   This is the lever for forcing a hostile fee back down.
     * - **The creator** may set a fee only on their own coin, only AFTER it graduates, only
     *   up to `maxCreatorTakerFee`, and only while an admin has not locked them out.
     *
     * The post-graduation condition is the point of the design. Before graduation the fee
     * is the venue's risk pricing for a thin, new book and is not the creator's to move;
     * after it, the coin is an established market and its creator has earned a say in what
     * trading it costs.
     *
     * There is no timelock. A creator can raise the fee in the same block as an incoming
     * trade, so the cap is doing all the work — see `maxCreatorTakerFee`.
     */
    function setPairTakerFee(address coin, uint32 feeNum) external {
        Launch storage record = launches[coin];
        address creator = record.creator;
        if (creator == address(0)) revert CoinNotLaunched(coin);

        if (hasRole(ADMIN_ROLE, msg.sender)) {
            if (feeNum > FEE_DENOM) revert InvalidFee(feeNum);
        } else {
            if (msg.sender != creator) revert NotTheCreator(msg.sender);
            if (!record.graduated) revert NotGraduatedYet(coin);
            if (record.creatorFeeLocked) revert CreatorFeeControlLocked(coin);
            uint32 cap = maxCreatorTakerFee;
            if (feeNum > cap) revert FeeAboveCreatorCap(feeNum, cap);
        }

        record.takerFee = feeNum;
        emit PairTakerFeeSet(coin, msg.sender, feeNum);
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

    /**
     * @notice Market cap of a launched coin, in `stablecoin` units, as the books price it.
     * @dev Two hops, because `IMatchingEngine.convert` is single-pair: coin -> its listing
     * quote, then quote -> stablecoin. `convert` returns the input unchanged when the two
     * sides are equal, so a coin listed directly against the stablecoin costs one no-op hop.
     *
     * `isBid = true` is "convert base to quote" in Orderbook.convert -- the direction that
     * answers "what is this supply worth", not "how much supply does this buy".
     *
     * Reverts `PairDoesNotExist` from the engine when a hop has no book. That is deliberate
     * upstream behaviour: an unpriced coin must fail loudly rather than read as worth zero,
     * which here would be the difference between "cannot value it" and "not worth enough".
     */
    function usdValueOf(address coin) public view returns (uint256 valueUsd) {
        Launch memory record = launches[coin];
        if (record.creator == address(0)) revert CoinNotLaunched(coin);

        uint256 supply = TransferHelper.totalSupply(coin);
        uint256 inQuote = IMatchingEngine(matchingEngine).convert(coin, record.quote, supply, true);
        return IMatchingEngine(matchingEngine).convert(record.quote, stablecoin, inQuote, true);
    }

    /// @notice Whether `coin` currently clears the graduation requirement.
    /// @dev Same revert behaviour as `usdValueOf` -- an unpriced coin is not a `false`.
    function meetsGraduation(address coin) external view returns (bool) {
        if (graduationUsd == 0) return false;
        return usdValueOf(coin) >= graduationUsd;
    }

    /* ------------------------------- fee schedule ------------------------------ */

    /**
     * @notice The taker fee that applies to a launched coin right now.
     * @dev 1.00% until it graduates, 0.10% after. Reverts for a coin this generator did
     * not launch -- see `feeOf` for why reverting is the useful answer.
     */
    function takerFeeOf(address coin) public view returns (uint32) {
        Launch memory record = launches[coin];
        if (record.creator == address(0)) revert CoinNotLaunched(coin);
        return record.takerFee;
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
     *    A maker already pays gas to place and to cancel; graduation reprices the taker
     *    side only.
     *
     * `quote` and `account` are unused: graduation is a property of the coin, not of the
     * pair's other leg or of who is trading. An account-tier ladder belongs in the
     * delegate, which is why one exists.
     */
    function feeOf(address base, address quote, address account, bool isMaker)
        external
        view
        returns (uint32 feeNum)
    {
        if (launches[base].creator != address(0)) {
            return isMaker ? 0 : takerFeeOf(base);
        }
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
        // ---- checks
        if (bytes(name).length == 0 || bytes(symbol).length == 0) revert EmptyMetadata();
        if (initialSupply == 0) revert SupplyIsZero();
        QuoteOption memory option = _quoteOptions[quote];
        if (!option.enabled) revert QuoteNotEnabled(quote);
        if (msg.value < launchFee) revert InsufficientFee(msg.value, launchFee);
        address feeRecipient = feeTo;
        if (launchFee > 0 && feeRecipient == address(0)) revert FeeToNotSet();

        // ---- effects
        coin = address(new Coin(name, symbol, initialSupply, address(this)));
        launches[coin] = Launch({
            creator: msg.sender,
            quote: quote,
            launchedAt: uint64(block.timestamp),
            graduated: false,
            // Snapshot, not a read-through: see setQuoteOption.
            takerFee: option.startingTakerFee,
            creatorFeeLocked: false
        });

        // ---- interactions
        address payment = option.listingPayment == address(0) ? coin : option.listingPayment;
        // The engine pulls the listing cost from msg.sender -- this contract -- with
        // transferFrom, unless it holds MARKET_MAKER_ROLE and lists for free. Approve only
        // what this contract actually holds of the payment token, then drop the allowance
        // again: a listing that spends less than the balance must not leave the engine able
        // to move the rest, and resetting to zero also keeps approve-from-nonzero tokens
        // working on the next launch.
        uint256 paymentBalance = IERC20(payment).balanceOf(address(this));
        if (paymentBalance > 0) TransferHelper.safeApprove(payment, matchingEngine, paymentBalance);
        address pair = IMatchingEngine(matchingEngine).addPair(
            coin, quote, option.listingPrice, block.timestamp, payment, option.mode
        );
        if (paymentBalance > 0) TransferHelper.safeApprove(payment, matchingEngine, 0);

        uint256 remaining = IERC20(coin).balanceOf(address(this));
        if (remaining > 0) TransferHelper.safeTransfer(coin, msg.sender, remaining);

        if (launchFee > 0) TransferHelper.safeTransferETH(feeRecipient, launchFee);
        uint256 refund = msg.value - launchFee;
        if (refund > 0) {
            (bool ok,) = payable(msg.sender).call{value: refund}("");
            if (!ok) revert RefundFailed();
        }

        emit Launched(coin, msg.sender, pair, quote, initialSupply);
    }

    /* -------------------------------- graduate -------------------------------- */

    /**
     * @notice Marks a coin as graduated once the book values it at or above the requirement.
     * @dev Callable by the coin's creator or by an admin. Both are held to the same USD
     * check -- an admin can graduate a coin the creator has not gotten around to, but
     * cannot graduate one that has not earned it.
     * @param coin The launched coin.
     */
    function graduate(address coin) external {
        Launch storage record = launches[coin];
        address creator = record.creator;

        // ---- checks
        if (creator == address(0)) revert CoinNotLaunched(coin);
        if (record.graduated) revert AlreadyGraduated(coin);
        if (msg.sender != creator && !hasRole(ADMIN_ROLE, msg.sender)) revert NotCreatorOrAdmin(msg.sender);
        uint256 required = graduationUsd;
        if (required == 0) revert GraduationRequirementNotSet();
        uint256 valueUsd = usdValueOf(coin);
        if (valueUsd < required) revert GraduationRequirementNotMet(valueUsd, required);

        // ---- effects
        record.graduated = true;
        // The fee drop IS graduation's effect, so it happens here rather than being
        // derived at read time -- and it is what hands the creator the control below.
        record.takerFee = postGraduationTakerFee;

        emit Graduated(coin, creator, block.timestamp);
        emit PairTakerFeeSet(coin, msg.sender, record.takerFee);
    }
}
