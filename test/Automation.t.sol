// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {Token} from "../src/Token.sol";
import {Vault} from "../src/Vault.sol";
import {Minter} from "../src/Minter.sol";
import {BoardManager, BoardState} from "../src/BoardManager.sol";
import {Airdrop} from "../src/Airdrop.sol";
import {Referral} from "../src/Referral.sol";
import {Automation} from "../src/Automation.sol";

contract MockUSDC {
    string public name = "Mock USDC";
    string public symbol = "USDC";
    uint8 public decimals = 6;
    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor() {
        totalSupply = 1_000_000 * 10 ** 6;
        balanceOf[msg.sender] = totalSupply;
    }

    function transfer(address to, uint256 value) external returns (bool) {
        require(balanceOf[msg.sender] >= value, "MockUSDC: insufficient balance");
        balanceOf[msg.sender] -= value;
        balanceOf[to] += value;
        return true;
    }

    function approve(address spender, uint256 value) external returns (bool) {
        allowance[msg.sender][spender] = value;
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        require(balanceOf[from] >= value, "MockUSDC: insufficient balance");
        require(allowance[from][msg.sender] >= value, "MockUSDC: insufficient allowance");
        balanceOf[from] -= value;
        balanceOf[to] += value;
        allowance[from][msg.sender] -= value;
        return true;
    }
}

contract AutomationTest is Test {
    Token public token;
    MockUSDC public usdc;
    Vault public vault;
    Minter public minter;
    BoardManager public boardManager;
    Airdrop public airdrop;
    Referral public referral;
    Automation public automation;

    address public miner = address(0x1);
    address public executor = address(0x999);

    uint256 public constant EXECUTION_FEE = 10; // 0.00001 tokens with 6 decimals
    uint256 private constant MIN_DEPOSIT = 100 * 10 ** 6;
    uint256 private constant MAX_PARTICIPANTS = 200;
    uint256 private constant MAX_SYNC_BATCH = 100;

    function setUp() public {
        token = new Token();
        usdc = new MockUSDC();
        airdrop = new Airdrop(address(token), address(this));
        vault = new Vault(address(usdc), address(token));
        referral = new Referral(address(usdc), address(token));
        minter = new Minter(address(usdc), address(token), address(vault), 100 * 10 ** 6, 100);
        boardManager = new BoardManager(
            address(usdc),
            address(minter),
            address(vault),
            address(airdrop),
            address(referral),
            address(this),
            MIN_DEPOSIT,
            MAX_PARTICIPANTS
        );

        airdrop.setBoardManager(address(boardManager));
        referral.setBoardContract(address(boardManager));

        token.transferOwnership(address(minter));
        vault.setMinter(address(minter));
        vault.setBoardContract(address(boardManager));
        minter.setBoardContract(address(boardManager));

        automation = new Automation(address(usdc), address(boardManager), EXECUTION_FEE);
        boardManager.setAutomation(address(automation));

        usdc.transfer(miner, 50_000 * 10 ** 6);
        vm.deal(miner, 10 ether);
        vm.deal(executor, 1 ether);
    }

    function testScheduleAndExecuteFixed() public {
        uint8[] memory squares = new uint8[](2);
        squares[0] = 2;
        squares[1] = 7;
        uint64 turns = 1;
        uint256 amountPerSquare = 1_000 * 10 ** 6;
        uint256 totalAmount = amountPerSquare * squares.length * turns;

        uint256 totalFee = EXECUTION_FEE * turns;
        vm.startPrank(miner);
        usdc.approve(address(automation), totalAmount + totalFee);
        automation.scheduleAutomation(
            Automation.Strategy.Fixed,
            uint8(squares.length),
            turns,
            squares,
            amountPerSquare,
            false
        );
        vm.stopPrank();

        bytes32 hash = keccak256("fixed");
        boardManager.newVar(hash);

        vm.startPrank(executor);
        automation.executeDeploys(boardManager.currentRoundId(), 10);
        vm.stopPrank();

        uint256 roundId = boardManager.currentRoundId();
        assertEq(boardManager.getMinerAllocation(roundId, squares[0], miner), amountPerSquare);
        assertEq(boardManager.getMinerAllocation(roundId, squares[1], miner), amountPerSquare);
        assertEq(usdc.balanceOf(executor), EXECUTION_FEE);
    }

    function testRandomStrategyAcrossRounds() public {
        uint8 squaresPerRound = 3;
        uint64 turns = 2;
        uint256 amountPerSquare = 500 * 10 ** 6;
        uint256 totalAmount = amountPerSquare * squaresPerRound * turns;

        uint256 totalFee = EXECUTION_FEE * turns;
        vm.startPrank(miner);
        usdc.approve(address(automation), totalAmount + totalFee);
        automation.scheduleAutomation(
            Automation.Strategy.Random,
            squaresPerRound,
            turns,
            new uint8[](0),
            amountPerSquare,
            false
        );
        vm.stopPrank();

        uint256 secret1 = 11;
        boardManager.newVar(keccak256(abi.encodePacked(secret1)));

        uint256 roundId1 = boardManager.currentRoundId();
        vm.prank(executor);
        automation.executeDeploys(roundId1, 10);
        _finalizeRound(secret1);

        uint256 secret2 = 22;
        boardManager.newVar(keccak256(abi.encodePacked(secret2)));
        uint256 roundId2 = boardManager.currentRoundId();
        vm.prank(executor);
        automation.executeDeploys(roundId2, 10);

        assertEq(usdc.balanceOf(executor), EXECUTION_FEE * 2);
    }

    function testCancelOrderRefundsDepositAndFees() public {
        uint8[] memory squares = new uint8[](1);
        squares[0] = 4;
        uint64 turns = 3;
        uint256 amountPerSquare = 1_000 * 10 ** 6;
        uint256 totalAmount = amountPerSquare * squares.length * turns;
        uint256 totalFee = EXECUTION_FEE * turns;
        uint256 balanceBefore = usdc.balanceOf(miner);

        vm.startPrank(miner);
        usdc.approve(address(automation), totalAmount + totalFee);
        uint256 orderId = automation.scheduleAutomation(
            Automation.Strategy.Fixed,
            uint8(squares.length),
            turns,
            squares,
            amountPerSquare,
            false
        );
        vm.stopPrank();
        assertEq(usdc.balanceOf(miner), balanceBefore - (totalAmount + totalFee));

        bytes32 hash = keccak256("cancel");
        boardManager.newVar(hash);

        vm.prank(executor);
        automation.executeDeploys(boardManager.currentRoundId(), 10);

        uint256 perRoundAmount = amountPerSquare * squares.length;

        vm.prank(miner);
        automation.cancelOrder(orderId);

        uint256 expectedBalance = balanceBefore - perRoundAmount - EXECUTION_FEE;
        assertEq(usdc.balanceOf(miner), expectedBalance);

        Automation.Order memory orderView = _getOrder(orderId);
        assertEq(orderView.remainingRounds, 0);
        assertEq(orderView.amountRemaining, 0);
        assertTrue(orderView.cancelled);
    }

    function testFeesConsumedOnCompletion() public {
        uint8[] memory squares = new uint8[](1);
        squares[0] = 5;
        uint64 turns = 2;
        uint256 amountPerSquare = 2_000 * 10 ** 6;
        uint256 totalAmount = amountPerSquare * squares.length * turns;
        uint256 totalFee = EXECUTION_FEE * turns;
        uint256 balanceBefore = usdc.balanceOf(miner);

        vm.startPrank(miner);
        usdc.approve(address(automation), totalAmount + totalFee);
        uint256 orderId = automation.scheduleAutomation(
            Automation.Strategy.Fixed,
            uint8(squares.length),
            turns,
            squares,
            amountPerSquare,
            false
        );
        vm.stopPrank();

        uint256 secret1 = 77;
        boardManager.newVar(keccak256(abi.encodePacked(secret1)));
        uint256 roundId1 = boardManager.currentRoundId();
        vm.prank(executor);
        automation.executeDeploys(roundId1, 10);
        _finalizeRound(secret1);

        uint256 secret2 = 88;
        boardManager.newVar(keccak256(abi.encodePacked(secret2)));
        uint256 roundId2 = boardManager.currentRoundId();
        vm.prank(executor);
        automation.executeDeploys(roundId2, 10);

        Automation.Order memory completedOrder = _getOrder(orderId);
        assertEq(completedOrder.remainingRounds, 0);
        assertEq(completedOrder.roundsExecuted, turns);
        assertEq(completedOrder.totalFeesPaid, totalFee);
        assertFalse(completedOrder.cancelled);
        assertEq(usdc.balanceOf(miner), balanceBefore - (totalAmount + totalFee));
    }

    function testExecutionHistoryTracking() public {
        uint8 squaresPerRound = 2;
        uint64 turns = 2;
        uint256 amountPerSquare = 750 * 10 ** 6;
        uint256 totalAmount = amountPerSquare * squaresPerRound * turns;
        uint256 totalFee = EXECUTION_FEE * turns;

        vm.startPrank(miner);
        usdc.approve(address(automation), totalAmount + totalFee);
        uint256 orderId = automation.scheduleAutomation(
            Automation.Strategy.Random,
            squaresPerRound,
            turns,
            new uint8[](0),
            amountPerSquare,
            false
        );
        vm.stopPrank();

        uint256 secret1 = 101;
        boardManager.newVar(keccak256(abi.encodePacked(secret1)));
        uint256 roundId1 = boardManager.currentRoundId();
        vm.prank(executor);
        automation.executeDeploys(roundId1, 10);
        _finalizeRound(secret1);

        uint256 secret2 = 202;
        boardManager.newVar(keccak256(abi.encodePacked(secret2)));
        uint256 roundId2 = boardManager.currentRoundId();
        vm.prank(executor);
        automation.executeDeploys(roundId2, 10);

        Automation.WalletStats memory stats = automation.getWalletStats(miner);
        assertEq(stats.totalExecutions, 2);
        assertEq(stats.totalAmountSpent, amountPerSquare * squaresPerRound * turns);
        assertEq(stats.lastRoundId, roundId2);
        assertEq(stats.totalFeesPaid, totalFee);
    }

    function testScheduleSkipsRoundWhenActiveEndingSoon() public {
        uint256 roundId = _startBoardRound();
        BoardManager.RoundSummary memory summary = boardManager.getRoundSummary(roundId);
        vm.warp(summary.activeUntil - 10); // less than 15 seconds remaining

        uint8[] memory squares = new uint8[](1);
        squares[0] = 4;
        uint64 turns = 1;
        uint256 amountPerSquare = 1_000 * 10 ** 6;
        uint256 totalAmount = amountPerSquare * squares.length * turns;
        uint256 totalFee = EXECUTION_FEE * turns;

        vm.startPrank(miner);
        usdc.approve(address(automation), totalAmount + totalFee);
        uint256 orderId = automation.scheduleAutomation(
            Automation.Strategy.Fixed,
            uint8(squares.length),
            turns,
            squares,
            amountPerSquare,
            false
        );
        vm.stopPrank();

        Automation.Order memory skippedOrder = _getOrder(orderId);
        assertEq(skippedOrder.nextRoundId, roundId + 1);
    }

    function testScheduleUsesCurrentRoundWhenPlentyTime() public {
        uint256 roundId = _startBoardRound();
        BoardManager.RoundSummary memory summary = boardManager.getRoundSummary(roundId);
        vm.warp(summary.activeUntil - 30); // >=15 seconds left, should stay in same round

        uint8[] memory squares = new uint8[](1);
        squares[0] = 2;
        uint64 turns = 1;
        uint256 amountPerSquare = 1_500 * 10 ** 6;
        uint256 totalAmount = amountPerSquare * squares.length * turns;
        uint256 totalFee = EXECUTION_FEE * turns;

        vm.startPrank(miner);
        usdc.approve(address(automation), totalAmount + totalFee);
        uint256 orderId = automation.scheduleAutomation(
            Automation.Strategy.Fixed,
            uint8(squares.length),
            turns,
            squares,
            amountPerSquare,
            false
        );
        vm.stopPrank();

        Automation.Order memory stayedOrder = _getOrder(orderId);
        assertEq(stayedOrder.nextRoundId, roundId);
    }

    function testAutomationOrderReschedulesToNextRoundWhenMissed() public {
        uint8[] memory squares = new uint8[](1);
        squares[0] = 3;
        uint64 turns = 1;
        uint256 amountPerSquare = 1_000 * 10 ** 6;
        uint256 totalAmount = amountPerSquare * squares.length * turns;
        uint256 totalFee = EXECUTION_FEE * turns;

        vm.startPrank(miner);
        usdc.approve(address(automation), totalAmount + totalFee);
        uint256 orderId = automation.scheduleAutomation(
            Automation.Strategy.Fixed,
            uint8(squares.length),
            turns,
            squares,
            amountPerSquare,
            false
        );
        usdc.approve(address(boardManager), type(uint256).max);
        vm.stopPrank();

        uint256 secret1 = 303;
        boardManager.newVar(keccak256(abi.encodePacked(secret1)));

        vm.prank(miner);
        uint8[] memory manualSquares = new uint8[](1);
        manualSquares[0] = 5;
        uint256[] memory manualAmounts = new uint256[](1);
        manualAmounts[0] = 500 * 10 ** 6;
        boardManager.deploy(manualSquares, manualAmounts, false);

        BoardManager.RoundSummary memory summary = boardManager.getRoundSummary(
            boardManager.currentRoundId()
        );
        vm.warp(summary.endTime + 1);
        vm.roll(summary.endBlock + 1);
        boardManager.resetBoard(secret1);

        uint256 secret2 = 404;
        boardManager.newVar(keccak256(abi.encodePacked(secret2)));
        uint256 roundId2 = boardManager.currentRoundId();
        assertEq(automation.pendingExecutions(roundId2), 1);

        vm.prank(executor);
        automation.executeDeploys(roundId2, 10);

        uint256 allocation = boardManager.getMinerAllocation(
            roundId2,
            squares[0],
            miner
        );
        assertEq(allocation, amountPerSquare);

        Automation.Order memory rescheduledOrder = _getOrder(orderId);
        assertEq(rescheduledOrder.remainingRounds, 0);
        assertEq(rescheduledOrder.roundsExecuted, 1);
        assertFalse(rescheduledOrder.cancelled);
    }

    function testSingleActiveOrderPerWallet() public {
        uint8[] memory squares = new uint8[](1);
        squares[0] = 3;
        uint64 turns = 1;
        uint256 amountPerSquare = 1_000 * 10 ** 6;
        uint256 totalAmount = amountPerSquare * squares.length * turns;
        uint256 totalFee = EXECUTION_FEE * turns;

        vm.startPrank(miner);
        usdc.approve(address(automation), (totalAmount + totalFee) * 2);
        uint256 firstOrderId = automation.scheduleAutomation(
            Automation.Strategy.Fixed,
            uint8(squares.length),
            turns,
            squares,
            amountPerSquare,
            false
        );
        vm.expectRevert("Automation: active order in progress");
        automation.scheduleAutomation(
            Automation.Strategy.Fixed,
            uint8(squares.length),
            turns,
            squares,
            amountPerSquare,
            false
        );
        vm.stopPrank();

        bytes32 hash = keccak256("single-run");
        boardManager.newVar(hash);
        uint256 roundId = boardManager.currentRoundId();
        vm.prank(executor);
        automation.executeDeploys(roundId, 10);

        uint8[] memory emptySquares = new uint8[](0);
        vm.prank(address(boardManager));
        automation.recordRoundResults(roundId, miner, 500, 250, emptySquares);

        assertFalse(automation.hasPendingPayout(miner, roundId));
        (bool hasActive, uint256 activeOrderId) = automation.getActiveOrder(
            miner
        );
        assertFalse(hasActive);
        assertEq(activeOrderId, 0);

        vm.startPrank(miner);
        uint256 secondOrderId = automation.scheduleAutomation(
            Automation.Strategy.Fixed,
            uint8(squares.length),
            turns,
            squares,
            amountPerSquare,
            false
        );
        vm.stopPrank();
        assertEq(secondOrderId, firstOrderId + 1);
    }

    function testOrderRoundResultsPersist() public {
        uint8[] memory squares = new uint8[](1);
        squares[0] = 5;
        uint64 turns = 2;
        uint256 amountPerSquare = 2_500 * 10 ** 6;
        uint256 totalAmount = amountPerSquare * squares.length * turns;
        uint256 totalFee = EXECUTION_FEE * turns;

        vm.startPrank(miner);
        usdc.approve(address(automation), totalAmount + totalFee);
        uint256 orderId = automation.scheduleAutomation(
            Automation.Strategy.Fixed,
            uint8(squares.length),
            turns,
            squares,
            amountPerSquare,
            false
        );
        vm.stopPrank();

        uint256 secret1 = 303;
        boardManager.newVar(keccak256(abi.encodePacked(secret1)));
        uint256 roundId1 = boardManager.currentRoundId();
        vm.prank(executor);
        automation.executeDeploys(roundId1, 10);
        assertTrue(automation.hasPendingPayout(miner, roundId1));
        uint8[] memory emptySquares = new uint8[](0);
        vm.prank(address(boardManager));
        automation.recordRoundResults(roundId1, miner, 100, 50, emptySquares);
        assertFalse(automation.hasPendingPayout(miner, roundId1));
        _finalizeRound(secret1);

        uint256 secret2 = 404;
        boardManager.newVar(keccak256(abi.encodePacked(secret2)));
        uint256 roundId2 = boardManager.currentRoundId();
        vm.prank(executor);
        automation.executeDeploys(roundId2, 10);
        vm.prank(address(boardManager));
        automation.recordRoundResults(roundId2, miner, 200, 75, emptySquares);
        _finalizeRound(secret2);

        (
            uint256[] memory roundIds,
            uint256[] memory amountsWon,
            uint256[] memory tokensEarned
        ) = automation.getOrderRoundResults(orderId);
        assertEq(roundIds.length, 2);
        assertEq(roundIds[0], roundId1);
        assertEq(roundIds[1], roundId2);
        assertEq(amountsWon[0], 100);
        assertEq(amountsWon[1], 200);
        assertEq(tokensEarned[0], 50);
        assertEq(tokensEarned[1], 75);

        (uint256 totalWon, uint256 totalTokens) = automation
            .getOrderRunTotals(orderId);
        assertEq(totalWon, 300);
        assertEq(totalTokens, 125);

        Automation.WalletStats memory walletStats = automation.getWalletStats(
            miner
        );
        assertEq(walletStats.totalExecutions, 2);
        assertEq(
            walletStats.totalAmountSpent,
            amountPerSquare * squares.length * turns
        );
        assertEq(walletStats.totalFeesPaid, totalFee);
        assertEq(walletStats.totalAmountWon, 300);
        assertEq(walletStats.totalTokensReceived, 125);
        assertTrue(walletStats.lastExecutedAt > 0);
    }

    function testSyncRoundQueueMigratesStaleOrders() public {
        // Start a board round so queued orders target it immediately.
        uint256 firstSecret = 111;
        boardManager.newVar(keccak256(abi.encodePacked(firstSecret)));
        vm.startPrank(miner);
        usdc.approve(address(boardManager), 1_000 * 10 ** 6);
        uint8[] memory warmSquares = new uint8[](1);
        warmSquares[0] = 1;
        uint256[] memory warmAmounts = new uint256[](1);
        warmAmounts[0] = 1_000 * 10 ** 6;
        boardManager.deploy(warmSquares, warmAmounts, false);
        vm.stopPrank();

        uint8[] memory squares = new uint8[](1);
        squares[0] = 2;
        uint64 turns = 1;
        uint256 amountPerSquare = 1_000 * 10 ** 6;
        uint256 totalAmount = amountPerSquare * squares.length * turns;
        uint256 totalFee = EXECUTION_FEE * turns;

        vm.startPrank(miner);
        usdc.approve(address(automation), totalAmount + totalFee);
        uint256 orderId = automation.scheduleAutomation(
            Automation.Strategy.Fixed,
            uint8(squares.length),
            turns,
            squares,
            amountPerSquare,
            false
        );
        vm.stopPrank();

        uint256 firstRound = boardManager.currentRoundId();
        _finalizeRound(firstSecret); // Round ends without automation executing, leaving the order stale.

        uint256 nextSecret = 222;
        boardManager.newVar(keccak256(abi.encodePacked(nextSecret)));
        uint256 nextRound = boardManager.currentRoundId();

        vm.prank(executor);
        automation.executeDeploys(nextRound, 10);

        Automation.Order memory orderView = _getOrder(orderId);
        assertEq(orderView.roundsExecuted, 1);
        assertEq(orderView.remainingRounds, 0);
        assertEq(orderView.nextRoundId, 0);
    }

    function testSyncRoundQueueRespectsMigrationCap() public {
        uint256 firstSecret = 333;
        boardManager.newVar(keccak256(abi.encodePacked(firstSecret)));
        vm.startPrank(miner);
        usdc.approve(address(boardManager), 1_000 * 10 ** 6);
        uint8[] memory warmSquares = new uint8[](1);
        warmSquares[0] = 3;
        uint256[] memory warmAmounts = new uint256[](1);
        warmAmounts[0] = 1_000 * 10 ** 6;
        boardManager.deploy(warmSquares, warmAmounts, false);
        vm.stopPrank();

        uint8 turns = 1;
        uint256 amountPerSquare = 500 * 10 ** 6;
        uint256 totalAmount = amountPerSquare;
        uint256 totalFee = EXECUTION_FEE * turns;
        uint256 totalOrders = MAX_SYNC_BATCH + 20;

        for (uint256 i = 0; i < totalOrders; i++) {
            address newMiner = address(uint160(0x1000 + i));
            usdc.transfer(newMiner, totalAmount + totalFee);
            vm.startPrank(newMiner);
            usdc.approve(address(automation), totalAmount + totalFee);
            uint8[] memory squares = new uint8[](1);
            squares[0] = uint8(i % 16);
            automation.scheduleAutomation(
                Automation.Strategy.Fixed,
                uint8(squares.length),
                turns,
                squares,
                amountPerSquare,
                false
            );
            vm.stopPrank();
        }

        _finalizeRound(firstSecret);

        uint256 nextSecret = 444;
        boardManager.newVar(keccak256(abi.encodePacked(nextSecret)));
        uint256 nextRound = boardManager.currentRoundId();

        vm.prank(executor);
        automation.executeDeploys(nextRound, 200);

        uint256 executedFirstRun;
        for (uint256 i = 0; i < totalOrders; i++) {
            Automation.Order memory orderView = _getOrder(i);
            if (orderView.remainingRounds == 0) {
                executedFirstRun += 1;
            }
        }
        assertEq(executedFirstRun, MAX_SYNC_BATCH);
        uint256 pendingAfterFirst = automation.pendingExecutions(nextRound);
        assertEq(pendingAfterFirst, totalOrders - MAX_SYNC_BATCH);

        vm.prank(executor);
        automation.executeDeploys(nextRound, 200);

        for (uint256 i = 0; i < totalOrders; i++) {
            Automation.Order memory orderView = _getOrder(i);
            assertEq(orderView.remainingRounds, 0);
            assertEq(orderView.nextRoundId, 0);
        }
    }

    function _finalizeRound(uint256 secret) internal {
        BoardManager.RoundSummary memory summary = boardManager.getRoundSummary(boardManager.currentRoundId());
        assertEq(uint256(summary.state), uint256(BoardState.Running));
        vm.warp(summary.endTime + 1);
        vm.roll(summary.endBlock + 1);
        boardManager.resetBoard(secret);
    }

    function _startBoardRound() internal returns (uint256 roundId) {
        bytes32 hash = keccak256("round-seed");
        boardManager.newVar(hash);

        vm.startPrank(miner);
        usdc.approve(address(boardManager), 1_000 * 10 ** 6);
        uint8[] memory squares = new uint8[](1);
        squares[0] = 1;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1_000 * 10 ** 6;
        boardManager.deploy(squares, amounts, false);
        vm.stopPrank();

        roundId = boardManager.currentRoundId();
    }

    function _getOrder(
        uint256 orderId
    ) internal view returns (Automation.Order memory order) {
        (
            order.miner,
            order.strategy,
            order.squaresPerRound,
            order.remainingRounds,
            order.amountPerSquare,
            order.nextRoundId,
            order.useReferralCredit,
            order.amountRemaining,
            order.feeBudget,
            order.fixedSquares,
            order.roundsExecuted,
            order.totalDeposited,
            order.totalFeesPaid,
            order.totalAmountWon,
            order.totalTokensReceived,
            order.cancelled
        ) = automation.getOrder(orderId);
    }
}
