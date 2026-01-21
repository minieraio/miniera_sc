// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IMinter {
    function getCirculatingSupply() external view returns (uint256);
    function burnNotification(uint256 amount) external;
}

interface IGridToken is IERC20 {
    function burn(address from, uint256 amount) external;
}

contract Vault is Ownable, ReentrancyGuard {
    IERC20 public paymentToken; // asset backing the MINB token
    IGridToken public gridToken;
    IMinter public minter;
    address public boardContract;
    
    uint256 public totalPaymentAmount;
    uint256 public totalBurnedAmount;
    uint256 public totalRedeemedAmount;
    uint256 public totalPaymentAmountReceived;

    event TokensRedeemed(address indexed user, uint256 tokenAmount, uint256 paymentAmount);
    event PaymentAmountReceived(uint256 amount);
    event MinterUpdated(address indexed newMinter);
    event BoardContractUpdated(address indexed newBoard);

    constructor(address _paymentToken, address _gridToken) Ownable(msg.sender) {
        paymentToken = IERC20(_paymentToken);
        gridToken = IGridToken(_gridToken);
    }

    // Burns MINB and returns the pro-rata share of the payment asset.
    function redeem(uint256 tokenAmount) external nonReentrant {
        require(tokenAmount > 0, "Vault: Amount must be greater than 0");
        
        uint256 userBalance = gridToken.balanceOf(msg.sender);
        require(userBalance >= tokenAmount, "Vault: Insufficient token balance");
        
        uint256 circulatingSupply = minter.getCirculatingSupply();
        require(circulatingSupply > 0, "Vault: No tokens in circulation");
        
        uint256 currentBalance = paymentToken.balanceOf(address(this));
        require(currentBalance > 0, "Vault: No collateral available");

        // (vault balance * amount) / circulating
        uint256 redemptionAmount = (currentBalance * tokenAmount) / circulatingSupply;

        // Update state
        totalBurnedAmount += tokenAmount;
        totalRedeemedAmount += redemptionAmount;

        // Burn tokens
        gridToken.burn(msg.sender, tokenAmount);

        // Transfer payment asset to user
        paymentToken.transfer(msg.sender, redemptionAmount);
        
        // Notify minter about burned tokens
        minter.burnNotification(tokenAmount);
        
        emit TokensRedeemed(msg.sender, tokenAmount, redemptionAmount);
    }

    // Records fresh deposits sent by the board or minter.
    function receivePaymentAmount(uint256 amount) external {
        require(
            msg.sender == address(minter) || msg.sender == boardContract,
            "Vault: Unauthorized sender"
        );
        require(amount > 0, "Vault: Amount must be greater than 0");
        
        totalPaymentAmountReceived += amount;
        totalPaymentAmount = paymentToken.balanceOf(address(this));
        
        emit PaymentAmountReceived(amount);
    }

    // Admin functions
    function setMinter(address _minter) external onlyOwner {
        require(_minter != address(0), "Vault: Minter cannot be zero address");
        minter = IMinter(_minter);
        emit MinterUpdated(_minter);
    }

    function setBoardContract(address _boardContract) external onlyOwner {
        require(_boardContract != address(0), "Vault: Board cannot be zero address");
        boardContract = _boardContract;
        emit BoardContractUpdated(_boardContract);
    }

    // View functions
    function getState() external view returns (
        uint256 balance,
        uint256 burnedAmount,
        uint256 redeemedAmount,
        uint256 totalReceived
    ) {
        return (
            paymentToken.balanceOf(address(this)),
            totalBurnedAmount,
            totalRedeemedAmount,
            totalPaymentAmountReceived
        );
    }

    function getPrice() external view returns (uint256) {
        uint256 circulatingSupply = minter.getCirculatingSupply();
        if (circulatingSupply == 0) return 0;
        
        uint256 currentBalance = paymentToken.balanceOf(address(this));
        return (currentBalance * 1e18) / circulatingSupply;
    }

    function getBalance() external view returns (uint256) {
        return paymentToken.balanceOf(address(this));
    }
}
