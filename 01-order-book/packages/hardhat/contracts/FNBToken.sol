// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Import the standard ERC20 contract from OpenZeppelin.
// This provides transfer, balanceOf, approve and other functions for free.
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// FNBToken is an ERC20 token that represents eBucks (FNB rewards).
// All tokens are minted to the deployer when the contract is created and no more can ever be made.
contract FNBToken is ERC20 {
    // The constructor runs once when the contract is deployed.
    // It takes one argument: the total number of tokens to mint (in the smallest unit).
    constructor(uint256 initialSupply) ERC20("FNB Token", "FNBT") {
        // Mint all tokens to the account that deployed this contract.
        // initialSupply is already in the token's smallest unit (like wei for Ether).
        _mint(msg.sender, initialSupply);
    }
}
