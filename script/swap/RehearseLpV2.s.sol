// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {ExchangeOrderbook} from "../../src/exchange/libraries/ExchangeOrderbook.sol";
import {MatchingEngine} from "../../src/exchange/MatchingEngine.sol";
import {MockToken} from "../../src/mock/MockToken.sol";
import {BandPool} from "../../src/swap/BandPool.sol";
import {BandPoolFactory} from "../../src/swap/BandPoolFactory.sol";
import {BandPositionManager} from "../../src/swap/BandPositionManager.sol";
import {BandSwapRouter} from "../../src/swap/BandSwapRouter.sol";
import {IBandPositionManager} from "../../src/swap/interfaces/IBandPositionManager.sol";

/**
 * LP v2 rehearsal against a deployed stack -- run it on a local anvil after
 * `RiseTestnetFull.s.sol` (or on a testnet after a redeploy) BEFORE seeding:
 *
 *   REHEARSE_KEY=<key> ENGINE=.. FACTORY=.. MANAGER=.. ROUTER=.. \
 *     forge script script/swap/RehearseLpV2.s.sol --rpc-url <rpc> --broadcast
 *
 * Lists a mock pair, mints ONE token across three bands, swaps through it, withdraws a
 * quarter of every band and collects. Every step asserts the v2 rule it exercises; read
 * the token's on-chain card back with `cast call <manager> "uri(uint256)(string)" <id>`.
 */
contract RehearseLpV2 is Script {
    struct Stack {
        MatchingEngine engine;
        BandPoolFactory factory;
        BandPositionManager manager;
        BandSwapRouter router;
        address me;
    }

    function run() external {
        uint256 key = vm.envUint("REHEARSE_KEY");
        Stack memory s = Stack({
            engine: MatchingEngine(payable(vm.envAddress("ENGINE"))),
            factory: BandPoolFactory(vm.envAddress("FACTORY")),
            manager: BandPositionManager(vm.envAddress("MANAGER")),
            router: BandSwapRouter(vm.envAddress("ROUTER")),
            me: vm.addr(key)
        });
        vm.startBroadcast(key);
        (MockToken base, MockToken quote, BandPool pool) = _list(s);
        uint256 tokenId = _mint(s, base, quote, pool);
        _trade(s, quote, pool);
        _exit(s, tokenId);
        vm.stopBroadcast();

        string memory uri = s.manager.uri(tokenId);
        require(bytes(uri).length > 0, "uri is empty: no descriptor wired");
        // Too long for the console: read it back with `cast call <manager> "uri(uint256)(string)" <id>`.
        console.log("uri bytes", bytes(uri).length);
    }

    function _list(Stack memory s) internal returns (MockToken base, MockToken quote, BandPool pool) {
        base = new MockToken("Rehearsal Base", "RBASE", 18);
        quote = new MockToken("Rehearsal Quote", "RQUOTE", 6);
        base.mint(s.me, 1_000_000e18);
        quote.mint(s.me, 1_000_000e6);
        s.engine.addPair(
            address(base), address(quote), 1e8, 0, address(quote), ExchangeOrderbook.MatchingMode.PriceTimePriority
        );
        pool = BandPool(s.factory.getPool(address(base), address(quote)));
        require(address(pool) != address(0), "addPair created no pool");
        require(pool.creator() == s.me, "the lister is not the pool's creator");
        require(pool.pairLimit(true) > 0, "addPair did not sync the limit");
        console.log("pool", address(pool));
        console.log("limitBuy", pool.pairLimit(true));
    }

    function _mint(Stack memory s, MockToken base, MockToken quote, BandPool pool) internal returns (uint256 tokenId) {
        base.approve(address(s.manager), type(uint256).max);
        quote.approve(address(s.manager), type(uint256).max);
        uint8[] memory bands = new uint8[](3);
        uint256[] memory b = new uint256[](3);
        uint256[] memory q = new uint256[](3);
        uint128[] memory m = new uint128[](3);
        for (uint8 i = 0; i < 3; i++) {
            bands[i] = i;
            b[i] = 1_000e18;
            q[i] = 1_000e6;
        }
        uint256 expected = s.manager.nextTokenId();
        (tokenId,) = s.manager.mint(
            IBandPositionManager.MintParams({
                pool: address(pool),
                bands: bands,
                baseAmounts: b,
                quoteAmounts: q,
                minShares: m,
                recipient: s.me,
                deadline: block.timestamp + 600
            })
        );
        require(tokenId == expected, "nextTokenId did not name the next id");
        require(s.manager.balanceOf(s.me, tokenId) == 1, "not held");
        require(s.manager.positionOf(tokenId).bands.length == 3, "one token must hold all three bands");
        console.log("tokenId", tokenId);
    }

    function _trade(Stack memory s, MockToken quote, BandPool pool) internal {
        quote.approve(address(s.router), type(uint256).max);
        uint256 out = s.router.swap(address(pool), 100e6, true, s.me, 0);
        require(out > 0, "the swap filled nothing");
        console.log("swap out (base)", out);
    }

    function _exit(Stack memory s, uint256 tokenId) internal {
        (uint256 bo, uint256 qo) = s.manager.decreaseLiquidity(tokenId, 2_500, 0, 0, s.me, block.timestamp + 600);
        require(bo + qo > 0, "a quarter paid nothing");
        require(s.manager.positionOf(tokenId).bands.length == 3, "a partial exit must keep every band");
        (uint256 cb, uint256 cq) = s.manager.collect(tokenId, s.me);
        console.log("withdrew 25% base / quote", bo, qo);
        console.log("collected base / quote", cb, cq);
    }
}
