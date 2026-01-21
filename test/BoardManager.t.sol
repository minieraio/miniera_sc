// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {Token} from "../src/Token.sol";
import {Vault} from "../src/Vault.sol";
import {Minter} from "../src/Minter.sol";
import {BoardManager, BoardState} from "../src/BoardManager.sol";
import {Airdrop} from "../src/Airdrop.sol";
import {Referral} from "../src/Referral.sol";

contract MockUSDC {
    string public name = "Mock USDC";
    string public symbol = "USDC";
    uint8 public decimals = 6;
    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor() {
        totalSupply = 1_000_000 * 10 ** 6;
        balanceOf[msg.sender] = totalSupply;
        emit Transfer(address(0), msg.sender, totalSupply);
    }

    function transfer(address to, uint256 value) external returns (bool) {
        require(balanceOf[msg.sender] >= value, "MockUSDC: insufficient balance");
        balanceOf[msg.sender] -= value;
        balanceOf[to] += value;
        emit Transfer(msg.sender, to, value);
        return true;
    }

    function approve(address spender, uint256 value) external returns (bool) {
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        require(balanceOf[from] >= value, "MockUSDC: insufficient balance");
        require(allowance[from][msg.sender] >= value, "MockUSDC: insufficient allowance");
        balanceOf[from] -= value;
        balanceOf[to] += value;
        allowance[from][msg.sender] -= value;
        emit Transfer(from, to, value);
        return true;
    }

    function mint(address to, uint256 value) external {
        totalSupply += value;
        balanceOf[to] += value;
        emit Transfer(address(0), to, value);
    }
}

contract BoardManagerTest is Test {
    Token public token;
    MockUSDC public usdc;
    Vault public vault;
    Minter public minter;
    BoardManager public boardManager;
    Airdrop public airdrop;
    Referral public referral;

    address public owner;
    address public user1;
    address public user2;
    address public user3;

    uint256 private constant BASIS_POINTS = 10_000;
    uint256 private constant MIN_DEPOSIT = 100 * 10 ** 6;
    uint256 private constant MAX_PARTICIPANTS = 3;

    // Event declarations for testing
    event RoundCompleted(
        uint256 indexed roundId,
        uint8 indexed winningSquare,
        address[] paymentRecipients,
        uint256[] paymentAmounts,
        address[] tokenRecipients,
        uint256[] tokenAmounts,
        bool airdropTriggered,
        address[] airdropWinners,
        uint256[] airdropAmounts
    );

    function setUp() public {
        owner = address(this);
        user1 = address(0x1);
        user2 = address(0x2);
        user3 = address(0x3);

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
            owner,
            MIN_DEPOSIT,
            MAX_PARTICIPANTS
        );

        airdrop.setBoardManager(address(boardManager));
        referral.setBoardContract(address(boardManager));

        token.transferOwnership(address(minter));
        vault.setMinter(address(minter));
        vault.setBoardContract(address(boardManager));
        minter.setBoardContract(address(boardManager));

        boardManager.setAutomation(address(this));

        usdc.transfer(user1, 10_000 * 10 ** 6);
        usdc.transfer(user2, 10_000 * 10 ** 6);
        usdc.transfer(user3, 10_000 * 10 ** 6);
    }

    function testInitialState() public {
        assertEq(boardManager.owner(), owner);
        assertEq(address(boardManager.paymentToken()), address(usdc));
        assertEq(address(boardManager.minter()), address(minter));
        assertEq(address(boardManager.vault()), address(vault));
        assertEq(address(boardManager.airdrop()), address(airdrop));
        assertEq(boardManager.currentRoundId(), 1);

        BoardManager.RoundSummary memory summary = boardManager.getRoundSummary(1);
        assertEq(summary.id, 1);
        assertEq(uint256(summary.state), uint256(BoardState.Created));
        assertEq(summary.totalDeposited, 0);
    }

    function testNewVarUpdatesSummary() public {
        bytes32 hash = keccak256("entropy");
        boardManager.newVar(hash);

        BoardManager.RoundSummary memory summary = boardManager.getRoundSummary(boardManager.currentRoundId());
        assertEq(summary.varHash, hash);
    }

    function testDeployRecordsAllocation() public {
        bytes32 hash = keccak256("round");
        boardManager.newVar(hash);

        uint8 squareId = 5;
        uint256 amount = 1_000 * 10 ** 6;

        vm.startPrank(user1);
        usdc.approve(address(boardManager), amount);
        uint8[] memory squares = new uint8[](1);
        squares[0] = squareId;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;
        boardManager.deploy(squares, amounts, false);
        vm.stopPrank();

        uint256 roundId = boardManager.currentRoundId();
        assertEq(boardManager.getMinerAllocation(roundId, squareId, user1), amount);
        (uint256 totalAllocated, uint256 participants) = boardManager.getSquareTotals(roundId, squareId);
        assertEq(totalAllocated, amount);
        assertEq(participants, 1);
    }

    function testDeployViaAutomationRecordsAllocation() public {
        bytes32 hash = keccak256("auto");
        boardManager.newVar(hash);

        uint8[] memory squares = new uint8[](1);
        squares[0] = 4;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 500 * 10 ** 6;

        usdc.approve(address(boardManager), amounts[0]);
        boardManager.deployFor(user1, squares, amounts, false);

        uint256 roundId = boardManager.currentRoundId();
        assertEq(boardManager.getMinerAllocation(roundId, squares[0], user1), amounts[0]);
    }

    function testDeployForNonAutomationReverts() public {
        bytes32 hash = keccak256("round");
        boardManager.newVar(hash);

        uint8[] memory squares = new uint8[](1);
        squares[0] = 1;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100 * 10 ** 6;

        vm.expectRevert("BoardManager: caller is not automation");
        vm.prank(user2);
        boardManager.deployFor(user1, squares, amounts, false);
    }

    function testDeployInvalidSquareReverts() public {
        bytes32 hash = keccak256("round");
        boardManager.newVar(hash);

        vm.startPrank(user1);
        usdc.approve(address(boardManager), 100 * 10 ** 6);
        uint8[] memory squares = new uint8[](1);
        squares[0] = 20;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100 * 10 ** 6;
        vm.expectRevert();
        boardManager.deploy(squares, amounts, false);
        vm.stopPrank();
    }

    function testDeployZeroAmountReverts() public {
        bytes32 hash = keccak256("round");
        boardManager.newVar(hash);

        vm.startPrank(user1);
        usdc.approve(address(boardManager), 1);
        uint8[] memory squares = new uint8[](1);
        squares[0] = 2;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 0;
        vm.expectRevert();
        boardManager.deploy(squares, amounts, false);
        vm.stopPrank();
    }

    function testDeployBelowMinimumReverts() public {
        bytes32 hash = keccak256("round");
        boardManager.newVar(hash);

        vm.startPrank(user1);
        usdc.approve(address(boardManager), MIN_DEPOSIT - 1);
        uint8[] memory squares = new uint8[](1);
        squares[0] = 2;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = MIN_DEPOSIT - 1;
        vm.expectRevert("BoardManager: amount below minimum");
        boardManager.deploy(squares, amounts, false);
        vm.stopPrank();
    }

    function testDeployWithoutVarReverts() public {
        vm.startPrank(user1);
        usdc.approve(address(boardManager), 100 * 10 ** 6);
        uint8[] memory squares = new uint8[](1);
        squares[0] = 1;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100 * 10 ** 6;
        vm.expectRevert();
        boardManager.deploy(squares, amounts, false);
        vm.stopPrank();
    }

    function testRoundParticipantLimit() public {
        bytes32 hash = keccak256("limit");
        boardManager.newVar(hash);

        _deployToSquare(user1, 1, MIN_DEPOSIT);
        _deployToSquare(user2, 2, MIN_DEPOSIT);
        _deployToSquare(user3, 3, MIN_DEPOSIT);

        address user4 = address(0x4);
        usdc.transfer(user4, 1_000 * 10 ** 6);
        vm.startPrank(user4);
        usdc.approve(address(boardManager), MIN_DEPOSIT);
        uint8[] memory squares = new uint8[](1);
        squares[0] = 4;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = MIN_DEPOSIT;
        vm.expectRevert("BoardManager: round full");
        boardManager.deploy(squares, amounts, false);
        vm.stopPrank();
    }

    function testResetBoardDistributesFunds() public {
        uint256 roundId = boardManager.currentRoundId();
        uint256 secret = 7_777;
        bytes32 hash = keccak256(abi.encodePacked(secret));
        boardManager.newVar(hash);

        uint256 amount1 = 1_000 * 10 ** 6;
        uint256 amount2 = 500 * 10 ** 6;

        _deployToSquare(user1, 3, amount1);
        _deployToSquare(user2, 7, amount2);

        BoardManager.RoundSummary memory summary = boardManager.getRoundSummary(roundId);
        uint256 warpTime = summary.endTime + 5;
        uint256 probability = boardManager.AIRDROP_TRIGGER_PROBABILITY();
        if (warpTime % probability == 0) {
            warpTime += 1;
        }
        vm.warp(warpTime);
        vm.roll(summary.endBlock + 5);

        uint256 vaultBalanceBefore = usdc.balanceOf(address(vault));
        uint256 ownerBalanceBefore = usdc.balanceOf(owner);

        boardManager.resetBoard(secret);

        assertEq(boardManager.currentRoundId(), roundId + 1);
        BoardManager.RoundSummary memory ended = boardManager.getRoundSummary(roundId);
        assertEq(uint256(ended.state), uint256(BoardState.Ended));
        assertEq(ended.totalDeposited, amount1 + amount2);
        assertGt(ended.totalMintedTokens, 0);
        assertGt(airdrop.currentBalance(), 0);

        uint256 totalDeposited = amount1 + amount2;

        uint256 expectedVault =
            (totalDeposited * boardManager.VAULT_SHARE()) / BASIS_POINTS;
        uint256 expectedFees =
            (totalDeposited * boardManager.PROTOCOL_FEES()) / BASIS_POINTS;

        assertGe(usdc.balanceOf(address(vault)) - vaultBalanceBefore, expectedVault);
        assertEq(usdc.balanceOf(owner) - ownerBalanceBefore, expectedFees);
        assertEq(usdc.balanceOf(address(boardManager)), 0);
    }

    function testReferralFeeDistribution() public {
        // user2 refers user1
        vm.prank(user1);
        referral.setReferredBy(user2);

        bytes32 hash = keccak256("round");
        boardManager.newVar(hash);

        uint256 depositAmount = 1_000 * 10 ** 6;
        uint256 expectedReferralFee = (depositAmount * boardManager.REFERRAL_FEE_PERCENTAGE()) / BASIS_POINTS;

        vm.startPrank(user1);
        usdc.approve(address(boardManager), depositAmount);
        uint8[] memory squares = new uint8[](1);
        squares[0] = 5;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = depositAmount;
        boardManager.deploy(squares, amounts, false);
        vm.stopPrank();

        // Check that user2 (referrer) received referral credit
        assertEq(referral.getReferralCredit(user2), expectedReferralFee);
        // Depositor also receives 1% cashback
        uint256 expectedCashback = (depositAmount *
            boardManager.SELF_REFERRAL_CASHBACK_PERCENTAGE()) / BASIS_POINTS;
        assertEq(referral.getReferralCredit(user1), expectedCashback);
    }

    function testReferralFeeKeptForMintingWhenNoReferrer() public {
        bytes32 hash = keccak256("round");
        boardManager.newVar(hash);

        uint256 depositAmount = 1_000 * 10 ** 6;
        uint256 boardBalanceBefore = usdc.balanceOf(address(boardManager));

        vm.startPrank(user1);
        usdc.approve(address(boardManager), depositAmount);
        uint8[] memory squares = new uint8[](1);
        squares[0] = 5;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = depositAmount;
        boardManager.deploy(squares, amounts, false);
        vm.stopPrank();

        assertEq(
            usdc.balanceOf(address(boardManager)) - boardBalanceBefore,
            depositAmount
        );
        assertEq(referral.getReferralCredit(user1), 0);
    }

    function testUseReferralCredit() public {
        // user2 refers user1, user1 makes a deposit to build credit for user2
        vm.prank(user1);
        referral.setReferredBy(user2);

        bytes32 hash = keccak256("round");
        boardManager.newVar(hash);

        uint256 firstDeposit = 1_000 * 10 ** 6;
        vm.startPrank(user1);
        usdc.approve(address(boardManager), firstDeposit);
        uint8[] memory squares = new uint8[](1);
        squares[0] = 5;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = firstDeposit;
        boardManager.deploy(squares, amounts, false);
        vm.stopPrank();

        uint256 user2Credit = referral.getReferralCredit(user2);
        assertGt(user2Credit, 0);

        // user2 uses referral credit for their deposit
        uint256 secondDeposit = 500 * 10 ** 6;
        uint256 user2BalanceBefore = usdc.balanceOf(user2);

        vm.startPrank(user2);
        usdc.approve(address(boardManager), secondDeposit);
        uint8[] memory squares2 = new uint8[](1);
        squares2[0] = 3;
        uint256[] memory amounts2 = new uint256[](1);
        amounts2[0] = secondDeposit;
        boardManager.deploy(squares2, amounts2, true);
        vm.stopPrank();

        // Check that user2 used credit (should pay less from wallet)
        uint256 expectedCreditUsed = user2Credit < secondDeposit ? user2Credit : secondDeposit;
        uint256 expectedPayment = secondDeposit - expectedCreditUsed;
        assertEq(user2BalanceBefore - usdc.balanceOf(user2), expectedPayment);
        // User2 does not earn cashback without setting a referrer
        assertEq(referral.getReferralCredit(user2), user2Credit - expectedCreditUsed);
    }

    function testNoCashbackWithoutReferrer() public {
        bytes32 hash = keccak256("round");
        boardManager.newVar(hash);

        uint256 depositAmount = 2_000 * 10 ** 6;
        vm.startPrank(user1);
        usdc.approve(address(boardManager), depositAmount);
        uint8[] memory squares = new uint8[](1);
        squares[0] = 8;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = depositAmount;
        boardManager.deploy(squares, amounts, false);
        vm.stopPrank();

        // No referrer set, so no cashback should accrue
        assertEq(referral.getReferralCredit(user1), 0);
    }

    function testSetVarSetter() public {
        address newVarSetter = address(0x999);
        boardManager.setVarSetter(newVarSetter);
        assertEq(boardManager.varSetter(), newVarSetter);
    }

    function testSetVarSetterOnlyOwner() public {
        address newVarSetter = address(0x999);
        vm.prank(user1);
        vm.expectRevert();
        boardManager.setVarSetter(newVarSetter);
    }

    function testVarSetterCanCallNewVar() public {
        address varSetter = address(0x999);
        boardManager.setVarSetter(varSetter);

        bytes32 hash = keccak256("test");
        vm.prank(varSetter);
        boardManager.newVar(hash);

        BoardManager.RoundSummary memory summary = boardManager.getRoundSummary(boardManager.currentRoundId());
        assertEq(summary.varHash, hash);
    }

    function testNonVarSetterCannotCallNewVar() public {
        bytes32 hash = keccak256("test");
        vm.prank(user1);
        vm.expectRevert();
        boardManager.newVar(hash);
    }

    function testOwnerCanStillCallNewVar() public {
        address varSetter = address(0x999);
        boardManager.setVarSetter(varSetter);

        bytes32 hash = keccak256("test");
        boardManager.newVar(hash);

        BoardManager.RoundSummary memory summary = boardManager.getRoundSummary(boardManager.currentRoundId());
        assertEq(summary.varHash, hash);
    }

    function testRoundResultsAvailableAfterReset() public {
        uint256 roundId = boardManager.currentRoundId();
        uint256 secret = 7_777;
        bytes32 hash = keccak256(abi.encodePacked(secret));
        boardManager.newVar(hash);

        uint256 amount1 = 1_000 * 10 ** 6;
        uint256 amount2 = 500 * 10 ** 6;

        _deployToSquare(user1, 3, amount1);
        _deployToSquare(user2, 7, amount2);

        BoardManager.RoundSummary memory summary = boardManager.getRoundSummary(roundId);
        uint256 warpTime = summary.endTime + 5;
        uint256 probability = boardManager.AIRDROP_TRIGGER_PROBABILITY();
        if (warpTime % probability == 0) {
            warpTime += 1;
        }
        vm.warp(warpTime);
        vm.roll(summary.endBlock + 5);

        boardManager.resetBoard(secret);

        // After reset, results should be available
        BoardManager.RoundResults memory results = boardManager.getLastRoundResults();
        assertEq(results.roundId, roundId);
        // Token recipients should always be present (even if payment recipients is 0 if winning square was empty)
        assertGt(results.tokenRecipients.length, 0);
        assertEq(results.paymentRecipients.length, results.paymentAmounts.length);
        assertEq(results.tokenRecipients.length, results.tokenAmounts.length);
    }

    function testRoundResultsClearedAfterNewRoundStarts() public {
        uint256 roundId = boardManager.currentRoundId();
        uint256 secret = 7_777;
        bytes32 hash = keccak256(abi.encodePacked(secret));
        boardManager.newVar(hash);

        uint256 amount = 1_000 * 10 ** 6;
        _deployToSquare(user1, 3, amount);

        BoardManager.RoundSummary memory summary = boardManager.getRoundSummary(roundId);
        uint256 warpTime = summary.endTime + 5;
        uint256 probability = boardManager.AIRDROP_TRIGGER_PROBABILITY();
        if (warpTime % probability == 0) {
            warpTime += 1;
        }
        vm.warp(warpTime);
        vm.roll(summary.endBlock + 5);

        boardManager.resetBoard(secret);

        // Results should be available after reset
        BoardManager.RoundResults memory results = boardManager.getLastRoundResults();
        assertEq(results.roundId, roundId);

        // Start new round by setting var and making deposit
        bytes32 newHash = keccak256(abi.encodePacked(uint256(8_888)));
        boardManager.newVar(newHash);
        _deployToSquare(user1, 5, amount);

        // Results should be cleared
        BoardManager.RoundResults memory clearedResults = boardManager.getLastRoundResults();
        assertEq(clearedResults.roundId, 0);
        assertEq(clearedResults.paymentRecipients.length, 0);
        assertEq(clearedResults.tokenRecipients.length, 0);
    }

    function testRoundCompletedEventEmitted() public {
        uint256 roundId = boardManager.currentRoundId();
        uint256 secret = 7_777;
        bytes32 hash = keccak256(abi.encodePacked(secret));
        boardManager.newVar(hash);

        uint256 amount = 1_000 * 10 ** 6;
        _deployToSquare(user1, 3, amount);

        BoardManager.RoundSummary memory summary = boardManager.getRoundSummary(roundId);
        uint256 warpTime = summary.endTime + 5;
        uint256 probability = boardManager.AIRDROP_TRIGGER_PROBABILITY();
        if (warpTime % probability == 0) {
            warpTime += 1;
        }
        vm.warp(warpTime);
        vm.roll(summary.endBlock + 5);

        // Expect RoundCompleted event to be emitted
        vm.recordLogs();
        boardManager.resetBoard(secret);

        // Verify event was emitted by checking logs
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bool foundRoundCompletedEvent = false;
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].topics[0] == keccak256("RoundCompleted(uint256,uint8,address[],uint256[],address[],uint256[],bool,address[],uint256[])")) {
                foundRoundCompletedEvent = true;
                break;
            }
        }
        assertTrue(foundRoundCompletedEvent, "RoundCompleted event not emitted");
    }

    function testSetMaxStoredRoundsOnlyOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        boardManager.setMaxStoredRounds(2);
    }

    function testSetMaxStoredRoundsRejectsZero() public {
        vm.expectRevert("BoardManager: invalid max stored rounds");
        boardManager.setMaxStoredRounds(0);
    }

    function testPruneOnResetBoardKeepsLatestRounds() public {
        boardManager.setMaxStoredRounds(2);

        _completeRound(111, user1, 1, MIN_DEPOSIT);
        _completeRound(222, user1, 2, MIN_DEPOSIT);

        vm.expectRevert("BoardManager: invalid round");
        boardManager.getRoundSummary(1);

        BoardManager.RoundSummary memory summary = boardManager.getRoundSummary(2);
        assertEq(summary.id, 2);
    }

    function testPruneOnSetMaxStoredRounds() public {
        _completeRound(333, user1, 1, MIN_DEPOSIT);
        _completeRound(444, user1, 2, MIN_DEPOSIT);
        _completeRound(555, user1, 3, MIN_DEPOSIT);
        _completeRound(666, user1, 4, MIN_DEPOSIT);

        boardManager.setMaxStoredRounds(2);

        vm.expectRevert("BoardManager: invalid round");
        boardManager.getRoundSummary(3);

        BoardManager.RoundSummary memory summary = boardManager.getRoundSummary(4);
        assertEq(summary.id, 4);
    }

    function testPruneMultipleRoundsWhenLimitLowered() public {
        _completeRound(111, user1, 1, MIN_DEPOSIT);
        _completeRound(222, user1, 2, MIN_DEPOSIT);
        _completeRound(333, user1, 3, MIN_DEPOSIT);
        _completeRound(444, user1, 4, MIN_DEPOSIT);
        _completeRound(555, user1, 5, MIN_DEPOSIT);

        boardManager.setMaxStoredRounds(2);

        vm.expectRevert("BoardManager: invalid round");
        boardManager.getRoundSummary(1);
        vm.expectRevert("BoardManager: invalid round");
        boardManager.getRoundSummary(2);
        vm.expectRevert("BoardManager: invalid round");
        boardManager.getRoundSummary(3);
        vm.expectRevert("BoardManager: invalid round");
        boardManager.getRoundSummary(4);

        BoardManager.RoundSummary memory round5 = boardManager.getRoundSummary(5);
        assertEq(round5.id, 5);
        assertEq(boardManager.oldestStoredRound(), 5);
    }

    function testNoPruneWhenLimitIncreases() public {
        _completeRound(111, user1, 1, MIN_DEPOSIT);
        _completeRound(222, user1, 2, MIN_DEPOSIT);
        _completeRound(333, user1, 3, MIN_DEPOSIT);

        boardManager.setMaxStoredRounds(10);

        BoardManager.RoundSummary memory round1 = boardManager.getRoundSummary(1);
        BoardManager.RoundSummary memory round2 = boardManager.getRoundSummary(2);
        BoardManager.RoundSummary memory round3 = boardManager.getRoundSummary(3);
        assertEq(round1.id, 1);
        assertEq(round2.id, 2);
        assertEq(round3.id, 3);
        assertEq(boardManager.oldestStoredRound(), 1);
    }

    function testOldestStoredRoundTracksResetPruning() public {
        boardManager.setMaxStoredRounds(2);

        _completeRound(111, user1, 1, MIN_DEPOSIT);
        assertEq(boardManager.oldestStoredRound(), 1);

        _completeRound(222, user1, 2, MIN_DEPOSIT);
        assertEq(boardManager.oldestStoredRound(), 2);

        _completeRound(333, user1, 3, MIN_DEPOSIT);
        assertEq(boardManager.oldestStoredRound(), 3);
    }

    function _deployToSquare(address miner, uint8 squareId, uint256 amount) internal {
        vm.startPrank(miner);
        usdc.approve(address(boardManager), amount);
        uint8[] memory squares = new uint8[](1);
        squares[0] = squareId;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;
        boardManager.deploy(squares, amounts, false);
        vm.stopPrank();
    }

    function _completeRound(uint256 secret, address miner, uint8 squareId, uint256 amount) internal {
        uint256 roundId = boardManager.currentRoundId();
        bytes32 hash = keccak256(abi.encodePacked(secret));
        boardManager.newVar(hash);

        _deployToSquare(miner, squareId, amount);

        BoardManager.RoundSummary memory summary = boardManager.getRoundSummary(roundId);
        uint256 warpTime = summary.endTime + 5;
        uint256 probability = boardManager.AIRDROP_TRIGGER_PROBABILITY();
        if (warpTime % probability == 0) {
            warpTime += 1;
        }
        vm.warp(warpTime);
        vm.roll(summary.endBlock + 5);

        boardManager.resetBoard(secret);
    }
}
