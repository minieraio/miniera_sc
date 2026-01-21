// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IMinter {
    function getCirculatingSupply() external view returns (uint256);
    function burnNotification(uint256 amount) external;
}

contract Referral is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public paymentToken; // asset backing the MINB token
    IERC20 public gridToken;
    address public boardContract;

    // Map keeping track of each user referrals (referred -> referrer)
    mapping(address => address) public referrals;

    // Tracks a list of referred addresses for every referrer
    mapping(address => address[]) private referrerToReferrals;

    // Map tracking accumulated referral credits for each user
    mapping(address => uint256) public referralCredits; 
    
    // Events
    event BoardContractUpdated(address indexed newBoard);
    event ReferralCreditAdded(address indexed referrer, address indexed referred, uint256 amount);
    event ReferralCreditUsed(address indexed user, uint256 amount);
    event ReferralSet(address indexed referred, address indexed referrer);

    constructor(address _paymentToken, address _gridToken) Ownable(msg.sender) {
        paymentToken = IERC20(_paymentToken);
        gridToken = IERC20(_gridToken);
    }

    function setReferredBy(address referrer) public {
        require(referrals[msg.sender] == address(0), "Referral: Already referred by someone");
        require(referrer != address(0), "Referral: Referrer cannot be zero address");
        require(referrer != msg.sender, "Referral: Cannot refer yourself");

        referrals[msg.sender] = referrer;
        referrerToReferrals[referrer].push(msg.sender);
        emit ReferralSet(msg.sender, referrer);
    }

    function getReferrer(address referred) public view returns (address) {
        return referrals[referred];
    }

    function getReferralCount(address referrer) external view returns (uint256) {
        return referrerToReferrals[referrer].length;
    }

    function getReferrals(address referrer, uint256 offset, uint256 limit) external view returns (address[] memory) {
        address[] storage referralsList = referrerToReferrals[referrer];
        uint256 total = referralsList.length;

        if (offset >= total) {
            return new address[](0);
        }

        uint256 end = offset + limit;
        if (end > total) {
            end = total;
        }

        uint256 sliceSize = end - offset;
        address[] memory page = new address[](sliceSize);

        for (uint256 i = 0; i < sliceSize; i++) {
            page[i] = referralsList[offset + i];
        }

        return page;
    }

    function collectReferralCredit(address user, uint256 requestedAmount) external nonReentrant returns (uint256) {
        require(msg.sender == boardContract, "Referral: Only board can call this");
        require(user != address(0), "Referral: Invalid user address");

        uint256 availableCredit = referralCredits[user];
        if (availableCredit == 0) {
            return 0;
        }

        uint256 amountToUse = requestedAmount > availableCredit ? availableCredit : requestedAmount;

        referralCredits[user] -= amountToUse;
        paymentToken.safeTransfer(boardContract, amountToUse);

        emit ReferralCreditUsed(user, amountToUse);
        return amountToUse;
    }

    function addReferralCredit(address referrer, uint256 amount) external nonReentrant {
        require(msg.sender == boardContract, "Referral: Only board can call this");
        require(referrer != address(0), "Referral: Invalid referrer address");
        require(amount > 0, "Referral: Amount must be greater than 0");

        referralCredits[referrer] += amount;
        emit ReferralCreditAdded(referrer, msg.sender, amount);
    }

    function getReferralCredit(address user) external view returns (uint256) {
        return referralCredits[user];
    }

    

    // // Admin functions
    function setBoardContract(address _boardContract) external onlyOwner {
        require(_boardContract != address(0), "Vault: Board cannot be zero address");
        boardContract = _boardContract;
        emit BoardContractUpdated(_boardContract);
    }
}
