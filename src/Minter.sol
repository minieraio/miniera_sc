// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

interface IVault {
    function receivePaymentAmount(uint256 amount) external;
}

contract Minter is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable paymentToken; // asset moved to the vault when minting
    IERC20 public gridToken; // MINB token ERC20 interface
    IVault public vault; // redemption vault
    
    uint256 private constant TOKEN_UNIT = 1e18;
    uint256 public totalMinted;
    uint256 public circulatingSupply;
    uint256 public baseCost;
    uint256 public growthRate;
    
    address public boardContract;
    
    // Events
    event TokensMinted(uint256 amount, uint256 paymentRequired);
    event TokensBurned(uint256 amount);
    event BaseCostUpdated(uint256 newBaseCost);
    event GrowthRateUpdated(uint256 newGrowthRate);
    event BoardContractUpdated(address indexed newBoardContract);

    constructor(
        address _paymentToken,
        address _gridToken,
        address _vault,
        uint256 _baseCost,
        uint256 _growthRate
    ) Ownable(msg.sender) {
        require(_paymentToken != address(0), "Minter: payment token required");
        require(_baseCost > 0, "Minter: base cost required");
        require(_growthRate > 0, "Minter: growth rate required");

        paymentToken = IERC20(_paymentToken);
        gridToken = IERC20(_gridToken);
        vault = IVault(_vault);
        baseCost = _baseCost;
        growthRate = _growthRate;
    }

    // External functions
    function mintFromCollateral(
        uint256 collateralAmount,
        address[] calldata recipients,
        uint256[] calldata shareUnits,
        uint256 totalShareUnits
    )
        external
        nonReentrant
        returns (
            uint256[] memory mintedAmounts,
            uint256 mintedTokens,
            uint256 collateralUsed
        )
    {
        require(msg.sender == boardContract, "Minter: Only board contract can mint");
        require(boardContract != address(0), "Minter: board not set");
        require(recipients.length == shareUnits.length, "Minter: Arrays length mismatch");
        require(totalShareUnits > 0, "Minter: invalid share total");

        if (collateralAmount == 0 || recipients.length == 0) {
            return (new uint256[](0), 0, 0);
        }

        mintedTokens = _solveMintAmount(collateralAmount, totalMinted);
        if (mintedTokens == 0) {
            return (new uint256[](0), 0, 0);
        }

        uint256 maxMintable = type(uint256).max - totalMinted;
        if (mintedTokens > maxMintable) {
            mintedTokens = maxMintable;
        }

        collateralUsed = _costForMint(totalMinted, mintedTokens);
        // Adjust for any rounding that pushed cost slightly above available collateral.
        if (collateralUsed > collateralAmount && mintedTokens > 0) {
            mintedTokens -= 1;
            collateralUsed = _costForMint(totalMinted, mintedTokens);
        }
        require(collateralUsed <= collateralAmount, "Minter: pricing mismatch");

        paymentToken.safeTransferFrom(boardContract, address(vault), collateralUsed);
        vault.receivePaymentAmount(collateralUsed);

        totalMinted += mintedTokens;
        circulatingSupply += mintedTokens;

        Token(address(gridToken)).mint(address(this), mintedTokens);

        mintedAmounts = new uint256[](recipients.length);
        uint256 distributed;
        for (uint256 i = 0; i < recipients.length; i++) {
            require(recipients[i] != address(0), "Minter: zero recipient");
            uint256 amount;
            if (i == recipients.length - 1) {
                amount = mintedTokens - distributed;
            } else {
                amount = (mintedTokens * shareUnits[i]) / totalShareUnits;
                distributed += amount;
            }
            mintedAmounts[i] = amount;
            if (amount > 0) {
                gridToken.transfer(recipients[i], amount);
            }
        }

        emit TokensMinted(mintedTokens, collateralUsed);
        return (mintedAmounts, mintedTokens, collateralUsed);
    }

    // Called by the Vault to keep supply stats aligned with token burns.
    function burnNotification(uint256 amount) external {
        require(msg.sender == address(vault), "Minter: Only vault can call this function");
        require(amount > 0, "Minter: Amount must be greater than 0");
        require(circulatingSupply >= amount, "Minter: Cannot burn more than circulating supply");
        
        circulatingSupply -= amount;
        
        emit TokensBurned(amount);
    }

    // Admin functions
    function setBaseCost(uint256 _baseCost) external onlyOwner {
        require(_baseCost > 0, "Minter: Base cost must be greater than 0");
        baseCost = _baseCost;
        emit BaseCostUpdated(_baseCost);
    }

    function setGrowthRate(uint256 _growthRate) external onlyOwner {
        require(_growthRate > 0, "Minter: Growth rate must be greater than 0");
        growthRate = _growthRate;
        emit GrowthRateUpdated(_growthRate);
    }

    function setBoardContract(address _boardContract) external onlyOwner {
        require(_boardContract != address(0), "Minter: Board contract cannot be zero address");
        boardContract = _boardContract;
        emit BoardContractUpdated(_boardContract);
    }

    function setVault(address _vault) external onlyOwner {
        require(_vault != address(0), "Minter: Vault cannot be zero address");
        vault = IVault(_vault); // update after redeploys/upgrades
    }

    // View functions
    function getCirculatingSupply() external view returns (uint256) {
        return circulatingSupply;
    }

    function getTotalMinted() external view returns (uint256) {
        return totalMinted;
    }

    // Internal helpers
    function _solveMintAmount(uint256 collateral, uint256 startSupply) internal view returns (uint256 mintedTokens) {
        if (collateral == 0) return 0;

        // If growth is zero, pricing is flat.
        if (growthRate == 0) {
            return Math.mulDiv(collateral, TOKEN_UNIT, baseCost);
        }

        // Inverse of the integral pricing curve.
        // Total cost from supply s for mint amount m:
        //   cost = base * m / 1e18 + growth * m * (2*s + m) / (2 * 1e36)
        // Rearranging gives quadratic: a*m^2 + b*m - c = 0 where
        //   a = growth
        //   b = 2 * (1e18 * base + growth * s)
        //   c = 2 * collateral * 1e36 (note the sign flip is absorbed in the formula)
        // We solve for the positive root to find m.
        uint256 a = growthRate;
        uint256 b = 2 * (TOKEN_UNIT * baseCost + growthRate * startSupply);
        uint256 c = 2 * collateral * 1e36;

        // Discriminant: b^2 + 4ac (c is positive after the sign flip)
        uint256 discriminant = b * b + 4 * a * c;
        uint256 sqrtDisc = Math.sqrt(discriminant);

        mintedTokens = (sqrtDisc - b) / (2 * a);
    }

    function _costForMint(uint256 startSupply, uint256 mintAmount) internal view returns (uint256) {
        if (mintAmount == 0) return 0;

        // Pricing follows a linear curve: price(x) = baseCost + growthRate * x.
        // The total cost to mint `m` tokens starting from supply `s` is the integral of that
        // linear price over the interval [s, s + m], which yields:
        //   baseCost * m / 1e18 + growthRate * m * (2*s + m) / (2 * 1e36)
        // The 1e18/1e36 factors come from token decimal scaling.
        uint256 baseComponent = Math.mulDiv(mintAmount, baseCost, TOKEN_UNIT);

        // growth component: growthRate * mintAmount * (2*startSupply + mintAmount) / (2 * 1e36)
        uint256 growthNumerator = mintAmount * (2 * startSupply + mintAmount);
        uint256 growthComponent = Math.mulDiv(growthRate, growthNumerator, 2 * 1e36);

        return baseComponent + growthComponent;
    }
}

// Import Token contract for minting function
interface Token {
    function mint(address to, uint256 amount) external;
}
