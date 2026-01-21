// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract Token is ERC20, Ownable {
    address public burner;

    event BurnerUpdated(address indexed newBurner);

    constructor() ERC20("Miniera Protocol Token", "MINB") Ownable(msg.sender) {
        // Minting is controlled by the Minter contract, no initial supply.
    }

    modifier onlyOwnerOrBurner() {
        require(msg.sender == owner() || msg.sender == burner, "Token: Unauthorized");
        _;
    }

    // External mint hook used by the Minter contract.
    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    // Burns tokens from the provided address when redeeming.
    function burn(address from, uint256 amount) external onlyOwnerOrBurner {
        _burn(from, amount);
    }

    // Set the burner address (Vault contract)
    function setBurner(address _burner) external onlyOwner {
        require(_burner != address(0), "Token: Burner cannot be zero address");
        burner = _burner;
        emit BurnerUpdated(_burner);
    }
}
