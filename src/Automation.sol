// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

// Board Manager
interface IBoardManagerAutomation {
    enum BoardState {
        Created,
        Running,
        Ended
    }

    struct RoundSummary {
        uint256 id;
        uint64 startBlock;
        uint64 endBlock;
        uint64 startTime;
        uint64 activeUntil;
        uint64 endTime;
        bytes32 varHash;
        bytes32 blockHash;
        uint256 varValue;
        BoardState state;
        uint256 totalDeposited;
        uint256 totalMintedTokens;
    }

    function deployFor(
        address miner,
        uint8[] calldata squareIds,
        uint256[] calldata amounts,
        bool useReferralCredit
    ) external;

    function currentRoundId() external view returns (uint256);

    function getRoundSummary(
        uint256 roundId
    ) external view returns (RoundSummary memory);
}

interface IAutomation {
    function recordRoundResults(
        uint256 roundId,
        address miner,
        uint256 amountWon,
        uint256 tokensReceived,
        uint8[] calldata squares
    ) external;
}

contract Automation is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    enum Strategy {
        Random,
        Fixed
    }

    uint8 private constant BOARD_SQUARES = 16;
    uint256 private constant MAX_STORED_ROUND_RESULTS = 100;

    // Tracks the lifecycle of a miner's automation order: strategy, budgets, running totals.
    struct Order {
        address miner;
        Strategy strategy;
        uint8 squaresPerRound;
        uint64 remainingRounds;
        uint64 roundsExecuted;
        uint256 amountPerSquare;
        uint256 nextRoundId;
        bool useReferralCredit;
        uint256 amountRemaining;
        uint256 totalDeposited;
        uint256 feeBudget;
        uint256 totalFeesPaid;
        uint256 totalAmountWon;
        uint256 totalTokensReceived;
        uint256 lastExecutedRound;
        bool cancelled;
        uint8[] fixedSquares;
    }

    // Aggregated metrics exposed per miner wallet.
    struct WalletStats {
        uint256 totalExecutions;
        uint256 totalAmountSpent;
        uint256 totalFeesPaid;
        uint256 totalAmountWon;
        uint256 totalTokensReceived;
        uint256 lastRoundId;
        uint64 lastExecutedAt;
    }

    // Bounded ring buffer storing per-round payouts for an order.
    struct RoundResult {
        uint256 roundId;
        uint256 amountWon;
        uint256 tokensReceived;
    }

    // Cached copy of the most recent execution so frontends can show last activity.
    struct WalletLastExecution {
        uint256 orderId;
        uint256 roundId;
        address executor;
        uint256 amountSpent;
        uint64 timestamp;
        uint8[] squares;
    }

    // ERC20 token that miners deposit and executors are paid in.
    IERC20 public immutable paymentToken;
    // BoardManager contract that actually deploys the deposits.
    IBoardManagerAutomation public boardManager;
    // Flat fee reward paid to whoever executes a round for an order.
    uint256 public immutable executionFeePerRound;
    // Upper bound on how many stale orders are migrated per execute call.
    uint256 private constant MAX_SYNC_MIGRATIONS = 100;

    // Storage for every automation order ever created.
    Order[] private orders;
    // Per-round queue of order ids waiting to be executed.
    mapping(uint256 => uint256[]) private roundQueue;
    // Sliding window of round payout results per order.
    mapping(uint256 => RoundResult[]) private orderRoundResults;
    // Aggregated wallet statistics keyed by miner address.
    mapping(address => WalletStats) private walletStats;
    // Cached info about the miner's last execution for UI convenience.
    mapping(address => WalletLastExecution) private walletLastExecution;
    // Next round id a miner is allowed to schedule (prevents overlap).
    mapping(address => uint256) private walletNextAvailableRound;
    // Tracks which order (id+1) is awaiting payout for each miner/round key.
    mapping(bytes32 => uint256) private pendingRoundAssignments; // orderId offset by +1
    // Active order id (id+1) per miner so only one automation runs at a time.
    mapping(address => uint256) private walletActiveOrder; // orderId offset by +1
    // Last completed order id (id+1) per miner for history lookups.
    mapping(address => uint256) private walletLastCompletedOrder; // orderId offset by +1
    // Set of round ids that still have pending orders.
    uint256[] private pendingRounds;
    // Helper index so pendingRounds behaves like a tracked set (1-based positions).
    mapping(uint256 => uint256) private pendingRoundIndex;
    // Cursor per round queue used when migrating stale orders in batches.
    mapping(uint256 => uint256) private roundQueueMigrationCursor;

    event OrderScheduled(
        uint256 indexed orderId,
        address indexed miner,
        uint256 indexed startRoundId,
        uint64 rounds,
        Strategy strategy
    );
    event OrderExecuted(
        uint256 indexed orderId,
        uint256 indexed roundId,
        address indexed executor,
        uint8[] squares
    );
    event OrderCancelled(
        uint256 indexed orderId,
        address indexed miner,
        uint256 depositRefund,
        uint256 feeRefund
    );
    event WalletStatsUpdated(
        address indexed miner,
        uint256 indexed orderId,
        uint256 indexed roundId,
        uint256 totalExecutions,
        uint256 totalAmountSpent,
        uint256 totalFeesPaid,
        uint256 totalAmountWon,
        uint256 totalTokensReceived,
        uint256 amountSpent,
        address executor,
        uint8[] squares
    );

    event RoundResultsRecorded(
        address indexed miner,
        uint256 indexed roundId,
        uint256 amountWon,
        uint256 tokensReceived,
        uint8[] squares
    );

    // Initializes Automation with the ERC20 used for payments, the board manager, and executor fee.
    constructor(address _paymentToken,address _boardManager,uint256 _executionFeePerRound) Ownable(msg.sender) {
        require(
            _paymentToken != address(0),
            "Automation: payment token required"
        );
        require(
            _boardManager != address(0),
            "Automation: board manager required"
        );

        paymentToken = IERC20(_paymentToken);
        boardManager = IBoardManagerAutomation(_boardManager);
        executionFeePerRound = _executionFeePerRound;
    }

    // Owner can rotate the board manager in case of redeploys.
    function setBoardManager(address _boardManager) external onlyOwner {
        require(_boardManager != address(0), "Automation: board manager required");
        boardManager = IBoardManagerAutomation(_boardManager);
    }

    // Miner schedules a new automation strategy, depositing funds and executor fees upfront.
    function scheduleAutomation(Strategy strategy,uint8 squaresPerRound,uint64 rounds,uint8[] calldata fixedSquares,uint256 amountPerSquare,bool useReferralCredit) external nonReentrant returns (uint256 orderId) {
        require(rounds > 0, "Automation: turns required");
        require(squaresPerRound > 0, "Automation: squares required");
        require(
            squaresPerRound <= BOARD_SQUARES,
            "Automation: too many squares"
        );
        require(amountPerSquare > 0, "Automation: invalid amount");

        if (strategy == Strategy.Fixed) {
            // Fixed strategy requires callers to provide exact square ids for each round.
            require(
                fixedSquares.length == squaresPerRound,
                "Automation: missing fixed squares"
            );
            _validateSquares(fixedSquares);
        } else {
            // Random strategy must not receive any fixed square data.
            require(
                fixedSquares.length == 0,
                "Automation: random ignores fixed squares"
            );
        }

        // Collect the entire deposit + fees upfront so Automation can execute trustlessly.
        uint256 perRoundAmount = uint256(amountPerSquare) * squaresPerRound;
        uint256 totalDepositAmount = perRoundAmount * rounds;
        uint256 totalFeeAmount = executionFeePerRound * rounds;
        require(
            walletActiveOrder[msg.sender] == 0,
            "Automation: active order in progress"
        );

        // Pull entire deposit + fee budget upfront so automation can operate autonomously.
        paymentToken.safeTransferFrom(
            msg.sender,
            address(this),
            totalDepositAmount + totalFeeAmount
        );
        paymentToken.safeIncreaseAllowance(
            address(boardManager),
            totalDepositAmount
        );

        // Default start round is whatever BoardManager is currently addressing.
        uint256 startRoundId = boardManager.currentRoundId();
        IBoardManagerAutomation.RoundSummary memory summary = boardManager
            .getRoundSummary(startRoundId);
        if (
            summary.state == IBoardManagerAutomation.BoardState.Running &&
            summary.activeUntil != 0
        ) {
            bool skipCurrentRound;
            if (block.timestamp >= summary.activeUntil) {
                // Active window already closed; skip to next round.
                skipCurrentRound = true;
            } else {
                uint256 remaining = summary.activeUntil - block.timestamp;
                if (remaining < 15) {
                    // Active window is about to close (less than 15 seconds remaining); avoid rushing deposits.
                    skipCurrentRound = true;
                }
            }
            if (skipCurrentRound) {
                // Current round is already in cooldown or about to end, push start to next round id.
                startRoundId += 1;
            }
        }

        uint256 walletHint = walletNextAvailableRound[msg.sender];
        if (walletHint > startRoundId) {
            // Wallet already has an automation scheduled later, so start there to avoid overlap.
            startRoundId = walletHint;
        }

        orders.push();
        orderId = orders.length - 1;
        Order storage order = orders[orderId];
        order.miner = msg.sender; // Track who owns this automation.
        order.strategy = strategy; // Remember whether it is random or fixed squares.
        order.squaresPerRound = squaresPerRound; // Cap how many squares each execution should place.
        order.remainingRounds = rounds; // Number of executions still pending.
        order.amountPerSquare = amountPerSquare; // Deposit size per square for this run.
        order.nextRoundId = startRoundId; // First round that should include this order.
        order.useReferralCredit = useReferralCredit; // Whether to consume referral credits.
        order.amountRemaining = totalDepositAmount; // Track how much deposit is still unused.
        order.totalDeposited = totalDepositAmount; // Snapshot of how much was funded initially.
        order.roundsExecuted = 0; // Initialized to zero; increments on every execution.
        order.totalFeesPaid = 0; // Running total of executor fees for this order.
        order.totalAmountWon = 0; // Running total of board payouts won by this order.
        order.totalTokensReceived = 0; // Running total of tokens received from the board.
        order.cancelled = false; // Fresh orders begin active.
        order.feeBudget = totalFeeAmount; // Amount set aside to pay executors.
        if (strategy == Strategy.Fixed) {
            order.fixedSquares = fixedSquares;
        }

        _enqueueOrder(startRoundId, orderId); // Push this order id to the queue for the chosen starting round.
        walletNextAvailableRound[msg.sender] = startRoundId + rounds; // Block overlapping automations until current one finishes.
        walletActiveOrder[msg.sender] = orderId + 1; // Track the active order (offset by +1 to use zero as “none”).
        walletLastCompletedOrder[msg.sender] = 0; // Reset completion pointer since this is a fresh automation.

        emit OrderScheduled(
            orderId,
            msg.sender,
            startRoundId,
            rounds,
            strategy
        );
    }

    // Executors run queued orders for a given round, up to `maxOrders`.
    function executeDeploys(uint256 roundId,uint256 maxOrders) external nonReentrant {

        // Executors must specify how many queued orders to process for this call.
        require(maxOrders > 0, "Automation: maxOrders required");
        require(
            roundId <= boardManager.currentRoundId(),
            "Automation: invalid round"
        );

        // If no queue exists for the requested round, pull forward any stale orders.
        if (roundQueue[roundId].length == 0) {
            _syncRoundQueue(roundId, MAX_SYNC_MIGRATIONS);
        }

        uint256[] storage queue = roundQueue[roundId];
        require(queue.length > 0, "Automation: nothing scheduled");

        uint256 processed;
        // Process orders from the queue until it empties or we hit maxOrders.
        while (queue.length > 0 && processed < maxOrders) {
            uint256 orderId = queue[queue.length - 1];
            queue.pop();
            Order storage order = orders[orderId];
            if (
                // Skip orders that have already finished, were cancelled, or were re-queued elsewhere.
                order.remainingRounds == 0 ||
                order.cancelled ||
                order.nextRoundId != roundId
            ) {
                // Nothing actionable for this order anymore.
                continue;
            }
            // Execute the actual deposits for this round.
            _processOrder(orderId, roundId);
            processed += 1;
        }

        if (queue.length == 0) {
            // Cleanup empty queues so _oldestPendingRound ignores them next time.
            delete roundQueue[roundId];
            delete roundQueueMigrationCursor[roundId];
            _removePendingRound(roundId);
        }
    }

    // Returns how many executions are queued for the provided round (or fallback from older rounds).
    function pendingExecutions(uint256 roundId) external view returns (uint256) {
        uint256 scheduled = roundQueue[roundId].length;
        if (scheduled > 0) {
            return scheduled; // Round already has a queue; no need to inspect stale rounds.
        }
        uint256 sourceRound = _oldestPendingRound();
        if (sourceRound != 0 && sourceRound < roundId) {
            uint256[] storage staleQueue = roundQueue[sourceRound];
            uint256 cursor = roundQueueMigrationCursor[sourceRound];
            if (staleQueue.length > cursor) {
                // Only count entries that haven't been migrated yet (length - cursor).
                return staleQueue.length - cursor;
            }
        }
        return 0; // Nothing pending for this round or any older round.
    }

    // Miner can stop their automation order and reclaim remaining deposit / fees.
    function cancelOrder(uint256 orderId) external nonReentrant {
        Order storage order = orders[orderId];
        require(order.miner == msg.sender, "Automation: not miner");
        require(!order.cancelled, "Automation: order cancelled");
        require(order.remainingRounds > 0, "Automation: order completed");

        order.cancelled = true;
        order.remainingRounds = 0;
        order.nextRoundId = 0;
        _clearActiveOrder(order.miner, orderId);

        uint256 depositRefund = _refundPrincipal(order);
        uint256 feeRefund = _refundFeeBudget(order);

        emit OrderCancelled(orderId, msg.sender, depositRefund, feeRefund);
    }

    // Detailed getter for a specific order id (used by UIs).
    function getOrder(uint256 orderId) external view returns (
            address miner,
            Strategy strategy,
            uint8 squaresPerRound,
            uint64 remainingRounds,
            uint256 amountPerSquare,
            uint256 nextRoundId,
            bool useReferralCredit,
            uint256 amountRemaining,
            uint256 feeBudget,
            uint8[] memory fixedSquares,
            uint64 roundsExecuted,
            uint256 totalDeposited,
            uint256 totalFeesPaid,
            uint256 totalAmountWon,
            uint256 totalTokensReceived,
            bool cancelled
        )
    {
        Order storage order = orders[orderId];
        return (
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
        );
    }

    // View aggregated stats for a miner wallet.
    function getWalletStats(address miner) external view returns (WalletStats memory) {
        return walletStats[miner];
    }

    // Fetch the cached last execution for a miner.
    function getWalletLastExecution(address miner) external view returns (WalletLastExecution memory) {
        return walletLastExecution[miner];
    }

    // Called by BoardManager to inform Automation of payouts so stats remain accurate.
    function recordRoundResults(uint256 roundId, address miner, uint256 amountWon, uint256 tokensReceived, uint8[] calldata squares) external {
        require(
            msg.sender == address(boardManager),
            "Automation: only board manager can call"
        );

        // Find the order Automation assigned to this miner/round pair (if any).
        bytes32 key = _assignmentKey(miner, roundId);
        uint256 storedOrderId = pendingRoundAssignments[key];
        if (storedOrderId == 0) {
            // No automation assignment for this miner/round; nothing to update.
            return;
        }
        delete pendingRoundAssignments[key];
        uint256 orderId = storedOrderId - 1; // Stored value is offset by +1 to allow zero sentinel.
        Order storage order = orders[orderId];
        order.totalAmountWon += amountWon; // Track aggregated winnings for this automation.
        order.totalTokensReceived += tokensReceived;

        RoundResult[] storage results = orderRoundResults[orderId];
        results.push();
        RoundResult storage result = results[results.length - 1];
        result.roundId = roundId; // Record which round produced the payout.
        result.amountWon = amountWon;
        result.tokensReceived = tokensReceived;
        if (results.length > MAX_STORED_ROUND_RESULTS) {
            uint256 targetLength = MAX_STORED_ROUND_RESULTS;
            // Shift newer entries left and drop the oldest entry to keep bounded history.
            for (uint256 i = 1; i < results.length; i++) {
                results[i - 1] = results[i];
            }
            while (results.length > targetLength) {
                results.pop();
            }
        }

        WalletStats storage stats = walletStats[miner];
        stats.totalAmountWon += amountWon; // Keep wallet-level stats in sync with order data.
        stats.totalTokensReceived += tokensReceived;

        emit RoundResultsRecorded(
            miner,
            roundId,
            amountWon,
            tokensReceived,
            squares
        );
    }

    function ordersCount() external view returns (uint256) {
        return orders.length;
    }

    // Returns whether the miner currently has an active order and its id.
    function getActiveOrder(address miner) external view returns (bool hasActive, uint256 orderId) {
        uint256 stored = walletActiveOrder[miner];
        if (stored == 0) {
            return (false, 0);
        }
        return (true, stored - 1);
    }

    // Checks if Automation is awaiting BoardManager payout for the miner/round pair.
    function hasPendingPayout(address miner,uint256 roundId) external view returns (bool) {
        return pendingRoundAssignments[_assignmentKey(miner, roundId)] != 0;
    }

    // Returns the most recently completed order for the miner if present.
    function getLastCompletedOrder(address miner) external view returns (bool hasOrder, uint256 orderId) {
        uint256 stored = walletLastCompletedOrder[miner];
        if (stored == 0) {
            return (false, 0);
        }
        return (true, stored - 1);
    }

    // Returns latest order info preferring active order, falling back to last completed.
    function getLatestOrder(address miner) external view returns (bool hasOrder, uint256 orderId, bool isActive) {
        uint256 activeStored = walletActiveOrder[miner];
        if (activeStored != 0) {
            return (true, activeStored - 1, true);
        }
        uint256 stored = walletLastCompletedOrder[miner];
        if (stored != 0) {
            return (true, stored - 1, false);
        }
        return (false, 0, false);
    }

    // Convenience getter for total amount won and tokens received across an order.
    function getOrderRunTotals(uint256 orderId) external view returns (uint256 totalAmountWon, uint256 totalTokensReceived) {
        require(orderId < orders.length, "Automation: invalid order");
        Order storage order = orders[orderId];
        return (order.totalAmountWon, order.totalTokensReceived);
    }

    // Returns the stored arrays of roundIds/amounts/tokens for an order's history.
    function getOrderRoundResults(uint256 orderId) external view returns (uint256[] memory roundIds, uint256[] memory amountsWon, uint256[] memory tokensReceived) {
        require(orderId < orders.length, "Automation: invalid order"); // Defensive: ensure order exists before reading storage.
        RoundResult[] storage results = orderRoundResults[orderId]; // Pull the storage ring buffer for this order.
        uint256 length = results.length;
        roundIds = new uint256[](length); // Prepare output arrays mirroring the stored structs.
        amountsWon = new uint256[](length);
        tokensReceived = new uint256[](length);
        for (uint256 i = 0; i < length; i++) {
            RoundResult storage result = results[i];
            roundIds[i] = result.roundId; // Copy round id so callers can correlate payouts.
            amountsWon[i] = result.amountWon; // Copy how much payment was won for the round.
            tokensReceived[i] = result.tokensReceived; // Copy how many bonus tokens were claimed.
        }
    }

    // Executes one round for an order, funding BoardManager and updating state.
    function _processOrder(uint256 orderId, uint256 roundId) internal {
        address executor = msg.sender;
        Order storage order = orders[orderId];
        require(!order.cancelled, "Automation: order cancelled");
        require(order.remainingRounds > 0, "Automation: order completed");
        require(order.nextRoundId == roundId, "Automation: wrong round");
        require(
            order.lastExecutedRound != roundId,
            "Automation: round already processed"
        );

        // Select squares either from fixed configuration or pseudo-randomly per round.
        uint8[] memory squares = order.strategy == Strategy.Fixed
            ? order.fixedSquares
            : _generateRandomSquares(orderId, roundId, order.squaresPerRound);
        if (order.strategy == Strategy.Random) {
            // Double-check randomness helper didn't return duplicates.
            _validateSquares(squares);
        }

        // Flatten amountPerSquare into the BoardManager's deploy format.
        uint256[] memory amounts = new uint256[](squares.length);
        uint256 perTurnAmount = order.amountPerSquare * squares.length;
        for (uint256 i = 0; i < squares.length; i++) {
            amounts[i] = order.amountPerSquare;
        }
        _registerRoundAssignment(order.miner, roundId, orderId);

        // Execute the deposits on BoardManager for this round.
        boardManager.deployFor(order.miner, squares, amounts, order.useReferralCredit);

        order.remainingRounds -= 1;
        order.amountRemaining -= perTurnAmount;
        order.roundsExecuted += 1;
        order.lastExecutedRound = roundId;
        _payExecutor(order, executor);
        _updateWalletStats(order.miner, orderId, roundId, perTurnAmount, executor, squares);

        emit OrderExecuted(orderId, roundId, executor, squares);

        if (order.remainingRounds > 0) {
            // Reschedule order for the next round.
            uint256 nextRound = roundId + 1;
            order.nextRoundId = nextRound;
            _enqueueOrder(nextRound, orderId);
        } else {
            // No rounds left—clean up state and track completion.
            order.nextRoundId = 0;
            order.feeBudget = 0;
            _clearActiveOrder(order.miner, orderId);
            walletLastCompletedOrder[order.miner] = orderId + 1;
        }
    }

    // Add order to queue for the specified round and track pending rounds.
    function _enqueueOrder(uint256 roundId, uint256 orderId) internal {
        uint256[] storage queue = roundQueue[roundId];
        if (queue.length == 0) {
            _addPendingRound(roundId);
        }
        queue.push(orderId);
    }

    // Deterministic key for mapping miner+round to pending payout entry.
    function _assignmentKey(address miner,uint256 roundId) private pure returns (bytes32) {
        return keccak256(abi.encodePacked(miner, roundId));
    }

    // Records that a miner is owed results for a given round and order.
    function _registerRoundAssignment(address miner,uint256 roundId,uint256 orderId) private {
        bytes32 key = _assignmentKey(miner, roundId);
        require(
            pendingRoundAssignments[key] == 0,
            "Automation: pending payout exists"
        );
        pendingRoundAssignments[key] = orderId + 1;
    }

    // Clears the active order pointer if the tracked id matches.
    function _clearActiveOrder(address miner, uint256 orderId) private {
        uint256 stored = walletActiveOrder[miner];
        if (stored == 0) {
            return;
        }
        uint256 currentId = stored - 1;
        if (currentId == orderId) {
            walletActiveOrder[miner] = 0;
        }
    }

    // Pulls orders forward from stale round queues to the requested round.
    function _syncRoundQueue(
        uint256 roundId,
        uint256 maxOrdersToMigrate
    ) internal {
        // Bounded loop so each call only migrates up to MAX_SYNC_MIGRATIONS orders.
        uint256 migrated;
        while (migrated < maxOrdersToMigrate) {
            uint256 sourceRound = _oldestPendingRound(); // Always drain the oldest pending round first.
            if (sourceRound == 0 || sourceRound >= roundId) {
                // No stale rounds to migrate (either none exist or all are already >= target).
                break;
            }
            uint256[] storage staleQueue = roundQueue[sourceRound];
            uint256 length = staleQueue.length;
            if (length == 0) {
                // Empty queue bookkeeping for this round; remove and check the next one.
                delete roundQueue[sourceRound];
                delete roundQueueMigrationCursor[sourceRound];
                _removePendingRound(sourceRound);
                continue;
            }

            uint256 cursor = roundQueueMigrationCursor[sourceRound]; // Resume from where the previous call stopped.
            if (cursor >= length) {
                delete roundQueue[sourceRound];
                delete roundQueueMigrationCursor[sourceRound];
                _removePendingRound(sourceRound);
                continue;
            }

            while (cursor < length && migrated < maxOrdersToMigrate) {
                uint256 orderId = staleQueue[cursor];
                cursor += 1; // Advance cursor regardless so we keep making progress even when skipping orders.
                Order storage order = orders[orderId];
                if (
                    order.remainingRounds == 0 ||
                    order.cancelled
                ) {
                    // Drop already completed/cancelled orders.
                    continue;
                }
                // Reassign orders that never fired in `sourceRound` to the target round.
                order.nextRoundId = roundId;
                _enqueueOrder(roundId, orderId); // Push into the active queue for the new round.
                migrated += 1;
            }

            roundQueueMigrationCursor[sourceRound] = cursor; // Persist cursor for the next sync call.
            if (cursor >= length) {
                delete roundQueue[sourceRound];
                delete roundQueueMigrationCursor[sourceRound];
                _removePendingRound(sourceRound); // Remove source round from pending set before looping again.
            }
        }
    }

    // Track a round in pendingRounds so executors know what still needs processing.
    function _addPendingRound(uint256 roundId) internal {
        if (pendingRoundIndex[roundId] != 0) {
            return;
        }
        pendingRounds.push(roundId);
        pendingRoundIndex[roundId] = pendingRounds.length; // 1-based index
    }

    // Remove a round from pendingRounds via swap-and-pop.
    function _removePendingRound(uint256 roundId) internal {
        uint256 pos = pendingRoundIndex[roundId];
        if (pos == 0) {
            return;
        }
        uint256 index = pos - 1;
        uint256 lastIndex = pendingRounds.length - 1;
        if (index != lastIndex) {
            uint256 lastRound = pendingRounds[lastIndex];
            pendingRounds[index] = lastRound;
            pendingRoundIndex[lastRound] = index + 1;
        }
        pendingRounds.pop();
        pendingRoundIndex[roundId] = 0;
    }

    // Find the smallest round id remaining in pendingRounds.
    function _oldestPendingRound() internal view returns (uint256 roundId) {
        uint256 length = pendingRounds.length;
        if (length == 0) {
            return 0;
        }

        roundId = pendingRounds[0];
        for (uint256 i = 1; i < length; i++) {
            uint256 candidate = pendingRounds[i];
            if (candidate < roundId) {
                roundId = candidate;
            }
        }
    }

    // Generates a list of unique square ids based on pseudo-random seed.
    function _generateRandomSquares(uint256 orderId,uint256 roundId,uint8 count) internal view returns (uint8[] memory) {
        uint8[] memory squares = new uint8[](count);
        bool[BOARD_SQUARES] memory used; // Tracks which square indices are already chosen.
        bytes32 seed = blockhash(block.number - 1); // Prefer a recent blockhash as randomness source.
        if (seed == bytes32(0)) {
            // Fallback for when blockhash is unavailable (e.g. in tests or genesis).
            seed = keccak256(
                abi.encodePacked(block.timestamp, block.prevrandao, roundId)
            );
        }

        uint256 randomness = uint256(
            keccak256(abi.encodePacked(seed, orderId, roundId))
        );
        for (uint256 i = 0; i < count; i++) {
            uint8 square;
            do {
                square = uint8(randomness % BOARD_SQUARES); // Pick a square from [0, BOARD_SQUARES).
                randomness = uint256(
                    keccak256(abi.encodePacked(randomness, i))
                );
            } while (used[square]); // Keep sampling until we find an unused slot.

            used[square] = true;
            squares[i] = square; // Record the unique square for this iteration.
        }
        return squares;
    }

    // Reverts if any square id is out of bounds or duplicated.
    function _validateSquares(uint8[] memory squares) internal pure {
        bool[BOARD_SQUARES] memory seen;
        for (uint256 i = 0; i < squares.length; i++) {
            uint8 square = squares[i];
            require(square < BOARD_SQUARES, "Automation: invalid square");
            require(!seen[square], "Automation: duplicate square");
            seen[square] = true;
        }
    }

    // Send unspent deposit back to the miner.
    function _refundPrincipal(Order storage order) internal returns (uint256 refund) {
        refund = order.amountRemaining;
        if (refund > 0) {
            order.amountRemaining = 0;
            paymentToken.safeTransfer(order.miner, refund);
        }
    }

    // Pay executor fee for the processed round from the order's fee budget.
    function _payExecutor(Order storage order, address executor) internal {
        if (executionFeePerRound == 0) return;
        require(
            order.feeBudget >= executionFeePerRound,
            "Automation: fee budget exhausted"
        );
        order.feeBudget -= executionFeePerRound;
        order.totalFeesPaid += executionFeePerRound;
        paymentToken.safeTransfer(executor, executionFeePerRound);
    }

    // Refund any unused fee budget to the miner.
    function _refundFeeBudget(Order storage order) internal returns (uint256 refund) {
        refund = order.feeBudget;
        if (refund > 0) {
            order.feeBudget = 0;
            paymentToken.safeTransfer(order.miner, refund);
        }
    }

    // Update per-wallet aggregated stats and emit event for UI tracking.
    function _updateWalletStats(address miner,uint256 orderId,uint256 roundId,uint256 amountSpent,address executor,uint8[] memory squares) internal {
        WalletStats storage stats = walletStats[miner];
        unchecked {
            stats.totalExecutions += 1;
        }
        stats.totalAmountSpent += amountSpent;
        if (executionFeePerRound > 0) {
            stats.totalFeesPaid += executionFeePerRound;
        }
        stats.lastRoundId = roundId;
        stats.lastExecutedAt = uint64(block.timestamp);

        WalletLastExecution storage lastExec = walletLastExecution[miner];
        lastExec.orderId = orderId;
        lastExec.roundId = roundId;
        lastExec.executor = executor;
        lastExec.amountSpent = amountSpent;
        lastExec.timestamp = uint64(block.timestamp);
        delete lastExec.squares;
        lastExec.squares = squares;

        emit WalletStatsUpdated(
            miner,
            orderId,
            roundId,
            stats.totalExecutions,
            stats.totalAmountSpent,
            stats.totalFeesPaid,
            stats.totalAmountWon,
            stats.totalTokensReceived,
            amountSpent,
            executor,
            squares
        );
    }
}
