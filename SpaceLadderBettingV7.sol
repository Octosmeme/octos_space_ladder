// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {VRFConsumerBaseV2Plus} from "@chainlink/contracts/src/v0.8/vrf/dev/VRFConsumerBaseV2Plus.sol";
import {VRFV2PlusClient} from "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";

/// @title SpaceLadderBettingV7
/// @notice Roundless Odd/Even betting. Backend assigns round ids and picks
///         new randomness; the contract has no persistent `currentLegs`.
///         - Per-player cumulative stake per side (single uint96 slot).
///         - VRF callback commits `{roundId, randomWord}`; owner then calls
///           `resolveExternal(_nextRoundId, _currentRoundId, _randomWord)` —
///           the contract re-derives `side`/`legs`/`result` from the
///           committed `_randomWord` and reverts on any mismatch.
///         - `emergencyResolve` refunds every bettor at 1× their stake into
///           the `winnings` pot and clears cycle state — no randomness used.
///         - Eager credit on resolve into a single `winnings[player]` pot.
/// @dev Round ID format (backend-assigned): YYYYMMDDxxx where xxx is a
///      zero-padded 1-288 sequence for the 5-minute slots in a day
///      (24·60/5 = 288). The contract enforces strict monotonic increase
///      on every transition; day rollover works naturally because
///      YYYYMMDD01 < (YYYYMMDD+1)01.
/// @dev Pool solvency is the pool-wallet operator's responsibility. `withdraw
///      Winnings` reverts `InsufficientPool` when the pool is underfunded or
///      under-approved (FCFS). Ownership uses Chainlink's 2-step flow: the
///      deployer is interim owner until `ownerWallet_` calls `acceptOwnership`.
contract SpaceLadderBettingV7 is VRFConsumerBaseV2Plus, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant MIN_MULTIPLIER_BPS = 15_000; // 1.50×
    uint256 public constant MAX_MULTIPLIER_BPS = 30_000; // 3.00×
    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant EMERGENCY_RESOLVE_DELAY = 2 minutes;

    uint8 public constant ODD = 1;
    uint8 public constant EVEN = 2;
    uint8 public constant LEFT = 1;
    uint8 public constant RIGHT = 2;
    uint8 public constant THREE_LEGS = 3;
    uint8 public constant FOUR_LEGS = 4;

    IERC20 public immutable token;
    uint256 public immutable vrfSubscriptionId;
    bytes32 public immutable vrfKeyHash;
    uint32 public immutable vrfCallbackGasLimit;
    uint16 public immutable vrfRequestConfirmations;

    address public poolWallet;

    /// @notice Per-user cumulative bet cap on a single side within a round.
    uint256 public minBet;
    uint256 public maxBet;
    uint256 public multiplierBps;

    bool public isDrawing;
    /// @notice True once VRF committed `currentRandomWord`, false once the
    ///         owner's cross-check finalized the round.
    bool public awaitingCrossCheck;

    /// @notice Round ID format: YYYYMMDDxxx where xxx is a zero-padded
    ///         1-288 sequence for the 5-minute slots in a day (24·60/5 = 288).
    ///         Assigned by the backend; the contract only enforces that
    ///         successive round ids are strictly increasing.
    uint64 public currentRoundId;
    uint256 public currentRandomWord;

    /// @notice Running per-side stake sums for the current cycle; reset on resolve.
    uint256 public oddStaked;
    uint256 public evenStaked;

    uint256 public vrfRequestId;
    uint64 public drawingStartedAt;

    uint8 public lastResult;

    /// @notice Per-player cumulative stake per side for the current cycle.
    ///         Wiped by the resolve sweep.
    mapping(address => uint96) public oddStakeOf;
    mapping(address => uint96) public evenStakeOf;

    /// @notice Iterable unique-player list per side for the current cycle.
    ///         A player is appended when their cumulative stake transitions
    ///         from 0. Deleted on resolve.
    address[] public oddPlayers;
    address[] public evenPlayers;

    /// @notice Claimable pot. Credited on resolve, drained by withdrawWinnings.
    mapping(address => uint256) public winnings;

    event BetPlaced(
        uint256 indexed roundId,
        address indexed player,
        uint8 pick,
        uint256 amount
    );
    event ResolutionClosed(uint256 indexed roundId, uint256 vrfRequestId);
    event ResolvedInternal(uint256 indexed roundId, uint256 randomWord);
    event Resolved(
        uint256 indexed roundId,
        uint8 legs,
        uint8 side,
        uint8 result,
        uint256 randomWord,
        uint256 totalStaked,
        uint256 totalPaid
    );
    event WinningsCreditedBatch(
        uint256 indexed roundId,
        uint8 pick,
        uint256 winnersCount,
        uint256 totalPaid
    );
    event StakeRefundedBatch(
        uint256 indexed roundId,
        uint8 pick,
        uint256 refundedCount,
        uint256 totalRefunded
    );
    event StakeClearedBatch(
        uint256 indexed roundId,
        uint8 pick,
        uint256 clearedCount,
        uint256 totalCleared
    );
    event WinningsWithdrawn(address indexed player, uint256 amount);
    event PoolWalletUpdated(address indexed oldWallet, address indexed newWallet);
    event MultiplierUpdated(uint256 oldBps, uint256 newBps);
    event BetLimitsUpdated(uint256 minBet, uint256 maxBet);
    event EmergencyResolved(uint64 indexed currentRoundId, uint256 totalRefunded);

    error BetTooSmall();
    error BetTooLarge();
    error BetAmountTooLarge();
    error InvalidPick();
    error NotOpen();
    error NotDrawing();
    error AlreadyDrawing();
    error MultiplierOutOfRange();
    error MinExceedsMax();
    error ResolutionNotStuck();
    error UnknownVrfRequest();
    error NothingToClaim();
    error InsufficientPool();
    error InvalidParameter();
    error NotAwaitingCrossCheck();
    error AlreadyAwaitingCrossCheck();
    // ZeroAddress is inherited from VRFConsumerBaseV2Plus.

    constructor(
        address ownerWallet_,
        address token_,
        address poolWallet_,
        address vrfCoordinator_,
        uint256 subscriptionId_,
        bytes32 keyHash_,
        uint32 callbackGasLimit_,
        uint16 requestConfirmations_,
        uint256 initialMinBet,
        uint256 initialMaxBet,
        uint256 initialMultiplierBps,
        uint64 initialRoundId_
    ) VRFConsumerBaseV2Plus(vrfCoordinator_) {
        if (token_ == address(0)) revert ZeroAddress();
        if (poolWallet_ == address(0)) revert ZeroAddress();
        if (vrfCoordinator_ == address(0)) revert ZeroAddress();
        if (ownerWallet_ == address(0)) revert ZeroAddress();
        if (initialMinBet == 0) revert BetTooSmall();
        if (initialMinBet > initialMaxBet) revert MinExceedsMax();
        if (initialMaxBet > type(uint96).max) revert BetAmountTooLarge();
        if (
            initialMultiplierBps < MIN_MULTIPLIER_BPS ||
            initialMultiplierBps > MAX_MULTIPLIER_BPS
        ) revert MultiplierOutOfRange();
        if (initialRoundId_ == 0) revert InvalidParameter();

        // Chainlink ConfirmedOwner is 2-step: this proposes; ownerWallet_
        // must call acceptOwnership() to activate. Deployer is interim owner.
        transferOwnership(ownerWallet_);

        token = IERC20(token_);
        poolWallet = poolWallet_;
        vrfSubscriptionId = subscriptionId_;
        vrfKeyHash = keyHash_;
        vrfCallbackGasLimit = callbackGasLimit_;
        vrfRequestConfirmations = requestConfirmations_;

        minBet = initialMinBet; // 50_000
        maxBet = initialMaxBet; // 100_000_000
        multiplierBps = initialMultiplierBps;
        currentRoundId = initialRoundId_;

        emit PoolWalletUpdated(address(0), poolWallet_);
    }

    // ─── Betting ──────────────────────────────────────────────────────────

    function placeBet(uint8 pick, uint96 amount) external nonReentrant {
        if (isDrawing) revert NotOpen();
        if (pick != ODD && pick != EVEN) revert InvalidPick();
        if (amount < minBet) revert BetTooSmall();

        uint256 prev;
        uint256 newSum;

        if (pick == ODD) {
            prev = uint256(oddStakeOf[msg.sender]);
            newSum = prev + amount;
            if (newSum > maxBet) revert BetTooLarge();
            if (prev == 0) oddPlayers.push(msg.sender);
            oddStakeOf[msg.sender] = uint96(newSum);
            oddStaked += amount;
        } else {
            prev = uint256(evenStakeOf[msg.sender]);
            newSum = prev + amount;
            if (newSum > maxBet) revert BetTooLarge();
            if (prev == 0) evenPlayers.push(msg.sender);
            evenStakeOf[msg.sender] = uint96(newSum);
            evenStaked += amount;
        }

        emit BetPlaced(currentRoundId, msg.sender, pick, amount);

        token.safeTransferFrom(msg.sender, poolWallet, amount);
    }

    /// @notice Single-call claim — pulls the accumulated `winnings[msg.sender]` pot.
    function withdrawWinnings() external nonReentrant {
        uint256 amount = winnings[msg.sender];
        if (amount == 0) revert NothingToClaim();

        winnings[msg.sender] = 0;

        if (_poolHeadroom() < amount) revert InsufficientPool();
        token.safeTransferFrom(poolWallet, msg.sender, amount);

        emit WinningsWithdrawn(msg.sender, amount);
    }

    /// @dev min(poolWallet balance, poolWallet allowance to this contract).
    function _poolHeadroom() internal view returns (uint256) {
        uint256 bal = token.balanceOf(poolWallet);
        uint256 allow = token.allowance(poolWallet, address(this));
        return bal < allow ? bal : allow;
    }

    // ─── Resolution ───────────────────────────────────────────────────────

    function closeAndRequestRandomness(uint64 _nextRoundId)
        external
        onlyOwner
        nonReentrant
        returns (uint256 requestId)
    {
        if (isDrawing) revert AlreadyDrawing();
        if (_nextRoundId <= currentRoundId) revert InvalidParameter();

        isDrawing = true;
        drawingStartedAt = uint64(block.timestamp);

        requestId = s_vrfCoordinator.requestRandomWords(
            VRFV2PlusClient.RandomWordsRequest({
                keyHash: vrfKeyHash,
                subId: vrfSubscriptionId,
                requestConfirmations: vrfRequestConfirmations,
                callbackGasLimit: vrfCallbackGasLimit,
                numWords: 1,
                extraArgs: VRFV2PlusClient._argsToBytes(
                    VRFV2PlusClient.ExtraArgsV1({nativePayment: false})
                )
            })
        );

        vrfRequestId = requestId;

        emit ResolutionClosed(currentRoundId, requestId);
    }

    function fulfillRandomWords(
        uint256 requestId,
        uint256[] calldata randomWords
    ) internal override {
        if (requestId != vrfRequestId) revert UnknownVrfRequest();
        _commitRandomWord(randomWords[0]);
    }

    /// @dev Commits the random word to storage; `resolveExternal` will
    ///      combine it with the owner-supplied legs to derive side/result.
    function _commitRandomWord(uint256 randomWord) internal {
        if (!isDrawing) revert NotDrawing();
        if (awaitingCrossCheck) revert AlreadyAwaitingCrossCheck();

        currentRandomWord = randomWord;
        awaitingCrossCheck = true;

        emit ResolvedInternal(currentRoundId, randomWord);
    }

    /// @notice Owner cross-check + finalize. `_randomWord` + `_currentRoundId`
    ///         must match the committed values. `side`, `legs`, and `result`
    ///         are all re-derived on-chain from `_randomWord` so the owner
    ///         has no knob to nudge the outcome. Legs comes from an unused
    ///         high bit of the same random word.
    function resolveExternal(
        uint64 _nextRoundId,
        uint64 _currentRoundId,
        uint256 _randomWord
    ) external onlyOwner nonReentrant {
        if (!isDrawing) revert NotDrawing();
        if (!awaitingCrossCheck) revert NotAwaitingCrossCheck();
        if (_nextRoundId <= _currentRoundId) revert InvalidParameter();

        // Committed random word + round id must match.
        if (currentRoundId != _currentRoundId || currentRandomWord != _randomWord) revert InvalidParameter();

        // 사다리 traversal must agree: LEFT + 3 legs → EVEN, etc.
        // Legs is derived from an unused bit of the same random word so the
        // owner cannot choose it after seeing the result.
        uint8 derivedSide = (_randomWord & 1) == 1 ? LEFT : RIGHT;
        uint8 derivedLegs = THREE_LEGS + uint8((_randomWord >> 8) & 1);
        uint8 derivedResult = derivedSide == LEFT
            ? (derivedLegs == THREE_LEGS ? EVEN : ODD)
            : (derivedLegs == FOUR_LEGS ? EVEN : ODD);

        uint256 mult = multiplierBps;
        uint256 totalStaked = oddStaked + evenStaked;
        uint256 paid = 0;

        if (totalStaked > 0) {
            if (derivedResult == ODD) {
                paid = _creditAndClear(oddPlayers, oddStakeOf, mult, _currentRoundId, ODD);
                _clearSide(evenPlayers, evenStakeOf, _currentRoundId, EVEN);
            } else {
                paid = _creditAndClear(evenPlayers, evenStakeOf, mult, _currentRoundId, EVEN);
                _clearSide(oddPlayers, oddStakeOf, _currentRoundId, ODD);
            }
        }

        emit Resolved(
            _currentRoundId,
            derivedLegs,
            derivedSide,
            derivedResult,
            _randomWord,
            totalStaked,
            paid
        );

        // ----- 초기화 -----
        delete oddPlayers;
        delete evenPlayers;

        oddStaked = 0;
        evenStaked = 0;
        vrfRequestId = 0;
        lastResult = derivedResult;
        awaitingCrossCheck = false;
        currentRandomWord = 0;

        isDrawing = false;
        currentRoundId = _nextRoundId;
    }

    /// @dev Credit every winner from their cumulative stake at rate `mult`,
    ///      zeroing each stake slot as it's read. Emits a single aggregated
    ///      `WinningsCreditedBatch` event after the loop.
    function _creditAndClear(
        address[] storage players,
        mapping(address => uint96) storage stakeOf,
        uint256 mult,
        uint64 currentId,
        uint8 pick
    ) internal returns (uint256 paid) {
        uint256 plen = players.length;
        uint256 count;
        for (uint256 i = 0; i < plen; ) {
            address p = players[i];
            uint256 stake = uint256(stakeOf[p]);
            if (stake != 0) {
                uint256 payout = (stake * mult) / BPS_DENOMINATOR;
                paid += payout;
                winnings[p] += payout;
                delete stakeOf[p];
                unchecked { ++count; }
            }
            unchecked { ++i; }
        }
        emit WinningsCreditedBatch(currentId, pick, count, paid);
    }

    /// @dev Zero the losing side's stake slots. Emits a single aggregated
    ///      `StakeClearedBatch` event after the loop.
    function _clearSide(
        address[] storage players,
        mapping(address => uint96) storage stakeOf,
        uint64 currentId,
        uint8 pick
    ) internal {
        uint256 plen = players.length;
        uint256 count;
        uint256 total;
        for (uint256 i = 0; i < plen; ) {
            address p = players[i];
            uint256 stake = uint256(stakeOf[p]);
            if (stake != 0) {
                total += stake;
                delete stakeOf[p];
                unchecked { ++count; }
            }
            unchecked { ++i; }
        }
        emit StakeClearedBatch(currentId, pick, count, total);
    }

    /// @dev Refund every bettor on a side at 1× their stake into `winnings`,
    ///      zeroing each stake slot as it's read. Emits a single aggregated
    ///      `StakeRefundedBatch` event after the loop.
    function _refundAndClear(
        address[] storage players,
        mapping(address => uint96) storage stakeOf,
        uint64 currentId,
        uint8 pick
    ) internal returns (uint256 refunded) {
        uint256 plen = players.length;
        uint256 count;
        for (uint256 i = 0; i < plen; ) {
            address p = players[i];
            uint256 stake = uint256(stakeOf[p]);
            if (stake != 0) {
                refunded += stake;
                winnings[p] += stake;
                delete stakeOf[p];
                unchecked { ++count; }
            }
            unchecked { ++i; }
        }
        emit StakeRefundedBatch(currentId, pick, count, refunded);
    }

    // ─── Admin ────────────────────────────────────────────────────────────

    function setPoolWallet(address newPoolWallet) external onlyOwner {
        if (isDrawing) revert AlreadyDrawing();
        if (newPoolWallet == address(0)) revert ZeroAddress();
        address old = poolWallet;
        poolWallet = newPoolWallet;
        emit PoolWalletUpdated(old, newPoolWallet);
    }

    function setMultiplierBps(uint256 newBps) external onlyOwner {
        if (isDrawing) revert AlreadyDrawing();
        if (newBps < MIN_MULTIPLIER_BPS || newBps > MAX_MULTIPLIER_BPS) {
            revert MultiplierOutOfRange();
        }
        uint256 old = multiplierBps;
        multiplierBps = newBps;
        emit MultiplierUpdated(old, newBps);
    }

    function setMinMaxBet(uint256 newMin, uint256 newMax) external onlyOwner {
        if (isDrawing) revert AlreadyDrawing();
        if (newMin == 0) revert BetTooSmall();
        if (newMin > newMax) revert MinExceedsMax();
        if (newMax > type(uint96).max) revert BetAmountTooLarge();
        minBet = newMin;
        maxBet = newMax;
        emit BetLimitsUpdated(newMin, newMax);
    }

    /// @notice Escape hatch when VRF or the resolve flow is stuck past
    ///         `EMERGENCY_RESOLVE_DELAY`. Refunds every bettor at 1× their
    ///         stake into `winnings` and clears cycle state. No randomness
    ///         used — safe regardless of whether VRF already committed.
    function emergencyResolve(uint64 _nextRoundId) external onlyOwner nonReentrant {
        if (!isDrawing) revert NotDrawing();
        if (_nextRoundId <= currentRoundId) revert InvalidParameter();
        if (block.timestamp < drawingStartedAt + EMERGENCY_RESOLVE_DELAY) {
            revert ResolutionNotStuck();
        }

        // --- Refund ---
        uint64 rid = currentRoundId;
        uint256 refunded = _refundAndClear(oddPlayers, oddStakeOf, rid, ODD);
        refunded += _refundAndClear(evenPlayers, evenStakeOf, rid, EVEN);

        // --- Event ---
        emit EmergencyResolved(rid, refunded);

        // --- 초기화 ---
        delete oddPlayers;
        delete evenPlayers;

        oddStaked = 0;
        evenStaked = 0;
        vrfRequestId = 0;
        awaitingCrossCheck = false;
        currentRandomWord = 0;

        isDrawing = false;
        currentRoundId = _nextRoundId;
    }

    // ───────── Views ─────────
    function oddPlayersLength() external view returns (uint256) {
        return oddPlayers.length;
    }

    function evenPlayersLength() external view returns (uint256) {
        return evenPlayers.length;
    }

    function getOddPlayers(uint256 offset, uint256 limit)
        external
        view
        returns (address[] memory)
    {
        return _sliceAddressArray(oddPlayers, offset, limit);
    }

    function getEvenPlayers(uint256 offset, uint256 limit)
        external
        view
        returns (address[] memory)
    {
        return _sliceAddressArray(evenPlayers, offset, limit);
    }

    function getPlayerBettingInfo(address player) external view returns(uint96 oddStake, uint96 evenStake, uint256 claimable) {
        return (oddStakeOf[player], evenStakeOf[player], winnings[player]);
    }

    function _sliceAddressArray(
        address[] storage arr,
        uint256 offset,
        uint256 limit
    ) internal view returns (address[] memory out) {
        uint256 len = arr.length;
        if (offset >= len || limit == 0) return new address[](0);
        uint256 end = offset + limit;
        if (end > len) end = len;
        uint256 n = end - offset;
        out = new address[](n);
        for (uint256 i = 0; i < n; ) {
            out[i] = arr[offset + i];
            unchecked { ++i; }
        }
    }

    function poolBalance() external view returns (uint256) {
        return token.balanceOf(poolWallet);
    }

    function poolAllowance() external view returns (uint256) {
        return token.allowance(poolWallet, address(this));
    }

    function poolAvailable() external view returns (uint256) {
        return _poolHeadroom();
    }

    function snapshot()
        external
        view
        returns (
            uint256 roundId_,
            bool isDrawing_,
            bool awaitingCrossCheck_,
            uint256 oddStaked_,
            uint256 evenStaked_,
            uint256 oddPlayerCount,
            uint256 evenPlayerCount,
            uint8 lastResult_,
            uint64 drawingStartedAt_
        )
    {
        return (
            currentRoundId,
            isDrawing,
            awaitingCrossCheck,
            oddStaked,
            evenStaked,
            oddPlayers.length,
            evenPlayers.length,
            lastResult,
            drawingStartedAt
        );
    }

    /// @notice One-shot config read for frontend init.
    function getInformation()
        external
        view
        returns (
            address pool,
            uint256 minBet_,
            uint256 maxBet_,
            uint256 multiplierBps_,
            uint64 currentRoundId_
        )
    {
        return (poolWallet, minBet, maxBet, multiplierBps, currentRoundId);
    }
}
