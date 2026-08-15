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
///   TEST_TRADE_BASE_AMOUNT / TEST_TRADE_QUOTE_AMOUNT
///   AUCTION_BIDDER_KEY and AUCTION_COMMIT_AMOUNT (creates one visible bid)
///
/// Example:
///   ALLOW_TEST_FIXTURES=true TEST_FIXTURE_CHAIN_ID=11155931 \
///   forge script script/launch/SeedTestLaunches.s.sol:SeedTestLaunches \
///     --rpc-url $RISE_RPC_URL --broadcast --private-key $RISE_TESTNET_DEPLOYER_KEY
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
        (address pool, uint256 tradePrice, uint256 tradedBase, uint256 tradedQuote) =
            _seedPoolAndTrade(config.generator, launchedCoin, config.quote, vm.addr(config.deployerKey));
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
        console.log("DEGEN_TRADE_PRICE=%s", tradePrice);
        console.log("DEGEN_TRADED_BASE=%s", tradedBase);
        console.log("DEGEN_TRADED_QUOTE=%s", tradedQuote);
        console.log("WHITE_AUCTION_PRESALE_ID=%s", presaleId);
        console.log("WHITE_AUCTION_COIN=%s", auctionCoin);
        console.log("WHITE_AUCTION_CONTRACT=%s", config.presale);
        console.log("quote=%s", config.quote);
        console.log("note: the launch created its Pool automatically and the fixture executed one matched trade");
    }

    function _createDegenLaunch(
        address generator,
        string memory name,
        string memory symbol,
        uint256 supply,
        address quote
    ) internal returns (address coin) {
        coin = AssetGenerator(generator).launch(name, symbol, supply, quote);
    }

    /// @dev AssetGenerator lists the pair through MatchingEngine, which creates the Pool
    /// in the same transaction. Execute one matched trade, then leave a bid and ask
    /// away from the market so the indexer/UI has both trade history and visible depth.
    function _seedPoolAndTrade(address generator, address coin, address quote, address recipient)
        internal
        returns (address pool, uint256 price, uint256 tradedBase, uint256 tradedQuote)
    {
        IMatchingEngine engine = IMatchingEngine(AssetGenerator(generator).matchingEngine());
        address pair = engine.getPair(coin, quote);
        price = IOrderbook(pair).lmp();
        pool = IPoolFactory(engine.poolFactory()).getPool(coin, quote);
        require(pool != address(0), "seed: pool not created");

        tradedBase = vm.envOr("TEST_TRADE_BASE_AMOUNT", uint256(1 ether));
        uint256 quoteUnit = 10 ** IERC20Metadata(quote).decimals();
        tradedQuote = vm.envOr("TEST_TRADE_QUOTE_AMOUNT", quoteUnit);
        require(tradedBase > 0 && tradedQuote > 0, "seed: trade amount is zero");
        require(IERC20(coin).balanceOf(recipient) >= tradedBase, "seed: insufficient launch coin");
        require(IERC20(quote).balanceOf(recipient) >= tradedQuote, "seed: insufficient quote");

        IERC20(coin).approve(address(engine), tradedBase);
        IERC20(quote).approve(address(engine), tradedQuote);
        engine.limitSell(
            IMatchingEngine.LimitOrderInput({
                base: coin,
                quote: quote,
                price: price,
                amount: tradedBase,
                isMaker: true,
                n: 1,
                recipient: recipient
            })
        );
        IMatchingEngine.OrderResult memory buy =
            engine.marketBuy(
                IMatchingEngine.MarketOrderInput({
                    base: coin,
                    quote: quote,
                    amount: tradedQuote,
                    isMaker: false,
                    n: 1,
                    recipient: recipient,
                    slippageLimit: 1_000_000
                })
            );
        require(buy.placed == 0, "seed: market buy left a resting order");

        DepthConfig memory depth = DepthConfig({
            coin: coin,
            quote: quote,
            recipient: recipient,
            askAmount: vm.envOr("TEST_BOOK_ASK_BASE_AMOUNT", tradedBase),
            bidAmount: vm.envOr("TEST_BOOK_BID_QUOTE_AMOUNT", tradedQuote),
            price: IOrderbook(pair).lmp()
        });
        _seedRestingDepth(engine, depth);
    }

    struct DepthConfig { address coin; address quote; address recipient; uint256 askAmount; uint256 bidAmount; uint256 price; }

    function _seedRestingDepth(IMatchingEngine engine, DepthConfig memory depth) internal {
        // The crossed fixture intentionally consumes its ask. Re-seed depth after
        // it settles, otherwise the book is empty even though a Trade exists.
        require(depth.price > 0, "seed: post-trade price is zero");
        uint256 askPrice = depth.price + (depth.price / 20);
        uint256 bidPrice = depth.price - (depth.price / 20);
        require(bidPrice > 0, "seed: invalid depth prices");
        require(IERC20(depth.coin).balanceOf(depth.recipient) >= depth.askAmount, "seed: insufficient ask balance");
        require(IERC20(depth.quote).balanceOf(depth.recipient) >= depth.bidAmount, "seed: insufficient bid balance");

        IERC20(depth.coin).approve(address(engine), depth.askAmount);
        IERC20(depth.quote).approve(address(engine), depth.bidAmount);
        IMatchingEngine.OrderResult memory ask = engine.limitSell(
            IMatchingEngine.LimitOrderInput({
                base: depth.coin,
                quote: depth.quote,
                price: askPrice,
                amount: depth.askAmount,
                isMaker: true,
                n: 1,
                recipient: depth.recipient
            })
        );
        IMatchingEngine.OrderResult memory bid = engine.limitBuy(
            IMatchingEngine.LimitOrderInput({
                base: depth.coin,
                quote: depth.quote,
                price: bidPrice,
                amount: depth.bidAmount,
                isMaker: true,
                n: 1,
                recipient: depth.recipient
            })
        );
        require(ask.placed > 0 && bid.placed > 0, "seed: depth orders did not rest");

        console.log("DEGEN_BOOK_BID_PRICE=%s", bidPrice);
        console.log("DEGEN_BOOK_ASK_PRICE=%s", askPrice);
        console.log("DEGEN_BOOK_BID_QUOTE=%s", depth.bidAmount);
        console.log("DEGEN_BOOK_ASK_BASE=%s", depth.askAmount);
    }

    function _createAuction(
        address presale,
        string memory name,
        string memory symbol,
        address quote,
        address treasury
    ) internal returns (uint256 presaleId, address coin) {
        uint256 quoteUnit = 10 ** IERC20Metadata(quote).decimals();
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
            // Leave mining headroom: createPresale rejects a start timestamp even one
            // second behind the transaction's block. The auction becomes live shortly
            // after this fixture is broadcast.
            startAt: uint64(block.timestamp + 30 seconds),
            endAt: uint64(block.timestamp + 3 days),
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
        address launchA = AssetGenerator(generator).launch("Iter New Pool", "NEWPOOL", 1_000_000_000 ether, quote);
        address launchB = AssetGenerator(generator).launch("Iter Active Pool", "ACTIVE", 1_000_000_000 ether, quote);

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
