// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IMinter {
    function mintFromCollateral(
        uint256 collateralAmount,
        address[] calldata recipients,
        uint256[] calldata shareUnits,
        uint256 totalShareUnits
    )
        external
        returns (
            uint256[] memory mintedAmounts,
            uint256 mintedTokens,
            uint256 collateralUsed
        );
}

interface IVault {
    function receivePaymentAmount(uint256 amount) external;
}

interface IAirdrop {
    function currentBalance() external view returns (uint256);
    function payout(address winner) external returns (uint256);
    function payoutMultiple(
        address[] calldata winners,
        uint256[] calldata allocations
    ) external returns (uint256);
}

interface IReferral {
    function getReferrer(address referred) external view returns (address);
    function collectReferralCredit(
        address user,
        uint256 requestedAmount
    ) external returns (uint256);
    function addReferralCredit(address referrer, uint256 amount) external;
}

interface IAutomation {
    function recordRoundResults(
        uint256 roundId,
        address miner,
        uint256 amountWon,
        uint256 tokensReceived,
        uint8[] calldata squares
    ) external;

    function hasPendingPayout(
        address miner,
        uint256 roundId
    ) external view returns (bool);
}

enum BoardState { Created, Running, Ended }

contract BoardManager is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 private constant BASIS_POINTS = 10_000;
    uint8 public constant SQUARES_COUNT = 16;
    uint256 private constant TOKEN_SHARE_SCALE = 1e18; // precision for proportional token distribution
    uint256 private constant TOTAL_TOKEN_SHARE_UNITS = BASIS_POINTS * TOKEN_SHARE_SCALE;

    // ========= Fee Distribution Percentages (in basis points) =========
    uint256 public constant WINNING_SQUARE_PAYMENT_SHARE = 4_500; // 45%
    uint256 public constant VAULT_SHARE = 5_400; // 54%
    uint256 public constant PROTOCOL_FEES = 100; // 1%
    uint256 public constant REFERRAL_FEE_PERCENTAGE = 500; // 5%
    uint256 public constant SELF_REFERRAL_CASHBACK_PERCENTAGE = 200; // 2%

    uint256 public constant WINNING_SQUARE_TOKEN_SHARE = 7_500; // 75%
    uint256 public constant OTHER_SQUARES_TOKEN_SHARE = 100; // 1% per non-winning square
    uint256 public constant AIRDROP_TOKEN_SHARE = 1_000; // 10%

    uint256 public constant AIRDROP_TRIGGER_PROBABILITY = 480; // ~1 in 480 rounds (2x per day average)
    uint64 public constant ACTIVE_PHASE_DURATION = 60; // seconds
    uint64 public constant COOLDOWN_PHASE_DURATION = 30; // seconds
    uint64 public constant ROUND_BLOCK_SPAN = 30; // approx. blocks for a round

    struct Square {
        uint256 totalDeposited;
        address[] participants;
        mapping(address => uint256) allocations;
    }

    struct Round {
        // Lifecycle metadata for the round window (block-based and wall clock)
        uint256 id;
        uint64 startBlock;
        uint64 endBlock;
        uint64 startTime;
        uint64 activeUntil;
        uint64 endTime;
        // Randomness commitment / reveal inputs for deciding winners
        bytes32 varHash;
        uint256 varValue;
        bytes32 blockHash;
        // High-level status and aggregated accounting for deposits and mints
        BoardState state;
        uint256 totalDeposited;
        uint256 totalMintedTokens;
        uint256 uniqueParticipants;
        // Per-participant and per-square tracking to prevent duplicates and pay out
        mapping(address => bool) hasParticipated;
        mapping(uint8 => Square) squares;
    }

    struct RoundSummary {
        uint256 id; // round identifier usable in external views
        uint64 startBlock; // block round was scheduled to start at
        uint64 endBlock; // block round was scheduled to end at
        uint64 startTime; // timestamp when active phase began
        uint64 activeUntil; // timestamp when active phase expires
        uint64 endTime; // timestamp when round finalized
        bytes32 varHash; // commitment hash for randomness reveal
        bytes32 blockHash; // block hash used in randomness mix
        uint256 varValue; // revealed randomness value
        BoardState state; // current status of round life cycle
        uint256 totalDeposited; // aggregate deposits across squares
        uint256 totalMintedTokens; // total tokens minted from deposits
    }

    struct RoundResults {
        uint256 roundId; // round identifier for linking with history
        uint8 winningSquare; // index of square selected as winner
        address[] paymentRecipients; // miners receiving payment token payouts
        uint256[] paymentAmounts; // per-recipient payment token amounts
        address[] tokenRecipients; // miners receiving protocol token payouts
        uint256[] tokenAmounts; // per-recipient protocol token amounts
        bool airdropTriggered; // whether the random airdrop fired
        address[] airdropWinners; // addresses that received the airdrop
        uint256[] airdropAmounts; // corresponding airdrop payout amounts
    }

    IERC20 public immutable paymentToken; // asset used for miner deposits
    IMinter public minter;
    IVault public vault;
    IAirdrop public airdrop;
    IReferral public referral;
    address public feeCollector;
    address public varSetter;
    address public automation;

    uint256 public currentRoundId;
    RoundResults private lastRoundResults;
    uint256 public maxStoredRounds;
    uint256 public oldestStoredRound;

    mapping(uint256 => Round) private rounds;

    event RoundInitialized(uint256 indexed roundId);
    event VarCommitted(
        uint256 indexed roundId,
        bytes32 indexed hash,
        address indexed setter
    );
    event VarSetterUpdated(address indexed newVarSetter);
    event RoundStarted(
        uint256 indexed roundId,
        uint64 startBlock,
        uint64 endBlock
    );
    event Deposited(
        uint256 indexed roundId,
        uint8 indexed squareId,
        address indexed miner,
        uint256 amount
    );
    event RoundFinalized(
        uint256 indexed roundId,
        uint8 indexed winningSquare,
        uint256 totalDeposits,
        uint256 mintedTokens
    );
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
    event AirdropWon(
        uint256 indexed roundId,
        address indexed winner,
        uint256 amount
    );
    event VaultUpdated(address indexed newVault);
    event MinterUpdated(address indexed newMinter);
    event AirdropUpdated(address indexed newAirdrop);
    event ReferralUpdated(address indexed newReferral);
    event FeeCollectorUpdated(address indexed newFeeCollector);
    event ReferralCreditUsed(address indexed user, uint256 amount);
    event ReferralFeeDistributed(
        address indexed depositor,
        address indexed referrer,
        uint256 amount
    );
    event SelfReferralCashback(address indexed depositor, uint256 amount);
    event AutomationUpdated(address indexed newAutomation);
    event RoundPruned(uint256 indexed roundId);
    event MaxStoredRoundsUpdated(uint256 indexed newLimit);

    uint256 public immutable minDepositPerAllocation;
    uint256 public immutable maxParticipantsPerRound;

    constructor(
        address _paymentToken,
        address _minter,
        address _vault,
        address _airdrop,
        address _referral,
        address _feeCollector,
        uint256 _minDepositPerAllocation,
        uint256 _maxParticipantsPerRound
    ) Ownable(msg.sender) {
        require(
            _paymentToken != address(0),
            "BoardManager: payment token required"
        );
        require(_minter != address(0), "BoardManager: minter required");
        require(_vault != address(0), "BoardManager: vault required");
        require(_airdrop != address(0), "BoardManager: airdrop required");
        require(
            _minDepositPerAllocation > 0,
            "BoardManager: minimum deposit required"
        );
        require(
            _maxParticipantsPerRound > 0,
            "BoardManager: max participants required"
        );

        paymentToken = IERC20(_paymentToken);
        minter = IMinter(_minter);
        vault = IVault(_vault);
        airdrop = IAirdrop(_airdrop);
        referral = IReferral(_referral);
        feeCollector = _feeCollector == address(0) ? msg.sender : _feeCollector;
        minDepositPerAllocation = _minDepositPerAllocation;
        maxParticipantsPerRound = _maxParticipantsPerRound;

        currentRoundId = 1;
        maxStoredRounds = 5000;
        oldestStoredRound = currentRoundId;
        _bootstrapRound(currentRoundId);
    }

    // ========= External actions =========

    modifier onlyOwnerOrVarSetter() {
        require(
            msg.sender == owner() || msg.sender == varSetter,
            "BoardManager: caller is not owner or varSetter"
        );
        _;
    }

    modifier onlyAutomation() {
        require(
            msg.sender == automation,
            "BoardManager: caller is not automation"
        );
        _;
    }

    /**
     * @notice Commits a hash of the random variable for the current round
     * @dev This implements a commit-reveal scheme for provably fair randomness.
     *      The hash is committed before the round starts, then revealed after it ends.
     *      Only owner or designated varSetter can call this.
     * @param hash The keccak256 hash of the random variable to be revealed later
     */
    function newVar(bytes32 hash) external onlyOwnerOrVarSetter {
        require(hash != bytes32(0), "BoardManager: invalid var hash");
        Round storage round = rounds[currentRoundId];
        require(
            round.state == BoardState.Created,
            "BoardManager: round already running"
        );

        round.varHash = hash; // commit the upcoming entropy anchor
        emit VarCommitted(round.id, hash, msg.sender);
    }

    /**
     * @notice Allows miners to deposit payment tokens into one or more squares
     * @dev Main entry point for participating in MINB mining. Miners select squares and deposit amounts.
     *      The first deposit automatically starts the round timer. Miners can use accumulated referral
     *      credits to reduce their payment. If the miner has a referrer, 4% of their deposit is credited
     *      to the referrer for future use.
     *
     * @param squareIds Array of square IDs (0-15) to deposit into
     * @param amounts Array of payment token amounts corresponding to each square
     * @param useReferralCredit If true, attempts to use miner's accumulated referral credits
     *
     * Flow:
     * 1. Validates inputs and round state
     * 2. Starts round if this is the first deposit
     * 3. Calculates total deposit amount
     * 4. Applies referral credits if requested (reduces amount to pay)
     * 5. Transfers remaining payment from user
     * 6. If user has referrer, sends 4% referral fee to referral contract
     * 7. Allocates deposits to selected squares
     */
    function deploy(
        uint8[] calldata squareIds,
        uint256[] calldata amounts,
        bool useReferralCredit
    ) external nonReentrant {
        _deploy(msg.sender, squareIds, amounts, useReferralCredit);
    }

    function deployFor(
        address miner,
        uint8[] calldata squareIds,
        uint256[] calldata amounts,
        bool useReferralCredit
    ) external nonReentrant onlyAutomation {
        require(miner != address(0), "BoardManager: invalid miner");
        _deploy(miner, squareIds, amounts, useReferralCredit);
    }

    /**
     * @notice Finalizes the current round by revealing the random variable and distributing rewards
     * @dev This is the reveal phase of the commit-reveal scheme. Anyone can call this once the
     *      round has ended and cooled down. The function:
     *      1. Verifies the revealed variable matches the committed hash
     *      2. Determines the winning square using verifiable randomness
     *      3. Distributes payment tokens (45% to winners, 54% to vault, 1% protocol)
     *      4. Mints and distributes MINB tokens (75% winners, 15% losers, 10% airdrop)
     *      5. Potentially triggers airdrop distribution
     *      6. Prepares the next round
     *
     * @param revealedVar The random variable that was hashed in newVar() (must match committed hash)
     *
     * Randomness: Combines revealedVar + block hash + round ID to determine winner
     * Payment Distribution: 45% winners | 54% vault | 1% protocol
     * Token Distribution: 75% winning square | 15% other squares (1% each) | 10% airdrop
     */
    function resetBoard(uint256 revealedVar) external nonReentrant {
        Round storage round = rounds[currentRoundId];
        require(
            round.state == BoardState.Running,
            "BoardManager: round not running"
        );
        require(
            block.timestamp >= round.endTime,
            "BoardManager: round cooling down"
        );
        require(
            block.number > round.endBlock,
            "BoardManager: block window not closed"
        );
        require(round.totalDeposited > 0, "BoardManager: no deposits");
        require(round.varHash != bytes32(0), "BoardManager: var not set");
        require(revealedVar != 0, "BoardManager: invalid var");
        require(
            keccak256(abi.encodePacked(revealedVar)) == round.varHash,
            "BoardManager: wrong reveal"
        );

        round.varValue = revealedVar;

        // Get block hash for randomness (use endBlock, fallback to recent block)
        bytes32 roundBlockHash = blockhash(round.endBlock);
        if (roundBlockHash == bytes32(0)) {
            roundBlockHash = blockhash(block.number - 1);
        }
        require(
            roundBlockHash != bytes32(0),
            "BoardManager: blockhash unavailable"
        );
        round.blockHash = roundBlockHash;

        // Determine winning square using verifiable randomness
        uint8 winningSquare = uint8(
            uint256(
                keccak256(
                    abi.encodePacked(revealedVar, roundBlockHash, round.id)
                )
            ) % SQUARES_COUNT
        );

        uint256 totalDeposits = round.totalDeposited;
        // Use actual balance (referral fees were already sent out during deposits)
        uint256 availableAmount = paymentToken.balanceOf(address(this));

        // Calculate payment token distributions (45% winners, 54% vault, 1% protocol)
        uint256 paymentForWinners = (availableAmount *
            WINNING_SQUARE_PAYMENT_SHARE) / BASIS_POINTS;
        uint256 paymentForVault = (availableAmount * VAULT_SHARE) /
            BASIS_POINTS;
        uint256 protocolCut = availableAmount -
            paymentForWinners -
            paymentForVault;

        // Distribute payments to mined square participants (proportional to their stakes)
        (
            uint256 paidToWinners,
            address[] memory paymentRecipients,
            uint256[] memory paymentAmounts
        ) = _payMinedSquare(round, winningSquare, paymentForWinners);
        // If mined square had no participants, redirect to vault
        if (paymentForWinners > paidToWinners) {
            paymentForVault += (paymentForWinners - paidToWinners);
        }

        // Send backing to vault (will be used to collateralize minted tokens)
        // Protocol fees leave immediately
        if (protocolCut > 0) {
            paymentToken.safeTransfer(feeCollector, protocolCut);
        }

        (
            address[] memory tokenRecipients,
            uint256[] memory tokenAmounts,
            uint256 mintedTokens,
            uint256 collateralUsedForMint
        ) = _mintRoundTokens(round, winningSquare, paymentForVault);
        round.totalMintedTokens = mintedTokens;

        if (paymentForVault > collateralUsedForMint) {
            uint256 remainder = paymentForVault - collateralUsedForMint;
            paymentToken.safeTransfer(address(vault), remainder);
            vault.receivePaymentAmount(remainder);
        }

        bytes32 randomnessSeed = keccak256(
            abi.encodePacked(
                revealedVar,
                roundBlockHash,
                round.id,
                totalDeposits,
                mintedTokens
            )
        );
        (
            bool airdropTriggered,
            address[] memory airdropWinners,
            uint256[] memory airdropAmounts
        ) = _maybePayAirdrop(round, winningSquare, randomnessSeed);

        // Store results for frontend retrieval
        lastRoundResults.roundId = round.id;
        lastRoundResults.winningSquare = winningSquare;
        lastRoundResults.paymentRecipients = paymentRecipients;
        lastRoundResults.paymentAmounts = paymentAmounts;
        lastRoundResults.tokenRecipients = tokenRecipients;
        lastRoundResults.tokenAmounts = tokenAmounts;
        lastRoundResults.airdropTriggered = airdropTriggered;
        lastRoundResults.airdropWinners = airdropWinners;
        lastRoundResults.airdropAmounts = airdropAmounts;

        round.state = BoardState.Ended;
        emit RoundFinalized(
            round.id,
            winningSquare,
            totalDeposits,
            mintedTokens
        );
        emit RoundCompleted(
            round.id,
            winningSquare,
            paymentRecipients,
            paymentAmounts,
            tokenRecipients,
            tokenAmounts,
            airdropTriggered,
            airdropWinners,
            airdropAmounts
        );

        if (address(automation) != address(0)) {
            IAutomation automationContract = IAutomation(automation);
            for (uint8 squareIndex = 0; squareIndex < SQUARES_COUNT; squareIndex++) {
                Square storage square = round.squares[squareIndex];
                address[] storage participants = square.participants;
                uint256 participantCount = participants.length;
                for (uint256 i = 0; i < participantCount; i++) {
                    address participant = participants[i];
                    bool pending;
                    try automationContract.hasPendingPayout(
                        participant,
                        round.id
                    ) returns (bool result) {
                        pending = result;
                    } catch {
                        continue;
                    }
                    if (!pending) {
                        continue;
                    }

                    uint8[] memory participantSquares = _collectParticipantSquares(
                        round,
                        participant
                    );
                    uint256 amountWon = _collectRecipientTotal(
                        participant,
                        paymentRecipients,
                        paymentAmounts
                    );
                    uint256 tokensReceived = _collectRecipientTotal(
                        participant,
                        tokenRecipients,
                        tokenAmounts
                    );

                    automationContract.recordRoundResults(
                        round.id,
                        participant,
                        amountWon,
                        tokensReceived,
                        participantSquares
                    );
                }
            }
        }

        currentRoundId += 1;
        _bootstrapRound(currentRoundId);
        _pruneOldRounds();
    }

    // ========= Admin setters =========

    function setVault(address _vault) external onlyOwner {
        require(_vault != address(0), "BoardManager: vault cannot be zero");
        vault = IVault(_vault);
        emit VaultUpdated(_vault); // keep track of payout destination updates
    }

    function setMinter(address _minter) external onlyOwner {
        require(_minter != address(0), "BoardManager: minter cannot be zero");
        minter = IMinter(_minter);
        emit MinterUpdated(_minter); // board admin rotated minting authority
    }

    function setFeeCollector(address _feeCollector) external onlyOwner {
        require(
            _feeCollector != address(0),
            "BoardManager: fee collector cannot be zero"
        );
        feeCollector = _feeCollector;
        emit FeeCollectorUpdated(_feeCollector); // protocol fees now flow elsewhere
    }

    function setVarSetter(address _varSetter) external onlyOwner {
        varSetter = _varSetter;
        emit VarSetterUpdated(_varSetter);
    }

    function setAirdrop(address _airdrop) external onlyOwner {
        require(_airdrop != address(0), "BoardManager: airdrop cannot be zero");
        airdrop = IAirdrop(_airdrop);
        emit AirdropUpdated(_airdrop); // keep airdrop address auditable
    }

    function setReferral(address _referral) external onlyOwner {
        referral = IReferral(_referral);
        emit ReferralUpdated(_referral);
    }

    function setAutomation(address _automation) external onlyOwner {
        require(
            _automation != address(0),
            "BoardManager: automation cannot be zero"
        );
        automation = _automation;
        emit AutomationUpdated(_automation);
    }

    function setMaxStoredRounds(uint256 newLimit) external onlyOwner {
        require(newLimit > 0, "BoardManager: invalid max stored rounds");
        maxStoredRounds = newLimit;
        emit MaxStoredRoundsUpdated(newLimit);
        _pruneOldRounds();
    }

    // ========= Views =========

    function getLastRoundResults() external view returns (RoundResults memory) {
        return lastRoundResults;
    }

    function getRoundSummary(uint256 roundId) external view returns (RoundSummary memory) {
        Round storage round = rounds[roundId];
        require(
            round.id == roundId && round.id != 0,
            "BoardManager: invalid round"
        );
        return
            RoundSummary({
                id: round.id,
                startBlock: round.startBlock,
                endBlock: round.endBlock,
                startTime: round.startTime,
                activeUntil: round.activeUntil,
                endTime: round.endTime,
                varHash: round.varHash,
                blockHash: round.blockHash,
                varValue: round.varValue,
                state: round.state,
                totalDeposited: round.totalDeposited,
                totalMintedTokens: round.totalMintedTokens
            });
    }

    function getSquareTotals(uint256 roundId, uint8 squareId) external view returns (uint256 totalAllocated, uint256 participantCount) {
        require(squareId < SQUARES_COUNT, "BoardManager: invalid square");
        Round storage round = rounds[roundId];
        require(
            round.id == roundId && round.id != 0,
            "BoardManager: invalid round"
        );
        Square storage square = round.squares[squareId];
        return (square.totalDeposited, square.participants.length);
    }

    function getSquareAllocations(uint256 roundId,uint8 squareId) external view returns (address[] memory participants, uint256[] memory allocations) {
        require(squareId < SQUARES_COUNT, "BoardManager: invalid square");
        Round storage round = rounds[roundId];
        require(
            round.id == roundId && round.id != 0,
            "BoardManager: invalid round"
        );

        Square storage square = round.squares[squareId];
        uint256 length = square.participants.length;
        participants = new address[](length);
        allocations = new uint256[](length);
        for (uint256 i = 0; i < length; i++) {
            address participant = square.participants[i];
            participants[i] = participant;
            allocations[i] = square.allocations[participant];
        }
    }

    function getMinerAllocation( uint256 roundId, uint8 squareId, address miner) external view returns (uint256) {
        require(squareId < SQUARES_COUNT, "BoardManager: invalid square");
        Round storage round = rounds[roundId];
        require(
            round.id == roundId && round.id != 0,
            "BoardManager: invalid round"
        );
        return round.squares[squareId].allocations[miner];
    }

    // ========= Internal helpers =========

    /**
     * @dev Shared deploy logic between direct miners and automation
     */
    function _deploy(
        address miner,
        uint8[] calldata squareIds,
        uint256[] calldata amounts,
        bool useReferralCredit
    ) internal {
        require(miner != address(0), "BoardManager: invalid miner");
        require(
            squareIds.length == amounts.length,
            "BoardManager: length mismatch"
        );
        require(squareIds.length > 0, "BoardManager: no squares selected");

        Round storage round = rounds[currentRoundId];
        require(round.varHash != bytes32(0), "BoardManager: var not committed");
        require(
            round.state == BoardState.Created ||
                round.state == BoardState.Running,
            "BoardManager: round closed"
        );

        // Start round on first deposit
        if (round.state == BoardState.Created) {
            _startRound(round);
        }

        require(
            block.timestamp < round.activeUntil,
            "BoardManager: active phase ended"
        );

        // Calculate total deposit amount needed
        uint256 totalAmount;
        for (uint256 i = 0; i < squareIds.length; i++) {
            require(
                squareIds[i] < SQUARES_COUNT,
                "BoardManager: invalid square id"
            );
            uint256 amount = amounts[i];
            require(amount > 0, "BoardManager: amount must be > 0");
            require(
                amount >= minDepositPerAllocation,
                "BoardManager: amount below minimum"
            );
            totalAmount += amount;
        }

        // Apply referral credits if requested (reduces amount miner needs to pay)
        uint256 creditUsed = 0;
        if (useReferralCredit && address(referral) != address(0)) {
            creditUsed = referral.collectReferralCredit(miner, totalAmount);
            if (creditUsed > 0) {
                emit ReferralCreditUsed(miner, creditUsed);
            }
        }

        // Transfer remaining payment from the caller (miner when interacting directly, automation otherwise)
        uint256 amountFromUser = totalAmount - creditUsed;
        if (amountFromUser > 0) {
            address payer = msg.sender == miner ? miner : msg.sender;
            if (msg.sender != miner) {
                require(
                    msg.sender == automation,
                    "BoardManager: invalid delegate"
                );
            }
            paymentToken.safeTransferFrom(payer, address(this), amountFromUser);
        }

        // Handle referral incentives (4% to referrer if set, 1% cashback to depositor)
        uint256 referralFee = (totalAmount * REFERRAL_FEE_PERCENTAGE) /
            BASIS_POINTS;
        uint256 selfCashback = (totalAmount *
            SELF_REFERRAL_CASHBACK_PERCENTAGE) / BASIS_POINTS;
        if (address(referral) != address(0)) {
            address referrer = referral.getReferrer(miner);
            if (referrer != address(0)) {
                if (selfCashback > 0) {
                    paymentToken.safeTransfer(address(referral), selfCashback);
                    referral.addReferralCredit(miner, selfCashback);
                    emit SelfReferralCashback(miner, selfCashback);
                }
                if (referralFee > 0) {
                    // User has a referrer: credit them with 4% of deposit
                    paymentToken.safeTransfer(address(referral), referralFee);
                    referral.addReferralCredit(referrer, referralFee);
                    emit ReferralFeeDistributed(miner, referrer, referralFee);
                }
            }
            // No referrer: cashback and referral fees stay in board contract to back additional minting
        }

        // Record miner's allocations to their chosen squares
        for (uint256 i = 0; i < squareIds.length; i++) {
            _allocateToSquare(round, squareIds[i], miner, amounts[i]);
        }
    }

    /**
     * @dev Initializes a new round in Created state with default values
     * @param roundId The ID of the round to initialize
     */
    function _bootstrapRound(uint256 roundId) internal {
        Round storage round = rounds[roundId];
        round.id = roundId;
        round.startBlock = 0;
        round.endBlock = 0;
        round.startTime = 0;
        round.activeUntil = 0;
        round.endTime = 0;
        round.varHash = bytes32(0);
        round.varValue = 0;
        round.blockHash = bytes32(0);
        round.state = BoardState.Created;
        round.totalDeposited = 0;
        round.totalMintedTokens = 0;
        round.uniqueParticipants = 0;
        emit RoundInitialized(roundId);
    }

    function _pruneOldRounds() internal {
        if (currentRoundId <= maxStoredRounds) {
            return;
        }
        uint256 pruneTarget = currentRoundId - maxStoredRounds;
        while (oldestStoredRound <= pruneTarget) {
            delete rounds[oldestStoredRound];
            emit RoundPruned(oldestStoredRound);
            oldestStoredRound += 1;
        }
    }

    /**
     * @dev Starts the round timer when the first deposit is made
     *      Sets activeUntil (60s) and endTime (60s + 30s cooldown) from current timestamp
     *      Clears the previous round results from storage
     * @param round The round to start
     */
    function _startRound(Round storage round) internal {
        require(round.varHash != bytes32(0), "BoardManager: var missing");

        // Clear previous round results when new round starts
        delete lastRoundResults;

        uint64 startBlock = uint64(block.number);
        uint64 startTime = uint64(block.timestamp);
        round.startBlock = startBlock;
        round.startTime = startTime;
        round.activeUntil = startTime + ACTIVE_PHASE_DURATION; // +60s for deposits
        round.endTime = round.activeUntil + COOLDOWN_PHASE_DURATION; // +30s cooldown
        round.endBlock = startBlock + ROUND_BLOCK_SPAN; // ~30 blocks
        round.state = BoardState.Running;
        emit RoundStarted(round.id, round.startBlock, round.endBlock);
    }

    /**
     * @dev Records a miner's deposit allocation to a specific square
     *      Adds miner to participants list if this is their first allocation to this square
     * @param round The current round
     * @param squareId The square receiving the allocation (0-15)
     * @param miner The address making the deposit
     * @param amount The payment token amount being allocated
     */
    function _allocateToSquare(Round storage round, uint8 squareId, address miner, uint256 amount) internal {
        if (!round.hasParticipated[miner]) {
            uint256 newCount = round.uniqueParticipants + 1;
            require(
                newCount <= maxParticipantsPerRound,
                "BoardManager: round full"
            );
            round.uniqueParticipants = newCount;
            round.hasParticipated[miner] = true;
        }
        Square storage square = round.squares[squareId];
        if (square.allocations[miner] == 0) {
            square.participants.push(miner); // Track new participant
        }
        square.allocations[miner] += amount;
        square.totalDeposited += amount;
        round.totalDeposited += amount;
        emit Deposited(round.id, squareId, miner, amount);
    }

    /**
     * @dev Distributes payment tokens to all participants in the winning square
     *      proportionally to their stake in that square
     * @param round The current round
     * @param squareId The winning square ID
     * @param pool Total payment tokens to distribute (45% of round total)
     * @return totalPaid Actual amount distributed (may be less than pool if square empty)
     * @return recipients Array of addresses that received payments
     * @return amounts Array of payment amounts corresponding to each recipient
     */
    function _payMinedSquare(Round storage round, uint8 squareId, uint256 pool) internal returns (uint256, address[] memory, uint256[] memory) {
        Square storage square = round.squares[squareId];
        if (pool == 0 || square.totalDeposited == 0) {
            return (0, new address[](0), new uint256[](0)); // Guard branch: nothing to pay or nobody deposited
        }

        uint256 totalDeposited = square.totalDeposited;
        address[] storage participants = square.participants;

        // Count valid recipients first
        uint256 recipientCount = 0;
        for (uint256 i = 0; i < participants.length; i++) {
            address participant = participants[i];
            uint256 allocation = square.allocations[participant];
            if (allocation == 0) continue; // Should not be necessary but just in case
            uint256 share = (pool * allocation) / totalDeposited;
            if (share > 0) {
                recipientCount++;
            }
        }

        address[] memory recipients = new address[](recipientCount);
        uint256[] memory amounts = new uint256[](recipientCount);
        uint256 totalPaid;
        uint256 cursor = 0;

        // Distribute proportionally: share = (pool * minerStake) / totalSquareStake
        for (uint256 i = 0; i < participants.length; i++) {
            address participant = participants[i];
            uint256 allocation = square.allocations[participant];
            if (allocation == 0) continue; // Same skip in payout loop
            uint256 share = (pool * allocation) / totalDeposited;
            if (share > 0) { // Branch only executes for positive payouts to avoid zero entries
                totalPaid += share;
                recipients[cursor] = participant;
                amounts[cursor] = share;
                cursor++;
                paymentToken.safeTransfer(participant, share);
            }
        }
        return (totalPaid, recipients, amounts);
    }

    /**
     * @dev Calculates how many MINB tokens to mint based on fresh collateral and current price,
     *      then calls minter to mint and distribute them
     * @param round The current round
     * @param winningSquare The ID of the winning square
     * @param collateralAdded Backing amount that was actually deposited into the vault
     * @return recipients Array of addresses that received tokens
     * @return amounts Array of token amounts corresponding to each recipient
     */
    function _mintRoundTokens( Round storage round, uint8 winningSquare, uint256 collateralAdded) internal
        returns (
            address[] memory,
            uint256[] memory,
            uint256 mintedTokens,
            uint256 collateralUsed
        )
    {
        if (collateralAdded == 0) {
            return (new address[](0), new uint256[](0), 0, 0); // Guard: no collateral came in so skip mint
        }

        (address[] memory recipients, uint256[] memory shareUnits) = _buildTokenDistributions(round, winningSquare);

        if (recipients.length == 0) {
            return (recipients, new uint256[](0), 0, 0); // No eligible recipients, skip mint
        }

        paymentToken.safeIncreaseAllowance(address(minter), collateralAdded);
        (
            uint256[] memory mintedAmounts,
            uint256 tokensMinted,
            uint256 usedCollateral
        ) = minter.mintFromCollateral(
                collateralAdded,
                recipients,
                shareUnits,
                TOTAL_TOKEN_SHARE_UNITS
            );
        if (collateralAdded > usedCollateral) {
            paymentToken.safeDecreaseAllowance(
                address(minter),
                collateralAdded - usedCollateral
            );
        }

        if (tokensMinted == 0) {
            return (new address[](0), new uint256[](0), 0, 0); // Not enough collateral to mint
        }

        return (recipients, mintedAmounts, tokensMinted, usedCollateral);
    }

    /**
     * @dev Builds the recipient list and proportional share units for mint distribution.
     *      Distribution: 75% to winning square, 1% to each of 15 losing squares, 10% to airdrop.
     *      Uses a two-pass approach: first preview to count recipients, then populate arrays.
     */
    function _buildTokenDistributions(Round storage round, uint8 winningSquare) internal view returns (address[] memory recipients, uint256[] memory shareUnits) {
        // Scale each token share bucket up so we can work with integers only
        uint256 winningScaledShare = WINNING_SQUARE_TOKEN_SHARE *
            TOKEN_SHARE_SCALE;
        uint256 loserScaledShare = OTHER_SQUARES_TOKEN_SHARE *
            TOKEN_SHARE_SCALE;
        uint256 airdropScaledShare = AIRDROP_TOKEN_SHARE * TOKEN_SHARE_SCALE;

        // First figure out how many addresses will get a non-zero share so arrays are sized once
        uint256 totalRecipients = _previewSquareDistribution(
            round.squares[winningSquare],
            winningScaledShare
        );

        for (uint8 i = 0; i < SQUARES_COUNT; i++) {
            if (i == winningSquare) continue;
            totalRecipients += _previewSquareDistribution(
                round.squares[i],
                loserScaledShare
            );
        }

        // Always add airdrop recipient as final entry to absorb rounding dust.
        recipients = new address[](totalRecipients + 1);
        shareUnits = new uint256[](recipients.length);

        // Second pass: fill the arrays with each square's participants and their scaled shares
        uint256 cursor = 0;
        cursor = _populateSquareDistribution(
            round.squares[winningSquare],
            winningScaledShare,
            recipients,
            shareUnits,
            cursor
        );

        for (uint8 i = 0; i < SQUARES_COUNT; i++) {
            if (i == winningSquare) continue;
            cursor = _populateSquareDistribution(
                round.squares[i],
                loserScaledShare,
                recipients,
                shareUnits,
                cursor
            );
        }

        // The last slot goes to the airdrop contract so leftover share units are retained there
        recipients[cursor] = address(airdrop);
        shareUnits[cursor] = airdropScaledShare;
        cursor += 1;

        require(cursor == recipients.length, "BoardManager: cursor mismatch");
        return (recipients, shareUnits);
    }

    /**
     * @dev Preview pass: counts how many recipients in a square would
     *      receive a non-zero share at the current scaling precision.
     */
    function _previewSquareDistribution(Square storage square,uint256 scaledShare) internal view returns (uint256 recipients) {
        // Skip expensive loop when there is nothing to divide or no deposits to consider
        if (scaledShare == 0 || square.totalDeposited == 0) {
            return 0;
        }

        uint256 totalDeposited = square.totalDeposited;
        address[] storage participants = square.participants;
        for (uint256 i = 0; i < participants.length; i++) {
            address participant = participants[i];
            uint256 allocation = square.allocations[participant];
            if (allocation == 0) continue;
            // Convert participant's allocation into its proportional share
            uint256 share = Math.mulDiv(allocation, scaledShare, totalDeposited);
            if (share > 0) {
                // Only increment for addresses that would end up receiving something
                recipients += 1;
            }
        }
    }

    /**
     * @dev Population pass: fills arrays with recipients and scaled share units.
     */
    function _populateSquareDistribution(Square storage square, uint256 scaledShare, address[] memory recipients, uint256[] memory shareUnits, uint256 cursor) internal view returns (uint256) {
        // Nothing to distribute if square has no share or no deposits
        if (scaledShare == 0 || square.totalDeposited == 0) {
            return cursor;
        }

        uint256 totalDeposited = square.totalDeposited;
        address[] storage participants = square.participants;

        for (uint256 i = 0; i < participants.length; i++) {
            address participant = participants[i];
            uint256 allocation = square.allocations[participant];
            if (allocation == 0) continue;
            // Translate the participant's allocation into scaled share units
            uint256 share = Math.mulDiv(allocation, scaledShare, totalDeposited);
            if (share > 0) {
                // Record the recipient and the amount of share units they should receive
                recipients[cursor] = participant;
                shareUnits[cursor] = share;
                cursor += 1;
            }
        }
        return cursor;
    }

    /**
     * @dev Potentially triggers airdrop payout to all losing participants
     *      Airdrop triggers with ~1/480 probability. If triggered, entire airdrop pool
     *      is distributed proportionally to all participants in non-winning squares
     * @param round The current round
     * @param winningSquare The ID of the winning square (losers are everyone else)
     * @param seed Random seed for airdrop trigger determination
     * @return triggered Whether the airdrop was triggered
     * @return winners Array of addresses that received airdrop payouts
     * @return amounts Array of airdrop amounts corresponding to each winner
     */
    function _maybePayAirdrop(Round storage round, uint8 winningSquare, bytes32 seed) internal returns (bool, address[] memory, uint256[] memory) {
        // Nothing to do if airdrop contract not configured or it holds no funds
        if (address(airdrop) == address(0))
            return (false, new address[](0), new uint256[](0));
        uint256 airdropBalance = airdrop.currentBalance();
        if (airdropBalance == 0)
            return (false, new address[](0), new uint256[](0));

        // Derive pseudo-random number and only continue for the lucky rounds (~1/480)
        uint256 randomNumber = uint256(
            keccak256(abi.encodePacked(seed, airdropBalance, block.timestamp))
        );
        // Only when the modulo hits zero do we award the airdrop; every other remainder means no drop
        if (randomNumber % AIRDROP_TRIGGER_PROBABILITY != 0) {
            return (false, new address[](0), new uint256[](0));
        }

        // Collect all losers (participants from non-winning squares) and their allocations
        address[] memory losers;
        uint256[] memory allocations;
        uint256 loserCount;
        uint256 totalLoserAllocation;

        // First pass: count losers and total allocation
        for (uint8 i = 0; i < SQUARES_COUNT; i++) {
            if (i == winningSquare) continue; // Skip winners
            Square storage square = round.squares[i];
            loserCount += square.participants.length;
            totalLoserAllocation += square.totalDeposited;
        }

        if (loserCount == 0) return (false, new address[](0), new uint256[](0)); // No losers (everyone bet on winning square)

        // Second pass: populate losers array with every losing participant once
        losers = new address[](loserCount);
        allocations = new uint256[](loserCount);
        uint256 cursor = 0;

        for (uint8 i = 0; i < SQUARES_COUNT; i++) {
            if (i == winningSquare) continue; // Skip winners
            Square storage square = round.squares[i];
            address[] storage participants = square.participants;

            // Walk every participant of the current losing square
            for (uint256 j = 0; j < participants.length; j++) {
                address participant = participants[j];
                uint256 allocation = square.allocations[participant];
                // Store participant plus how much they deposited so payoutMultiple can weight them
                losers[cursor] = participant;
                allocations[cursor] = allocation;
                cursor++;
            }
        }

        // Distribute the entire airdrop pool to losers using their deposit weight
        uint256 paid = airdrop.payoutMultiple(losers, allocations);
        emit AirdropWon(round.id, address(0), paid); // address(0) indicates multiple winners

        // Calculate precise individual amounts (payoutMultiple can round internally)
        uint256[] memory individualAmounts = new uint256[](loserCount);
        for (uint256 i = 0; i < loserCount; i++) {
            individualAmounts[i] =
                (paid * allocations[i]) /
                totalLoserAllocation;
        }

        return (true, losers, individualAmounts);
    }

    function _collectParticipantSquares(Round storage round, address participant) internal view returns (uint8[] memory squares) {
        uint8[] memory buffer = new uint8[](SQUARES_COUNT);
        uint256 count;
        for (uint8 i = 0; i < SQUARES_COUNT; i++) {
            Square storage square = round.squares[i];
            if (square.allocations[participant] > 0) {
                buffer[count] = i;
                count++;
            }
        }
        assembly {
            mstore(buffer, count)
        }
        return buffer;
    }

    function _collectRecipientTotal( address target, address[] memory recipients, uint256[] memory amounts) internal pure returns (uint256 total) {
        for (uint256 i = 0; i < recipients.length; i++) {
            if (recipients[i] == target) {
                total += amounts[i];
            }
        }
    }
}
