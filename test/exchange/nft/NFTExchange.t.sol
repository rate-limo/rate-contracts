// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {NFTAsset} from "../../../src/exchange/nft/NFTAsset.sol";
import {NFTTokenMatchingEngine} from "../../../src/exchange/nft/token/NFTTokenMatchingEngine.sol";
import {NFTBarterMatchingEngine} from "../../../src/exchange/nft/barter/NFTBarterMatchingEngine.sol";

contract NFTExchangeTest is Test {
    MockERC20 quote;
    Mock721 nftA;
    Mock721 nftB;
    Mock1155 multi;
    NFTTokenMatchingEngine tokenEngine;
    NFTBarterMatchingEngine barterEngine;
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function setUp() public {
        quote = new MockERC20();
        nftA = new Mock721();
        nftB = new Mock721();
        multi = new Mock1155();
        tokenEngine = new NFTTokenMatchingEngine();
        barterEngine = new NFTBarterMatchingEngine();
        nftA.mint(alice, 1);
        nftB.mint(bob, 2);
        multi.mint(alice, 7, 10);
        multi.mint(bob, 7, 10);
        quote.mint(bob, 1_000 ether);
        quote.mint(alice, 1_000 ether);
        vm.warp(100);
    }

    function testERC721AskAndBuy() public {
        NFTAsset.Item memory item = NFTAsset.Item(address(nftA), NFTAsset.Standard.ERC721, 1, 1);
        vm.startPrank(alice);
        nftA.approve(address(tokenEngine), 1);
        uint256 id = tokenEngine.createAsk(item, address(quote), 10 ether, 200);
        vm.stopPrank();
        vm.startPrank(bob);
        quote.approve(address(tokenEngine), 10 ether);
        tokenEngine.buy(id);
        vm.stopPrank();
        assertEq(nftA.ownerOf(1), bob);
        assertEq(quote.balanceOf(alice), 1_010 ether);
    }

    function testERC1155BidAndAccept() public {
        NFTAsset.Item memory item = NFTAsset.Item(address(multi), NFTAsset.Standard.ERC1155, 7, 4);
        vm.startPrank(bob);
        quote.approve(address(tokenEngine), 40 ether);
        uint256 id = tokenEngine.createBid(item, address(quote), 40 ether, 200);
        vm.stopPrank();
        vm.startPrank(alice);
        multi.setApprovalForAll(address(tokenEngine), true);
        tokenEngine.acceptBid(id);
        vm.stopPrank();
        assertEq(multi.balanceOf(bob, 7), 14);
        assertEq(quote.balanceOf(alice), 1_040 ether);
    }

    function testBarterERC721ToERC1155() public {
        NFTAsset.Item memory offered = NFTAsset.Item(address(nftA), NFTAsset.Standard.ERC721, 1, 1);
        NFTAsset.Item memory wanted = NFTAsset.Item(address(multi), NFTAsset.Standard.ERC1155, 7, 3);
        vm.startPrank(alice);
        nftA.approve(address(barterEngine), 1);
        uint256 id = barterEngine.createOffer(offered, wanted, 200);
        vm.stopPrank();
        vm.startPrank(bob);
        multi.setApprovalForAll(address(barterEngine), true);
        barterEngine.acceptOffer(id);
        vm.stopPrank();
        assertEq(nftA.ownerOf(1), bob);
        assertEq(multi.balanceOf(alice, 7), 13);
    }

    function testCancelReturnsEscrow() public {
        NFTAsset.Item memory item = NFTAsset.Item(address(nftA), NFTAsset.Standard.ERC721, 1, 1);
        vm.startPrank(alice);
        nftA.approve(address(tokenEngine), 1);
        uint256 id = tokenEngine.createAsk(item, address(quote), 1 ether, 200);
        tokenEngine.cancel(id);
        vm.stopPrank();
        assertEq(nftA.ownerOf(1), alice);
    }

    /* ─────────── reverts ───────────
     *
     * Each of these asserts the ARGUMENTS, not just the selector. The reason the errors
     * carry arguments at all is that a wallet decodes them into a toast, and "invalid
     * order" — which is what a single catch-all error produced — cannot tell someone
     * they set an expiry in the past rather than forgot an approval. A test that only
     * checked the selector would pass just as happily with the arguments wrong.
     */

    function _askItem() internal view returns (NFTAsset.Item memory) {
        return NFTAsset.Item(address(nftA), NFTAsset.Standard.ERC721, 1, 1);
    }

    function test_createAsk_revertsOnExpiryInThePast() public {
        vm.startPrank(alice);
        nftA.approve(address(tokenEngine), 1);
        // block.timestamp is 100 (setUp warps there); 99 is already gone.
        vm.expectRevert(
            abi.encodeWithSelector(NFTTokenMatchingEngine.ExpiryNotInFuture.selector, uint64(99), uint64(100))
        );
        tokenEngine.createAsk(_askItem(), address(quote), 1 ether, 99);
        vm.stopPrank();
    }

    function test_createAsk_revertsOnZeroQuoteAmount() public {
        vm.startPrank(alice);
        nftA.approve(address(tokenEngine), 1);
        vm.expectRevert(NFTTokenMatchingEngine.ZeroQuoteAmount.selector);
        tokenEngine.createAsk(_askItem(), address(quote), 0, 200);
        vm.stopPrank();
    }

    function test_createAsk_revertsOnZeroQuoteToken() public {
        vm.startPrank(alice);
        nftA.approve(address(tokenEngine), 1);
        vm.expectRevert(NFTTokenMatchingEngine.ZeroQuoteToken.selector);
        tokenEngine.createAsk(_askItem(), address(0), 1 ether, 200);
        vm.stopPrank();
    }

    /// An ERC-721 leg with amount 0 would move nothing and settle as though it had.
    function test_createAsk_revertsWhenErc721AmountIsNotOne() public {
        vm.startPrank(alice);
        nftA.approve(address(tokenEngine), 1);
        vm.expectRevert(abi.encodeWithSelector(NFTAsset.ERC721AmountNotOne.selector, uint256(0)));
        tokenEngine.createAsk(
            NFTAsset.Item(address(nftA), NFTAsset.Standard.ERC721, 1, 0), address(quote), 1 ether, 200
        );
        vm.stopPrank();
    }

    function test_buy_revertsWithBothSidesWhenTheOrderIsABid() public {
        NFTAsset.Item memory item = NFTAsset.Item(address(multi), NFTAsset.Standard.ERC1155, 7, 4);
        vm.startPrank(bob);
        quote.approve(address(tokenEngine), 40 ether);
        uint256 id = tokenEngine.createBid(item, address(quote), 40 ether, 200);
        vm.stopPrank();

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                NFTTokenMatchingEngine.WrongSide.selector,
                id,
                NFTTokenMatchingEngine.Side.Ask,
                NFTTokenMatchingEngine.Side.Bid
            )
        );
        tokenEngine.buy(id);
    }

    function test_cancel_revertsNamingTheRealMaker() public {
        vm.startPrank(alice);
        nftA.approve(address(tokenEngine), 1);
        uint256 id = tokenEngine.createAsk(_askItem(), address(quote), 1 ether, 200);
        vm.stopPrank();

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(NFTTokenMatchingEngine.NotMaker.selector, id, bob, alice));
        tokenEngine.cancel(id);
    }

    function test_buy_revertsWithTheExpiryItPassed() public {
        vm.startPrank(alice);
        nftA.approve(address(tokenEngine), 1);
        uint256 id = tokenEngine.createAsk(_askItem(), address(quote), 1 ether, 200);
        vm.stopPrank();

        vm.warp(200);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(NFTTokenMatchingEngine.Expired.selector, id, uint64(200)));
        tokenEngine.buy(id);
    }

    function test_expire_revertsBeforeTheDeadline() public {
        vm.startPrank(alice);
        nftA.approve(address(tokenEngine), 1);
        uint256 id = tokenEngine.createAsk(_askItem(), address(quote), 1 ether, 200);
        vm.stopPrank();

        vm.expectRevert(abi.encodeWithSelector(NFTTokenMatchingEngine.NotExpired.selector, id, uint64(200)));
        tokenEngine.expire(id);
    }

    function test_cancel_revertsOnAnOrderAlreadyClosed() public {
        vm.startPrank(alice);
        nftA.approve(address(tokenEngine), 1);
        uint256 id = tokenEngine.createAsk(_askItem(), address(quote), 1 ether, 200);
        tokenEngine.cancel(id);
        vm.expectRevert(abi.encodeWithSelector(NFTTokenMatchingEngine.Inactive.selector, id));
        tokenEngine.cancel(id);
        vm.stopPrank();
    }

    /// Bartering a token for itself would escrow and return the same item, which is a
    /// no-op the maker paid gas for rather than a trade.
    function test_createOffer_revertsWhenOfferedIsWanted() public {
        NFTAsset.Item memory same = NFTAsset.Item(address(nftA), NFTAsset.Standard.ERC721, 1, 1);
        vm.startPrank(alice);
        nftA.approve(address(barterEngine), 1);
        vm.expectRevert(
            abi.encodeWithSelector(NFTBarterMatchingEngine.OfferedIsWanted.selector, address(nftA), uint256(1))
        );
        barterEngine.createOffer(same, same, 200);
        vm.stopPrank();
    }
}

contract MockERC20 is ERC20 {
    constructor() ERC20("Quote", "Q") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract Mock721 is ERC721 {
    constructor() ERC721("NFT", "N") {}
    function mint(address to, uint256 id) external { _mint(to, id); }
}

contract Mock1155 is ERC1155 {
    constructor() ERC1155("") {}
    function mint(address to, uint256 id, uint256 amount) external { _mint(to, id, amount, ""); }
}
