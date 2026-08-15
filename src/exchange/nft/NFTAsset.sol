// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

library NFTAsset {
    enum Standard {
        ERC721,
        ERC1155
    }

    struct Item {
        address token;
        Standard standard;
        uint256 tokenId;
        uint256 amount;
    }

    error ZeroToken();
    /// @dev Carries the offending amount: the caller's next question is always "what did I send?"
    error ERC721AmountNotOne(uint256 amount);
    error ZeroAmount(address token, uint256 tokenId);

    function validate(Item memory item) internal pure {
        if (item.token == address(0)) revert ZeroToken();
        // An ERC-721 leg with amount 0 would transfer nothing and settle as if it had, so this
        // is the one bound that has to be exact rather than merely non-zero.
        if (item.standard == Standard.ERC721) {
            if (item.amount != 1) revert ERC721AmountNotOne(item.amount);
        } else if (item.amount == 0) {
            revert ZeroAmount(item.token, item.tokenId);
        }
    }
}
