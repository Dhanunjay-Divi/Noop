package com.noop.bandsdk

import java.util.ArrayDeque
import java.util.UUID

class BandSessionMachine(
    private val diagnostics: BandDiagnosticsRecorder = BandDiagnosticsRecorder(),
    restoredHistoryCheckpoint: BandHistoryCheckpoint? = null,
) {
    private data class PendingLive(
        val acceptance: LiveAcceptance,
        val samples: List<BandSample>,
        val expectedSampleCount: Int,
    )

    private data class PendingHistory(
        val acceptance: HistoryAcceptance,
        val samples: List<BandSample>,
        val expectedSampleCount: Int,
    )

    private data class CallerTraversalFence(
        val state: BandSessionState,
        val generation: Long,
        val nextConnectionSequence: Long,
        val nextReconnectSequence: Long,
        val nextOperationSequence: Long,
        val nextLiveSequence: Long,
        val nextLiveReceiptSequence: Long,
        val nextHistoryReceiptSequence: Long,
        val activeScanToken: BandScanToken?,
        val activeConnectionToken: BandConnectionToken?,
        val activeReconnectToken: BandReconnectToken?,
        val activeOperation: BandOperationToken?,
        val activeLiveToken: BandLiveToken?,
        val liveActive: Boolean,
        val identity: BandIdentity?,
        val capabilityReport: BandCapabilityReport?,
        val pendingLive: PendingLive?,
        val pendingHistory: PendingHistory?,
    )

    private val restoredHistoryCheckpoint =
        restoredHistoryCheckpoint?.immutableSnapshot()
    private val sessionNonce = UUID.randomUUID()
    private var state = BandSessionState.IDLE
    private var generation = 0L
    private var nextConnectionSequence = 0L
    private var nextReconnectSequence = 0L
    private var nextOperationSequence = 0L
    private var nextLiveSequence = 0L
    private var nextLiveReceiptSequence = 0L
    private var nextHistoryReceiptSequence = 0L
    private var activeOperation: BandOperationToken? = null
    private var activeScanToken: BandScanToken? = null
    private var activeConnectionToken: BandConnectionToken? = null
    private var activeReconnectToken: BandReconnectToken? = null
    private var activeLiveToken: BandLiveToken? = null
    private var liveActive = false
    private var liveStreams = emptySet<BandStreamKind>()
    private var identity: BandIdentity? = null
    private var capabilityReport: BandCapabilityReport? = null
    private var pendingLive: PendingLive? = null
    private var pendingHistory: PendingHistory? = null
    private var callerTraversalActive = false
    private var lastDurableHistoryComplete: Boolean? = null
    private var historyOperationReceivedDurableReceipt = false
    private var historyOperationLastReceiptComplete: Boolean? = null
    private val durableSampleIdentities = mutableSetOf<BandSampleIdentity>()
    private val durableSamplesByIdentity =
        mutableMapOf<BandSampleIdentity, BandSample>()
    private val durableSampleFingerprintsByIdentity =
        mutableMapOf<BandSampleIdentity, BandSampleFingerprint>()
    private val durableSampleIdentityOrder = ArrayDeque<BandSampleIdentity>()
    private var durableSourceIdentity: String? = null
    private var restoredHistoryCheckpointConsumed = false
    private var acknowledgedHistoryCursor: String? = null

    @Synchronized
    fun snapshot(): BandSessionSnapshot {
        rejectCallerTraversalReentry(BandDiagnosticKind.COMMAND)
        return BandSessionSnapshot(
            state = state,
            generation = generation,
            activeOperation = activeOperation?.operationClass,
            liveActive = liveActive,
            acknowledgedHistoryCursor = acknowledgedHistoryCursor,
            durableSampleCount = durableSampleIdentities.size,
        )
    }

    @Synchronized
    fun historyCheckpoint(): BandHistoryCheckpoint? {
        rejectCallerTraversalReentry(BandDiagnosticKind.HISTORY)
        val sourceIdentity =
            durableSourceIdentity ?: identity?.sourceIdentity ?: return null
        return BandHistoryCheckpoint(
            sourceIdentity = sourceIdentity,
            acknowledgedCursor = acknowledgedHistoryCursor,
            lastHistoryComplete = lastDurableHistoryComplete,
            durableSampleIdentities = durableSampleIdentities.toSet(),
            durableSampleFingerprints =
                durableSampleFingerprintsByIdentity.values.toSet(),
        )
    }

    @Synchronized
    fun beginScan(): BandScanToken {
        rejectCallerTraversalReentry(BandDiagnosticKind.DISCOVERY)
        ensureNotClosed()
        if (hasPendingPersistence) {
            diagnostics.record(
                BandDiagnosticEvent(
                    BandDiagnosticKind.DISCOVERY,
                    BandDiagnosticOutcome.REJECTED,
                    failureCategory = BandFailureCategory.BUSY,
                ),
            )
            fail(BandFailureCategory.BUSY)
        }
        if (
            state != BandSessionState.IDLE &&
            state != BandSessionState.RECOVERING &&
            state != BandSessionState.REJECTED
        ) {
            fail(BandFailureCategory.INVALID_STATE)
        }
        generation += 1
        clearOperationTracking()
        clearLiveTracking()
        activeConnectionToken = null
        activeReconnectToken = null
        identity = null
        capabilityReport = null
        state = BandSessionState.SCANNING
        diagnostics.record(
            BandDiagnosticEvent(
                BandDiagnosticKind.DISCOVERY,
                BandDiagnosticOutcome.BEGAN,
            ),
        )
        val token = BandScanToken(
            sessionNonce = sessionNonce,
            generation = generation,
        )
        activeScanToken = token
        return token
    }

    @Synchronized
    fun selectCandidate(
        candidate: BandPairingCandidate,
        callbackGeneration: BandScanToken,
    ): BandConnectionToken {
        rejectCallerTraversalReentry(BandDiagnosticKind.DISCOVERY)
        ensureNotClosed()
        validateScanToken(
            callbackGeneration,
            BandDiagnosticKind.DISCOVERY,
        )
        try {
            candidate.validate()
        } catch (_: BandException) {
            diagnostics.record(
                BandDiagnosticEvent(
                    BandDiagnosticKind.DISCOVERY,
                    BandDiagnosticOutcome.REJECTED,
                    failureCategory = BandFailureCategory.INVALID_INPUT,
                ),
            )
            fail(BandFailureCategory.INVALID_INPUT)
        }
        if (
            state != BandSessionState.SCANNING ||
            !candidate.compatible ||
            !candidate.identifyEligible
        ) {
            diagnostics.record(
                BandDiagnosticEvent(
                    BandDiagnosticKind.DISCOVERY,
                    BandDiagnosticOutcome.REJECTED,
                    failureCategory = BandFailureCategory.REJECTED,
                ),
            )
            fail(BandFailureCategory.REJECTED)
        }
        nextConnectionSequence += 1
        val token = BandConnectionToken(
            sessionNonce = sessionNonce,
            generation = generation,
            sequence = nextConnectionSequence,
            candidateHandle = candidate.handle,
        )
        activeScanToken = null
        activeConnectionToken = token
        state = BandSessionState.CANDIDATE_SELECTED
        diagnostics.record(
            BandDiagnosticEvent(
                BandDiagnosticKind.DISCOVERY,
                BandDiagnosticOutcome.COMPLETED,
                BandCountBucket.ONE,
            ),
        )
        return token
    }

    @Synchronized
    fun cancelScan(callbackGeneration: BandScanToken) {
        rejectCallerTraversalReentry(BandDiagnosticKind.DISCOVERY)
        ensureNotClosed()
        validateScanToken(
            callbackGeneration,
            BandDiagnosticKind.DISCOVERY,
        )
        if (state != BandSessionState.SCANNING) {
            diagnostics.record(
                BandDiagnosticEvent(
                    BandDiagnosticKind.DISCOVERY,
                    BandDiagnosticOutcome.REJECTED,
                    failureCategory = BandFailureCategory.INVALID_STATE,
                ),
            )
            fail(BandFailureCategory.INVALID_STATE)
        }
        generation += 1
        activeScanToken = null
        activeConnectionToken = null
        state = BandSessionState.IDLE
        diagnostics.record(
            BandDiagnosticEvent(
                BandDiagnosticKind.DISCOVERY,
                BandDiagnosticOutcome.CANCELLED,
            ),
        )
    }

    @Synchronized
    fun failScan(
        category: BandFailureCategory,
        callbackGeneration: BandScanToken,
    ) {
        rejectCallerTraversalReentry(BandDiagnosticKind.DISCOVERY)
        ensureNotClosed()
        validateScanToken(
            callbackGeneration,
            BandDiagnosticKind.DISCOVERY,
        )
        if (state != BandSessionState.SCANNING) {
            diagnostics.record(
                BandDiagnosticEvent(
                    BandDiagnosticKind.DISCOVERY,
                    BandDiagnosticOutcome.REJECTED,
                    failureCategory = BandFailureCategory.INVALID_STATE,
                ),
            )
            fail(BandFailureCategory.INVALID_STATE)
        }
        if (category !in scanFailureCategories) {
            diagnostics.record(
                BandDiagnosticEvent(
                    BandDiagnosticKind.DISCOVERY,
                    BandDiagnosticOutcome.REJECTED,
                    failureCategory = BandFailureCategory.INVALID_INPUT,
                ),
            )
            fail(BandFailureCategory.INVALID_INPUT)
        }
        generation += 1
        activeScanToken = null
        activeConnectionToken = null
        state = BandSessionState.IDLE
        diagnostics.record(
            BandDiagnosticEvent(
                BandDiagnosticKind.DISCOVERY,
                if (category == BandFailureCategory.TIMEOUT) {
                    BandDiagnosticOutcome.TIMED_OUT
                } else {
                    BandDiagnosticOutcome.FAILED
                },
                failureCategory = category,
            ),
        )
    }

    @Synchronized
    fun beginConnection(
        token: BandConnectionToken,
        callbackGeneration: Long,
    ) {
        rejectCallerTraversalReentry(BandDiagnosticKind.CONNECTION)
        ensureNotClosed()
        validateConnectionToken(
            token,
            callbackGeneration,
            BandDiagnosticKind.CONNECTION,
        )
        if (state != BandSessionState.CANDIDATE_SELECTED) {
            diagnostics.record(
                BandDiagnosticEvent(
                    BandDiagnosticKind.CONNECTION,
                    BandDiagnosticOutcome.REJECTED,
                    failureCategory = BandFailureCategory.INVALID_STATE,
                ),
            )
            fail(BandFailureCategory.INVALID_STATE)
        }
        state = BandSessionState.CONNECTING
        diagnostics.record(
            BandDiagnosticEvent(
                BandDiagnosticKind.CONNECTION,
                BandDiagnosticOutcome.BEGAN,
            ),
        )
    }

    @Synchronized
    fun beginAuthentication(
        token: BandConnectionToken,
        callbackGeneration: Long,
    ) {
        rejectCallerTraversalReentry(BandDiagnosticKind.AUTHENTICATION)
        ensureNotClosed()
        validateConnectionToken(
            token,
            callbackGeneration,
            BandDiagnosticKind.AUTHENTICATION,
        )
        if (state != BandSessionState.CONNECTING) {
            diagnostics.record(
                BandDiagnosticEvent(
                    BandDiagnosticKind.AUTHENTICATION,
                    BandDiagnosticOutcome.REJECTED,
                    failureCategory = BandFailureCategory.INVALID_STATE,
                ),
            )
            fail(BandFailureCategory.INVALID_STATE)
        }
        state = BandSessionState.AUTHENTICATING
        diagnostics.record(
            listOf(
                BandDiagnosticEvent(
                    BandDiagnosticKind.CONNECTION,
                    BandDiagnosticOutcome.COMPLETED,
                ),
                BandDiagnosticEvent(
                    BandDiagnosticKind.AUTHENTICATION,
                    BandDiagnosticOutcome.BEGAN,
                ),
            ),
        )
    }

    @Synchronized
    fun completeConnection(
        newIdentity: BandIdentity,
        token: BandConnectionToken,
        callbackGeneration: Long,
    ) {
        rejectCallerTraversalReentry(BandDiagnosticKind.AUTHENTICATION)
        ensureNotClosed()
        validateConnectionToken(
            token,
            callbackGeneration,
            BandDiagnosticKind.AUTHENTICATION,
        )
        if (state != BandSessionState.AUTHENTICATING) {
            diagnostics.record(
                BandDiagnosticEvent(
                    BandDiagnosticKind.AUTHENTICATION,
                    BandDiagnosticOutcome.REJECTED,
                    failureCategory = BandFailureCategory.INVALID_STATE,
                ),
            )
            fail(BandFailureCategory.INVALID_STATE)
        }
        try {
            newIdentity.validate()
        } catch (_: BandException) {
            diagnostics.record(
                BandDiagnosticEvent(
                    BandDiagnosticKind.AUTHENTICATION,
                    BandDiagnosticOutcome.REJECTED,
                    failureCategory = BandFailureCategory.INVALID_INPUT,
                ),
            )
            fail(BandFailureCategory.INVALID_INPUT)
        }
        prepareDurableState(newIdentity.sourceIdentity)
        capabilityReport = null
        identity = newIdentity
        state = BandSessionState.NEGOTIATING_CAPABILITIES
        diagnostics.record(
            BandDiagnosticEvent(
                BandDiagnosticKind.AUTHENTICATION,
                BandDiagnosticOutcome.COMPLETED,
            ),
        )
    }

    @Synchronized
    fun cancelConnection(
        token: BandConnectionToken,
        phase: BandConnectionPhase,
        callbackGeneration: Long,
    ) {
        val diagnosticKind = diagnosticKind(phase)
        rejectCallerTraversalReentry(diagnosticKind)
        ensureNotClosed()
        validateConnectionToken(
            token,
            callbackGeneration,
            diagnosticKind,
        )
        if (state != sessionState(phase)) {
            diagnostics.record(
                BandDiagnosticEvent(
                    diagnosticKind,
                    BandDiagnosticOutcome.REJECTED,
                    failureCategory = BandFailureCategory.INVALID_STATE,
                ),
            )
            fail(BandFailureCategory.INVALID_STATE)
        }
        clearConnectionAttempt(BandSessionState.IDLE)
        diagnostics.record(
            BandDiagnosticEvent(
                diagnosticKind,
                BandDiagnosticOutcome.CANCELLED,
            ),
        )
    }

    @Synchronized
    fun failConnection(
        category: BandFailureCategory,
        token: BandConnectionToken,
        phase: BandConnectionPhase,
        callbackGeneration: Long,
    ) {
        val diagnosticKind = diagnosticKind(phase)
        rejectCallerTraversalReentry(diagnosticKind)
        ensureNotClosed()
        validateConnectionToken(
            token,
            callbackGeneration,
            diagnosticKind,
        )
        if (state != sessionState(phase)) {
            diagnostics.record(
                BandDiagnosticEvent(
                    diagnosticKind,
                    BandDiagnosticOutcome.REJECTED,
                    failureCategory = BandFailureCategory.INVALID_STATE,
                ),
            )
            fail(BandFailureCategory.INVALID_STATE)
        }
        if (category !in connectionFailureCategories) {
            diagnostics.record(
                BandDiagnosticEvent(
                    diagnosticKind,
                    BandDiagnosticOutcome.REJECTED,
                    failureCategory = BandFailureCategory.INVALID_INPUT,
                ),
            )
            fail(BandFailureCategory.INVALID_INPUT)
        }
        val terminalState = when (category) {
            BandFailureCategory.REJECTED,
            BandFailureCategory.AUTHENTICATION,
            -> BandSessionState.REJECTED
            BandFailureCategory.SECURITY_FAILURE ->
                BandSessionState.SECURITY_FAILURE
            else -> BandSessionState.RECOVERING
        }
        clearConnectionAttempt(terminalState)
        val outcome = when (category) {
            BandFailureCategory.TIMEOUT -> BandDiagnosticOutcome.TIMED_OUT
            BandFailureCategory.REJECTED,
            BandFailureCategory.AUTHENTICATION,
            BandFailureCategory.SECURITY_FAILURE,
            -> BandDiagnosticOutcome.REJECTED
            else -> BandDiagnosticOutcome.FAILED
        }
        diagnostics.record(
            BandDiagnosticEvent(
                diagnosticKind,
                outcome,
                failureCategory = category,
            ),
        )
    }

    @Synchronized
    fun acceptCapabilities(
        report: BandCapabilityReport,
        token: BandConnectionToken,
        callbackGeneration: Long,
    ) {
        rejectCallerTraversalReentry(BandDiagnosticKind.CAPABILITY)
        ensureNotClosed()
        validateConnectionToken(
            token,
            callbackGeneration,
            BandDiagnosticKind.CAPABILITY,
        )
        val traversalFence = captureCallerTraversalFence()
        val immutableReport = try {
            snapshotCallerOwned {
                report.immutableSnapshot()
            }
        } catch (_: BandException) {
            validateCallerTraversalFence(
                traversalFence,
                BandDiagnosticKind.CAPABILITY,
            )
            if (state == BandSessionState.NEGOTIATING_CAPABILITIES) {
                state = BandSessionState.INCOMPATIBLE
                capabilityReport = null
            }
            diagnostics.record(
                BandDiagnosticEvent(
                    BandDiagnosticKind.CAPABILITY,
                    BandDiagnosticOutcome.REJECTED,
                    failureCategory = BandFailureCategory.INVALID_INPUT,
                ),
            )
            fail(BandFailureCategory.INVALID_INPUT)
        }
        validateCallerTraversalFence(
            traversalFence,
            BandDiagnosticKind.CAPABILITY,
        )
        try {
            immutableReport.validate()
        } catch (_: BandException) {
            if (state == BandSessionState.NEGOTIATING_CAPABILITIES) {
                rejectCapabilities(mutateSession = true)
            }
            diagnostics.record(
                BandDiagnosticEvent(
                    BandDiagnosticKind.CAPABILITY,
                    BandDiagnosticOutcome.REJECTED,
                    failureCategory = BandFailureCategory.INVALID_INPUT,
                ),
            )
            fail(BandFailureCategory.INVALID_INPUT)
        }
        val currentIdentity = identity
        val identityMatches =
            currentIdentity?.hardwareRevision == immutableReport.hardwareRevision &&
                currentIdentity.firmwareVersion == immutableReport.firmwareVersion &&
                currentIdentity.protocolVersion == immutableReport.protocolVersion
        if (state != BandSessionState.NEGOTIATING_CAPABILITIES) {
            if (identityMatches && capabilityReport == immutableReport) {
                diagnostics.record(
                    BandDiagnosticEvent(
                        BandDiagnosticKind.CAPABILITY,
                        BandDiagnosticOutcome.STALE,
                    ),
                )
                return
            }
            rejectCapabilities(mutateSession = false)
        }
        if (
            !identityMatches
        ) {
            rejectCapabilities(mutateSession = true)
        }
        capabilityReport = immutableReport
        state = BandSessionState.READY
        diagnostics.record(
            BandDiagnosticEvent(
                BandDiagnosticKind.CAPABILITY,
                BandDiagnosticOutcome.COMPLETED,
                BandCountBucket.from(immutableReport.capabilities.size),
            ),
        )
    }

    @Synchronized
    fun cancelCapabilities(
        token: BandConnectionToken,
        callbackGeneration: Long,
    ) {
        rejectCallerTraversalReentry(BandDiagnosticKind.CAPABILITY)
        ensureNotClosed()
        validateConnectionToken(
            token,
            callbackGeneration,
            BandDiagnosticKind.CAPABILITY,
        )
        if (state != BandSessionState.NEGOTIATING_CAPABILITIES) {
            diagnostics.record(
                BandDiagnosticEvent(
                    BandDiagnosticKind.CAPABILITY,
                    BandDiagnosticOutcome.REJECTED,
                    failureCategory = BandFailureCategory.INVALID_STATE,
                ),
            )
            fail(BandFailureCategory.INVALID_STATE)
        }
        invalidateAuthenticatedSession(BandSessionState.IDLE)
        diagnostics.record(
            BandDiagnosticEvent(
                BandDiagnosticKind.CAPABILITY,
                BandDiagnosticOutcome.CANCELLED,
            ),
        )
    }

    @Synchronized
    fun failCapabilities(
        category: BandFailureCategory,
        token: BandConnectionToken,
        callbackGeneration: Long,
    ) {
        rejectCallerTraversalReentry(BandDiagnosticKind.CAPABILITY)
        ensureNotClosed()
        validateConnectionToken(
            token,
            callbackGeneration,
            BandDiagnosticKind.CAPABILITY,
        )
        if (state != BandSessionState.NEGOTIATING_CAPABILITIES) {
            diagnostics.record(
                BandDiagnosticEvent(
                    BandDiagnosticKind.CAPABILITY,
                    BandDiagnosticOutcome.REJECTED,
                    failureCategory = BandFailureCategory.INVALID_STATE,
                ),
            )
            fail(BandFailureCategory.INVALID_STATE)
        }
        if (category !in capabilityFailureCategories) {
            diagnostics.record(
                BandDiagnosticEvent(
                    BandDiagnosticKind.CAPABILITY,
                    BandDiagnosticOutcome.REJECTED,
                    failureCategory = BandFailureCategory.INVALID_INPUT,
                ),
            )
            fail(BandFailureCategory.INVALID_INPUT)
        }

        val terminalState = when (category) {
            BandFailureCategory.AUTHENTICATION -> BandSessionState.REJECTED
            BandFailureCategory.SECURITY_FAILURE ->
                BandSessionState.SECURITY_FAILURE
            else -> BandSessionState.RECOVERING
        }
        invalidateAuthenticatedSession(terminalState)

        val outcome = when (category) {
            BandFailureCategory.TIMEOUT -> BandDiagnosticOutcome.TIMED_OUT
            BandFailureCategory.AUTHENTICATION,
            BandFailureCategory.SECURITY_FAILURE,
            -> BandDiagnosticOutcome.REJECTED
            else -> BandDiagnosticOutcome.FAILED
        }
        diagnostics.record(
            BandDiagnosticEvent(
                BandDiagnosticKind.CAPABILITY,
                outcome,
                failureCategory = category,
            ),
        )
    }

    @Synchronized
    fun failEstablishedSession(
        category: BandFailureCategory,
        token: BandConnectionToken,
        callbackGeneration: Long,
    ) {
        rejectCallerTraversalReentry(BandDiagnosticKind.AUTHENTICATION)
        ensureNotClosed()
        validateConnectionToken(
            token,
            callbackGeneration,
            BandDiagnosticKind.AUTHENTICATION,
        )
        if (hasPendingPersistence) {
            diagnostics.record(
                BandDiagnosticEvent(
                    BandDiagnosticKind.AUTHENTICATION,
                    BandDiagnosticOutcome.REJECTED,
                    failureCategory = BandFailureCategory.BUSY,
                ),
            )
            fail(BandFailureCategory.BUSY)
        }
        if (
            state != BandSessionState.READY &&
            state != BandSessionState.LIVE_COLLECTING &&
            !isActiveOperationalState
        ) {
            diagnostics.record(
                BandDiagnosticEvent(
                    BandDiagnosticKind.AUTHENTICATION,
                    BandDiagnosticOutcome.REJECTED,
                    failureCategory = BandFailureCategory.INVALID_STATE,
                ),
            )
            fail(BandFailureCategory.INVALID_STATE)
        }
        if (
            category != BandFailureCategory.AUTHENTICATION &&
            category != BandFailureCategory.SECURITY_FAILURE
        ) {
            diagnostics.record(
                BandDiagnosticEvent(
                    BandDiagnosticKind.AUTHENTICATION,
                    BandDiagnosticOutcome.REJECTED,
                    failureCategory = BandFailureCategory.INVALID_INPUT,
                ),
            )
            fail(BandFailureCategory.INVALID_INPUT)
        }

        val interruptedOperation = activeOperation
        val liveWasActive = liveActive
        invalidateAuthenticatedSession(
            if (category == BandFailureCategory.SECURITY_FAILURE) {
                BandSessionState.SECURITY_FAILURE
            } else {
                BandSessionState.REJECTED
            },
        )
        diagnostics.record(
            buildList {
                interruptedOperation?.let {
                    add(
                        BandDiagnosticEvent(
                            diagnosticKind(it.operationClass),
                            BandDiagnosticOutcome.INTERRUPTED,
                            failureCategory = category,
                            operationClass = it.operationClass,
                        ),
                    )
                }
                if (liveWasActive) {
                    add(
                        BandDiagnosticEvent(
                            BandDiagnosticKind.LIVE,
                            BandDiagnosticOutcome.INTERRUPTED,
                            failureCategory = category,
                        ),
                    )
                }
                add(
                    BandDiagnosticEvent(
                        BandDiagnosticKind.AUTHENTICATION,
                        BandDiagnosticOutcome.REJECTED,
                        failureCategory = category,
                    ),
                )
            },
        )
    }

    @Synchronized
    fun beginLive(
        requestedStreams: Set<BandStreamKind>? = null,
    ): BandLiveToken {
        rejectCallerTraversalReentry(BandDiagnosticKind.LIVE)
        try {
            ensureReadyForOperation()
        } catch (error: BandException) {
            diagnostics.record(
                BandDiagnosticEvent(
                    BandDiagnosticKind.LIVE,
                    BandDiagnosticOutcome.REJECTED,
                    failureCategory = error.category,
                ),
            )
            throw error
        }
        if (liveActive) {
            diagnostics.record(
                BandDiagnosticEvent(
                    BandDiagnosticKind.LIVE,
                    BandDiagnosticOutcome.REJECTED,
                    failureCategory = BandFailureCategory.BUSY,
                ),
            )
            fail(BandFailureCategory.BUSY)
        }
        val traversalFence = captureCallerTraversalFence()
        val negotiatedStreams = capabilityReport?.liveStreams.orEmpty()
        val selectedStreams = try {
            requestedStreams?.let { streams ->
                snapshotCallerOwned {
                    streams.boundedSnapshot(BandStreamKind.entries.size)
                }
            } ?: negotiatedStreams
        } catch (_: BandException) {
            validateCallerTraversalFence(
                traversalFence,
                BandDiagnosticKind.LIVE,
            )
            diagnostics.record(
                BandDiagnosticEvent(
                    BandDiagnosticKind.LIVE,
                    BandDiagnosticOutcome.REJECTED,
                    failureCategory = BandFailureCategory.INVALID_INPUT,
                ),
            )
            fail(BandFailureCategory.INVALID_INPUT)
        }
        validateCallerTraversalFence(
            traversalFence,
            BandDiagnosticKind.LIVE,
        )
        if (
            selectedStreams.isEmpty() ||
            !negotiatedStreams.containsAll(selectedStreams)
        ) {
            diagnostics.record(
                BandDiagnosticEvent(
                    BandDiagnosticKind.LIVE,
                    BandDiagnosticOutcome.REJECTED,
                    failureCategory = BandFailureCategory.UNSUPPORTED,
                ),
            )
            fail(BandFailureCategory.UNSUPPORTED)
        }
        nextLiveSequence += 1
        val token = BandLiveToken(
            sessionNonce = sessionNonce,
            generation = generation,
            sequence = nextLiveSequence,
        )
        activeLiveToken = token
        liveStreams = selectedStreams
        liveActive = true
        state = BandSessionState.LIVE_COLLECTING
        diagnostics.record(
            BandDiagnosticEvent(
                BandDiagnosticKind.LIVE,
                BandDiagnosticOutcome.BEGAN,
            ),
        )
        return token
    }

    @Synchronized
    fun stopLive(token: BandLiveToken) {
        rejectCallerTraversalReentry(BandDiagnosticKind.LIVE)
        ensureNotClosed()
        validateLiveToken(token)
        if (!liveActive) {
            diagnostics.record(
                BandDiagnosticEvent(
                    BandDiagnosticKind.LIVE,
                    BandDiagnosticOutcome.REJECTED,
                    failureCategory = BandFailureCategory.INVALID_STATE,
                ),
            )
            fail(BandFailureCategory.INVALID_STATE)
        }
        if (state != BandSessionState.LIVE_COLLECTING) {
            diagnostics.record(
                BandDiagnosticEvent(
                    BandDiagnosticKind.LIVE,
                    BandDiagnosticOutcome.REJECTED,
                    failureCategory = BandFailureCategory.INVALID_STATE,
                ),
            )
            fail(BandFailureCategory.INVALID_STATE)
        }
        if (pendingLive != null) {
            diagnostics.record(
                BandDiagnosticEvent(
                    BandDiagnosticKind.LIVE,
                    BandDiagnosticOutcome.REJECTED,
                    failureCategory = BandFailureCategory.STORAGE,
                ),
            )
            fail(BandFailureCategory.STORAGE)
        }
        if (activeOperation != null) {
            diagnostics.record(
                BandDiagnosticEvent(
                    BandDiagnosticKind.LIVE,
                    BandDiagnosticOutcome.REJECTED,
                    failureCategory = BandFailureCategory.INVALID_STATE,
                ),
            )
            fail(BandFailureCategory.INVALID_STATE)
        }
        clearLiveTracking()
        state = BandSessionState.READY
        diagnostics.record(
            BandDiagnosticEvent(
                BandDiagnosticKind.LIVE,
                BandDiagnosticOutcome.COMPLETED,
            ),
        )
    }

    @Synchronized
    fun stageLiveBatch(
        batch: BandSampleBatch,
        token: BandLiveToken,
        callbackGeneration: Long,
    ): LiveAcceptance {
        rejectCallerTraversalReentry(BandDiagnosticKind.LIVE)
        validateCallbackGeneration(
            callbackGeneration,
            BandDiagnosticKind.LIVE,
        )
        if (
            !liveActive ||
            (state != BandSessionState.LIVE_COLLECTING && activeOperation == null)
        ) {
            diagnostics.record(
                BandDiagnosticEvent(
                    BandDiagnosticKind.LIVE,
                    BandDiagnosticOutcome.REJECTED,
                    failureCategory = BandFailureCategory.INVALID_STATE,
                ),
            )
            fail(BandFailureCategory.INVALID_STATE)
        }
        validateLiveToken(token)
        if (batch.sourceIdentity != identity?.sourceIdentity) {
            diagnostics.record(
                BandDiagnosticEvent(
                    BandDiagnosticKind.LIVE,
                    BandDiagnosticOutcome.REJECTED,
                    failureCategory = BandFailureCategory.INVALID_INPUT,
                ),
            )
            fail(BandFailureCategory.INVALID_INPUT)
        }
        if (pendingLive != null || pendingHistory != null) {
            diagnostics.record(
                BandDiagnosticEvent(
                    BandDiagnosticKind.LIVE,
                    BandDiagnosticOutcome.REJECTED,
                    failureCategory = BandFailureCategory.BUSY,
                ),
            )
            fail(BandFailureCategory.BUSY)
        }
        val traversalFence = captureCallerTraversalFence()
        val immutableBatch = try {
            snapshotCallerOwned {
                batch.immutableSnapshot().also {
                    it.validate(BandProvenanceLane.LIVE)
                }
            }
        } catch (error: BandException) {
            validateCallerTraversalFence(
                traversalFence,
                BandDiagnosticKind.LIVE,
            )
            diagnostics.record(
                BandDiagnosticEvent(
                    BandDiagnosticKind.LIVE,
                    BandDiagnosticOutcome.REJECTED,
                    failureCategory = error.category,
                ),
            )
            throw error
        }
        validateCallerTraversalFence(
            traversalFence,
            BandDiagnosticKind.LIVE,
        )
        validateNegotiatedBatch(
            immutableBatch,
            BandDiagnosticKind.LIVE,
            liveStreams,
        )
        val negotiatedReport = capabilityReport
            ?: fail(BandFailureCategory.INVALID_STATE)
        val deduplicated = deduplicateSamples(
            immutableBatch.samples,
            BandDiagnosticKind.LIVE,
        )
        val unique = deduplicated.first
        nextLiveReceiptSequence += 1
        val acceptance = LiveAcceptance(
            acceptedSamples = unique,
            duplicateSamples = deduplicated.second,
            capabilityReportRevision = negotiatedReport.reportRevision,
            parserRevision = immutableBatch.parserRevision,
            calibrationRevision = immutableBatch.calibrationRevision,
            sessionNonce = sessionNonce,
            generation = generation,
            receiptSequence = nextLiveReceiptSequence,
        )
        pendingLive = PendingLive(
            acceptance = acceptance,
            samples = unique,
            expectedSampleCount = unique.size,
        )
        diagnostics.recordCoalescingLatest(
            BandDiagnosticEvent(
                BandDiagnosticKind.LIVE,
                BandDiagnosticOutcome.STAGED,
                BandCountBucket.from(unique.size),
            ),
        )
        return acceptance
    }

    @Synchronized
    fun acknowledgeLive(
        receipt: DurableLiveReceipt,
        callbackGeneration: Long,
    ) {
        rejectCallerTraversalReentry(BandDiagnosticKind.LIVE)
        validateCallbackGeneration(
            callbackGeneration,
            BandDiagnosticKind.LIVE,
        )
        validateSessionNonce(
            receipt.sessionNonce,
            BandDiagnosticKind.LIVE,
        )
        val pending = pendingLive
        if (
            pending == null ||
            receipt.generation != pending.acceptance.generation ||
            receipt.receiptSequence != pending.acceptance.receiptSequence
        ) {
            diagnostics.record(
                BandDiagnosticEvent(
                    BandDiagnosticKind.LIVE,
                    BandDiagnosticOutcome.FAILED,
                    failureCategory = BandFailureCategory.STORAGE,
                ),
            )
            fail(BandFailureCategory.STORAGE)
        }
        if (
            !receipt.committed ||
            receipt.committedSamples < pending.expectedSampleCount
        ) {
            pendingLive = null
            diagnostics.record(
                BandDiagnosticEvent(
                    BandDiagnosticKind.LIVE,
                    BandDiagnosticOutcome.FAILED,
                    failureCategory = BandFailureCategory.STORAGE,
                ),
            )
            fail(BandFailureCategory.STORAGE)
        }
        rememberDurableSamples(pending.samples)
        pendingLive = null
        diagnostics.recordCoalescingConsecutive(
            BandDiagnosticEvent(
                BandDiagnosticKind.LIVE,
                BandDiagnosticOutcome.COMPLETED,
                BandCountBucket.from(receipt.committedSamples),
            ),
        )
    }

    @Synchronized
    fun beginOperation(
        operationClass: BandOperationClass,
        requiredCapability: BandCapability? = null,
    ): BandOperationToken {
        val operationDiagnosticKind = diagnosticKind(operationClass)
        rejectCallerTraversalReentry(operationDiagnosticKind)
        try {
            ensureNotClosed()
        } catch (error: BandException) {
            diagnostics.record(
                BandDiagnosticEvent(
                    operationDiagnosticKind,
                    BandDiagnosticOutcome.REJECTED,
                    failureCategory = error.category,
                    operationClass = operationClass,
                ),
            )
            throw error
        }
        if (activeOperation != null) {
            diagnostics.record(
                BandDiagnosticEvent(
                    operationDiagnosticKind,
                    BandDiagnosticOutcome.REJECTED,
                    failureCategory = BandFailureCategory.BUSY,
                    operationClass = operationClass,
                ),
            )
            fail(BandFailureCategory.BUSY)
        }
        try {
            ensureReadyForOperation()
        } catch (error: BandException) {
            diagnostics.record(
                BandDiagnosticEvent(
                    operationDiagnosticKind,
                    BandDiagnosticOutcome.REJECTED,
                    failureCategory = error.category,
                    operationClass = operationClass,
                ),
            )
            throw error
        }
        if (
            liveActive &&
            capabilityReport?.operationsAllowedDuringLive
                ?.contains(operationClass) != true
        ) {
            diagnostics.record(
                BandDiagnosticEvent(
                    operationDiagnosticKind,
                    BandDiagnosticOutcome.REJECTED,
                    failureCategory = BandFailureCategory.BUSY,
                    operationClass = operationClass,
                ),
            )
            fail(BandFailureCategory.BUSY)
        }
        if (operationClass == BandOperationClass.FIRMWARE && liveActive) {
            diagnostics.record(
                BandDiagnosticEvent(
                    operationDiagnosticKind,
                    BandDiagnosticOutcome.REJECTED,
                    failureCategory = BandFailureCategory.BUSY,
                    operationClass = operationClass,
                ),
            )
            fail(BandFailureCategory.BUSY)
        }
        if (
            operationClass == BandOperationClass.FIRMWARE &&
            capabilityReport?.capabilities?.contains(BandCapability.FIRMWARE_UPDATE) != true
        ) {
            diagnostics.record(
                BandDiagnosticEvent(
                    operationDiagnosticKind,
                    BandDiagnosticOutcome.REJECTED,
                    failureCategory = BandFailureCategory.UPDATE_NOT_ELIGIBLE,
                    operationClass = operationClass,
                ),
            )
            fail(BandFailureCategory.UPDATE_NOT_ELIGIBLE)
        }
        if (
            operationClass == BandOperationClass.HISTORY &&
            (
                (capabilityReport?.historyDays ?: 0) <= 0 ||
                    capabilityReport?.historyStreams.isNullOrEmpty()
            )
        ) {
            diagnostics.record(
                BandDiagnosticEvent(
                    operationDiagnosticKind,
                    BandDiagnosticOutcome.REJECTED,
                    failureCategory = BandFailureCategory.UNSUPPORTED,
                    operationClass = operationClass,
                ),
            )
            fail(BandFailureCategory.UNSUPPORTED)
        }
        if (operationClass == BandOperationClass.SAMPLING) {
            val negotiated = capabilityReport?.capabilities.orEmpty()
            val eligible = if (requiredCapability != null) {
                requiredCapability in samplingCapabilities &&
                    requiredCapability in negotiated
            } else {
                negotiated.any { it in samplingCapabilities }
            }
            if (!eligible) {
                diagnostics.record(
                    BandDiagnosticEvent(
                        operationDiagnosticKind,
                        BandDiagnosticOutcome.REJECTED,
                        failureCategory = BandFailureCategory.UNSUPPORTED,
                        operationClass = operationClass,
                    ),
                )
                fail(BandFailureCategory.UNSUPPORTED)
            }
        } else {
            listOfNotNull(
                impliedCapability(operationClass),
                requiredCapability,
            ).forEach { capability ->
                if (capabilityReport?.capabilities?.contains(capability) != true) {
                    diagnostics.record(
                        BandDiagnosticEvent(
                            operationDiagnosticKind,
                            BandDiagnosticOutcome.REJECTED,
                            failureCategory = BandFailureCategory.UNSUPPORTED,
                            operationClass = operationClass,
                        ),
                    )
                    fail(BandFailureCategory.UNSUPPORTED)
                }
            }
        }

        nextOperationSequence += 1
        val token = BandOperationToken(
            sessionNonce,
            generation,
            nextOperationSequence,
            operationClass,
        )
        activeOperation = token
        state = when (operationClass) {
            BandOperationClass.HISTORY -> {
                historyOperationReceivedDurableReceipt = false
                historyOperationLastReceiptComplete = null
                BandSessionState.HISTORY_COLLECTING
            }
            BandOperationClass.FIRMWARE -> BandSessionState.UPDATING_FIRMWARE
            else -> BandSessionState.EXECUTING_COMMAND
        }
        diagnostics.record(
            BandDiagnosticEvent(
                operationDiagnosticKind,
                BandDiagnosticOutcome.BEGAN,
                operationClass = operationClass,
            ),
        )
        return token
    }

    @Synchronized
    fun stageHistoryChunk(
        chunk: BandHistoryChunk,
        token: BandOperationToken,
        callbackGeneration: Long,
    ): HistoryAcceptance {
        rejectCallerTraversalReentry(BandDiagnosticKind.HISTORY)
        validateCallbackGeneration(
            callbackGeneration,
            BandDiagnosticKind.HISTORY,
        )
        try {
            validateActiveToken(token, BandOperationClass.HISTORY)
        } catch (error: BandException) {
            diagnostics.record(
                BandDiagnosticEvent(
                    BandDiagnosticKind.HISTORY,
                    BandDiagnosticOutcome.REJECTED,
                    failureCategory = error.category,
                ),
            )
            throw error
        }
        if (pendingHistory != null || pendingLive != null) {
            diagnostics.record(
                BandDiagnosticEvent(
                    BandDiagnosticKind.HISTORY,
                    BandDiagnosticOutcome.REJECTED,
                    failureCategory = BandFailureCategory.BUSY,
                ),
            )
            fail(BandFailureCategory.BUSY)
        }
        if (historyOperationLastReceiptComplete == true) {
            diagnostics.record(
                BandDiagnosticEvent(
                    BandDiagnosticKind.HISTORY,
                    BandDiagnosticOutcome.REJECTED,
                    failureCategory = BandFailureCategory.INVALID_STATE,
                ),
            )
            fail(BandFailureCategory.INVALID_STATE)
        }
        val traversalFence = captureCallerTraversalFence()
        val immutableChunk = try {
            snapshotCallerOwned {
                chunk.immutableSnapshot().also(BandHistoryChunk::validate)
            }
        } catch (error: BandException) {
            validateCallerTraversalFence(
                traversalFence,
                BandDiagnosticKind.HISTORY,
            )
            diagnostics.record(
                BandDiagnosticEvent(
                    BandDiagnosticKind.HISTORY,
                    BandDiagnosticOutcome.REJECTED,
                    failureCategory = error.category,
                ),
            )
            throw error
        }
        validateCallerTraversalFence(
            traversalFence,
            BandDiagnosticKind.HISTORY,
        )
        immutableChunk.batches.forEach {
            validateNegotiatedBatch(
                it,
                BandDiagnosticKind.HISTORY,
                capabilityReport?.historyStreams.orEmpty(),
            )
        }
        val negotiatedReport = capabilityReport
            ?: fail(BandFailureCategory.INVALID_STATE)
        if (immutableChunk.previousCursor != acknowledgedHistoryCursor) {
            diagnostics.record(
                BandDiagnosticEvent(
                    BandDiagnosticKind.HISTORY,
                    BandDiagnosticOutcome.REJECTED,
                    failureCategory = BandFailureCategory.HISTORY_STALLED,
                ),
            )
            fail(BandFailureCategory.HISTORY_STALLED)
        }
        if (
            !immutableChunk.complete &&
            (
                immutableChunk.nextCursor == null ||
                    immutableChunk.nextCursor == immutableChunk.previousCursor
                )
        ) {
            diagnostics.record(
                BandDiagnosticEvent(
                    BandDiagnosticKind.HISTORY,
                    BandDiagnosticOutcome.REJECTED,
                    failureCategory = BandFailureCategory.HISTORY_STALLED,
                ),
            )
            fail(BandFailureCategory.HISTORY_STALLED)
        }
        if (
            immutableChunk.batches.any {
                it.sourceIdentity != identity?.sourceIdentity
            }
        ) {
            diagnostics.record(
                BandDiagnosticEvent(
                    BandDiagnosticKind.HISTORY,
                    BandDiagnosticOutcome.REJECTED,
                    failureCategory = BandFailureCategory.INVALID_INPUT,
                ),
            )
            fail(BandFailureCategory.INVALID_INPUT)
        }

        val deduplicated = deduplicateSamples(
            immutableChunk.batches.flatMap(BandSampleBatch::samples),
            BandDiagnosticKind.HISTORY,
        )
        val acceptedIdentities =
            deduplicated.first.map(BandSample::identity).toSet()
        val appendedIdentities = mutableSetOf<BandSampleIdentity>()
        val unique = mutableListOf<AcceptedHistorySample>()
        immutableChunk.batches.forEach { batch ->
            batch.samples.forEach { sample ->
                if (
                    sample.identity in acceptedIdentities &&
                    appendedIdentities.add(sample.identity)
                ) {
                    unique += AcceptedHistorySample(
                        sourceIdentity = batch.sourceIdentity,
                        lane = batch.lane,
                        parserRevision = batch.parserRevision,
                        calibrationRevision = batch.calibrationRevision,
                        capabilityReportRevision =
                            negotiatedReport.reportRevision,
                        sample = sample,
                    )
                }
            }
        }
        nextHistoryReceiptSequence += 1
        val effectiveNextCursor =
            immutableChunk.nextCursor ?: if (immutableChunk.complete) {
                immutableChunk.previousCursor
            } else {
                null
            }
        val acceptance = HistoryAcceptance(
            chunkIdentity = immutableChunk.chunkIdentity,
            acknowledgementToken = immutableChunk.acknowledgementToken,
            nextCursor = effectiveNextCursor,
            complete = immutableChunk.complete,
            overflowed = immutableChunk.overflowed,
            retainedRange = immutableChunk.retainedRange,
            firstLostRange = immutableChunk.firstLostRange,
            acceptedSamples = unique,
            duplicateSamples = deduplicated.second,
            sessionNonce = sessionNonce,
            receiptSequence = nextHistoryReceiptSequence,
        )
        pendingHistory = PendingHistory(
            acceptance,
            unique.map(AcceptedHistorySample::sample),
            unique.size,
        )
        diagnostics.record(
            BandDiagnosticEvent(
                BandDiagnosticKind.HISTORY,
                BandDiagnosticOutcome.STAGED,
                BandCountBucket.from(unique.size),
            ),
        )
        return acceptance
    }

    @Synchronized
    fun acknowledgeHistory(
        receipt: DurableHistoryReceipt,
        token: BandOperationToken,
        callbackGeneration: Long,
    ) {
        rejectCallerTraversalReentry(BandDiagnosticKind.HISTORY)
        validateCallbackGeneration(
            callbackGeneration,
            BandDiagnosticKind.HISTORY,
        )
        validateSessionNonce(
            receipt.sessionNonce,
            BandDiagnosticKind.HISTORY,
        )
        try {
            validateActiveToken(token, BandOperationClass.HISTORY)
        } catch (error: BandException) {
            diagnostics.record(
                BandDiagnosticEvent(
                    BandDiagnosticKind.HISTORY,
                    BandDiagnosticOutcome.REJECTED,
                    failureCategory = error.category,
                ),
            )
            throw error
        }
        val pending = pendingHistory
        if (
            pending == null ||
            receipt.receiptSequence != pending.acceptance.receiptSequence ||
            receipt.chunkIdentity != pending.acceptance.chunkIdentity ||
            receipt.acknowledgementToken != pending.acceptance.acknowledgementToken ||
            receipt.nextCursor != pending.acceptance.nextCursor ||
            receipt.complete != pending.acceptance.complete ||
            receipt.overflowed != pending.acceptance.overflowed ||
            receipt.retainedRange != pending.acceptance.retainedRange ||
            receipt.firstLostRange != pending.acceptance.firstLostRange
        ) {
            diagnostics.record(
                BandDiagnosticEvent(
                    BandDiagnosticKind.HISTORY,
                    BandDiagnosticOutcome.FAILED,
                    failureCategory = BandFailureCategory.STORAGE,
                ),
            )
            fail(BandFailureCategory.STORAGE)
        }
        if (
            !receipt.committed ||
            !receipt.historyStateCommitted ||
            receipt.committedSamples < pending.expectedSampleCount
        ) {
            pendingHistory = null
            diagnostics.record(
                BandDiagnosticEvent(
                    BandDiagnosticKind.HISTORY,
                    BandDiagnosticOutcome.FAILED,
                    failureCategory = BandFailureCategory.STORAGE,
                ),
            )
            fail(BandFailureCategory.STORAGE)
        }

        rememberDurableSamples(pending.samples)
        acknowledgedHistoryCursor = receipt.nextCursor
        lastDurableHistoryComplete = pending.acceptance.complete
        historyOperationReceivedDurableReceipt = true
        historyOperationLastReceiptComplete = pending.acceptance.complete
        pendingHistory = null
        diagnostics.record(
            BandDiagnosticEvent(
                BandDiagnosticKind.HISTORY,
                BandDiagnosticOutcome.COMPLETED,
                BandCountBucket.from(receipt.committedSamples),
            ),
        )
    }

    @Synchronized
    fun completeOperation(token: BandOperationToken) {
        val operationDiagnosticKind = diagnosticKind(token.operationClass)
        rejectCallerTraversalReentry(operationDiagnosticKind)
        try {
            validateActiveToken(token, token.operationClass)
        } catch (error: BandException) {
            diagnostics.record(
                BandDiagnosticEvent(
                    operationDiagnosticKind,
                    BandDiagnosticOutcome.REJECTED,
                    failureCategory = error.category,
                    operationClass = token.operationClass,
                ),
            )
            throw error
        }
        if (
            token.operationClass == BandOperationClass.HISTORY &&
            pendingHistory != null
        ) {
            diagnostics.record(
                BandDiagnosticEvent(
                    operationDiagnosticKind,
                    BandDiagnosticOutcome.FAILED,
                    failureCategory = BandFailureCategory.STORAGE,
                    operationClass = token.operationClass,
                ),
            )
            fail(BandFailureCategory.STORAGE)
        }
        if (
            token.operationClass == BandOperationClass.HISTORY &&
            !historyOperationReceivedDurableReceipt
        ) {
            diagnostics.record(
                BandDiagnosticEvent(
                    operationDiagnosticKind,
                    BandDiagnosticOutcome.FAILED,
                    failureCategory = BandFailureCategory.STORAGE,
                    operationClass = token.operationClass,
                ),
            )
            fail(BandFailureCategory.STORAGE)
        }
        if (
            token.operationClass == BandOperationClass.HISTORY &&
            historyOperationLastReceiptComplete != true
        ) {
            diagnostics.record(
                BandDiagnosticEvent(
                    operationDiagnosticKind,
                    BandDiagnosticOutcome.FAILED,
                    failureCategory = BandFailureCategory.HISTORY_STALLED,
                    operationClass = token.operationClass,
                ),
            )
            fail(BandFailureCategory.HISTORY_STALLED)
        }
        if (token.operationClass == BandOperationClass.FIRMWARE) {
            invalidateNegotiationAfterFirmware()
        } else {
            clearActiveOperation()
        }
        diagnostics.record(
            BandDiagnosticEvent(
                operationDiagnosticKind,
                BandDiagnosticOutcome.COMPLETED,
                operationClass = token.operationClass,
            ),
        )
    }

    @Synchronized
    fun cancelOperation(token: BandOperationToken) {
        val operationDiagnosticKind = diagnosticKind(token.operationClass)
        rejectCallerTraversalReentry(operationDiagnosticKind)
        try {
            validateActiveToken(token, token.operationClass)
        } catch (error: BandException) {
            diagnostics.record(
                BandDiagnosticEvent(
                    operationDiagnosticKind,
                    BandDiagnosticOutcome.REJECTED,
                    failureCategory = error.category,
                    operationClass = token.operationClass,
                ),
            )
            throw error
        }
        if (
            token.operationClass == BandOperationClass.HISTORY &&
            pendingHistory != null
        ) {
            diagnostics.record(
                BandDiagnosticEvent(
                    operationDiagnosticKind,
                    BandDiagnosticOutcome.REJECTED,
                    failureCategory = BandFailureCategory.BUSY,
                    operationClass = token.operationClass,
                ),
            )
            fail(BandFailureCategory.BUSY)
        }
        if (token.operationClass == BandOperationClass.FIRMWARE) {
            invalidateNegotiationAfterFirmware()
        } else {
            clearActiveOperation()
        }
        diagnostics.record(
            BandDiagnosticEvent(
                operationDiagnosticKind,
                BandDiagnosticOutcome.CANCELLED,
                operationClass = token.operationClass,
            ),
        )
    }

    @Synchronized
    fun failOperation(
        token: BandOperationToken,
        category: BandFailureCategory,
        firmwareDisposition: BandFirmwareFailureDisposition =
            BandFirmwareFailureDisposition.RECOVERABLE,
    ): BandReconnectToken? {
        val operationDiagnosticKind = diagnosticKind(token.operationClass)
        rejectCallerTraversalReentry(operationDiagnosticKind)
        try {
            validateActiveToken(token, token.operationClass)
        } catch (error: BandException) {
            diagnostics.record(
                BandDiagnosticEvent(
                    operationDiagnosticKind,
                    BandDiagnosticOutcome.REJECTED,
                    failureCategory = error.category,
                    operationClass = token.operationClass,
                ),
            )
            throw error
        }
        if (
            token.operationClass != BandOperationClass.FIRMWARE &&
            firmwareDisposition != BandFirmwareFailureDisposition.RECOVERABLE
        ) {
            diagnostics.record(
                BandDiagnosticEvent(
                    operationDiagnosticKind,
                    BandDiagnosticOutcome.REJECTED,
                    failureCategory = BandFailureCategory.INVALID_INPUT,
                    operationClass = token.operationClass,
                ),
            )
            fail(BandFailureCategory.INVALID_INPUT)
        }
        if (category !in operationFailureCategories(token.operationClass)) {
            diagnostics.record(
                BandDiagnosticEvent(
                    operationDiagnosticKind,
                    BandDiagnosticOutcome.REJECTED,
                    failureCategory = BandFailureCategory.INVALID_INPUT,
                    operationClass = token.operationClass,
                ),
            )
            fail(BandFailureCategory.INVALID_INPUT)
        }
        val terminalFirmwareFailure =
            token.operationClass == BandOperationClass.FIRMWARE &&
                firmwareDisposition == BandFirmwareFailureDisposition.TERMINAL
        val invalidatesSession =
            category == BandFailureCategory.SECURITY_FAILURE ||
                category == BandFailureCategory.AUTHENTICATION ||
                category == BandFailureCategory.DISCONNECTED ||
                terminalFirmwareFailure
        if (
            (
                token.operationClass == BandOperationClass.HISTORY &&
                    pendingHistory != null
                ) ||
            (invalidatesSession && hasPendingPersistence)
        ) {
            diagnostics.record(
                BandDiagnosticEvent(
                    operationDiagnosticKind,
                    BandDiagnosticOutcome.REJECTED,
                    failureCategory = BandFailureCategory.BUSY,
                    operationClass = token.operationClass,
                ),
            )
            fail(BandFailureCategory.BUSY)
        }
        if (terminalFirmwareFailure) {
            invalidateAuthenticatedSession(BandSessionState.FIRMWARE_FAILURE)
        } else if (
            category == BandFailureCategory.SECURITY_FAILURE ||
            category == BandFailureCategory.AUTHENTICATION
        ) {
            val liveWasActive = liveActive
            invalidateAuthenticatedSession(
                if (category == BandFailureCategory.SECURITY_FAILURE) {
                    BandSessionState.SECURITY_FAILURE
                } else {
                    BandSessionState.REJECTED
                },
            )
            diagnostics.record(
                buildList {
                    if (liveWasActive) {
                        add(
                            BandDiagnosticEvent(
                                BandDiagnosticKind.LIVE,
                                BandDiagnosticOutcome.INTERRUPTED,
                                failureCategory = category,
                            ),
                        )
                    }
                    add(
                        BandDiagnosticEvent(
                            operationDiagnosticKind,
                            BandDiagnosticOutcome.FAILED,
                            failureCategory = category,
                            operationClass = token.operationClass,
                        ),
                    )
                },
            )
            return null
        } else if (
            token.operationClass == BandOperationClass.FIRMWARE &&
            category == BandFailureCategory.DISCONNECTED
        ) {
            invalidateNegotiationAfterFirmware()
            diagnostics.record(
                listOf(
                    BandDiagnosticEvent(
                        BandDiagnosticKind.FIRMWARE,
                        BandDiagnosticOutcome.INTERRUPTED,
                        failureCategory = BandFailureCategory.DISCONNECTED,
                        operationClass = BandOperationClass.FIRMWARE,
                    ),
                    BandDiagnosticEvent(
                        BandDiagnosticKind.RECONNECT,
                        BandDiagnosticOutcome.INTERRUPTED,
                        failureCategory = BandFailureCategory.DISCONNECTED,
                    ),
                ),
            )
            return null
        } else if (token.operationClass == BandOperationClass.FIRMWARE) {
            invalidateNegotiationAfterFirmware()
        } else if (category == BandFailureCategory.DISCONNECTED) {
            nextReconnectSequence += 1
            generation += 1
            val reconnectToken = BandReconnectToken(
                sessionNonce = sessionNonce,
                generation = generation,
                sequence = nextReconnectSequence,
            )
            activeReconnectToken = reconnectToken
            state = BandSessionState.RECOVERING
            val interruptionEvents = buildList {
                add(
                    BandDiagnosticEvent(
                        operationDiagnosticKind,
                        BandDiagnosticOutcome.FAILED,
                        failureCategory = category,
                        operationClass = token.operationClass,
                    ),
                )
                if (liveActive) {
                    add(
                        BandDiagnosticEvent(
                            BandDiagnosticKind.LIVE,
                            BandDiagnosticOutcome.INTERRUPTED,
                        ),
                    )
                }
                add(
                    BandDiagnosticEvent(
                        BandDiagnosticKind.RECONNECT,
                        BandDiagnosticOutcome.INTERRUPTED,
                        failureCategory = BandFailureCategory.DISCONNECTED,
                    ),
                )
            }
            diagnostics.record(interruptionEvents)
            clearOperationTracking()
            clearLiveTracking()
            activeConnectionToken = null
            return reconnectToken
        } else {
            clearActiveOperation()
        }
        diagnostics.record(
            BandDiagnosticEvent(
                operationDiagnosticKind,
                if (terminalFirmwareFailure) {
                    BandDiagnosticOutcome.TERMINAL
                } else {
                    BandDiagnosticOutcome.FAILED
                },
                failureCategory = category,
                operationClass = token.operationClass,
            ),
        )
        if (
            category == BandFailureCategory.DISCONNECTED &&
            !terminalFirmwareFailure
        ) {
            diagnostics.record(
                BandDiagnosticEvent(
                    BandDiagnosticKind.RECONNECT,
                    BandDiagnosticOutcome.INTERRUPTED,
                    failureCategory = BandFailureCategory.DISCONNECTED,
                ),
            )
        }
        return null
    }

    @Synchronized
    fun interruptForReconnect(
        token: BandConnectionToken,
        callbackGeneration: Long,
    ): BandReconnectToken {
        rejectCallerTraversalReentry(BandDiagnosticKind.RECONNECT)
        ensureNotClosed()
        validateConnectionToken(
            token,
            callbackGeneration,
            BandDiagnosticKind.RECONNECT,
        )
        if (
            identity == null ||
            capabilityReport == null ||
            activeOperation?.operationClass == BandOperationClass.FIRMWARE
        ) {
            diagnostics.record(
                BandDiagnosticEvent(
                    BandDiagnosticKind.RECONNECT,
                    BandDiagnosticOutcome.REJECTED,
                    failureCategory = BandFailureCategory.INVALID_STATE,
                ),
            )
            fail(BandFailureCategory.INVALID_STATE)
        }
        if (hasPendingPersistence) {
            diagnostics.record(
                BandDiagnosticEvent(
                    BandDiagnosticKind.RECONNECT,
                    BandDiagnosticOutcome.REJECTED,
                    failureCategory = BandFailureCategory.BUSY,
                ),
            )
            fail(BandFailureCategory.BUSY)
        }
        val interruptedOperation = activeOperation
        nextReconnectSequence += 1
        generation += 1
        val reconnectToken = BandReconnectToken(
            sessionNonce = sessionNonce,
            generation = generation,
            sequence = nextReconnectSequence,
        )
        activeReconnectToken = reconnectToken
        state = BandSessionState.RECOVERING
        val interruptionEvents = buildList {
            interruptedOperation?.let {
                add(
                    BandDiagnosticEvent(
                        diagnosticKind(it.operationClass),
                        BandDiagnosticOutcome.INTERRUPTED,
                        failureCategory = BandFailureCategory.DISCONNECTED,
                        operationClass = it.operationClass,
                    ),
                )
            }
            if (liveActive) {
                add(
                    BandDiagnosticEvent(
                        BandDiagnosticKind.LIVE,
                        BandDiagnosticOutcome.INTERRUPTED,
                    ),
                )
            }
            add(
                BandDiagnosticEvent(
                    BandDiagnosticKind.RECONNECT,
                    BandDiagnosticOutcome.INTERRUPTED,
                ),
            )
        }
        diagnostics.record(interruptionEvents)
        clearOperationTracking()
        clearLiveTracking()
        activeConnectionToken = null
        return reconnectToken
    }

    @Synchronized
    fun resumeAfterReconnect(
        reconnectToken: BandReconnectToken,
        callbackGeneration: Long,
    ): BandConnectionToken {
        rejectCallerTraversalReentry(BandDiagnosticKind.RECONNECT)
        ensureNotClosed()
        validateReconnectToken(
            reconnectToken,
            callbackGeneration,
            BandDiagnosticKind.RECONNECT,
        )
        val connectedIdentity = identity
        if (
            state != BandSessionState.RECOVERING ||
            connectedIdentity == null ||
            capabilityReport == null
        ) {
            fail(BandFailureCategory.INVALID_STATE)
        }
        nextConnectionSequence += 1
        val connectionToken = BandConnectionToken(
            sessionNonce = sessionNonce,
            generation = generation,
            sequence = nextConnectionSequence,
            candidateHandle = connectedIdentity.sourceIdentity,
        )
        activeConnectionToken = connectionToken
        activeReconnectToken = null
        state = BandSessionState.READY
        diagnostics.record(
            BandDiagnosticEvent(
                BandDiagnosticKind.RECONNECT,
                BandDiagnosticOutcome.COMPLETED,
            ),
        )
        return connectionToken
    }

    @Synchronized
    fun disconnect(
        reason: BandDisconnectReason,
        callbackGeneration: Long,
    ): Long {
        rejectCallerTraversalReentry(BandDiagnosticKind.DISCONNECT)
        ensureNotClosed()
        validateCallbackGeneration(
            callbackGeneration,
            BandDiagnosticKind.DISCONNECT,
            disconnectReason = reason,
        )
        if (
            state == BandSessionState.IDLE ||
            state == BandSessionState.DISCONNECTING ||
            state == BandSessionState.INCOMPATIBLE ||
            state == BandSessionState.REJECTED ||
            state == BandSessionState.SECURITY_FAILURE ||
            state == BandSessionState.FIRMWARE_FAILURE
        ) {
            diagnostics.record(
                BandDiagnosticEvent(
                    BandDiagnosticKind.DISCONNECT,
                    BandDiagnosticOutcome.REJECTED,
                    failureCategory = BandFailureCategory.INVALID_STATE,
                    disconnectReason = reason,
                ),
            )
            fail(BandFailureCategory.INVALID_STATE)
        }
        if (hasPendingPersistence) {
            diagnostics.record(
                BandDiagnosticEvent(
                    BandDiagnosticKind.DISCONNECT,
                    BandDiagnosticOutcome.REJECTED,
                    failureCategory = BandFailureCategory.BUSY,
                    disconnectReason = reason,
                ),
            )
            fail(BandFailureCategory.BUSY)
        }
        if (
            activeOperation?.operationClass == BandOperationClass.FIRMWARE
        ) {
            diagnostics.record(
                BandDiagnosticEvent(
                    BandDiagnosticKind.DISCONNECT,
                    BandDiagnosticOutcome.REJECTED,
                    failureCategory = BandFailureCategory.INVALID_STATE,
                    disconnectReason = reason,
                ),
            )
            fail(BandFailureCategory.INVALID_STATE)
        }

        val cancelledOperationClass = activeOperation?.operationClass
        val cancelledKinds = activeTerminalDiagnosticKinds()
        state = BandSessionState.DISCONNECTING
        generation += 1
        val idleGeneration = generation
        clearOperationTracking()
        clearLiveTracking()
        activeConnectionToken = null
        activeReconnectToken = null
        identity = null
        capabilityReport = null
        diagnostics.record(
            BandDiagnosticEvent(
                BandDiagnosticKind.DISCONNECT,
                BandDiagnosticOutcome.BEGAN,
                disconnectReason = reason,
            ),
        )
        state = BandSessionState.IDLE
        diagnostics.record(
            cancelledKinds.map {
                BandDiagnosticEvent(
                    it,
                    BandDiagnosticOutcome.CANCELLED,
                    operationClass = cancelledOperationClass?.takeIf {
                        operation -> diagnosticKind(operation) == it
                    },
                )
            } + BandDiagnosticEvent(
                BandDiagnosticKind.DISCONNECT,
                BandDiagnosticOutcome.COMPLETED,
                disconnectReason = reason,
            ),
        )
        return idleGeneration
    }

    @Synchronized
    fun close() {
        rejectCallerTraversalReentry(BandDiagnosticKind.DISCONNECT)
        if (state == BandSessionState.CLOSED) {
            return
        }
        if (hasPendingPersistence) {
            val pendingKind = if (pendingHistory == null) {
                BandDiagnosticKind.LIVE
            } else {
                BandDiagnosticKind.HISTORY
            }
            diagnostics.record(
                BandDiagnosticEvent(
                    pendingKind,
                    BandDiagnosticOutcome.REJECTED,
                    failureCategory = BandFailureCategory.BUSY,
                ),
            )
            fail(BandFailureCategory.BUSY)
        }
        val terminalOperationClass = activeOperation?.operationClass
        val terminalKinds = activeTerminalDiagnosticKinds()
        generation += 1
        clearOperationTracking()
        clearLiveTracking()
        activeConnectionToken = null
        activeReconnectToken = null
        identity = null
        capabilityReport = null
        state = BandSessionState.CLOSED
        diagnostics.record(
            terminalKinds.map {
                BandDiagnosticEvent(
                    it,
                    BandDiagnosticOutcome.CANCELLED,
                    operationClass = terminalOperationClass?.takeIf {
                        operation -> diagnosticKind(operation) == it
                    },
                )
            },
        )
    }

    private fun rejectCapabilities(mutateSession: Boolean): Nothing {
        if (mutateSession) {
            state = BandSessionState.INCOMPATIBLE
            capabilityReport = null
        }
        diagnostics.record(
            BandDiagnosticEvent(
                BandDiagnosticKind.CAPABILITY,
                BandDiagnosticOutcome.REJECTED,
                failureCategory = if (mutateSession) {
                    BandFailureCategory.INCOMPATIBLE
                } else {
                    BandFailureCategory.INVALID_STATE
                },
            ),
        )
        fail(
            if (mutateSession) {
                BandFailureCategory.INCOMPATIBLE
            } else {
                BandFailureCategory.INVALID_STATE
            },
        )
    }

    private fun validateCallbackGeneration(
        callbackGeneration: Long,
        diagnosticKind: BandDiagnosticKind,
        disconnectReason: BandDisconnectReason? = null,
    ) {
        if (callbackGeneration != generation) {
            diagnostics.record(
                BandDiagnosticEvent(
                    diagnosticKind,
                    BandDiagnosticOutcome.STALE,
                    failureCategory = BandFailureCategory.STALE_CALLBACK,
                    disconnectReason = disconnectReason,
                ),
            )
            fail(BandFailureCategory.STALE_CALLBACK)
        }
    }

    private fun validateScanToken(
        token: BandScanToken,
        diagnosticKind: BandDiagnosticKind,
    ) {
        if (
            token.sessionNonce != sessionNonce ||
            token.generation != generation ||
            token !== activeScanToken
        ) {
            diagnostics.record(
                BandDiagnosticEvent(
                    diagnosticKind,
                    BandDiagnosticOutcome.STALE,
                    failureCategory = BandFailureCategory.STALE_CALLBACK,
                ),
            )
            fail(BandFailureCategory.STALE_CALLBACK)
        }
    }

    private fun validateConnectionToken(
        token: BandConnectionToken,
        callbackGeneration: Long,
        diagnosticKind: BandDiagnosticKind,
    ) {
        validateCallbackGeneration(callbackGeneration, diagnosticKind)
        if (
            token.sessionNonce != sessionNonce ||
            token.generation != generation ||
            token !== activeConnectionToken
        ) {
            diagnostics.record(
                BandDiagnosticEvent(
                    diagnosticKind,
                    BandDiagnosticOutcome.STALE,
                    failureCategory = BandFailureCategory.STALE_CALLBACK,
                ),
            )
            fail(BandFailureCategory.STALE_CALLBACK)
        }
    }

    private fun validateReconnectToken(
        token: BandReconnectToken,
        callbackGeneration: Long,
        diagnosticKind: BandDiagnosticKind,
    ) {
        validateCallbackGeneration(callbackGeneration, diagnosticKind)
        if (
            token.sessionNonce != sessionNonce ||
            token.generation != generation ||
            token !== activeReconnectToken
        ) {
            diagnostics.record(
                BandDiagnosticEvent(
                    diagnosticKind,
                    BandDiagnosticOutcome.STALE,
                    failureCategory = BandFailureCategory.STALE_CALLBACK,
                ),
            )
            fail(BandFailureCategory.STALE_CALLBACK)
        }
    }

    private fun validateActiveToken(
        token: BandOperationToken,
        expected: BandOperationClass,
    ) {
        if (
            token.sessionNonce != sessionNonce ||
            token.generation != generation
        ) {
            fail(BandFailureCategory.STALE_CALLBACK)
        }
        if (token.operationClass != expected || token != activeOperation) {
            fail(BandFailureCategory.INVALID_STATE)
        }
    }

    private fun validateLiveToken(token: BandLiveToken) {
        if (
            token.sessionNonce != sessionNonce ||
            token.generation != generation ||
            token !== activeLiveToken
        ) {
            diagnostics.record(
                BandDiagnosticEvent(
                    BandDiagnosticKind.LIVE,
                    BandDiagnosticOutcome.STALE,
                    failureCategory = BandFailureCategory.STALE_CALLBACK,
                ),
            )
            fail(BandFailureCategory.STALE_CALLBACK)
        }
    }

    private fun validateSessionNonce(
        candidate: UUID,
        diagnosticKind: BandDiagnosticKind,
    ) {
        if (candidate != sessionNonce) {
            diagnostics.record(
                BandDiagnosticEvent(
                    diagnosticKind,
                    BandDiagnosticOutcome.STALE,
                    failureCategory = BandFailureCategory.STALE_CALLBACK,
                ),
            )
            fail(BandFailureCategory.STALE_CALLBACK)
        }
    }

    private fun ensureReadyForOperation() {
        ensureNotClosed()
        if (
            state != BandSessionState.READY &&
            state != BandSessionState.LIVE_COLLECTING
        ) {
            fail(BandFailureCategory.INVALID_STATE)
        }
    }

    private fun ensureNotClosed() {
        if (state == BandSessionState.CLOSED) {
            fail(BandFailureCategory.CLOSED)
        }
    }

    private fun rejectCallerTraversalReentry(
        diagnosticKind: BandDiagnosticKind,
    ) {
        // JVM synchronized monitors are reentrant, so every public entry must
        // reject while a caller-owned collection is being traversed.
        if (callerTraversalActive) {
            diagnostics.record(
                BandDiagnosticEvent(
                    diagnosticKind,
                    BandDiagnosticOutcome.REJECTED,
                    failureCategory = BandFailureCategory.INVALID_INPUT,
                ),
            )
            fail(BandFailureCategory.INVALID_INPUT)
        }
    }

    private inline fun <T> snapshotCallerOwned(block: () -> T): T {
        if (callerTraversalActive) {
            fail(BandFailureCategory.INVALID_INPUT)
        }
        callerTraversalActive = true
        return try {
            block()
        } finally {
            callerTraversalActive = false
        }
    }

    private fun captureCallerTraversalFence(): CallerTraversalFence =
        CallerTraversalFence(
            state = state,
            generation = generation,
            nextConnectionSequence = nextConnectionSequence,
            nextReconnectSequence = nextReconnectSequence,
            nextOperationSequence = nextOperationSequence,
            nextLiveSequence = nextLiveSequence,
            nextLiveReceiptSequence = nextLiveReceiptSequence,
            nextHistoryReceiptSequence = nextHistoryReceiptSequence,
            activeScanToken = activeScanToken,
            activeConnectionToken = activeConnectionToken,
            activeReconnectToken = activeReconnectToken,
            activeOperation = activeOperation,
            activeLiveToken = activeLiveToken,
            liveActive = liveActive,
            identity = identity,
            capabilityReport = capabilityReport,
            pendingLive = pendingLive,
            pendingHistory = pendingHistory,
        )

    private fun validateCallerTraversalFence(
        expected: CallerTraversalFence,
        diagnosticKind: BandDiagnosticKind,
    ) {
        if (
            state != expected.state ||
            generation != expected.generation ||
            nextConnectionSequence != expected.nextConnectionSequence ||
            nextReconnectSequence != expected.nextReconnectSequence ||
            nextOperationSequence != expected.nextOperationSequence ||
            nextLiveSequence != expected.nextLiveSequence ||
            nextLiveReceiptSequence != expected.nextLiveReceiptSequence ||
            nextHistoryReceiptSequence != expected.nextHistoryReceiptSequence ||
            activeScanToken !== expected.activeScanToken ||
            activeConnectionToken !== expected.activeConnectionToken ||
            activeReconnectToken !== expected.activeReconnectToken ||
            activeOperation !== expected.activeOperation ||
            activeLiveToken !== expected.activeLiveToken ||
            liveActive != expected.liveActive ||
            identity !== expected.identity ||
            capabilityReport !== expected.capabilityReport ||
            pendingLive !== expected.pendingLive ||
            pendingHistory !== expected.pendingHistory
        ) {
            diagnostics.record(
                BandDiagnosticEvent(
                    diagnosticKind,
                    BandDiagnosticOutcome.STALE,
                    failureCategory = BandFailureCategory.STALE_CALLBACK,
                ),
            )
            fail(BandFailureCategory.STALE_CALLBACK)
        }
    }

    private val samplingCapabilities: Set<BandCapability>
        get() = setOf(
            BandCapability.HEART_RATE,
            BandCapability.RR_INTERVALS,
            BandCapability.STEPS,
            BandCapability.SPO2,
            BandCapability.RESPIRATION,
            BandCapability.TEMPERATURE,
            BandCapability.ACCELEROMETER,
        )

    private val scanFailureCategories: Set<BandFailureCategory>
        get() = setOf(
            BandFailureCategory.NO_RESULT,
            BandFailureCategory.TIMEOUT,
            BandFailureCategory.PERMISSION,
            BandFailureCategory.UNAVAILABLE,
            BandFailureCategory.INTERNAL_FAILURE,
        )

    private val connectionFailureCategories: Set<BandFailureCategory>
        get() = setOf(
            BandFailureCategory.UNAVAILABLE,
            BandFailureCategory.PERMISSION,
            BandFailureCategory.TIMEOUT,
            BandFailureCategory.REJECTED,
            BandFailureCategory.AUTHENTICATION,
            BandFailureCategory.SECURITY_FAILURE,
            BandFailureCategory.DISCONNECTED,
            BandFailureCategory.INTERNAL_FAILURE,
        )

    private val capabilityFailureCategories: Set<BandFailureCategory>
        get() = setOf(
            BandFailureCategory.UNAVAILABLE,
            BandFailureCategory.TIMEOUT,
            BandFailureCategory.AUTHENTICATION,
            BandFailureCategory.SECURITY_FAILURE,
            BandFailureCategory.DISCONNECTED,
            BandFailureCategory.INTERNAL_FAILURE,
        )

    private fun diagnosticKind(
        operationClass: BandOperationClass,
    ): BandDiagnosticKind = when (operationClass) {
        BandOperationClass.HISTORY -> BandDiagnosticKind.HISTORY
        BandOperationClass.FIRMWARE -> BandDiagnosticKind.FIRMWARE
        else -> BandDiagnosticKind.COMMAND
    }

    private fun clearActiveOperation() {
        clearOperationTracking()
        state = if (liveActive) {
            BandSessionState.LIVE_COLLECTING
        } else {
            BandSessionState.READY
        }
    }

    private fun invalidateNegotiationAfterFirmware() {
        invalidateAuthenticatedSession(BandSessionState.RECOVERING)
    }

    private fun clearLiveTracking() {
        liveActive = false
        activeLiveToken = null
        liveStreams = emptySet()
        pendingLive = null
    }

    private fun activeTerminalDiagnosticKinds(): List<BandDiagnosticKind> {
        val kinds = mutableListOf<BandDiagnosticKind>()
        activeOperation?.let {
            kinds += diagnosticKind(it.operationClass)
        }
        if (liveActive) {
            kinds += BandDiagnosticKind.LIVE
        }
        val phaseKind = when (state) {
            BandSessionState.SCANNING -> BandDiagnosticKind.DISCOVERY
            BandSessionState.CONNECTING -> BandDiagnosticKind.CONNECTION
            BandSessionState.AUTHENTICATING ->
                BandDiagnosticKind.AUTHENTICATION
            BandSessionState.NEGOTIATING_CAPABILITIES ->
                BandDiagnosticKind.CAPABILITY
            BandSessionState.RECOVERING -> BandDiagnosticKind.RECONNECT
            BandSessionState.DISCONNECTING ->
                BandDiagnosticKind.DISCONNECT
            else -> null
        }
        if (phaseKind != null && phaseKind !in kinds) {
            kinds += phaseKind
        }
        return kinds
    }

    private fun clearOperationTracking() {
        activeOperation = null
        pendingHistory = null
        historyOperationReceivedDurableReceipt = false
        historyOperationLastReceiptComplete = null
    }

    private fun clearConnectionAttempt(nextState: BandSessionState) {
        invalidateAuthenticatedSession(nextState)
    }

    private val hasPendingPersistence: Boolean
        get() = pendingLive != null || pendingHistory != null

    private fun invalidateAuthenticatedSession(nextState: BandSessionState) {
        clearOperationTracking()
        clearLiveTracking()
        activeConnectionToken = null
        activeReconnectToken = null
        identity = null
        capabilityReport = null
        generation += 1
        state = nextState
    }

    private fun diagnosticKind(
        phase: BandConnectionPhase,
    ): BandDiagnosticKind = when (phase) {
        BandConnectionPhase.CONNECTION -> BandDiagnosticKind.CONNECTION
        BandConnectionPhase.AUTHENTICATION ->
            BandDiagnosticKind.AUTHENTICATION
    }

    private fun sessionState(
        phase: BandConnectionPhase,
    ): BandSessionState = when (phase) {
        BandConnectionPhase.CONNECTION -> BandSessionState.CONNECTING
        BandConnectionPhase.AUTHENTICATION ->
            BandSessionState.AUTHENTICATING
        }

    private fun clearDurableSampleIdentities() {
        durableSampleIdentities.clear()
        durableSamplesByIdentity.clear()
        durableSampleFingerprintsByIdentity.clear()
        durableSampleIdentityOrder.clear()
    }

    private fun restoreDurableSampleState(
        identities: Set<BandSampleIdentity>,
        fingerprints: Set<BandSampleFingerprint>,
    ) {
        clearDurableSampleIdentities()
        val orderedIdentities = identities.sortedWith(
            compareBy<BandSampleIdentity> {
                it.deviceTimeMilliseconds
            }.thenBy {
                it.sequence
            }.thenBy {
                it.stream.wireValue
            },
        )
        rememberDurableSampleIdentities(orderedIdentities)
        val ordered = fingerprints.sortedWith(
            compareBy<BandSampleFingerprint> {
                it.identity.deviceTimeMilliseconds
            }.thenBy {
                it.identity.sequence
            }.thenBy {
                it.identity.stream.wireValue
            },
        )
        ordered.forEach { fingerprint ->
            durableSampleFingerprintsByIdentity[fingerprint.identity] =
                fingerprint
        }
    }

    private fun prepareDurableState(sourceIdentity: String) {
        if (
            !restoredHistoryCheckpointConsumed &&
            restoredHistoryCheckpoint?.sourceIdentity == sourceIdentity
        ) {
            try {
                restoredHistoryCheckpoint.validate()
            } catch (_: BandException) {
                diagnostics.record(
                    BandDiagnosticEvent(
                        BandDiagnosticKind.HISTORY,
                        BandDiagnosticOutcome.REJECTED,
                        failureCategory = BandFailureCategory.INVALID_INPUT,
                    ),
                )
                fail(BandFailureCategory.INVALID_INPUT)
            }
            restoreDurableSampleState(
                restoredHistoryCheckpoint.durableSampleIdentities,
                restoredHistoryCheckpoint.durableSampleFingerprints,
            )
            acknowledgedHistoryCursor =
                restoredHistoryCheckpoint.acknowledgedCursor
            lastDurableHistoryComplete =
                restoredHistoryCheckpoint.lastHistoryComplete
            durableSourceIdentity = sourceIdentity
            restoredHistoryCheckpointConsumed = true
        } else if (durableSourceIdentity != sourceIdentity) {
            clearDurableSampleIdentities()
            acknowledgedHistoryCursor = null
            lastDurableHistoryComplete = null
            durableSourceIdentity = sourceIdentity
        }
    }

    private fun rememberDurableSampleIdentities(
        identities: List<BandSampleIdentity>,
    ) {
        identities.forEach { identity ->
            if (identity !in durableSampleIdentities) {
                if (
                    durableSampleIdentities.size ==
                    BandContractLimits.HISTORY_CHECKPOINT_IDENTITIES
                ) {
                    val oldest = durableSampleIdentityOrder.removeFirst()
                    durableSampleIdentities.remove(oldest)
                    durableSamplesByIdentity.remove(oldest)
                    durableSampleFingerprintsByIdentity.remove(oldest)
                }
                durableSampleIdentities.add(identity)
                durableSampleIdentityOrder.addLast(identity)
            }
        }
    }

    private fun rememberDurableSamples(samples: List<BandSample>) {
        rememberDurableSampleIdentities(samples.map(BandSample::identity))
        samples.forEach { sample ->
            if (sample.identity in durableSampleIdentities) {
                durableSamplesByIdentity[sample.identity] = sample
                durableSampleFingerprintsByIdentity[sample.identity] =
                    BandSampleFingerprint(sample)
            }
        }
    }

    private fun deduplicateSamples(
        samples: List<BandSample>,
        diagnosticKind: BandDiagnosticKind,
    ): Pair<List<BandSample>, Int> {
        val incomingByIdentity =
            mutableMapOf<BandSampleIdentity, BandSample>()
        val unique = mutableListOf<BandSample>()
        var duplicates = 0

        samples.forEach { sample ->
            val incoming = incomingByIdentity[sample.identity]
            if (incoming != null) {
                if (!incoming.hasEquivalentPayload(sample)) {
                    diagnostics.record(
                        BandDiagnosticEvent(
                            diagnosticKind,
                            BandDiagnosticOutcome.REJECTED,
                            failureCategory = BandFailureCategory.INVALID_INPUT,
                        ),
                    )
                    fail(BandFailureCategory.INVALID_INPUT)
                }
                duplicates += 1
            } else {
                incomingByIdentity[sample.identity] = sample
                val durable = durableSamplesByIdentity[sample.identity]
                if (durable != null) {
                    if (!durable.hasEquivalentPayload(sample)) {
                        diagnostics.record(
                            BandDiagnosticEvent(
                                diagnosticKind,
                                BandDiagnosticOutcome.REJECTED,
                                failureCategory =
                                BandFailureCategory.INVALID_INPUT,
                            ),
                        )
                        fail(BandFailureCategory.INVALID_INPUT)
                    }
                    duplicates += 1
                } else {
                    val fingerprint =
                        durableSampleFingerprintsByIdentity[sample.identity]
                    if (fingerprint != null) {
                        if (!fingerprint.matches(sample)) {
                            diagnostics.record(
                                BandDiagnosticEvent(
                                    diagnosticKind,
                                    BandDiagnosticOutcome.REJECTED,
                                    failureCategory =
                                    BandFailureCategory.INVALID_INPUT,
                                ),
                            )
                            fail(BandFailureCategory.INVALID_INPUT)
                        }
                        duplicates += 1
                    } else {
                        unique += sample
                    }
                }
            }
        }
        return unique to duplicates
    }

    private val isActiveOperationalState: Boolean
        get() = when (activeOperation?.operationClass) {
            BandOperationClass.HISTORY ->
                state == BandSessionState.HISTORY_COLLECTING
            BandOperationClass.FIRMWARE ->
                state == BandSessionState.UPDATING_FIRMWARE
            null -> false
            else -> state == BandSessionState.EXECUTING_COMMAND
        }

    private fun operationFailureCategories(
        operationClass: BandOperationClass,
    ): Set<BandFailureCategory> {
        val categories = mutableSetOf(
            BandFailureCategory.UNAVAILABLE,
            BandFailureCategory.PERMISSION,
            BandFailureCategory.NO_RESULT,
            BandFailureCategory.TIMEOUT,
            BandFailureCategory.REJECTED,
            BandFailureCategory.AUTHENTICATION,
            BandFailureCategory.SECURITY_FAILURE,
            BandFailureCategory.DISCONNECTED,
            BandFailureCategory.LOW_BATTERY,
            BandFailureCategory.UNSUPPORTED,
            BandFailureCategory.INTERNAL_FAILURE,
        )
        when (operationClass) {
            BandOperationClass.HISTORY -> categories += setOf(
                BandFailureCategory.STORAGE,
                BandFailureCategory.HISTORY_STALLED,
            )
            BandOperationClass.FIRMWARE -> categories += setOf(
                BandFailureCategory.UPDATE_NOT_ELIGIBLE,
                BandFailureCategory.UPDATE_INTERRUPTED,
                BandFailureCategory.UPDATE_VERIFICATION,
            )
            else -> Unit
        }
        return categories
    }

    private fun validateNegotiatedBatch(
        batch: BandSampleBatch,
        diagnosticKind: BandDiagnosticKind,
        allowedStreams: Set<BandStreamKind>? = null,
    ) {
        val report = capabilityReport
        if (
            report == null ||
            batch.samples.any {
                val stream = it.identity.stream
                requiredCapability(stream) !in report.capabilities ||
                    (
                        allowedStreams != null &&
                            stream !in allowedStreams
                        ) ||
                    report.streamSemantics.none { semantics ->
                        semantics.lane == batch.lane &&
                            semantics.stream == stream &&
                            semantics.unit == it.unit &&
                            semantics.parserRevision ==
                            batch.parserRevision &&
                            semantics.calibrationRevision ==
                            batch.calibrationRevision
                    }
            }
        ) {
            diagnostics.record(
                BandDiagnosticEvent(
                    diagnosticKind,
                    BandDiagnosticOutcome.REJECTED,
                    failureCategory = BandFailureCategory.UNSUPPORTED,
                ),
            )
            fail(BandFailureCategory.UNSUPPORTED)
        }
    }

    private fun impliedCapability(
        operationClass: BandOperationClass,
    ): BandCapability? = when (operationClass) {
        BandOperationClass.BATTERY -> BandCapability.BATTERY
        BandOperationClass.WEAR_STATE -> BandCapability.WEAR_STATE
        BandOperationClass.HAPTIC -> BandCapability.HAPTICS
        BandOperationClass.ALARM -> BandCapability.ALARMS
        BandOperationClass.HISTORY,
        BandOperationClass.SAMPLING,
        BandOperationClass.FIRMWARE,
        -> null
    }
}
