// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

/**
 * @title  IBullsEthCRE
 * @notice Public interface for BullsEthCRE. Declares the full external surface: every callable
 *         function, every custom error, every event, with the NatSpec that documents them.
 *         No implementation. Read this to learn what the contract does and how to call it.
 *         Read BullsEthCRE.sol only when you need to know how it works.
 * @dev    Implemented by contract BullsEth. The compiler enforces that this interface and the
 *         implementation cannot drift apart. Public state variable getters are NOT declared
 *         here; read those off the contract.
 *         Version history: CHANGELOG-BullsEthCRE-CRE-arc-consolidated.md
 */
interface IBullsEthCRE {

    // ── Types ───────────────────────────────────────────────────────────────────
    enum GamePhase { PREGAME, ACTIVE, DORMANT, CLOSED }
    enum DrawPhase { IDLE, CUTOFF_SUBMISSION, MATCHING, DISTRIBUTING, FINALIZING, RESET_FINALIZING, UNWINDING }

    // ── Errors ──────────────────────────────────────────────────────────────────
    error GameNotActive();
    error GameNotClosed();
    error DrawInProgress();
    error NotEnoughPlayers();
    error MaxPlayersReached();
    error OwnableUnauthorizedAccount(address account);
    error AlreadyRegistered();
    error NotRegistered();
    error AlreadyOG();
    error OGCapReached();
    error NotOG();
    error NotEligible();
    error PicksLocked();
    error AlreadyBoughtThisWeek();
    error InvalidPrediction();
    error InvalidAddress();
    error FeedUnchanged();
    error InsufficientBalance();
    error TreasuryLocked();
    error NothingToClaim();
    error InsufficientGasForBatch();
    error ResetRefundNotEligible();
    error ResetRefundExpired();
    error AlreadyClaimed();
    error WrongPhase();
    error TooEarly();
    error CooldownActive();
    error ExceedsLimit();
    error BelowMinimum();
    error CanOnlyDecrease();
    error NotStuck();
    error DrawNotProgressing();
    error MalformedPerformData();
    error SolvencyCheckFailed();
    error TimelockPending();
    error NoTimelockPending();
    error GameAlreadyClosed();
    error SignupNotFailed();
    error PregameWindowExpired();
    error AlreadyRefunded();
    error MinimumTicketsRequired();
    error GameNotDormant();
    error AlreadyCommitted();
    error DormancyWindowExpired();
    error NotQualifiedForEndgame();
    error NotEnoughValidPrices();
    error SequencerNotReady();
    error PotBelowTrajectory();
    error BreathUnchanged();
    error RenounceOwnershipDisabled();
    error OwnershipTransferExpired();
    error TreasuryBonusProtected(uint256 required, uint256 available);
    error SeedNotDeposited(); // [CRE v0.4 / SE-H-01] startGame() fired without VC seed deposited
    error PotAlreadySeeded();
    error IntentQueueFull(); // [v1.57-P1] never fired -- intent queue removed
    error AlreadyInIntentQueue(); // [v1.57-P1] kept for ABI compat
    error NoIntentPending(); // [v1.57-P1] never fired -- intent queue removed
    error IntentWindowExpired(); // [v1.57-P1] never fired -- intent queue removed
    error IntentQueueNotEmpty(); // kept for ABI compat, no longer fired
    error DeclineWindowExpired();
    error NotInDeclineWindow();
    error ActiveDeclineWindowOpen(); // [v1.57-P1] never fired -- retained for ABI compat
    error PregameOGNetNotSet(); // [v1.57] never fired -- guard removed
    error FeedDecimalsMismatch();
    error UnknownAction(uint8 action);
    error CutoffOutOfRange();
    error InvalidCutoffOrder();

    // ── Events ──────────────────────────────────────────────────────────────────
    event StaleOGsPruned(uint256 pruned, uint256 remaining);
    event PlayerRegistered(address indexed player, uint256 totalPlayers);
    event CommitmentPaid(address indexed player, uint256 amount);
    event CommitmentDoublePaid(address indexed player, uint256 amount);
    event CommitmentDoubleUnused(address indexed player, uint256 amount);
    event CommitmentCreditExpired(address indexed player, uint256 creditAmount);
    event UpfrontOGRegistered(address indexed player, uint256 prediction, uint256 prediction2, uint256 ogCount);
    event WeeklyOGRegistered(address indexed player, uint256 prediction, uint256 prediction2, uint256 draw);
    event WeeklyOGStatusLost(address indexed player, uint256 atDraw);
    event TicketsBought(address indexed player, uint256 draw, uint256 ticketCount);
    event TierSkippedDust(uint256 indexed tier, uint256 amount);
    event PredictionSubmitted(address indexed player, uint256 prediction, uint256 draw);
    event Prediction2Submitted(address indexed player, uint256 prediction2, uint256 draw);
    event AutoPrediction2Applied(address indexed player, uint256 indexed draw, uint256 prediction2);
    event GameStarted(uint256 timestamp, uint256 totalPlayers);
    event StartGameProposed(uint256 launchNotBefore);
    event StartGameProposalCancelled();
    event FeedSubstituted(address indexed oldFeed, address indexed newFeed);
    event SignupRefund(address indexed player, uint256 amount, uint256 fullAmount);
    event DrawResolved(uint256 indexed draw, int256 resolvedPrice);
    /// @notice [v1.15 / C-01] Emitted when a draw settles via the pinned path. slotTimestamp
    ///         is the scheduled settlement moment the round was pinned against, so anyone can
    ///         independently verify the correct round was used.
    event SettlementRoundPinned(uint256 indexed draw, uint80 roundId, int256 price, uint256 slotTimestamp);
    event AutoPredictionApplied(address indexed player, uint256 indexed draw, uint256 prediction);
    event AutomationForwarderSet(address indexed forwarder);
    event CreForwarderSet(address indexed forwarder);
    event CreReportProcessed(uint8 indexed action, uint256 indexed draw);
    event SignupRefundSkipped(address indexed player);
    event MatchingComplete(uint256 indexed draw, uint256 totalWinners);
    /// @notice [v1.14 / H-01] Emitted when a draw has bounced MAX_CUTOFF_ATTEMPTS times on
    ///         cutoff reconciliation. From this point emergencyResetDraw() is available to the
    ///         owner immediately, without waiting out DRAW_STUCK_TIMEOUT. Treat as: this draw is
    ///         very likely unsatisfiable, stop resubmitting and reset it.
    event CutoffAttemptsExhausted(uint256 indexed draw, uint256 attempts);
    event MatchCountMismatch( uint256 indexed draw, uint256 t1Actual, uint256 t12Actual, uint256 t123Actual, uint256 snapshot );
    event MatchingBatchProcessed(uint256 indexed draw, uint256 processed, uint256 total);
    event PrizeDistributed(address indexed winner, uint256 amount, uint256 tier);
    event CutoffDiffsSubmitted( uint256 indexed draw, uint256 t1CutoffDiff, uint256 t2CutoffDiff, uint256 t3CutoffDiff, uint256 t1Count, uint256 t2Count, uint256 t3Count );
    event SeedReturned(uint256 indexed draw, uint256 amount);
    event WeekFinalized(uint256 indexed draw);
    event GameClosed(uint256 perOG, uint256 surplusToTreasury, uint256 qualifiedOGs);
    event YieldCaptured(uint256 yieldAmount);
    event AccountingDiscrepancy(uint256 trackedUnclaimed, uint256 claimAmount);
    event SolvencyAlert(uint256 indexed allocated, uint256 balance, bytes32 context);
    event SolverDistressSignal(uint256 indexed draw, uint256 pot, uint256 floor, uint256 drawsLeft, uint256 projectedAtZero);
    /// @notice [v1.14 / H-06] Emitted when the geometric solver returns a breath rate BELOW
    ///         breathRailMin because holding the rail would draw prizePot below requiredEndPot.
    ///         Solvency overrides the prize-experience floor. appliedBps may be 0, meaning the
    ///         draw distributes no prizes at all. Wire monitoring to this: it is the earliest
    ///         on-chain signal that the season is not tracking its obligations.
    event BreathRailReleased(uint256 indexed draw, uint256 railMinBps, uint256 appliedBps, uint256 pot, uint256 requiredFloor);
    event OGDeclineWindowOpened(address indexed player, uint256 windowExpiry);
    event OGRegistrationCancelled(address indexed player, uint256 netRefund);
    event EndgameClaimed(address indexed og, uint256 amount);
    event TreasuryWithdrawal(uint256 amount, address recipient);
    event UnclaimedFundsSwept(bytes32 indexed reason, uint256 amount);
    event TreasuryAccrual(uint256 indexed draw, uint256 amount, uint256 rateBps);
    event PrizeRateReductionProposed(uint256 newMultiplier, uint256 effectiveTime, bytes32 reason);
    event PrizeRateReductionExecuted(uint256 oldMultiplier, uint256 newMultiplier, bytes32 reason);
    event PrizeRateReductionCancelled();
    event PrizeRateIncreaseProposed(uint256 newMultiplier, uint256 effectiveTime, bytes32 reason);
    event PrizeRateIncreaseExecuted(uint256 oldMultiplier, uint256 newMultiplier, bytes32 reason);
    event PrizeRateIncreaseCancelled();
    event FeedStaleFallback();
    event ReserveFeedUsed(address indexed feed, uint256 indexed draw);
    event FeedChangeProposed(address newFeed, uint256 effectiveTime);
    event FeedChangeExecuted(address oldFeed, address newFeed);
    event FeedChangeCancelled();
    event EmergencyReset(uint256 indexed draw, DrawPhase fromPhase, uint256 amountReturned);
    event EmergencyUnwindBatch(uint256 indexed draw, uint256 unwoundSoFar, uint256 total);
    event PredictionResetOnUnwind(address indexed player, uint256 indexed draw);
    event EmergencyUnwindComplete(uint256 indexed draw, uint256 total);
    event PrizeClaimed(address indexed player, uint256 amount);
    event DormancyActivated(uint256 timestamp);
    event DormancyClaimDeadline(uint256 deadline);
    event DormancyRefund(address indexed player, uint256 amount);
    event DormancyProposed(uint256 effectiveTime);
    event DormancyCancelled();
    event ResetRefundClaimed(address indexed player, uint256 indexed draw, uint256 amount);
    event ResetRefundPartial(address indexed player, uint256 indexed draw, uint256 paid, uint256 owed);
    event ResetRefundExpiredSwept(uint256 indexed draw, uint256 amount);
    event ResetRefundSkipped(uint256 indexed draw, uint256 unprotectedTicketTotal);
    event ResetRefundOverflow(uint256 indexed draw, uint256 amount);
    event CommitmentRefundActivated(uint256 indexed draw, uint256 poolAmount);
    event CommitmentRefundClaimed(address indexed player, uint256 amount);
    event CommitmentRefundPartial(address indexed player, uint256 paid, uint256 owed);
    event CommitmentRefundExpiredSwept(uint256 indexed draw, uint256 amount);
    event DormancyRemainderSwept(uint256 toProtocolBeneficiary);
    event FailedPregameSwept(uint256 toProtocolBeneficiary);
    event FailedPregameSeedReturned(uint256 seedReturned);
    event StreakBroken(address indexed player, uint256 previousStreak);
    event EarnedOGQualified(address indexed player, uint256 atDraw);
    event OGObligationLocked(uint256 obligation, uint256 requiredPot, uint256 qualifiedOGs);
    event OGObligationSnapshot(uint256 indexed draw, uint256 oldObligation, uint256 newObligation, uint256 oldRequiredPot, uint256 newRequiredPot, uint256 ogCount);
    event BreathMultiplierAdjusted(uint256 oldMultiplier, uint256 newMultiplier, bool isUp);
    event BreathOverrideProposed(uint256 indexed newMultiplier, uint256 effectiveTime, bytes32 reason);
    event BreathOverrideCancelled(uint256 cancelledMultiplier);
    event BreathOverrideExecuted(uint256 oldMultiplier, uint256 newMultiplier, bytes32 reason);
    event BreathRailsUpdated(uint256 newMin, uint256 newMax, uint256 atDraw);
    event BreathRailsProposed(uint256 newMin, uint256 newMax, uint256 effectiveTime, bytes32 reason);
    event BreathRailsProposalCancelled(uint256 cancelledMin, uint256 cancelledMax);
    event OGIntentForceDeclineFailed(address indexed player, uint256 amount); // [v1.57-P1] never emitted -- forceDeclineIntent removed
    event EndgameShortfall(uint256 perOGPaid, uint256 perOGPromised, uint256 shortfallTotal);
    event PlayerLapsed(address indexed player, uint256 atDraw);
    event PlayerUnlapsed(address indexed player, uint256 atDraw);
    event BreathCalibrated( uint256 ogRatioBps, uint256 targetReturnBps, uint256 initialBreathBps, uint256 ogBreathBps, uint256 t3FloorBps, uint256 estimatedEntriesDraw1 );
    event FinalReturnCalibrated(uint256 indexed draw, uint256 oldTargetBps, uint256 newTargetBps, uint256 newRatioBps, uint256 newRequiredEndPot);
    event ExhaleFloorReleaseProposed(uint256 newBps, uint256 executeAfter);
    event ExhaleFloorReleaseUpdated(uint256 oldBps, uint256 newBps);
    event ExhaleFloorReleaseCancelled(uint256 cancelledBps);
    event Draw30BonusReturned(uint256 amount);
    event BreathRecalibrated(uint256 oldTargetBps, uint256 newTargetBps, uint256 oldBreath, uint256 computedBreath, uint256 actualRatioBps);
    event OGIntentRegistered(address indexed player, uint256 queueIndex, uint256 amount); // [v1.57-P1] never emitted -- intent queue removed
    event OGIntentOffered(address indexed player, uint256 windowExpiry); // [v1.57-P1] never emitted
    event OGIntentDeclined(address indexed player, uint256 netRefund, uint256 grossAmount, uint256 depositKept); // [v1.57-P1] never emitted
    event OGIntentSwept(address indexed player); // [v1.57-P1] never emitted
    event OGIntentForcedDeclined(address indexed player, uint256 refund, uint256 grossAmount); // [v1.57-P1] never emitted
    event ForceDeclineRefundClaimed(address indexed player, uint256 amount);
    event OGSlotsConfirmed(uint256 confirmed, uint256 pendingRemaining); // [v1.57-P1] never emitted -- confirmOGSlots removed
    event DefaultPredictionUpdated(uint256 oldPrediction, uint256 newPrediction);
    event PotSeeded(uint256 amount, address indexed seeder);
    event SeedSupplementPaid(uint256 indexed draw, uint256 supplement, uint256 totalSeedReleased);
    event SeedT3FloorTopup(uint256 indexed draw, uint256 topupRecorded, uint256 t3Winners);
    event SeedReleaseRatioProposed(uint256 indexed newRatio, uint256 effectiveTime);
    event SeedReleaseRatioExecuted(uint256 indexed oldRatio, uint256 indexed newRatio);
    event SeedReleaseRatioCancelled(uint256 indexed cancelledRatio);
    event VCReturnClaimed(uint256 amount);

    // ── Functions ───────────────────────────────────────────────────────────────

    /// @notice Seeds the prize pot with exactly VC_SEED USDC. Callable once during PREGAME only.
    ///         VC capital goes 100% to prizePot — no treasury slice on seed.
    ///         The seed supplement activates only after SEED_RELEASE_THRESHOLD of cumulative
    ///         season treasury is earned AND seedReleaseRatioBps > 0.
    ///         [CRE v0.2 / LOW-01] Restricted to onlyOwner (was permissionless). A stranger calling
    ///         this would pull VC_SEED from their own wallet and route it to VC_SEED_RETURN_ADDRESS
    ///         at close — not theft, but an accidental donation. Phase gate added: PREGAME only.
    ///         A post-game call would seed a closed/dormant contract with no distribution path.
    function seedPot() external;

    /// @notice Registers the caller as a player. Required before any other action.
    function register() external;

    /// @notice Pays the pregame ticket commitment and locks in a prediction. PREGAME only.
    /// @param prediction  ETH/USD price prediction in USD cents.
    function payCommitment(uint256 prediction) external;

    /// @notice Pregame double-ticket commitment. Pays 2x TICKET_PRICE upfront.
    ///         WARNING [v1.54]: If the player buys only 1 ticket on draw 1, the second credit
    ///         is NOT refunded -- it is forfeited to the prize pool. CommitmentDoubleUnused fires
    ///         on draw 2 when the expired credit is detected. Players uncertain about buying 2 tickets
    ///         on draw 1 should use payCommitment() (single) instead. This is by design: the double
    ///         commitment signals intent to play 2 tickets from day one.
    /// @param prediction   First ETH/USD prediction (USD cents).
    /// @param prediction2  Second ETH/USD prediction (USD cents).
    function payCommitmentDouble(uint256 prediction, uint256 prediction2) external;

    /// @notice Registers caller as an Upfront OG. Pays OG_UPFRONT_COST immediately.
    ///         OG status is GRANTED IMMEDIATELY -- no queue, no owner confirmation needed.
    ///         If a pregame commitment credit was applied, that credit is forfeited on
    ///         cancellation -- only the OG transfer net of 25% is returned.
    ///         A 72-hour voluntary decline window opens. Call cancelOGRegistration() within
    ///         72 hours for a 75% refund (25% treasury slice non-refundable as commitment).
    ///         [CRE v0.2 / LOW-02] was "90% refund (10% treasury slice)". Rates updated for flat 25%.
    ///         After 72 hours the registration is permanent.
    /// @dev [v1.57-P1] Intent queue removed entirely. No PENDING status. No confirmOGSlots().
    ///      No ratio cap on OG registration. Any number of OGs can register.
    ///      Game can start with 100% OGs if that is what happens -- economics handle it.
    /// @param prediction   ETH/USD price in USD cents. Primary prediction for all draws.
    /// @param prediction2  Secondary prediction (second match entry). May equal prediction.
    function registerAsOG(uint256 prediction, uint256 prediction2) external;

    /// @notice Cancels an OG registration within the 72-hour decline window.
    ///         Returns 75% of the OG transfer (ogTransfer * 75%).
    ///         The 25% treasury slice is non-refundable -- it was the commitment signal.
    ///         [CRE v0.2 / LOW-02] was "90% / 10%" — updated for flat 25% treasury.
    ///         If a commitment credit was applied at registration, the credit is forfeited.
    ///         This is voluntary consumer protection. The window is player-controlled.
    ///         Re-registration: cancelling does NOT set dormancyRefunded. The player may
    ///         call registerAsOG() again (paying another 25% treasury slice each time).
    ///         Each attempt costs the same treasury signal. This is intentional.
    /// @dev [v1.57-P1] Replaces claimOGIntentRefund(). No queue state to unwind.
    ///      Uses stored ogCancelRefund mapping to avoid mixed-rate calculation errors
    ///      (commitment paid 25% treasury; OG transfer paid 25% UF treasury).
    ///      [CRE v0.5 / NS] Corrected from "15%/10%" — both rates are now 25% in CRE v0.1+.
    function cancelOGRegistration() external;

    /// @notice Claims any outstanding force-decline refund owed to the caller.
    /// @dev [v1.57-P1] forceDeclineIntent() was removed with the intent queue.
    ///      forceDeclineRefundOwed[] is never written in the new design.
    ///      This function always reverts NothingToClaim() for any new deployment.
    ///      Retained for ABI compatibility with tooling built against earlier versions.
    function claimForceDeclineRefund() external;

    /// @notice Registers caller as a Weekly OG. Pays 2x TICKET_PRICE. PREGAME only.
    ///         Weekly OGs must buy tickets every draw to maintain status.
    ///         Missing a draw loses status -- no mulligan in BullsEth.
    ///         Note: weekly OG registration has NO 72-hour decline window.
    ///         Unlike registerAsOG(), this registration is immediate and permanent.
    ///         Weekly OG slots may be fully consumed by upfront OG uptake if
    ///         upfrontOGCount exceeds TOTAL_OG_CAP_BPS% of committed players.
    /// @dev [v1.57-P1] startGameProposedAt guard now throws TimelockPending (was ActiveDeclineWindowOpen).
    ///      Weekly OG ratio cap (_weeklyOGCapReached) still enforced. Upfront OG cap removed.
    /// @param prediction   First ETH/USD prediction for the current draw (USD cents).
    /// @param prediction2  Second ETH/USD prediction for the current draw (USD cents).
    function registerAsWeeklyOG(uint256 prediction, uint256 prediction2) external;

    /// @notice Sets the global auto-default prediction value. Owner only.
    /// @param _prediction  Default prediction in USD cents. Used when autoDefaultCents == 0.
    function setDefaultPrediction(uint256 _prediction) external;

    /// @notice Proposes game start with START_GAME_NOTICE_PERIOD (72h) notice.
    ///         Requires MIN_PLAYERS_TO_START (500) committed players.
    /// @dev [v1.57-P1] pendingIntentCount check removed -- intent queue eliminated.
    function proposeStartGame() external;

    /// @notice Cancels a pending startGame() proposal. Owner only.
    function cancelStartGameProposal() external;

    /// @notice Starts the game, sets draw 1, calibrates breath from OG ratio.
    /// @dev [v1.57-P2] STEP 1 computes targetReturnBps from actual OG ratio (50% at <=20% OG,
    ///      linear to 10% at 100% OG). [CRE v0.2 / LOW-02] corrected from "90%/30%". STEP 2 derives ogBreath from targetReturnBps.
    ///      STEP 3 takes max(ogBreath, t3FloorBreath) as starting breathMultiplier.
    /// @dev [v1.58-P3] Locks OG obligation immediately. Runs geometric solvency check.
    ///      Reverts with PotBelowTrajectory if the game cannot honour obligations at breathRailMin.
    ///      [v1.62] _simGeomPot does not model the draw30BonusFund injection at draw 30.
    ///      In reality the draw-30 pot = simulated_pot + draw30BonusFund accumulated,
    ///      so the solvency check underestimates the final pot. Conservative (pessimistic).
    function startGame() external;

    /// @notice Claims registration refund if the game never started. PREGAME only.
    ///         If contract balance is insufficient for a full refund (rare: requires
    ///         large OG cancellations to drain treasury in pregame), refunds are
    ///         first-come-first-served. The SignupRefund event captures actual vs owed.
    function claimSignupRefund() external;

    /// @notice Removes stale weekly OGs from ogList. Callable by owner, automationForwarder, or
    ///         creForwarder [CRE v1.0], and reachable via onReport (ACTION_PRUNE = 4).
    /// @dev [v1.54] M-02 FIX: accessible to automationForwarder as well as owner.
    ///      Stale OGs each consume one slot of the MAX_MATCH_PER_TX budget per batch
    ///      without producing match results -- reducing effective throughput per call.
    ///      Keepers must call this regularly (every draw cycle) to prevent throughput degradation.
    ///      Risk: if stale OG count approaches MAX_MATCH_PER_TX (500), draws stall.
    /// @param maxPrune  Maximum number of stale OGs to remove in this call. Must be <= MAX_LAPSE_BATCH (500).
    function pruneStaleOGs(uint256 maxPrune) external;

    /// @notice Buys 1 or 2 tickets for the current draw. ACTIVE phase only.
    /// @dev [v2.15] Treasury rate is flat TREASURY_BPS on all draws. [CRE v0.1] TREASURY_BPS = 2500 (25%).
    ///      Commitment credit applied at the same flat rate -- no rate asymmetry.
    /// @param ticketCount  Number of tickets to buy (1 or 2). Weekly OGs must buy 2.
    function buyTickets(uint256 ticketCount) external;

    /// @notice Submits or updates the first prediction for the current draw.
    /// @param prediction  ETH/USD price prediction in USD cents.
    function submitPrediction(uint256 prediction) external;

    /// @notice Submits or updates the second prediction for the current draw
///         (OGs and players who bought 2 tickets this draw). [v2.35 NS-L-02]
///         After v2.34 M-01, 2-ticket casuals who do not call this function receive
///         an auto-default second entry at matching time. Frontends should surface
///         this function to all lastTicketCount>=2 players, not OGs only.
    /// @param prediction2  Second ETH/USD price prediction in USD cents.
    function submitPrediction2(uint256 prediction2) external;

    /// @notice Resolves ETH price and transitions to CUTOFF_SUBMISSION.
    /// @dev    Precondition: none. PERMISSIONLESS, any address may call, and the only timing
    ///         gate is a lower bound (block.timestamp >= lastDrawTimestamp + DRAW_COOLDOWN).
    ///         There is no upper bound, so the caller chooses the instant at which the price is
    ///         read and therefore the value every prediction is scored against. Known open
    ///         finding; see KNOWN_ISSUES section A. Integrators and players should be aware that
    ///         settlement timing is not currently deterministic.
    /// @dev    [v1.0] FLOW CHANGE: transitions to CUTOFF_SUBMISSION not MATCHING.
    ///         Keeper must call submitCutoffDiffs() before processMatches() can run.
    ///         snapshotTotalEntries captured here for verification.
    ///         tier1-4Band computation removed. Dynamic cutoffs replace fixed bands.
    function resolveWeek() external;

    /// @notice [v1.15 / C-01] Normal settlement. Permissionless, and deterministic: the
    ///         caller supplies the FIRST feed round at or after this draw's scheduled slot,
    ///         so every honest caller settles on the same price regardless of when they
    ///         call. Supersedes resolveWeek(), which is now owner/keeper only and delayed.
    /// @dev    Precondition: none, PERMISSIONLESS. Off-chain: walk back from
    ///         latestRoundData until updatedAt < lastDrawTimestamp + DRAW_COOLDOWN, then
    ///         take the round after it. Reverts NotEnoughValidPrices if the round is not
    ///         valid or is not the first qualifying one.
    function resolveWeek(uint80 roundId) external;

    /// @notice Runs the prize matching pass for the current draw.
    /// @dev    Precondition: none. PERMISSIONLESS, any address may call. The prior "callable by
    ///         keeper or owner" wording was wrong: the implementation carries no access control,
    ///         only a drawPhase == MATCHING check. Keeper and owner are the expected callers in
    ///         normal operation, not the permitted set.
    function processMatches() external;

    /// @dev [v1.54] L-02 FIX: address(0) permitted to DISABLE automation forwarder.
    ///      Use during key compromise recovery -- disables performUpkeep/submitCutoffDiffs
    ///      from the compromised key until a replacement is set. Manual keeper calls still work.
    ///      INCIDENT RUNBOOK [CRE v1.0 / seam L-01]: as of the CRE seam there are TWO delivery
    ///      paths. Revoking keeper access on a compromise now requires zeroing BOTH:
    ///      setAutomationForwarder(address(0)) AND setCreForwarder(address(0)). Zeroing only one
    ///      leaves the other live. After both are zeroed the owner submits cutoffs directly.
    /// @param forwarder  New automation forwarder address. address(0) disables automation.
    function setAutomationForwarder(address forwarder) external;

    /// @notice Sets the CRE delivery address. Owner only. address(0) disables CRE.
    /// @dev Mirrors setAutomationForwarder's blocklist.
    ///      [v1.16 / C-02] Set this to a deployed CreReportGuard, NOT to the chain-level
    ///      KeystoneForwarder. The forwarder is shared, so pointing at it directly makes the
    ///      msg.sender check in onReport meaningless. See the note on onReport.
    /// @param forwarder  New CRE delivery address. address(0) disables.
    function setCreForwarder(address forwarder) external;

    /// @notice Applies auto-default predictions to a batch of players for the current draw.
    /// @param players_  Array of player addresses to apply auto-default to.
    function applyAutoPicksForDraw(address[] calldata players_) external;

    /// @notice Chainlink Automation compatibility. Returns upkeepNeeded and encoded action.
    ///         Action 1: advance draw phase (MATCHING/DISTRIBUTING/FINALIZING/UNWINDING).
    ///         Action 2: apply auto-picks before PICK_DEADLINE.
    ///         Action 3: prune stale OGs (fires when stale count >= STALE_OG_PRUNE_THRESHOLD). [v1.55]
    ///         CUTOFF_SUBMISSION is never returned as upkeepNeeded -- keeper submits diffs directly.
    /// @dev ACTION-2 NOTE: action 2 is a TIMING SIGNAL. Automation passes back abi.encode(uint8(2))
    ///      (32 bytes, no player list). performUpkeep handles this gracefully as a no-op.
    ///      To force-apply auto-picks for specific players, call applyAutoPicksForDraw() directly.
    /// @dev [v1.1] CUTOFF_SUBMISSION phase: returns (false, "") not (true, action1).
    ///      Chainlink Automation cannot advance CUTOFF_SUBMISSION -- calling performUpkeep
    ///      reverts DrawNotProgressing, which would burn LINK on every retry for 48h.
    ///      Keeper detects drawPhase == CUTOFF_SUBMISSION from on-chain state,
    ///      computes cutoff diffs off-chain, calls submitCutoffDiffs() directly.
    function checkUpkeep(bytes calldata) external view returns (bool upkeepNeeded, bytes memory performData);

    /// @notice Chainlink Automation entry point. Executes the scheduled upkeep action.
    /// @param performData  ABI-encoded uint8 action code from checkUpkeep.
    function performUpkeep(bytes calldata performData) external;

    /// @notice Chainlink CRE delivery entry point. Called by the KeystoneForwarder
    ///         after DON signature verification. Routes to INTERNAL cores.
    /// @dev holds nonReentrant; routed targets must not also hold it. pruneStaleOGs
    ///      is public with an auth guard that ACCEPTS creForwarder; the internal call preserves
    ///      msg.sender == creForwarder, which its auth accepts. Unknown action -> UnknownAction.
    /// @dev [v1.16 / C-02] METADATA IS DELIBERATELY UNREAD HERE, AND THAT IS ONLY SAFE ON ONE
    ///      DEPLOYMENT SHAPE. The prior wording, "forwarder gate is the trust root", was true
    ///      only if creForwarder is an address that nothing but our own workflow can cause to
    ///      call. The chain-level Chainlink KeystoneForwarder is NOT that: it is a shared
    ///      singleton and any party can register a workflow pointing at an arbitrary receiver.
    ///      Setting creForwarder directly to it therefore lets a stranger's workflow reach
    ///      submitCutoffDiffs, closeGame and resolveWeek.
    ///      REQUIRED DEPLOYMENT: point creForwarder at a dedicated CreReportGuard which
    ///      validates the workflow identity from the report envelope and only then relays
    ///      here. With that in place this contract's msg.sender check is true by construction
    ///      and the metadata check lives in a small contract that can be redeployed if
    ///      Chainlink changes the envelope, without touching this one.
    ///      DO NOT point creForwarder at the shared forwarder.
    /// @param report  abi.encode(uint8 action, bytes payload).
    function onReport(bytes calldata /* metadata */, bytes calldata report) external;

    /// @notice Runs the prize distribution pass for the current draw. Callable by anyone.
    function distributePrizes() external;

    /// @notice Finalises the current draw. Advances to the next draw or closes the game.
    /// @dev    Precondition: none. PERMISSIONLESS, any address may call. Gated only on
    ///         drawPhase being FINALIZING or RESET_FINALIZING.
    function finalizeWeek() external;

    /// @notice Permissionless draw step progression.
    /// @dev    [v1.0] CUTOFF_SUBMISSION cannot auto-advance (requires keeper computation).
    ///         Returns DrawNotProgressing for that phase.
    function completeDrawStep() external;

    /// @notice Settles the game. Distributes endgame pot to qualified OGs.
    ///         perOGPromised = OG_UPFRONT_COST * avgTargetReturnBps / 10000
    ///         where avgTargetReturnBps is derived from the season-average OG ratio.
    ///         Callable by owner, automationForwarder, or creForwarder [CRE v1.0], and reachable
    ///         via onReport (ACTION_CLOSE_GAME = 5).
    /// @dev [v1.57-P2] OG endgame cap is targetReturnBps% of cost, not full cost.
    ///      Surplus above the cap goes to treasury. Shortfall emits EndgameShortfall.
    /// @dev [v1.59] perOGPromised uses season-average OG ratio across non-reset draws.
    ///      Prevents a late-game ratio spike from retroactively cutting OG returns.
    ///      Reset-finalize draws excluded. Draw 30 also excluded from accumulator
    ///      (v2.30 SSoT guard) -- only draws 1-29 are counted. See the ogRatioDrawCount dev-note.
    ///      NOTE: P3 solvency check targets pot adequacy for draw-1 targetReturnBps only.
    ///      If the OG ratio drops mid-season (fewer OGs stay), avgTargetReturnBps rises
    ///      above the draw-1 value (lower ratio = higher return per P2 curve).
    ///      Extra casual revenue from the ratio drop typically funds the difference,
    ///      but this is not guaranteed by mathematical proof. See deployment documentation.
    ///      Falls back to live ratio if accumulator is zero (should never occur).
    function closeGame() external;

    /// @notice Claims VC principal return + SmartEarn bonus after settlement. Routes to
    ///         VC_SEED_RETURN_ADDRESS (immutable). FULLY PERMISSIONLESS [CRE v1.0 / B-L-02]:
    ///         anyone may call the moment the game is settled. No owner gate and no time gate.
    ///         (Supersedes the v0.14 owner-any-time / anyone-after-180-day design; the old
    ///         ENDGAME_SWEEP_WINDOW gate no longer applies to this function.)
    ///         vcReturnOwed is set by closeGame() or sweepDormancyRemainder().
    /// @dev    [CRE v1.0 / B-L-02] The destination is immutable and the amount deterministic, so
    ///         any auth added a liveness dependency (owner key loss would permanently strand
    ///         vcReturnOwed — no sweep includes it) without any security benefit (funds can ONLY
    ///         ever go to VC_SEED_RETURN_ADDRESS). Making it fully permissionless from settlement
    ///         means nobody — including the operator — can withhold the investor's principal, and
    ///         it removes the 180-day wait that the earlier fallback imposed. Same anti-lock
    ///         rationale as the permissionless sweeps.
    /// @dev    [CRE v0.6 / INFO-02] On the dormancy (emergency shutdown) path, vcReturnOwed
    ///         is not set until sweepDormancyRemainder(), which requires the full 90-day
    ///         DORMANCY_CLAIM_WINDOW to elapse. The dormancyVCPool senior tier is reserved at
    ///         activateDormancy() but is not payable here until that window closes. The VC
    ///         should expect a minimum 90-day wait for principal on an early shutdown.
    function claimVCReturn() external;

    /// @notice Proposes a new seedReleaseRatioBps. Executes after SEED_RATIO_TIMELOCK (7 days).
    ///         0 = pause all seed release. MAX_SEED_RELEASE_RATIO_BPS is the hard cap at deploy.
    /// @dev    [CRE v0.10 / NS-L-01] PHASE GATES: callable only in ACTIVE + IDLE (not PREGAME,
    ///         DORMANT, or CLOSED, and not mid-draw). EFFECTIVE TIMING: the 7-day timelock means a
    ///         ratio proposed at season start cannot take effect until roughly draw 3-4 (draw cadence
    ///         dependent), so the earliest seed supplement a governance change enables is that draw,
    ///         not draw 1. Material to SmartEarn/VC term sheets: the VC cannot rely on a ratio change
    ///         landing sooner than the timelock permits. A pending proposal is auto-cancelled by
    ///         proposeDormancy() [D-L-01].
    function proposeSeedReleaseRatio(uint256 newRatio) external;

    /// @notice Executes a pending seedReleaseRatioBps change after the timelock.
    /// @dev    [CRE v0.11 / D4-I-01] ACTIVE + IDLE gates added for uniformity with sibling execute
    ///         functions. Execution outside ACTIVE was harmless (seedReleaseRatioBps is read once
    ///         per draw in _calculatePrizePools(), effective next draw), but the asymmetry was a
    ///         review flag. cancelSeedReleaseRatio() intentionally stays ungated (cancel must work
    ///         in any phase, e.g. after proposeDormancy() has moved the game toward DORMANT).
    function executeSeedReleaseRatio() external;

    /// @notice Cancels a pending seedReleaseRatioBps proposal.
    function cancelSeedReleaseRatio() external;

    /// @notice Claims the OG endgame payout after closeGame(). The payout is CAPPED at the
    ///         targeted return and is NOT guaranteed: it may be reduced on shortfall, in which
    ///         case closeGame() emits EndgameShortfall. See closeGame() for the conditions under
    ///         which a shortfall is reachable.
    function claimEndgame() external;

    /// @notice Sweeps unclaimed endgame payouts to the protocol beneficiary after claim window. Owner only.
    /// @dev    Callable once block.timestamp >= settlementTimestamp + ENDGAME_SWEEP_WINDOW
    ///         (180 days). settlementTimestamp is set by closeGame(), sweepDormancyRemainder(),
    ///         or sweepFailedPregame() -- whichever first transitions game to CLOSED.
    ///         After this call swept endgame amounts are unrecoverable by individual OGs.
    function sweepUnclaimedEndgame() external;

    /// @notice Sweeps unclaimed draw prizes to the protocol beneficiary after claim window. Owner only.
    /// @dev    Callable once block.timestamp >= settlementTimestamp + ENDGAME_SWEEP_WINDOW
    ///         (180 days). settlementTimestamp is set by closeGame(), sweepDormancyRemainder(),
    ///         or sweepFailedPregame() -- whichever first transitions game to CLOSED.
    ///         Sets prizesSweepComplete=true permanently. After this call individual
    ///         p.unclaimedPrizes balances remain non-zero on-chain but are unclaimable.
    ///         See also: claimPrize() @dev warning.
    function sweepUnclaimedPrizes() external;

    /// @notice Proposes emergency dormancy activation with 24h timelock (DORMANCY_TIMELOCK). Owner only.
    function proposeDormancy() external;

    /// @notice Cancels a pending dormancy proposal. Owner only.
    function cancelDormancy() external;

    /// @notice Executes dormancy after the 24h timelock (DORMANCY_TIMELOCK). Distributes all funds. Owner only.
    function activateDormancy() external;

    /// @notice Claims dormancy refund for the caller. DORMANT phase only.
    /// @dev [v2.15] Casual ticket refund uses flat TREASURY_BPS on all draws. [CRE v0.1] 25%.
    ///      Commitment-only path also uses flat TREASURY_BPS -- commitment was paid pre-game.
    ///      Status-lost weekly OGs who did not re-enter as casuals this draw are not
    ///      eligible for any dormancy pool. Their OG principal was redistributed to
    ///      the prize pot at the draw they lost status. This is intentional -- the
    ///      commitment mechanic does not protect players who chose to stop participating.
    ///      IMPORTANT: Casuals who did not buy tickets in the CURRENT draw at dormancy
    ///      activation are also NOT eligible for refund -- even if they bought in prior
    ///      draws. Only current-draw buyers appear in weeklyNonOGPlayers. Prior-draw
    ///      contributions remain in the pot. This is intentional design.
    /// @dev [v2.05] p.commitmentPaid is NOT cleared during the casual path while a live
    ///      commitmentRefundPool exists (cleared only when pool == 0 or deadline expired).
    ///      Preserves the player's claimCommitmentRefund() entitlement on an overlapping
    ///      dormancy claim. Without this gate the commitment deposit would be stranded.
    function claimDormancyRefund() external;

    /// @notice Sweeps expired unclaimed dormancy pool allocations to PROTOCOL_BENEFICIARY.
    /// @dev [CRE v0.14 / NS-I-01] INTENTIONALLY PERMISSIONLESS (no onlyOwner), unlike the other
    ///      owner-gated sweeps. Everything it moves goes to fixed destinations (PROTOCOL_BENEFICIARY
    ///      and vcReturnOwed to the immutable VC address), and it is time-gated by the dormancy claim
    ///      window, so anyone triggering it cannot redirect funds. Permissionless by design to avoid
    ///      an owner-key-loss lock, matching sweepResetRefundRemainder()'s anti-lock rationale. A cold
    ///      reviewer may flag the missing access control until they trace the destinations; this is it.
    /// @dev Sweeps dormancy-specific pools only (OG pool, casual pool, commitment pool,
    ///      per-head pool, prizePot remainder). The following are intentionally excluded
    ///      and remain accessible via their own functions:
    ///      - treasuryBalance: withdrawTreasury() (after gameSettled)
    ///      - totalUnclaimedPrizes: claimPrize() / sweepUnclaimedPrizes()
    ///      - resetDrawRefundPool(s): claimResetRefund() / sweepResetRefundRemainder()
    ///      - commitmentRefundPool: claimCommitmentRefund() / sweepResetRefundRemainder()
    ///      - draw30BonusFund: returned to prizePot at activateDormancy() before this fires.
    function sweepDormancyRemainder() external;

    /// @notice Refunds a batch of players during a failed pregame. PREGAME only. Owner only.
    /// @param playerList  Array of player addresses to refund.
    function batchRefundPlayers(address[] calldata playerList) external;

    /// @notice Sweeps residual pregame contract balance to PROTOCOL_BENEFICIARY if the
    ///         game never reached ACTIVE state. Owner only. PREGAME phase only.
    ///         Individual player refunds are handled first by batchRefundPlayers() and
    ///         claimSignupRefund(). This function closes the accounting and sweeps any
    ///         remaining balance (treasuryBalance excepted) to PROTOCOL_BENEFICIARY.
    ///         treasuryBalance remains withdrawable via withdrawTreasury() after
    ///         gameSettled = true. Via time-gate path, unclaimed funds go to
    ///         PROTOCOL_BENEFICIARY -- NOT returned to individual players.
    /// @dev    [CRE v0.6 / MEDIUM-01] If a VC seed was deposited (potSeeded) but the game
    ///         never started, the seed is returned to VC_SEED_RETURN_ADDRESS here, atomically,
    ///         BEFORE the protocol-beneficiary sweep. Without this the deposited seed would be
    ///         swept to PROTOCOL_BENEFICIARY -- a misroute of investor principal. seedReleased
    ///         is always 0 in PREGAME (the supplement only fires in ACTIVE), so the full VC_SEED
    ///         is the correct return amount. This is the mirror of the SE-H-01 guard: that stops
    ///         the game defending a seed never deposited; this returns a seed that WAS deposited
    ///         when the game never starts. The seed is subtracted from the residual first so the
    ///         two transfers cannot draw on the same balance.
    function sweepFailedPregame() external;

    /// @notice Claims reset refund for the caller. Post-emergencyResetDraw only.
    /// @dev [v2.15] Flat treasury: both pools use TREASURY_BPS (25%) regardless of draw [CRE v0.6 NS].
    ///      Callers eligible for both pools must call twice -- returns after pool1.
    function claimResetRefund() external;

    /// @notice Claims refund of pregame commitment if OG registration was cancelled.
    function claimCommitmentRefund() external;

    /// @notice Sweeps expired reset refund pools and expired commitment refund pool
    ///         back to prizePot (ACTIVE) or protocol beneficiary (CLOSED/DORMANT).
    ///         Sweeps: resetDrawRefundPool (pool 1), resetDrawRefundPool2 (pool 2),
    ///         and commitmentRefundPool. Each swept independently on expiry.
    ///         Permissionless -- any caller may trigger once the window expires.
    /// @dev Intentionally permissionless -- any caller may trigger the sweep once the window expires.
    ///      Economic outcome is identical regardless of caller. Permissionless design avoids
    ///      permanent lock if owner becomes unavailable before the 30-day window expires.
    function sweepResetRefundRemainder() external;

    /// @notice Marks a player as lapsed (missed buy and not an active OG). Owner only.
    /// @param player  Address of the player to mark as lapsed.
    function markLapsed(address player) external;

    /// @notice Marks a batch of players as lapsed in a single owner call. ACTIVE phase only.
    /// @dev Reimplements markLapsed() logic inline for gas efficiency.
    ///      Phase and drawPhase checks fire once before the loop, not per-address.
    /// @param playerList  Addresses to mark as lapsed.
    function batchMarkLapsed(address[] calldata playerList) external;

    /// @notice Claims accumulated draw prizes owed to the caller.
    /// @dev    WARNING: if sweepUnclaimedPrizes() has been called, prizesSweepComplete
    ///         is permanently true and this function reverts NothingToClaim() for ALL
    ///         callers. Individual p.unclaimedPrizes balances remain non-zero on-chain
    ///         but are permanently unclaimable. Frontends must check prizesSweepComplete
    ///         before displaying or allowing claim of any unclaimedPrizes balance.
    function claimPrize() external;

    /// @notice Withdraws accrued treasury to a recipient. Owner only. Gated by VC + OG protections.
    function withdrawTreasury(uint256 amount, address recipient) external;

    /// @notice Proposes a prize rate reduction with 48h timelock. Owner only.
    /// @param newMultiplier  New prize rate multiplier BPS (< current). Min 5000 (50% of normal).
    /// @param reason         Bytes32 reason code emitted in event for monitoring.
    function proposePrizeRateReduction(uint256 newMultiplier, bytes32 reason) external;

    /// @notice Executes a pending prize rate reduction after the timelock. Owner only.
    function executePrizeRateReduction() external;

    /// @notice Cancels a pending prize rate reduction proposal. Owner only.
    function cancelPrizeRateReduction() external;

    /// @notice Cancels a pending prize rate increase proposal. Owner only.
    function cancelPrizeRateIncrease() external;

    function proposePrizeRateIncrease(uint256 newMultiplier, bytes32 reason) external;

    /// @notice Executes a pending prize rate increase after the timelock. Owner only.
    function executePrizeRateIncrease() external;

    /// @notice Proposes an override of the breath multiplier with 7-day timelock. Owner only.
    /// @dev [v2.01] UP-direction proposals revert PotBelowTrajectory when pot health
    ///      (prizePot * 10000 / requiredEndPot) < 8000 (below 80%). Same gate fires
    ///      at executeBreathOverride. See also: exhaleFloorReleaseBps threshold (120%)
    ///      which governs auto-adjust floor releases -- two independent pot-health
    ///      thresholds operate simultaneously.
    /// @param newMultiplier  New breathMultiplier BPS. Must be within [breathRailMin, breathRailMax].
    /// @param reason         Bytes32 reason code emitted in event for monitoring.
    function proposeBreathOverride(uint256 newMultiplier, bytes32 reason) external;

    /// @notice Executes a pending breath override after the timelock. Owner only.
    /// @dev UP-direction overrides re-check pot health < 80% at execution time
    ///      (same PotBelowTrajectory guard as proposeBreathOverride). If pot health
    ///      dropped below 80% between proposal and execution, the execute reverts.
    function executeBreathOverride() external;

    /// @notice Cancels a pending breath override proposal. Owner only.
    function cancelBreathOverride() external;

    /// @notice Proposes new breath rail bounds. Owner only. 7-day timelock.
    /// @dev newMin must be >= ABSOLUTE_BREATH_FLOOR (100 bps). newMax must be <= ABSOLUTE_BREATH_CEILING (2000 bps).
    ///      [v1.61] Setting a low breathRailMax can reduce draw-1 T3 prizes.
    ///      _computeStartingBreath() calibrates initial breath to target T3 near TICKET_PRICE.
    ///      If breathRailMax < t3FloorBreath (output of _computeStartingBreath,
    ///      see step 3 of startGame()) the calibration target cannot be met.
    ///      At default breathRailMax=1500 the target is achievable at normal parameters.
    /// @param newMin   New minimum breath BPS. Must be >= ABSOLUTE_BREATH_FLOOR (100).
    /// @param newMax   New maximum breath BPS. Must be <= ABSOLUTE_BREATH_CEILING (2000)
    ///                 and strictly > newMin.
    ///                 Equal rails (newMax == newMin) are NOT permitted here -- they would
    ///                 bypass the geometric solver and are rejected with ExceedsLimit().
    ///                 Use proposeBreathOverride() for fixed-rate mode instead.
    /// @param reason   Bytes32 reason code emitted in BreathRailsProposed. Not stored on-chain.
    function proposeBreathRails(uint256 newMin, uint256 newMax, bytes32 reason) external;

    /// @notice Cancels a pending breath rails proposal. Owner only.
    function cancelBreathRails() external;

    /// @notice Executes pending breath rail bounds after the timelock. Owner only.
    function executeBreathRails() external;

    /// @notice Proposes a primary price feed change with 7-day timelock. Owner only.
    /// @param newFeed  Address of the new primary ETH/USD Chainlink feed (8 decimals required).
    function proposeFeedChange(address newFeed) external;

    /// @notice Executes a pending feed change after the 7-day timelock. Owner only.
    function executeFeedChange() external;

    /// @notice Cancels a pending feed change proposal. Owner only.
    function cancelFeedChange() external;

    /// @dev [v1.0] CUTOFF_SUBMISSION handled: if stuck past DRAW_STUCK_TIMEOUT,
    ///      owner can call emergencyResetDraw() to reset. Same timeout applies.
    ///      Cutoff state (t1/t2/t3CutoffDiff, snapshotTotalEntries) cleared on reset.
    ///      tierPools loop uses i<3 (not i<4). p4Winners.slot clear REMOVED.
    /// @notice Initiates an emergency draw reset. VOIDS the current draw: rolls back its
    ///         distribution/accounting and unwinds OG status changes. [CRE v0.9 / NS-I-02]
    ///         The draw number is CONSUMED, not re-run under the same number -- at
    ///         reset-finalize the schedule re-anchors and currentDraw advances. "Replay"
    ///         elsewhere refers to the next draw proceeding, not a repeat of the voided one.
    ///         Owner only EXCEPT during UNWINDING phase: after UNWIND_CONTINUATION_TIMEOUT
    ///         (7 days) any address may call to continue the unwind. This permissionless
    ///         continuation prevents permanent lock if owner is unavailable mid-unwind.
    function emergencyResetDraw() external;

    /// @notice Returns full player state (14 values). See @dev for ABI change note.
    /// @dev [v1.3] ABI CHANGE from v1.2: mulliganUsedVal (bool) removed from return tuple.
    ///      Returns 14 values (was 15). Subgraphs and frontends must update their decoder.
    /// @return registered         True if register() was called.
    /// @return upfrontOG          True if active upfront OG.
    /// @return weeklyOG           True if active weekly OG.
    /// @return statusLost         True if weekly OG status was lost this season.
    /// @return prediction         Primary price prediction (USD cents) for current predictionDraw.
    /// @return prediction2        Secondary price prediction (USD cents).
    /// @return predictionDraw     Draw number for which primary prediction was last set.
    /// @return prediction2Draw    Draw number for which secondary prediction was last set.
    /// @return streak             Consecutive-week buy streak count.
    /// @return unclaimed          Unclaimed prize balance (USDC 6-dec).
    /// @return totalWon           Cumulative prizes won lifetime (USDC 6-dec).
    /// @return boughtThisWeek     True if tickets bought in currentDraw.
    /// @return totalPaid          Cumulative USDC paid to the contract (6-dec).
    /// @return qualifiedForEndgame True if currently eligible for claimEndgame().
    function getPlayerInfo(address addr) external view returns ( bool registered, bool upfrontOG, bool weeklyOG, bool statusLost, uint256 prediction, uint256 prediction2, uint256 predictionDraw, uint256 prediction2Draw, uint256 streak, uint256 unclaimed, uint256 totalWon, bool boughtThisWeek, uint256 totalPaid, bool qualifiedForEndgame );

    /// @notice Returns true if the current draw resolution result has gone stale.
    /// @return  True if resolution is overdue (IDLE, lastResolvedDraw stale).
    ///          False during any non-IDLE phase regardless of resolvedPrice --
    ///          monitoring tools should check drawPhase independently.
    ///          Also returns true when currentDraw == 0 (PREGAME, no draws started yet).
    function isResultStale() external view returns (bool);

    /// @notice Returns a comprehensive snapshot of current game state.
    /// @return gPhase       Current GamePhase enum value.
    /// @return dPhase       Current DrawPhase enum value.
    /// @return draw         Current draw number (0 = pre-game, 1-30 active).
    /// @return pot          Current prizePot (USDC 6-dec).
    /// @return treasury     Current treasuryBalance (USDC 6-dec).
    /// @return unclaimed    Total unclaimed draw prizes outstanding (USDC 6-dec).
    /// @return playerCount  Total registered player count.
    /// @return upfrontOGs   Current upfront OG count.
    /// @return weeklyOGs    Current weekly OG count.
    /// @return breathMult   Current breathMultiplier (BPS).
    /// @return obligLocked  True if OG obligation is locked (always true after startGame).
    /// @return ogObligation Locked OG endgame obligation (USDC 6-dec).
    /// @return lastResolved Last draw number for which price was resolved.
    function getGameState() external view returns ( GamePhase gPhase, DrawPhase dPhase, uint256 draw, uint256 pot, uint256 treasury, uint256 unclaimed, uint256 playerCount, uint256 upfrontOGs, uint256 weeklyOGs, uint256 breathMult, bool obligLocked, uint256 ogObligation, uint256 lastResolved );

    function getSolvencyStatus() external view returns (uint256 totalValue, uint256 totalAllocated, bool isSolvent);

    /// @notice Returns current breath-based prize rate in BPS.
    ///         Returns 0 when currentDraw >= TOTAL_DRAWS (draw 30). [v1.55 I-NEW-02]
    /// @return  BPS prize rate (breathMultiplier * prizeRateMultiplier / 10000).
    ///          Returns 0 at draw 30+ (surplus path used instead -- see notice above).
    ///          At draw 0 (pregame): returns the initial breathMultiplier (informational).
    ///         IMPORTANT: 0 on draw 30 does NOT mean zero payout. Draw 30 uses a special
    ///         surplus path in _calculatePrizePools() that ignores this rate and distributes
    ///         the pot above the running-average targeted holdback (29-draw OG ratio estimate). Draw 30 is typically the highest-payout
    ///         draw of the season. Frontends should display "Final Draw -- Surplus Distribution"
    ///         rather than "0% prize rate" when currentDraw >= TOTAL_DRAWS.
    function getCurrentPrizeRate() external view returns (uint256);

    /// @notice Returns projected OG endgame payout per qualified OG.
    /// @dev Pre-settlement: estimates pot / qualifiedOGs capped at OG_UPFRONT_COST * targetReturnBps / 10000.
    ///      This matches the closeGame() perOGPromised ceiling (live ratio, not season average).
    ///      [v1.59] closeGame() uses season-average ratio; actual payout may be higher.
    ///      [v1.63] Cap corrected from OG_UPFRONT_COST to OG_UPFRONT_COST * targetReturnBps/10000.
    /// @return currentPerOG  Projected payout per OG, capped at OG_UPFRONT_COST * targetReturnBps/10000.
    /// @return obligation    Total OG endgame obligation at targetReturnBps.
    /// @return potHealth     Pot as BPS of requiredEndPot (10000 = at solvency floor). [v1.68] Uncapped --
    ///                       values above 10000 = above-floor health (e.g. 20000 = 2x requiredEndPot).
    ///                       [v2.27] Denominator is requiredEndPot (obligation * targetReturnBps/10000
    ///                       + DRAW30_PRIZE_RESERVE + unreleased VC seed), not gross obligation. [CRE v0.8 / NS-L-01]
    ///                       Monitoring tools should calibrate alerts against requiredEndPot, not the gross figure.
    function getProjectedEndgamePerOG() external view returns (uint256 currentPerOG, uint256 obligation, uint256 potHealth);

    /// @notice Returns OG registration counts and capacity figures.
    /// @dev [v1.57-P1] upfrontMax is informational only -- the upfront OG ratio cap was
    ///      removed from registerAsOG() in v1.57-P1. Any number of upfront OGs can register.
    ///      weeklyMax / availableWeeklySlots are still enforced by _weeklyOGCapReached().
    /// @return upfrontCurrent      upfrontOGCount -- registered upfront OGs.
    /// @return upfrontMax          Computed upfront cap (formula: committedPlayerCount * UPFRONT_OG_CAP_BPS / 10000).
    ///                             INFORMATIONAL ONLY. Cap removed in v1.57-P1. Any number of upfront
    ///                             OGs can register regardless of this value.
    /// @return weeklyCurrent       weeklyOGCount -- active weekly OGs.
    /// @return weeklyMax           Computed weekly OG slot maximum (enforced).
    /// @return totalMax            Computed total OG cap (upfront + weekly).
    /// @return availableWeeklySlots  weeklyMax - weeklyCurrent (remaining weekly slots).
    function getOGCapInfo() external view returns (uint256 upfrontCurrent, uint256 upfrontMax, uint256 weeklyCurrent, uint256 weeklyMax, uint256 totalMax, uint256 availableWeeklySlots);

    /// @notice Returns pregame state for frontend display.
    /// @dev [v1.57-P1] intentQueueClear always returns true -- intent queue removed.
    ///      Retained in return signature for ABI compatibility with existing tooling.
    ///      [v1.69] intentQueueClear is permanently true in all v1.57+ deployments.
    ///      Any downstream consumer of this field should treat it as a deprecated constant.
    /// @return committed          committedPlayerCount -- total pregame commitments.
    /// @return upfrontOGs         upfrontOGCount.
    /// @return weeklyOGs          weeklyOGCount.
    /// @return neededToStart      MIN_PLAYERS_TO_START.
    /// @return readyToStart       True when proposeStartGame() can be called: player threshold
    ///                             met, PREGAME phase, no pending proposal, AND
    ///                             block.timestamp < signupDeadline + MAX_PREGAME_DURATION.
    ///                             Does NOT mean startGame() can execute -- that also requires
    ///                             the 72h notice period to have elapsed.
    /// @return intentQueueClear   Always true. Deprecated ABI-compat field from v1.57-P1.
    /// @return proposalTimestamp  startGameProposedAt (0 if no proposal pending).
    function getPreGameStats() external view returns ( uint256 committed, uint256 upfrontOGs, uint256 weeklyOGs, uint256 neededToStart, bool readyToStart, bool intentQueueClear, uint256 proposalTimestamp );

    /// @notice Returns dormancy pool balances and claim window status.
    /// @return ogPoolRemaining       Remaining OG principal pool (USDC 6-dec).
    /// @return principalFullCover    True if OG principal is fully covered by pot.
    /// @return casualPoolRemaining   Remaining casual refund pool (USDC 6-dec).
    /// @return casualFullCover       True if casual refund pool is fully covered.
    /// @return casualTicketTotal     Total casual ticket contributions at dormancy.
    /// @return commitmentPoolRemaining Remaining commitment refund pool (USDC 6-dec).
    /// @return commitmentFullCover   True if commitment pool is fully covered.
    /// @return perHeadPoolRemaining  Remaining per-head surplus pool (USDC 6-dec).
    /// @return perHeadShare          Per-participant share amount (USDC 6-dec).
    /// @return participantCount      Number of participants eligible for per-head share.
    /// @return sweepWindowOpens      Timestamp when unclaimed funds can be swept (0 if not dormant).
    function getDormancyInfo() external view returns ( uint256 ogPoolRemaining, bool principalFullCover, uint256 casualPoolRemaining, bool casualFullCover, uint256 casualTicketTotal, uint256 commitmentPoolRemaining, bool commitmentFullCover, uint256 perHeadPoolRemaining, uint256 perHeadShare, uint256 participantCount, uint256 sweepWindowOpens );

    /// @notice Returns current cutoff diff state for monitoring and keeper verification. [v1.0]
    /// @return _t1        t1CutoffDiff (top 1% boundary diff value).
    /// @return _t2        t2CutoffDiff (top ~6% cumulative boundary diff value).
    /// @return _t3        t3CutoffDiff (top ~12-15% boundary diff value).
    /// @return _snapshot  snapshotTotalEntries used as BPS denominator.
    function getCutoffState() external view returns (uint256 _t1, uint256 _t2, uint256 _t3, uint256 _snapshot);

    /// @notice Returns the count bounds that submitCutoffDiffs() will verify against. [v1.51]
    ///         Keepers SHOULD call this before submitting cutoff diffs to pre-validate
    ///         their computed counts. If submitted counts fall outside these bounds,
    ///         submitCutoffDiffs() will revert CutoffOutOfRange.
    ///
    ///         KEEPER WORKFLOW:
    ///           1. Wait for drawPhase == CUTOFF_SUBMISSION.
    ///           2. Read all predictions from chain events.
    ///           3. Compute diffs = |prediction * PREDICTION_SCALE - resolvedPrice| for each entry.
    ///           4. Sort entries by diff ascending.
    ///           5. Find diff values at 1%, ~6%, and ~12-15% cumulative thresholds (draw-schedule
    ///              dependent; include tie clusters). T3_COUNT_MIN_BPS=1000 means target >= 10%.
    ///           6. Call getRequiredCutoffDiffBounds() to verify your counts are in range.
    ///           7. If counts in range, call submitCutoffDiffs().
    ///
    ///      ENTRY ENUMERATION RULES (v2.35 I-04 / NS-I-01 -- load-bearing post-M-01):
    ///        The entry count you compute in step 3-4 MUST match _processMatchesCore()
    ///        exactly or your honest diff counts will trip MatchCountMismatch.
    ///        Rules as of v2.34:
    ///          - Upfront OGs (isUpfrontOG): 2 entries each, always.
    ///          - Weekly OGs: 2 entries each ONLY when isWeeklyOG && !weeklyOGStatusLost
    ///            && lastBoughtDraw == currentDraw. The lastBoughtDraw filter is REQUIRED and
    ///            was missing from this spec before v1.12. weeklyOGStatusLost is still false at
    ///            CUTOFF_SUBMISSION time for a weekly OG who missed this draw's buy, because
    ///            _processMatchesCore() only sets that flag during MATCHING, after the keeper has
    ///            already submitted. Such an OG produces ZERO entries on chain. Counting them as
    ///            2 over-states the entry set, mis-sites every percentile threshold, and can trip
    ///            MatchCountMismatch on entirely honest keeper behaviour.
    ///            prediction1 auto-filled from autoDefaultPrediction if stale or zero.
    ///            prediction2 always auto-filled regardless (OG always has 2 entries).
    ///          - Casuals (weeklyNonOGPlayers): 1 entry for lastTicketCount == 1.
    ///            prediction1 auto-filled from autoDefaultPrediction if stale or zero.
    ///          - Casuals (weeklyNonOGPlayers): 2 entries for lastTicketCount >= 2.
    ///            prediction1 auto-filled. prediction2 auto-filled if stale or zero.
    ///            [Changed at v2.34 M-01: previously prediction2 was dropped if not
    ///            explicitly submitted. Update off-chain keeper spec to match.]
    ///        autoDefaultPrediction = autoDefaultCents when non-zero, else defaultPrediction.
    ///        There is NO staleness or age check. Earlier wording here claimed the value falls
    ///        back to defaultPrediction once it is older than DRAW_COOLDOWN; no such condition
    ///        exists in _autoDefaultPrediction(). This matters most after an emergency reset:
    ///        emergencyResetDraw() sets resolvedPrice = 0, so the next resolveWeek() skips the
    ///        autoDefaultCents refresh and the value stays two draw cycles stale while still
    ///        being used. Read the live value from getAutoDefault(); do not re-derive it.
    ///        Same value used for all fills in one draw, which is why a large auto-default
    ///        cohort ties at one identical diff. See the tie-cluster note in KNOWN_ISSUES.
    ///
    /// @return inCutoffSubmission  True if currently awaiting keeper submission.
    /// @return snapshot            snapshotTotalEntries -- denominator for all BPS checks.
    /// @return t1Min               Minimum acceptable T1 count (0.5% of snapshot).
    /// @return t1Max               Maximum acceptable T1 count (4% of snapshot).
    /// @return t2Min               Minimum acceptable T2 cumulative count (4% of snapshot).
    /// @return t2Max               Maximum acceptable T2 cumulative count (12% of snapshot). [v2.18: was 6%]
    /// @return t3Min               Minimum acceptable T3 cumulative count (10% of snapshot). [v2.18: was 16%]
    /// @return t3Max               Maximum acceptable T3 cumulative count (50% of snapshot).
    ///      NOTE: At draws 1-2 (T3_WINNER_BPS_D1_2=600) theoretical cumulative is ~12%.
    ///      The 10% minimum gives a 2% margin -- the tightest point in the season.
    ///      OG status losses during MATCHING reduce actual entries vs snapshot (overcounting)
    ///      which can push BPS lower. Verified safe at 20% OG + 10% attrition.
    ///      [v2.19] Margin structurally identical to old design: 12%-10% MIN = 2pp
    ///      (old: 18%-16% = 2pp). Re-confirm under new schedule before production.
    ///                             Upper bound is wide due to 2-ticket casual snapshot bias.
    ///                             Actual T3% of real entries is 12-15% depending on draw.
    /// @return priceForDiffs       resolvedPrice -- compute diffs against this value.
    /// @dev    DENOMINATOR NOTE: all bounds are computed against snapshotTotalEntries,
    ///         which uses the same 2-ticket casual undercount bias as submitCutoffDiffs().
    ///         (Each casual = 1 in snapshot regardless of ticket count; 2-ticket casuals
    ///         generate 2 entries. This makes BPS values read higher than actual percentages.)
    ///         Keepers do NOT need to adjust for this -- the bounds returned here exactly
    ///         match what submitCutoffDiffs() will accept. The bias is consistent end-to-end.
    function getRequiredCutoffDiffBounds() external view returns ( bool inCutoffSubmission, uint256 snapshot, uint256 t1Min, uint256 t1Max, uint256 t2Min, uint256 t2Max, uint256 t3Min, uint256 t3Max, int256 priceForDiffs );

    /// @notice Returns the most recently resolved ETH/USD price (Chainlink 8-dec).
    ///         Returns 0 between draws and during draw 1 before the first resolution.
    function getResolvedPrice() external view returns (int256);

    /// @notice Returns winner counts for each tier in the current draw.
    /// @dev [v1.0] 3 tiers only (T1/T2/T3). p4 REMOVED -- ABI change from 1Y game.
    ///      Subgraphs must update from 4-return to 3-return signature.
    /// @dev During IDLE phase these reflect the most recently completed draw.
    ///      Arrays are cleared at the start of resolveWeek() for the next draw,
    ///      not at finalizeWeek(). Counts are accurate during MATCHING → FINALIZING only.
    /// @return t1  T1 (1% Club) winner count.
    /// @return t2  T2 winner count.
    /// @return t3  T3 winner count.
    function getWinnerCounts() external view returns (uint256 t1, uint256 t2, uint256 t3);

    /// @notice Returns true if prediction is within [1, MAX_PREDICTION_CENTS].
    /// @param prediction  Value to validate.
    /// @return valid   True if prediction falls within [1, MAX_PREDICTION_CENTS].
    /// @return reason  Human-readable rejection reason if invalid; empty string if valid.
    function isValidPrediction(uint256 prediction) external pure returns (bool valid, string memory reason);

    /// @notice Returns 0-based ogList index for addr.
    /// @dev    Returns 0 for both the first list entry AND addresses not in the list
    ///         (storage default). AMBIGUOUS on its own. Always confirm membership via
    ///         p.isUpfrontOG || p.isWeeklyOG before using this index for list operations.
    /// @param addr  Address to look up.
    function getOGListIndex(address addr) external view returns (uint256);

    /// @notice Returns the contract version string.
    /// @return  Version string identifying this deployment.
    function getContractVersion() external pure returns (string memory);

    /// @notice Returns current draw-30 bonus fund balance and expected contribution per draw.
    /// @dev [v1.62] For off-chain monitoring and frontend display.
    ///      perDrawEstimate returns 0 at draw 30 because getCurrentPrizeRate() returns 0
    ///      on the final draw. accumulated reflects the full season siphon at that point.
    /// @return accumulated  Total bonus siphoned so far.
    /// @return perDrawEstimate  Estimated bonus per draw at current breathMultiplier
    ///                          and prizeRateMultiplier (via getCurrentPrizeRate()).
    ///                          Returns 0 at draw 30+ (getCurrentPrizeRate() returns 0).
    ///                          [CRE v0.13] Excludes any active seed supplement. The bonus
    ///                          siphon in _calculatePrizePools() is taken from weeklyPool
    ///                          INCLUDING the supplement, so on supplement-active draws the
    ///                          real per-draw bonus contribution is proportionally higher than
    ///                          this estimate. Monitoring only; no economic effect.
    function getDraw30BonusStatus() external view returns ( uint256 accumulated, uint256 perDrawEstimate );

    /// @notice Returns current pot health relative to requiredEndPot.
    ///         Used by operators and front-ends to monitor exhale floor gate status.
    /// @dev [v1.60] potHealthBps = prizePot * 10000 / requiredEndPot.
    ///      Gate fires when potHealthBps < exhaleFloorReleaseBps (default 12000).
    ///      Integer division truncates -- e.g. exact 1.2x gives potHealthBps=11999,
    ///      so gateActive returns true ~0.01% before the nominal threshold. Consequence:
    ///      exhale floor may release fractionally early. Negligible in practice.
    ///      gateActive is true only during exhale phase (currentDraw > INHALE_DRAWS).
    /// @return potHealthBps  Current pot as BPS of requiredEndPot (10000 = 100%).
    ///                       Returns 10000 as a sentinel when requiredEndPot == 0
    ///                       (no OG obligation locked -- game has no OGs or obligation
    ///                       not yet set). Sentinel indicates no floor exists, not full
    ///                       health. gateActive will be false in this state.
    /// @return gateActive    True if the gate could currently release the exhale floor.
    /// @return threshold     Current exhaleFloorReleaseBps setting.
    function getExhaleFloorHealth() external view returns ( uint256 potHealthBps, bool gateActive, uint256 threshold );

    /// @notice Pre-flight solvency check. Call before startGame() to verify the
    ///         game can be started without reverting PotBelowTrajectory.
    /// @dev [v1.58-P3] Runs the same geometric simulation as startGame().
    ///      Returns (true, 0) if solvent. Returns (false, deficit) if not,
    ///      where deficit is how much extra revenue per draw is needed.
    ///      Uses current breathRailMin, prizePot, and committed player counts.
    ///      PREGAME only -- call during signup window to diagnose before startGame.
    ///      [v1.59] Uses live OG ratio for the floor estimate (conservative).
    ///      Actual perOGPromised at closeGame() uses the season average and may
    ///      be higher if the ratio was elevated early but drops mid-season.
    /// @return solvent  True if the geometric simulation confirms solvency at breathRailMin.
    /// @return deficit  Approximate per-draw revenue shortfall if not solvent (lower-bound estimate).
    function checkSolvency() external view returns (bool solvent, uint256 deficit);

    /// @notice Returns the current auto-default prediction value and whether it is the seed fallback.
    /// @dev cents is autoDefaultCents (last resolved price in cent units) when > 0.
    ///      isSeed = true when autoDefaultCents == 0, meaning defaultPrediction is used instead.
    ///      Frontends must handle both cases differently -- isSeed = true means no prior resolution.
    /// @return cents     Auto-default prediction in USD cents. When isSeed=true this is
    ///                   the owner-set defaultPrediction (always non-zero by constructor);
    ///                   when isSeed=false this is autoDefaultCents from the previous draw.
    /// @return isSeed    True when falling back to the owner-set defaultPrediction.
    function getAutoDefault() external view returns (uint256 cents, bool isSeed);

    /// @notice Counts all stale weekly OGs in the full ogList. Unbounded -- use paginated overload for large lists.
    /// @return staleCount  Number of weekly OGs with weeklyOGStatusLost == true.
    function countStaleOGs() external view returns (uint256 staleCount);

    /// @notice Counts stale weekly OGs in a paginated range. For keeper gas estimation.
    ///         A weekly OG is stale when weeklyOGStatusLost is true and not yet pruned.
    /// @param start  Index into ogList to start from (0-based).
    /// @param count  Maximum number of entries to check from start.
    /// @return staleCount  Number of stale weekly OGs found in the range.
    function countStaleOGs(uint256 start, uint256 count) external view returns (uint256 staleCount);

    /// @notice Proposes a new exhale floor release threshold. Owner only. 48h timelock.
    /// @dev [v1.60] newBps must be in [8000, 20000]. Values outside this range revert.
    ///      8000 (80%): floor holds until deep distress -- prioritises prize experience.
    ///      20000 (200%): floor releases proactively -- prioritises solvency.
    ///      Default 12000 (120%) is the recommended balanced setting.
    /// @param newBps  New threshold in BPS. Must be in [8000, 20000].
    function proposeExhaleFloorRelease(uint256 newBps) external;

    /// @notice Executes a pending exhale floor release proposal after timelock.
    /// @dev [v1.60] Reverts TooEarly() if called before the 48h timelock expires.
    ///      Reverts NoTimelockPending() if no proposal is pending.
    function executeExhaleFloorRelease() external;

    /// @notice Cancels a pending exhale floor release proposal.
    function cancelExhaleFloorRelease() external;

    /// @notice Returns current seed release state for off-chain monitoring.
    /// @dev    [CRE v0.11 / NS-L-01] Return tags added (was untagged multi-value view).
    /// @return ratioBps             Current active seedReleaseRatioBps (governance-set).
    /// @return maxReleasable        CEILING only: cumulativeSeasonTreasury * ratioBps / 10000,
    ///                              capped at VC_SEED. This IGNORES the SEED_RELEASE_THRESHOLD gate
    ///                              and the per-draw MAX_SEED_PER_DRAW_BPS cap, so it is an upper
    ///                              bound, NOT a next-draw release prediction. Actual per-draw
    ///                              release is computed in _calculatePrizePools() and is typically
    ///                              lower. Do not use this to forecast the next supplement.
    /// @return released             Cumulative seed released to date (seedReleased).
    /// @return remaining            VC_SEED - seedReleased (0 if fully released).
    /// @return thresholdMet         True if cumulativeSeasonTreasury >= SEED_RELEASE_THRESHOLD
    ///                              (the gate maxReleasable ignores).
    /// @return pendingRatio         Pending governance ratio (0 if none pending).
    /// @return pendingEffectiveTime Timelock expiry for the pending ratio (0 if none).
    function getSeedReleaseStatus() external view returns ( uint256 ratioBps, uint256 maxReleasable, uint256 released, uint256 remaining, bool thresholdMet, uint256 pendingRatio, uint256 pendingEffectiveTime );
}
