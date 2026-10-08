// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * The wrapped-native ERC-20, with its name and symbol supplied at construction.
 *
 * ## Why this exists alongside WETH9
 *
 * `src/mock/WETH9.sol` hardcodes `ERC20("Wrapped Ether", "WETH")`. That is correct on a
 * chain whose gas token is ether and actively wrong on one whose gas token is not — Arc
 * Testnet's is USDC, so wrapping native there produces wrapped USDC while every surface
 * that renders the symbol calls it WETH. Nothing on chain breaks (the engine only ever
 * treats this slot as "the wrapped native ERC-20"), which is exactly what makes the
 * mislabel durable: no test fails, and the only symptom is a token list that lies.
 *
 * WETH9 is left untouched. It is the deployed wrapper on RISE and changing its
 * constructor signature would be a redeploy of a live contract for a cosmetic reason,
 * and redeploying a wrapper strands every balance anyone has already wrapped.
 *
 * ## withdraw uses call, not transfer
 *
 * WETH9 ends `withdraw` with `payable(msg.sender).transfer(amount)`, which forwards a
 * 2300 gas stipend. That is enough for an EOA and not for a contract with a non-trivial
 * `receive`, so under WETH9 a smart-account holder cannot unwrap at all — and gas costs
 * have moved under that stipend before. `call` with a checked return is the pattern that
 * does not depend on a gas schedule staying still.
 *
 * There is no reentrancy opening in the swap: the burn precedes the call, so a re-entered
 * `withdraw` sees a balance already reduced and reverts on the `_burn` underflow.
 */
contract WrappedNative is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    receive() external payable {
        deposit();
    }

    function deposit() public payable {
        _mint(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) public {
        // Burn first: this is the state change that makes the external call below safe
        // to make at all.
        _burn(msg.sender, amount);
        (bool ok, ) = payable(msg.sender).call{value: amount}("");
        require(ok, "native transfer failed");
    }
}
