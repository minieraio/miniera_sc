// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Holds airdrop payouts and allows the BoardManager to trigger winners.
contract Airdrop is Ownable {
    using SafeERC20 for IERC20;

    IERC20 public immutable gridToken;
    address public boardManager;

    event BoardManagerUpdated(address indexed newBoardManager);
    event AirdropPaid(address indexed winner, uint256 amount);
    event AirdropPaidMultiple(uint256 totalAmount, uint256 winnersCount);

    constructor(address _gridToken, address _boardManager) Ownable(msg.sender) {
        require(_gridToken != address(0), "Airdrop: token required");
        gridToken = IERC20(_gridToken);
        _updateBoardManager(_boardManager);
    }

    modifier onlyBoardManager() {
        require(msg.sender == boardManager, "Airdrop: not board manager");
        _;
    }

    // Allows governance to rotate the board manager authority.
    function setBoardManager(address _boardManager) external onlyOwner {
        _updateBoardManager(_boardManager);
    }

    // Quick view for UIs analytics.
    function currentBalance() external view returns (uint256) {
        return gridToken.balanceOf(address(this));
    }

    // Transfers the entire pot to the provided winner.
    function payout(address winner) external onlyBoardManager returns (uint256 amount) {
        require(winner != address(0), "Airdrop: invalid winner");
        amount = gridToken.balanceOf(address(this));
        require(amount > 0, "Airdrop: empty");
        gridToken.safeTransfer(winner, amount);
        emit AirdropPaid(winner, amount);
    }

    // Distributes the entire airdrop pool to multiple winners proportionally
    function payoutMultiple(
        address[] calldata winners,
        uint256[] calldata allocations
    ) external onlyBoardManager returns (uint256 totalPaid) {
        require(winners.length == allocations.length, "Airdrop: length mismatch");
        require(winners.length > 0, "Airdrop: no winners");

        uint256 airdropBalance = gridToken.balanceOf(address(this));
        require(airdropBalance > 0, "Airdrop: empty");

        // Calculate total allocations
        uint256 totalAllocations;
        for (uint256 i = 0; i < allocations.length; i++) {
            totalAllocations += allocations[i];
        }
        require(totalAllocations > 0, "Airdrop: no allocations");

        // Distribute proportionally
        for (uint256 i = 0; i < winners.length; i++) {
            require(winners[i] != address(0), "Airdrop: invalid winner");
            uint256 share = (airdropBalance * allocations[i]) / totalAllocations;
            if (share > 0) {
                gridToken.safeTransfer(winners[i], share);
                totalPaid += share;
            }
        }

        emit AirdropPaidMultiple(totalPaid, winners.length);
    }

    function _updateBoardManager(address _boardManager) internal {
        require(_boardManager != address(0), "Airdrop: board required");
        boardManager = _boardManager;
        emit BoardManagerUpdated(_boardManager);
    }
}
