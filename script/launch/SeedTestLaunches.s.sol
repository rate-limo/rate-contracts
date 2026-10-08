// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {AssetGenerator} from "../../src/asset/AssetGenerator.sol";
import {PresaleLaunch} from "../../src/asset/PresaleLaunch.sol";
import {ExchangeOrderbook} from "../../src/exchange/libraries/ExchangeOrderbook.sol";
import {IMatchingEngine} from "../../src/exchange/interfaces/IMatchingEngine.sol";
import {IOrderbook} from "../../src/exchange/interfaces/IOrderbook.sol";
import {IPoolFactory} from "../../src/swap/interfaces/IPoolFactory.sol";

/// @notice Creates disposable launch fixtures for testnet UI/indexer testing.
///
/// This script is intentionally separate from every chain deployment script. Mainnet
/// deployments must not create demo launches, auction campaigns, or seed test data.
/// The script requires TEST_FIXTURE_CHAIN_ID and an explicit ALLOW_TEST_FIXTURES=true,
/// and rejects the production chain ids known to this repository.
///
/// Required environment:
///   DEPLOYER_KEY, ASSET_GENERATOR, PRESALE_LAUNCH, LAUNCH_QUOTE,
///   TEST_FIXTURE_CHAIN_ID, ALLOW_TEST_FIXTURES=true
///
/// Optional:
///   TEST_LAUNCH_NAME / TEST_LAUNCH_SYMBOL / TEST_LAUNCH_SUPPLY
///   TEST_AUCTION_NAME / TEST_AUCTION_SYMBOL
///   TEST_TRADES_PER_PAIR (default 10, alternating buy and sell)
///   TEST_TRADE_BASE_AMOUNT / TEST_TRADE_QUOTE_AMOUNT (size of one sell / one buy)
///   TEST_BOOK_ASK_BASE_AMOUNT / TEST_BOOK_BID_QUOTE_AMOUNT (depth to rest)
///   AUCTION_BIDDER_KEY and AUCTION_COMMIT_AMOUNT (creates one visible bid)
///
/// Example:
///   ALLOW_TEST_FIXTURES=true TEST_FIXTURE_CHAIN_ID=11155931 \
///   forge script script/launch/SeedTestLaunches.s.sol:SeedTestLaunches \
///     --rpc-url $RISE_RPC_URL --broadcast --private-key $RISE_TESTNET_DEPLOYER_KEY
/// A launch hands the creator only what they buy, so the fixture buys the most it may
/// -- 10% of supply, a tenth of the starting market cap -- to have coins to trade. The
/// other 80% rests as the launch ladder: the fixture's buys fill it from step 0 up.
function _launchWithDevBuy(
    address generator,
    string memory name,
    string memory symbol,
    uint256 supply,
    address quote
) returns (address coin) {
    uint256 devBuy = AssetGenerator(generator).quoteOption(quote).startingMarketCap / 10;
    IERC20(quote).approve(generator, devBuy);
    coin = AssetGenerator(generator).launch{value: AssetGenerator(generator).launchFee()}(
        name, symbol, supply, quote, devBuy, AssetGenerator.LockMode.FeesOnly
    );
    // A two-transaction launch (Tempo): the ladder is its own call, and the fixture's
    // buys below have nothing to fill until it is placed.
    if (AssetGenerator(generator).ladderDeferred()) AssetGenerator(generator).placeLadder(coin);
}


contract SeedTestLaunches is Script {
    struct FixtureConfig {
        uint256 deployerKey;
        address generator;
        address presale;
        address quote;
        string launchName;
        string launchSymbol;
        uint256 launchSupply;
        string auctionName;
        string auctionSymbol;
    }
    /// @dev `MatchingEngine.DENOM`. Every spread numerator is scaled to 1e8.
    uint256 internal constant SPREAD_DENOM = 100_000_000;

    // Production chains currently supported by the exchange deployment scripts.
    uint256 internal constant ETHEREUM = 1;
    uint256 internal constant OPTIMISM = 10;
    uint256 internal constant BASE = 8453;
    uint256 internal constant ARBITRUM = 42161;
    uint256 internal constant FRAXTAL = 252;

    error TestFixturesDisabled();
    error WrongFixtureChain(uint256 actual, uint256 expected);
    error MainnetFixtureBlocked(uint256 chainId);

    function run() external {
        if (!vm.envOr("ALLOW_TEST_FIXTURES", false)) revert TestFixturesDisabled();

        uint256 expectedChainId = vm.envUint("TEST_FIXTURE_CHAIN_ID");
        if (block.chainid != expectedChainId) revert WrongFixtureChain(block.chainid, expectedChainId);
        if (_isProductionChain(block.chainid)) revert MainnetFixtureBlocked(block.chainid);

        FixtureConfig memory config = FixtureConfig({
            deployerKey: vm.envUint("DEPLOYER_KEY"),
            generator: vm.envAddress("ASSET_GENERATOR"),
            presale: vm.envAddress("PRESALE_LAUNCH"),
            quote: vm.envAddress("LAUNCH_QUOTE"),
            launchName: vm.envOr("TEST_LAUNCH_NAME", string("Iter Test Launch")),
            launchSymbol: vm.envOr("TEST_LAUNCH_SYMBOL", string("TITER")),
            launchSupply: vm.envOr("TEST_LAUNCH_SUPPLY", uint256(1_000_000_000 ether)),
            auctionName: vm.envOr("TEST_AUCTION_NAME", string("Iter Test Auction")),
            auctionSymbol: vm.envOr("TEST_AUCTION_SYMBOL", string("WAUCT"))
        });

        vm.startBroadcast(config.deployerKey);
        address launchedCoin = _createDegenLaunch(config.generator, config.launchName, config.launchSymbol, config.launchSupply, config.quote);
        (address pool, TradeReport memory report) =
            _seedPoolAndTrades(config.generator, launchedCoin, config.quote, vm.addr(config.deployerKey));
        (uint256 presaleId, address auctionCoin) = _createAuction(config.presale, config.auctionName, config.auctionSymbol, config.quote, vm.addr(config.deployerKey));
        vm.stopBroadcast();

        // Optional bidder fixture. This is deliberately opt-in because it spends a
        // second wallet's quote balance; leaving it unset still creates a valid auction.
        uint256 bidderKey = vm.envOr("AUCTION_BIDDER_KEY", uint256(0));
        uint256 bidAmount = vm.envOr("AUCTION_COMMIT_AMOUNT", uint256(0));
        if (bidderKey != 0 && bidAmount > 0) {
            _commitAuction(bidderKey, config.quote, config.presale, presaleId, bidAmount);
        }

        console.log("TEST_FIXTURE_CHAIN_ID=%s", block.chainid);
        console.log("DEGEN_LAUNCH_COIN=%s", launchedCoin);
        console.log("DEGEN_POOL=%s", pool);
        console.log("DEGEN_TRADE_PRICE=%s", report.price);
        console.log("DEGEN_TRADED_BASE=%s", report.sellBase);
        console.log("DEGEN_TRADED_QUOTE=%s", report.buyQuote);
        console.log("DEGEN_TRADES_BUY=%s", report.buys);
        console.log("DEGEN_TRADES_SELL=%s", report.sells);
        console.log("WHITE_AUCTION_PRESALE_ID=%s", presaleId);
        console.log("WHITE_AUCTION_COIN=%s", auctionCoin);
        console.log("WHITE_AUCTION_CONTRACT=%s", config.presale);
        console.log("quote=%s", config.quote);
        console.log(
            "note: the launch created its Pool automatically and the fixture traded the pair on both sides"
        );
    }

    function _createDegenLaunch(
        address generator,
        string memory name,
        string memory symbol,
        uint256 supply,
        address quote
    ) internal returns (address coin) {
        coin = _launchWithDevBuy(generator, name, symbol, supply, quote);
    }

    /// @dev What one seeded market ended up with, so `run` can report it without
    /// six return values threaded through the helpers below.
    struct TradeReport {
        uint256 price;
        uint256 buyQuote;
        uint256 sellBase;
        uint256 buys;
        uint256 sells;
    }

    /// @dev Everything one market's round of trading needs, bundled because the loop
    /// passes it through four helpers and hits "stack too deep" without it.
    struct TradeConfig {
        IMatchingEngine engine;
        address pair;
        address coin;
        address quote;
        address recipient;
        uint256 askBase;
        uint256 bidQuote;
        uint256 buyQuote;
        uint256 sellBase;
        uint256 trades;
    }

    /// @dev AssetGenerator lists the pair through MatchingEngine, which creates the Pool
    /// in the same transaction. This then trades the pair BOTH WAYS, ten times by default.
    ///
    /// It used to execute exactly one matched trade — a maker sell crossed by a market
    /// buy — and then re-rest depth. That is enough to prove the engine settles and not
    /// enough to populate anything that reads a MARKET rather than a trade: a candle
    /// needs opens and closes to have a shape, a tape needs rows to scroll, and every
    /// surface that splits volume by direction needs a direction that is not always the
    /// same one. Worse, every `OrderMatched` the fixture emitted carried `isBid = false`,
    /// so the venue rendered a coin that had only ever been bought and never sold.
    ///
    /// Depth is re-checked before every trade rather than rested once. Each fill drags
    /// `lmp` to the price it happened at, so the side that is not being hit drifts away
    /// from the market price and eventually out of the band a taker is allowed to price
    /// into — and `_limitBuy`/`_limitSell` CLAMP an out-of-band price instead of
    /// reverting, so the order executes, reaches nothing, and refunds itself.
    function _seedPoolAndTrades(address generator, address coin, address quote, address recipient)
        internal
        returns (address pool, TradeReport memory report)
    {
        TradeConfig memory cfg;
        cfg.engine = IMatchingEngine(AssetGenerator(generator).matchingEngine());
        cfg.pair = cfg.engine.getPair(coin, quote);
        cfg.coin = coin;
        cfg.quote = quote;
        cfg.recipient = recipient;
        pool = IPoolFactory(cfg.engine.poolFactory()).getPool(coin, quote);
        require(pool != address(0), "seed: pool not created");

        uint256 quoteUnit = 10 ** IERC20Metadata(quote).decimals();
        cfg.trades = vm.envOr("TEST_TRADES_PER_PAIR", uint256(10));
        cfg.sellBase = vm.envOr("TEST_TRADE_BASE_AMOUNT", uint256(1 ether));
        cfg.buyQuote = vm.envOr("TEST_TRADE_QUOTE_AMOUNT", quoteUnit);
        // Depth sized for the whole round, not for one trade: a book re-rested mid-round
        // still works, it just costs a transaction and moves the price further.
        cfg.askBase = vm.envOr("TEST_BOOK_ASK_BASE_AMOUNT", cfg.sellBase * cfg.trades * 2);
        cfg.bidQuote = vm.envOr("TEST_BOOK_BID_QUOTE_AMOUNT", cfg.buyQuote * cfg.trades);
        require(cfg.trades > 0, "seed: trade count is zero");
        require(cfg.sellBase > 0 && cfg.buyQuote > 0, "seed: trade amount is zero");
        require(
            IERC20(coin).balanceOf(recipient) >= cfg.askBase + cfg.sellBase * cfg.trades,
            "seed: insufficient launch coin"
        );
        // The bid is the only quote that leaves for long: this wallet owns both sides of
        // the book, so a taker buy pays quote to its own resting ask and a taker sell is
        // paid back out of its own resting bid.
        require(IERC20(quote).balanceOf(recipient) >= cfg.bidQuote + cfg.buyQuote, "seed: insufficient quote");

        // Approved once rather than before every order. The alternative is ~20 extra
        // broadcast transactions for a fixture wallet holding testnet funds.
        IERC20(coin).approve(address(cfg.engine), type(uint256).max);
        IERC20(quote).approve(address(cfg.engine), type(uint256).max);

        (report.buys, report.sells) = _tradeRound(cfg);
        report.price = IOrderbook(cfg.pair).lmp();
        report.buyQuote = cfg.buyQuote;
        report.sellBase = cfg.sellBase;
        require(report.buys > 0 && report.sells > 0, "seed: the pair did not trade both ways");
    }

    function _tradeRound(TradeConfig memory cfg) internal returns (uint256 buys, uint256 sells) {
        for (uint256 i = 0; i < cfg.trades; ++i) {
            if (i % 2 == 0) {
                _ensureAsk(cfg);
                if (_takerBuy(cfg)) ++buys;
            } else {
                _ensureBid(cfg);
                if (_takerSell(cfg)) ++sells;
            }
        }
    }

    /// @dev Rest an ask when the book has none a taker buy could reach. Present is not
    /// the same as reachable — see `_seedPoolAndTrades`.
    function _ensureAsk(TradeConfig memory cfg) internal {
        uint256 lmp = IOrderbook(cfg.pair).lmp();
        require(lmp > 0, "seed: market price is zero");
        uint256 ceiling = (lmp * (SPREAD_DENOM + cfg.engine.getSpread(cfg.pair, true, false))) / SPREAD_DENOM;
        (, uint256 askHead) = cfg.engine.heads(cfg.coin, cfg.quote);
        if (askHead != 0 && askHead <= ceiling) return;

        // AT the market price, never through it: a maker order priced across the spread
        // executes against itself as a taker.
        cfg.engine.limitSell(
            IMatchingEngine.LimitOrderInput({
                base: cfg.coin,
                quote: cfg.quote,
                price: lmp,
                amount: cfg.askBase,
                isMaker: true,
                n: 1,
                recipient: cfg.recipient
            })
        );
    }

    /// @dev Rest a bid, a quarter of the allowed band under the market price.
    ///
    /// Not at the edge of the band: each fill drags `lmp` with it, so a quarter leaves
    /// room for several fills on one side before the other becomes unreachable. Strictly
    /// under the ask, because this wallet owns the ask — a crossing bid would wash-trade
    /// against its own depth and eat what every buy in the round needs.
    function _ensureBid(TradeConfig memory cfg) internal {
        uint256 lmp = IOrderbook(cfg.pair).lmp();
        require(lmp > 0, "seed: market price is zero");
        uint256 spread = cfg.engine.getSpread(cfg.pair, false, false);
        (uint256 bidHead, uint256 askHead) = cfg.engine.heads(cfg.coin, cfg.quote);
        if (bidHead != 0 && bidHead >= (lmp * (SPREAD_DENOM - spread)) / SPREAD_DENOM) return;

        uint256 price = lmp - (lmp * spread) / (SPREAD_DENOM * 4);
        require(price > 0 && (askHead == 0 || price < askHead), "seed: no room for a bid under the ask");
        cfg.engine.limitBuy(
            IMatchingEngine.LimitOrderInput({
                base: cfg.coin,
                quote: cfg.quote,
                price: price,
                amount: cfg.bidQuote,
                isMaker: true,
                n: 1,
                recipient: cfg.recipient
            })
        );
    }

    /// @dev A taker buy priced AT the resting ask, which is the price guaranteed to cross
    /// it. Reports whether it actually filled by the base it received: an order that
    /// matched nothing is refunded rather than reverted, so `OrderResult` cannot say.
    function _takerBuy(TradeConfig memory cfg) internal returns (bool filled) {
        (, uint256 askHead) = cfg.engine.heads(cfg.coin, cfg.quote);
        if (askHead == 0) return false;
        uint256 held = IERC20(cfg.coin).balanceOf(cfg.recipient);
        cfg.engine.limitBuy(
            IMatchingEngine.LimitOrderInput({
                base: cfg.coin,
                quote: cfg.quote,
                price: askHead,
                amount: cfg.buyQuote,
                isMaker: false,
                n: 20,
                recipient: cfg.recipient
            })
        );
        return IERC20(cfg.coin).balanceOf(cfg.recipient) > held;
    }

    /// @dev The mirror of `_takerBuy`, and the trade the fixture never made.
    function _takerSell(TradeConfig memory cfg) internal returns (bool filled) {
        (uint256 bidHead,) = cfg.engine.heads(cfg.coin, cfg.quote);
        if (bidHead == 0) return false;
        uint256 held = IERC20(cfg.quote).balanceOf(cfg.recipient);
        cfg.engine.limitSell(
            IMatchingEngine.LimitOrderInput({
                base: cfg.coin,
                quote: cfg.quote,
                price: bidHead,
                amount: cfg.sellBase,
                isMaker: false,
                n: 20,
                recipient: cfg.recipient
            })
        );
        return IERC20(cfg.quote).balanceOf(cfg.recipient) > held;
    }

    function _createAuction(
        address presale,
        string memory name,
        string memory symbol,
        address quote,
        address treasury
    ) internal returns (uint256 presaleId, address coin) {
        uint256 quoteUnit = 10 ** IERC20Metadata(quote).decimals();
        uint64 auctionStartDelay = uint64(vm.envOr("TEST_AUCTION_START_DELAY", uint256(600)));
        PresaleLaunch.CreateParams memory params = PresaleLaunch.CreateParams({
            name: name,
            symbol: symbol,
            totalSupply: 100_000_000 ether,
            presaleAllocation: 10_000_000 ether,
            lpTokenAllocation: 2_000_000 ether,
            priceQuotePerToken: quoteUnit / 100,
            targetRaise: 1_000 * quoteUnit,
            minimumRaise: 100 * quoteUnit,
            maxPerWallet: 1_000 * quoteUnit,
            creatorTokenAllocation: 20_000_000 ether,
            treasuryTokenAllocation: 68_000_000 ether,
            /*
             * Leave mining headroom: `_validateCreate` rejects a start timestamp even
             * one second behind the block that mines it.
             *
             * This was `+ 30 seconds` and that is not enough. `block.timestamp` is read
             * once, from the block the script forked at, while the run ahead of this
             * call launches a coin and puts ten trades through the pair — so by the time
             * `createPresale` is validated the chain has moved on. Measured on RISE
             * 2026-09-24: `startAt` landed 42 seconds BEHIND the head and the whole seed
             * died on `InvalidSchedule()`, which reads as a bad fixture rather than a
             * clock that ran out.
             *
             * Ten minutes is headroom the script cannot plausibly outrun, and the cost
             * is only that the auction is UPCOMING for that long before it opens — which
             * is itself a state worth having a fixture for. `endAt` hangs off `startAt`
             * rather than off `block.timestamp`, so widening the delay cannot quietly
             * shorten the sale.
             */
            startAt: uint64(block.timestamp + auctionStartDelay),
            endAt: uint64(block.timestamp + auctionStartDelay + 3 days),
            creatorCliff: 90 days,
            creatorVestingDuration: 365 days,
            lpBps: 2_000,
            quote: quote,
            treasury: treasury
        });
        (presaleId, coin) = PresaleLaunch(presale).createPresale(params);
    }

    function _commitAuction(
        uint256 bidderKey,
        address quote,
        address presale,
        uint256 presaleId,
        uint256 amount
    ) internal {
        address bidder = vm.addr(bidderKey);
        vm.startBroadcast(bidderKey);
        IERC20(quote).approve(presale, amount);
        PresaleLaunch(presale).commit(presaleId, amount);
        vm.stopBroadcast();
        console.log("auction bidder=%s committed=%s", bidder, amount);
    }

    function _isProductionChain(uint256 chainId) internal pure returns (bool) {
        return chainId == ETHEREUM || chainId == OPTIMISM || chainId == BASE || chainId == ARBITRUM || chainId == FRAXTAL;
    }
}

/// @notice Phase one of the complete UI fixture set.
/// Creates upcoming/live auctions plus three short-lived terminal-state candidates.
/// Run FinalizeTestLaunches after TEST_TERMINAL_DURATION has elapsed.
contract PrepareAllLaunchStates is Script {
    function run() external {
        _guard();
        uint256 key = vm.envUint("DEPLOYER_KEY");
        address generator = vm.envAddress("ASSET_GENERATOR");
        address presale = vm.envAddress("PRESALE_LAUNCH");
        address quote = vm.envAddress("LAUNCH_QUOTE");
        uint256 unit = 10 ** IERC20Metadata(quote).decimals();
        uint64 activationDelay = uint64(vm.envOr("TEST_ACTIVATION_DELAY", uint256(300)));
        uint64 shortDuration = uint64(vm.envOr("TEST_TERMINAL_DURATION", uint256(180)));
        uint64 activationAt = uint64(block.timestamp) + activationDelay;
        address deployer = vm.addr(key);

        vm.startBroadcast(key);
        address launchA = _launchWithDevBuy(generator, "Iter New Pool", "NEWPOOL", 1_000_000_000 ether, quote);
        address launchB = _launchWithDevBuy(generator, "Iter Active Pool", "ACTIVE", 1_000_000_000 ether, quote);

        (uint256 upcomingId,) = _create(presale, quote, "Upcoming Auction", "UPCOMING", uint64(block.timestamp + 1 days), uint64(block.timestamp + 4 days), deployer);
        (uint256 liveId,) = _create(presale, quote, "Live Auction", "LIVE", activationAt, activationAt + 3 days, deployer);
        (uint256 successfulId,) = _create(presale, quote, "Successful Auction", "SUCCESS", activationAt, activationAt + shortDuration, deployer);
        (uint256 graduatedId,) = _create(presale, quote, "Graduated Auction", "GRAD", activationAt, activationAt + shortDuration, deployer);
        (uint256 failedId,) = _create(presale, quote, "Failed Auction", "FAILED", activationAt, activationAt + shortDuration, deployer);
        vm.stopBroadcast();

        console.log("DEGEN_NEW_POOL_COIN=%s", launchA);
        console.log("DEGEN_ACTIVE_POOL_COIN=%s", launchB);
        console.log("UPCOMING_AUCTION_ID=%s", upcomingId);
        console.log("LIVE_AUCTION_ID=%s", liveId);
        console.log("SUCCESSFUL_AUCTION_ID=%s", successfulId);
        console.log("GRADUATED_AUCTION_ID=%s", graduatedId);
        console.log("FAILED_AUCTION_ID=%s", failedId);
        console.log("ACTIVATION_AT=%s", activationAt);
        console.log("TERMINAL_END_AT=%s", activationAt + shortDuration);
        console.log("QUOTE_UNIT=%s", unit);
    }

    function _create(address presale, address quote, string memory name, string memory symbol, uint64 startAt, uint64 endAt, address treasury)
        internal returns (uint256 id, address coin)
    {
        uint256 unit = 10 ** IERC20Metadata(quote).decimals();
        PresaleLaunch.CreateParams memory p = PresaleLaunch.CreateParams({
            name: name, symbol: symbol, totalSupply: 100_000_000 ether,
            presaleAllocation: 10_000_000 ether, lpTokenAllocation: 2_000_000 ether,
            priceQuotePerToken: unit / 100, targetRaise: 1_000 * unit,
            minimumRaise: 100 * unit, maxPerWallet: 1_000 * unit,
            creatorTokenAllocation: 20_000_000 ether, treasuryTokenAllocation: 68_000_000 ether,
            startAt: startAt, endAt: endAt, creatorCliff: 90 days,
            creatorVestingDuration: 365 days, lpBps: 2_000, quote: quote, treasury: treasury
        });
        return PresaleLaunch(presale).createPresale(p);
    }

    function _guard() internal view {
        if (!vm.envOr("ALLOW_TEST_FIXTURES", false)) revert SeedTestLaunches.TestFixturesDisabled();
        uint256 expected = vm.envUint("TEST_FIXTURE_CHAIN_ID");
        if (block.chainid != expected) revert SeedTestLaunches.WrongFixtureChain(block.chainid, expected);
        if (block.chainid == 1 || block.chainid == 10 || block.chainid == 8453 || block.chainid == 42161 || block.chainid == 252) {
            revert SeedTestLaunches.MainnetFixtureBlocked(block.chainid);
        }
    }
}

/// @notice Phase two: funds/finalizes terminal candidates and graduates one into a pool.
contract FinalizeTestLaunches is Script {
    function run() external {
        if (!vm.envOr("ALLOW_TEST_FIXTURES", false)) revert SeedTestLaunches.TestFixturesDisabled();
        uint256 expected = vm.envUint("TEST_FIXTURE_CHAIN_ID");
        if (block.chainid != expected) revert SeedTestLaunches.WrongFixtureChain(block.chainid, expected);

        uint256 key = vm.envUint("DEPLOYER_KEY");
        address presaleAddress = vm.envAddress("PRESALE_LAUNCH");
        address quote = vm.envAddress("LAUNCH_QUOTE");
        uint256 successfulId = vm.envUint("SUCCESSFUL_AUCTION_ID");
        uint256 graduatedId = vm.envUint("GRADUATED_AUCTION_ID");
        uint256 failedId = vm.envUint("FAILED_AUCTION_ID");
        uint256 unit = 10 ** IERC20Metadata(quote).decimals();
        PresaleLaunch presale = PresaleLaunch(presaleAddress);

        bool finalizeOnly = vm.envOr("FINALIZE_ONLY", false);
        if (!finalizeOnly) {
            vm.startBroadcast(key);
            IERC20(quote).approve(presaleAddress, 410 * unit);
            presale.commit(successfulId, 200 * unit);
            presale.commit(graduatedId, 200 * unit);
            presale.commit(failedId, 10 * unit);
            vm.stopBroadcast();
            console.log("WAIT_UNTIL_END_AT_BEFORE_FINALIZE=true");
            console.log("Run this contract again with FINALIZE_ONLY=true after the candidates expire.");
            return;
        }

        vm.startBroadcast(key);
        presale.finalizeSale(successfulId);
        presale.finalizeSale(graduatedId);
        presale.finalizeSale(failedId);
        presale.configureGraduation(graduatedId, PresaleLaunch.GraduationConfig({
            listingPrice: 1e8, minPrice: 50_000_000, maxPrice: 150_000_000,
            lpSlippageLimit: 1_000_000, volatilityBps: 50,
            makerFee: 0, takerFee: 100_000, liquidityLockDuration: 30 days,
            mode: ExchangeOrderbook.MatchingMode.PriceTimePriority
        }));
        presale.graduate(graduatedId);
        vm.stopBroadcast();
        console.log("ALL_AUCTION_STATES_FINALIZED=true");
    }
}
