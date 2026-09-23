import Foundation

public actor BandSessionMachine {
    private struct PendingLive {
        let acceptance: LiveAcceptance
        let sampleIdentities: [BandSampleIdentity]
        let expectedSampleCount: Int
    }

    private struct PendingHistory {
        let acceptance: HistoryAcceptance
        let sampleIdentities: [BandSampleIdentity]
        let expectedSampleCount: Int
    }

    private let diagnostics: BandDiagnosticsRecorder
    private let restoredHistoryCheckpoint: BandHistoryCheckpoint?
    private let sessionNonce = UUID()
    private var state: BandSessionState = .idle
    private var generation: UInt64 = 0
    private var nextConnectionSequence: UInt64 = 0
    private var nextReconnectSequence: UInt64 = 0
    private var nextOperationSequence: UInt64 = 0
    private var nextLiveSequence: UInt64 = 0
    private var nextLiveReceiptSequence: UInt64 = 0
    private var nextHistoryReceiptSequence: UInt64 = 0
    private var activeOperation: BandOperationToken?
    private var activeScanToken: BandScanToken?
    private var activeConnectionToken: BandConnectionToken?
    private var activeReconnectToken: BandReconnectToken?
    private var activeLiveToken: BandLiveToken?
    private var liveActive = false
    private var liveStreams: Set<BandStreamKind> = []
    private var identity: BandIdentity?
    private var capabilityReport: BandCapabilityReport?
    private var pendingLive: PendingLive?
    private var liveReceiptCompleting = false
    private var pendingHistory: PendingHistory?
    private var lastDurableHistoryComplete: Bool?
    private var historyOperationReceivedDurableReceipt = false
    private var historyOperationLastReceiptComplete: Bool?
    private var durableSampleIdentities: Set<BandSampleIdentity> = []
    private var durableSampleIdentityOrder: [BandSampleIdentity] = []
    private var durableSampleIdentityNextEviction = 0
    private var acknowledgedHistoryCursor: String?
    private var durableSourceIdentity: String?
    private var restoredHistoryCheckpointConsumed = false

    public init(
        diagnostics: BandDiagnosticsRecorder = BandDiagnosticsRecorder(),
        historyCheckpoint: BandHistoryCheckpoint? = nil
    ) {
        self.diagnostics = diagnostics
        restoredHistoryCheckpoint = historyCheckpoint
    }

    public func snapshot() -> BandSessionSnapshot {
        BandSessionSnapshot(
            state: state,
            generation: generation,
            activeOperation: activeOperation?.operationClass,
            liveActive: liveActive,
            acknowledgedHistoryCursor: acknowledgedHistoryCursor,
            durableSampleCount: durableSampleIdentities.count
        )
    }

    public func historyCheckpoint() -> BandHistoryCheckpoint? {
        guard let sourceIdentity = durableSourceIdentity
            ?? identity?.sourceIdentity
        else {
            return nil
        }
        return BandHistoryCheckpoint(
            sourceIdentity: sourceIdentity,
            acknowledgedCursor: acknowledgedHistoryCursor,
            lastHistoryComplete: lastDurableHistoryComplete,
            durableSampleIdentities: durableSampleIdentities
        )
    }

    @discardableResult
    public func beginScan() async throws -> BandScanToken {
        try ensureNotClosed()
        guard !hasPendingPersistence else {
            await diagnostics.record(
                BandDiagnosticEvent(
                    kind: .discovery,
                    outcome: .rejected,
                    failureCategory: .busy
                )
            )
            throw BandFailureCategory.busy
        }
        guard state == .idle
            || state == .recovering
            || state == .rejected
        else {
            throw BandFailureCategory.invalidState
        }
        generation &+= 1
        let scanGeneration = generation
        let scanToken = BandScanToken(
            sessionNonce: sessionNonce,
            generation: scanGeneration
        )
        clearOperationTracking()
        clearLiveTracking()
        activeScanToken = scanToken
        activeConnectionToken = nil
        activeReconnectToken = nil
        identity = nil
        capabilityReport = nil
        state = .scanning
        await diagnostics.record(
            BandDiagnosticEvent(kind: .discovery, outcome: .began)
        )
        guard generation == scanGeneration,
              state == .scanning,
              activeScanToken == scanToken
        else {
            await diagnostics.record(
                BandDiagnosticEvent(
                    kind: .discovery,
                    outcome: .stale,
                    failureCategory: .staleCallback
                )
            )
            throw BandFailureCategory.staleCallback
        }
        return scanToken
    }

    public func selectCandidate(
        _ candidate: BandPairingCandidate,
        callbackGeneration: BandScanToken
    ) async throws -> BandConnectionToken {
        try ensureNotClosed()
        try await validateScanToken(
            callbackGeneration,
            diagnosticKind: .discovery
        )
        do {
            try candidate.validate()
        } catch {
            await diagnostics.record(
                BandDiagnosticEvent(
                    kind: .discovery,
                    outcome: .rejected,
                    failureCategory: .invalidInput
                )
            )
            throw BandFailureCategory.invalidInput
        }
        guard state == .scanning,
              candidate.compatible,
              candidate.identifyEligible
        else {
            await diagnostics.record(
                BandDiagnosticEvent(
                    kind: .discovery,
                    outcome: .rejected,
                    failureCategory: .rejected
                )
            )
            throw BandFailureCategory.rejected
        }
        nextConnectionSequence &+= 1
        let token = BandConnectionToken(
            sessionNonce: sessionNonce,
            generation: generation,
            sequence: nextConnectionSequence,
            candidateHandle: candidate.handle
        )
        activeScanToken = nil
        activeConnectionToken = token
        state = .candidateSelected
        await diagnostics.record(
            BandDiagnosticEvent(
                kind: .discovery,
                outcome: .completed,
                countBucket: .one
            )
        )
        guard generation == token.generation,
              state == .candidateSelected,
              activeConnectionToken == token
        else {
            throw BandFailureCategory.staleCallback
        }
        return token
    }

    public func cancelScan(callbackGeneration: BandScanToken) async throws {
        try ensureNotClosed()
        try await validateScanToken(
            callbackGeneration,
            diagnosticKind: .discovery
        )
        guard state == .scanning else {
            await diagnostics.record(
                BandDiagnosticEvent(
                    kind: .discovery,
                    outcome: .rejected,
                    failureCategory: .invalidState
                )
            )
            throw BandFailureCategory.invalidState
        }
        generation &+= 1
        activeScanToken = nil
        activeConnectionToken = nil
        state = .idle
        await diagnostics.record(
            BandDiagnosticEvent(kind: .discovery, outcome: .cancelled)
        )
    }

    public func failScan(
        _ category: BandFailureCategory,
        callbackGeneration: BandScanToken
    ) async throws {
        try ensureNotClosed()
        try await validateScanToken(
            callbackGeneration,
            diagnosticKind: .discovery
        )
        let allowed: Set<BandFailureCategory> = [
            .noResult,
            .timeout,
            .permission,
            .unavailable,
            .internalFailure,
        ]
        guard state == .scanning, allowed.contains(category) else {
            await diagnostics.record(
                BandDiagnosticEvent(
                    kind: .discovery,
                    outcome: .rejected,
                    failureCategory: state == .scanning
                        ? .invalidInput
                        : .invalidState
                )
            )
            throw state == .scanning
                ? BandFailureCategory.invalidInput
                : BandFailureCategory.invalidState
        }
        generation &+= 1
        activeScanToken = nil
        activeConnectionToken = nil
        state = .idle
        await diagnostics.record(
            BandDiagnosticEvent(
                kind: .discovery,
                outcome: category == .timeout ? .timedOut : .failed,
                failureCategory: category
            )
        )
    }

    public func beginConnection(
        token: BandConnectionToken,
        callbackGeneration: UInt64
    ) async throws {
        try ensureNotClosed()
        try await validateConnectionToken(
            token,
            callbackGeneration,
            diagnosticKind: .connection
        )
        guard state == .candidateSelected else {
            await diagnostics.record(
                BandDiagnosticEvent(
                    kind: .connection,
                    outcome: .rejected,
                    failureCategory: .invalidState
                )
            )
            throw BandFailureCategory.invalidState
        }
        state = .connecting
        await diagnostics.record(
            BandDiagnosticEvent(kind: .connection, outcome: .began)
        )
        guard generation == token.generation,
              state == .connecting,
              activeConnectionToken == token
        else {
            await diagnostics.record(
                BandDiagnosticEvent(
                    kind: .connection,
                    outcome: .stale,
                    failureCategory: .staleCallback
                )
            )
            throw BandFailureCategory.staleCallback
        }
    }

    public func beginAuthentication(
        token: BandConnectionToken,
        callbackGeneration: UInt64
    ) async throws {
        try ensureNotClosed()
        try await validateConnectionToken(
            token,
            callbackGeneration,
            diagnosticKind: .authentication
        )
        guard state == .connecting else {
            await diagnostics.record(
                BandDiagnosticEvent(
                    kind: .authentication,
                    outcome: .rejected,
                    failureCategory: .invalidState
                )
            )
            throw BandFailureCategory.invalidState
        }
        state = .authenticating
        await diagnostics.record(
            [
                BandDiagnosticEvent(
                    kind: .connection,
                    outcome: .completed
                ),
                BandDiagnosticEvent(
                    kind: .authentication,
                    outcome: .began
                ),
            ]
        )
        guard generation == token.generation,
              state == .authenticating,
              activeConnectionToken == token
        else {
            await diagnostics.record(
                BandDiagnosticEvent(
                    kind: .authentication,
                    outcome: .stale,
                    failureCategory: .staleCallback
                )
            )
            throw BandFailureCategory.staleCallback
        }
    }

    public func completeConnection(
        _ newIdentity: BandIdentity,
        token: BandConnectionToken,
        callbackGeneration: UInt64
    ) async throws {
        try ensureNotClosed()
        try await validateConnectionToken(
            token,
            callbackGeneration,
            diagnosticKind: .authentication
        )
        guard state == .authenticating else {
            await diagnostics.record(
                BandDiagnosticEvent(
                    kind: .authentication,
                    outcome: .rejected,
                    failureCategory: .invalidState
                )
            )
            throw BandFailureCategory.invalidState
        }
        do {
            try newIdentity.validate()
        } catch {
            await diagnostics.record(
                BandDiagnosticEvent(
                    kind: .authentication,
                    outcome: .rejected,
                    failureCategory: .invalidInput
                )
            )
            throw BandFailureCategory.invalidInput
        }
        if !restoredHistoryCheckpointConsumed,
           let restoredHistoryCheckpoint,
           restoredHistoryCheckpoint.sourceIdentity.hasIdenticalUTF8(
               to: newIdentity.sourceIdentity
           )
        {
            do {
                try restoredHistoryCheckpoint.validate()
            } catch {
                await diagnostics.record(
                    BandDiagnosticEvent(
                        kind: .history,
                        outcome: .rejected,
                        failureCategory: .invalidInput
                    )
                )
                throw BandFailureCategory.invalidInput
            }
            restoreDurableSampleIdentities(
                restoredHistoryCheckpoint.durableSampleIdentities
            )
            acknowledgedHistoryCursor =
                restoredHistoryCheckpoint.acknowledgedCursor
            lastDurableHistoryComplete =
                restoredHistoryCheckpoint.lastHistoryComplete
            durableSourceIdentity = newIdentity.sourceIdentity
            restoredHistoryCheckpointConsumed = true
        } else if !optionalStringsHaveIdenticalUTF8(
            durableSourceIdentity,
            newIdentity.sourceIdentity
        ) {
            clearDurableSampleIdentities()
            acknowledgedHistoryCursor = nil
            lastDurableHistoryComplete = nil
            durableSourceIdentity = newIdentity.sourceIdentity
        }
        capabilityReport = nil
        identity = newIdentity
        state = .negotiatingCapabilities
        await diagnostics.record(
            BandDiagnosticEvent(kind: .authentication, outcome: .completed)
        )
        let authenticationProgressRemainsCurrent =
            state == .negotiatingCapabilities || capabilityReport != nil
        guard generation == token.generation,
              activeConnectionToken == token,
              identity == newIdentity,
              authenticationProgressRemainsCurrent
        else {
            await diagnostics.record(
                BandDiagnosticEvent(
                    kind: .authentication,
                    outcome: .stale,
                    failureCategory: .staleCallback
                )
            )
            throw BandFailureCategory.staleCallback
        }
    }

    public func cancelConnection(
        token: BandConnectionToken,
        phase: BandConnectionPhase,
        callbackGeneration: UInt64
    ) async throws {
        try ensureNotClosed()
        let diagnosticKind = diagnosticKind(for: phase)
        try await validateConnectionToken(
            token,
            callbackGeneration,
            diagnosticKind: diagnosticKind
        )
        guard state == sessionState(for: phase) else {
            await diagnostics.record(
                BandDiagnosticEvent(
                    kind: diagnosticKind,
                    outcome: .rejected,
                    failureCategory: .invalidState
                )
            )
            throw BandFailureCategory.invalidState
        }
        clearConnectionAttempt(nextState: .idle)
        await diagnostics.record(
            BandDiagnosticEvent(kind: diagnosticKind, outcome: .cancelled)
        )
    }

    public func failConnection(
        _ category: BandFailureCategory,
        token: BandConnectionToken,
        phase: BandConnectionPhase,
        callbackGeneration: UInt64
    ) async throws {
        try ensureNotClosed()
        let diagnosticKind = diagnosticKind(for: phase)
        try await validateConnectionToken(
            token,
            callbackGeneration,
            diagnosticKind: diagnosticKind
        )
        guard state == sessionState(for: phase) else {
            await diagnostics.record(
                BandDiagnosticEvent(
                    kind: diagnosticKind,
                    outcome: .rejected,
                    failureCategory: .invalidState
                )
            )
            throw BandFailureCategory.invalidState
        }
        let allowed: Set<BandFailureCategory> = [
            .unavailable,
            .permission,
            .timeout,
            .rejected,
            .authentication,
            .securityFailure,
            .disconnected,
            .internalFailure,
        ]
        guard allowed.contains(category) else {
            await diagnostics.record(
                BandDiagnosticEvent(
                    kind: diagnosticKind,
                    outcome: .rejected,
                    failureCategory: .invalidInput
                )
            )
            throw BandFailureCategory.invalidInput
        }

        let terminalState: BandSessionState
        switch category {
        case .rejected, .authentication:
            terminalState = .rejected
        case .securityFailure:
            terminalState = .securityFailure
        default:
            terminalState = .recovering
        }
        clearConnectionAttempt(nextState: terminalState)
        let outcome: BandDiagnosticOutcome
        switch category {
        case .timeout:
            outcome = .timedOut
        case .rejected, .authentication, .securityFailure:
            outcome = .rejected
        default:
            outcome = .failed
        }
        await diagnostics.record(
            BandDiagnosticEvent(
                kind: diagnosticKind,
                outcome: outcome,
                failureCategory: category
            )
        )
    }

    public func acceptCapabilities(
        _ report: BandCapabilityReport,
        token: BandConnectionToken,
        callbackGeneration: UInt64
    ) async throws {
        try ensureNotClosed()
        try await validateConnectionToken(
            token,
            callbackGeneration,
            diagnosticKind: .capability
        )
        do {
            try report.validate()
        } catch {
            if state == .negotiatingCapabilities {
                state = .incompatible
                capabilityReport = nil
                await diagnostics.record(
                    BandDiagnosticEvent(
                        kind: .capability,
                        outcome: .rejected,
                        failureCategory: .incompatible
                    )
                )
                throw BandFailureCategory.incompatible
            }
            await diagnostics.record(
                BandDiagnosticEvent(
                    kind: .capability,
                    outcome: .rejected,
                    failureCategory: .invalidInput
                )
            )
            throw BandFailureCategory.invalidInput
        }
        if state != .negotiatingCapabilities {
            if capabilityReport == report {
                await diagnostics.record(
                    BandDiagnosticEvent(kind: .capability, outcome: .stale)
                )
                return
            }
            await diagnostics.record(
                BandDiagnosticEvent(
                    kind: .capability,
                    outcome: .rejected,
                    failureCategory: .invalidState
                )
            )
            throw BandFailureCategory.invalidState
        }
        guard state == .negotiatingCapabilities,
              let identity,
              identity.hardwareRevision.hasIdenticalUTF8(
                  to: report.hardwareRevision
              ),
              identity.firmwareVersion.hasIdenticalUTF8(
                  to: report.firmwareVersion
              ),
              identity.protocolVersion.hasIdenticalUTF8(
                  to: report.protocolVersion
              )
        else {
            state = .incompatible
            capabilityReport = nil
            await diagnostics.record(
                BandDiagnosticEvent(
                    kind: .capability,
                    outcome: .rejected,
                    failureCategory: .incompatible
                )
            )
            throw BandFailureCategory.incompatible
        }

        capabilityReport = report
        state = .ready
        await diagnostics.record(
            BandDiagnosticEvent(
                kind: .capability,
                outcome: .completed,
                countBucket: BandCountBucket(count: report.capabilities.count)
            )
        )
        let capabilityProgressRemainsCurrent =
            state == .ready || state == .liveCollecting
                || activeOperation != nil
        guard generation == token.generation,
              activeConnectionToken == token,
              self.identity == identity,
              capabilityReport == report,
              capabilityProgressRemainsCurrent
        else {
            await diagnostics.record(
                BandDiagnosticEvent(
                    kind: .capability,
                    outcome: .stale,
                    failureCategory: .staleCallback
                )
            )
            throw BandFailureCategory.staleCallback
        }
    }

    public func cancelCapabilities(
        token: BandConnectionToken,
        callbackGeneration: UInt64
    ) async throws {
        try ensureNotClosed()
        try await validateConnectionToken(
            token,
            callbackGeneration,
            diagnosticKind: .capability
        )
        guard state == .negotiatingCapabilities else {
            await diagnostics.record(
                BandDiagnosticEvent(
                    kind: .capability,
                    outcome: .rejected,
                    failureCategory: .invalidState
                )
            )
            throw BandFailureCategory.invalidState
        }
        invalidateAuthenticatedSession(nextState: .idle)
        await diagnostics.record(
            BandDiagnosticEvent(kind: .capability, outcome: .cancelled)
        )
    }

    public func failCapabilities(
        _ category: BandFailureCategory,
        token: BandConnectionToken,
        callbackGeneration: UInt64
    ) async throws {
        try ensureNotClosed()
        try await validateConnectionToken(
            token,
            callbackGeneration,
            diagnosticKind: .capability
        )
        guard state == .negotiatingCapabilities else {
            await diagnostics.record(
                BandDiagnosticEvent(
                    kind: .capability,
                    outcome: .rejected,
                    failureCategory: .invalidState
                )
            )
            throw BandFailureCategory.invalidState
        }
        let allowed: Set<BandFailureCategory> = [
            .unavailable,
            .timeout,
            .authentication,
            .securityFailure,
            .disconnected,
            .internalFailure,
        ]
        guard allowed.contains(category) else {
            await diagnostics.record(
                BandDiagnosticEvent(
                    kind: .capability,
                    outcome: .rejected,
                    failureCategory: .invalidInput
                )
            )
            throw BandFailureCategory.invalidInput
        }

        let terminalState: BandSessionState
        switch category {
        case .authentication:
            terminalState = .rejected
        case .securityFailure:
            terminalState = .securityFailure
        default:
            terminalState = .recovering
        }
        invalidateAuthenticatedSession(nextState: terminalState)

        let outcome: BandDiagnosticOutcome
        switch category {
        case .timeout:
            outcome = .timedOut
        case .authentication, .securityFailure:
            outcome = .rejected
        default:
            outcome = .failed
        }
        await diagnostics.record(
            BandDiagnosticEvent(
                kind: .capability,
                outcome: outcome,
                failureCategory: category
            )
        )
    }

    public func failEstablishedSession(
        _ category: BandFailureCategory,
        token: BandConnectionToken,
        callbackGeneration: UInt64
    ) async throws {
        try ensureNotClosed()
        try await validateConnectionToken(
            token,
            callbackGeneration,
            diagnosticKind: .authentication
        )
        guard !hasPendingPersistence else {
            await diagnostics.record(
                BandDiagnosticEvent(
                    kind: .authentication,
                    outcome: .rejected,
                    failureCategory: .busy
                )
            )
            throw BandFailureCategory.busy
        }
        guard state == .ready || state == .liveCollecting else {
            await diagnostics.record(
                BandDiagnosticEvent(
                    kind: .authentication,
                    outcome: .rejected,
                    failureCategory: .invalidState
                )
            )
            throw BandFailureCategory.invalidState
        }
        guard category == .authentication || category == .securityFailure else {
            await diagnostics.record(
                BandDiagnosticEvent(
                    kind: .authentication,
                    outcome: .rejected,
                    failureCategory: .invalidInput
                )
            )
            throw BandFailureCategory.invalidInput
        }

        let liveWasActive = liveActive
        invalidateAuthenticatedSession(
            nextState: category == .securityFailure
                ? .securityFailure
                : .rejected
        )
        await diagnostics.record(
            (liveWasActive
                ? [
                    BandDiagnosticEvent(
                        kind: .live,
                        outcome: .interrupted,
                        failureCategory: category
                    ),
                    BandDiagnosticEvent(
                        kind: .authentication,
                        outcome: .rejected,
                        failureCategory: category
                    ),
                ]
                : [
                    BandDiagnosticEvent(
                        kind: .authentication,
                        outcome: .rejected,
                        failureCategory: category
                    ),
                ])
        )
    }

    public func beginLive(
        streams requestedStreams: Set<BandStreamKind>? = nil
    ) async throws -> BandLiveToken {
        do {
            try ensureReadyForOperation()
        } catch let failure as BandFailureCategory {
            await diagnostics.record(
                BandDiagnosticEvent(
                    kind: .live,
                    outcome: .rejected,
                    failureCategory: failure
                )
            )
            throw failure
        }
        guard !liveActive else {
            await diagnostics.record(
                BandDiagnosticEvent(
                    kind: .live,
                    outcome: .rejected,
                    failureCategory: .busy
                )
            )
            throw BandFailureCategory.busy
        }
        let negotiatedStreams = capabilityReport?.liveStreams ?? []
        let selectedStreams = requestedStreams ?? negotiatedStreams
        guard !selectedStreams.isEmpty,
              selectedStreams.isSubset(of: negotiatedStreams)
        else {
            await diagnostics.record(
                BandDiagnosticEvent(
                    kind: .live,
                    outcome: .rejected,
                    failureCategory: .unsupported
                )
            )
            throw BandFailureCategory.unsupported
        }
        nextLiveSequence &+= 1
        let token = BandLiveToken(
            sessionNonce: sessionNonce,
            generation: generation,
            sequence: nextLiveSequence
        )
        activeLiveToken = token
        liveStreams = selectedStreams
        liveActive = true
        state = .liveCollecting
        await diagnostics.record(
            BandDiagnosticEvent(kind: .live, outcome: .began)
        )
        let liveStateIsCurrent =
            state == .liveCollecting || activeOperation != nil
        guard generation == token.generation,
              activeLiveToken == token,
              liveActive,
              liveStreams == selectedStreams,
              liveStateIsCurrent
        else {
            await diagnostics.record(
                BandDiagnosticEvent(
                    kind: .live,
                    outcome: .stale,
                    failureCategory: .staleCallback
                )
            )
            throw BandFailureCategory.staleCallback
        }
        return token
    }

    public func stopLive(token: BandLiveToken) async throws {
        try ensureNotClosed()
        try await validateLiveToken(token)
        guard liveActive else {
            await diagnostics.record(
                BandDiagnosticEvent(
                    kind: .live,
                    outcome: .rejected,
                    failureCategory: .invalidState
                )
            )
            throw BandFailureCategory.invalidState
        }
        guard state == .liveCollecting else {
            await diagnostics.record(
                BandDiagnosticEvent(
                    kind: .live,
                    outcome: .rejected,
                    failureCategory: .invalidState
                )
            )
            throw BandFailureCategory.invalidState
        }
        guard pendingLive == nil else {
            await diagnostics.record(
                BandDiagnosticEvent(
                    kind: .live,
                    outcome: .rejected,
                    failureCategory: .storage
                )
            )
            throw BandFailureCategory.storage
        }
        guard activeOperation == nil else {
            await diagnostics.record(
                BandDiagnosticEvent(
                    kind: .live,
                    outcome: .rejected,
                    failureCategory: .invalidState
                )
            )
            throw BandFailureCategory.invalidState
        }
        clearLiveTracking()
        state = .ready
        await diagnostics.record(
            BandDiagnosticEvent(kind: .live, outcome: .completed)
        )
    }

    public func stageLiveBatch(
        _ batch: BandSampleBatch,
        token: BandLiveToken,
        callbackGeneration: UInt64
    ) async throws -> LiveAcceptance {
        try await validateCallbackGeneration(
            callbackGeneration,
            diagnosticKind: .live
        )
        guard liveActive,
              state == .liveCollecting || activeOperation != nil
        else {
            await diagnostics.record(
                BandDiagnosticEvent(
                    kind: .live,
                    outcome: .rejected,
                    failureCategory: .invalidState
                )
            )
            throw BandFailureCategory.invalidState
        }
        try await validateLiveToken(token)
        guard let sourceIdentity = identity?.sourceIdentity,
              batch.sourceIdentity.hasIdenticalUTF8(to: sourceIdentity)
        else {
            await diagnostics.record(
                BandDiagnosticEvent(
                    kind: .live,
                    outcome: .rejected,
                    failureCategory: .invalidInput
                )
            )
            throw BandFailureCategory.invalidInput
        }
        guard pendingLive == nil, pendingHistory == nil else {
            await diagnostics.record(
                BandDiagnosticEvent(
                    kind: .live,
                    outcome: .rejected,
                    failureCategory: .busy
                )
            )
            throw BandFailureCategory.busy
        }
        do {
            try batch.validate(expectedLane: .live)
        } catch {
            await diagnostics.record(
                BandDiagnosticEvent(
                    kind: .live,
                    outcome: .rejected,
                    failureCategory: .invalidInput
                )
            )
            throw BandFailureCategory.invalidInput
        }
        try await validateNegotiatedBatch(
            batch,
            diagnosticKind: .live,
            allowedStreams: liveStreams
        )
        guard let capabilityReport else {
            throw BandFailureCategory.invalidState
        }
        var acceptedIdentities: Set<BandSampleIdentity> = []
        let unique = batch.samples.filter { sample in
            !durableSampleIdentities.contains(sample.identity)
                && acceptedIdentities.insert(sample.identity).inserted
        }
        nextLiveReceiptSequence &+= 1
        let acceptance = LiveAcceptance(
            acceptedSamples: unique,
            duplicateSamples: batch.samples.count - unique.count,
            capabilityReportRevision: capabilityReport.reportRevision,
            parserRevision: batch.parserRevision,
            calibrationRevision: batch.calibrationRevision,
            sessionNonce: sessionNonce,
            generation: generation,
            receiptSequence: nextLiveReceiptSequence
        )
        pendingLive = PendingLive(
            acceptance: acceptance,
            sampleIdentities: unique.map(\.identity),
            expectedSampleCount: unique.count
        )
        await diagnostics.recordCoalescingLatest(
            BandDiagnosticEvent(
                kind: .live,
                outcome: .staged,
                countBucket: BandCountBucket(count: unique.count)
            )
        )
        guard generation == acceptance.generation,
              activeLiveToken == token,
              pendingLive?.acceptance.receiptSequence
                == acceptance.receiptSequence
        else {
            await diagnostics.record(
                BandDiagnosticEvent(
                    kind: .live,
                    outcome: .stale,
                    failureCategory: .staleCallback
                )
            )
            throw BandFailureCategory.staleCallback
        }
        return acceptance
    }

    public func acknowledgeLive(
        receipt: DurableLiveReceipt,
        callbackGeneration: UInt64
    ) async throws {
        try await validateCallbackGeneration(
            callbackGeneration,
            diagnosticKind: .live
        )
        try await validateSessionNonce(
            receipt.sessionNonce,
            diagnosticKind: .live
        )
        guard let pendingLive,
              !liveReceiptCompleting,
              receipt.generation == pendingLive.acceptance.generation,
              receipt.receiptSequence
                == pendingLive.acceptance.receiptSequence
        else {
            await diagnostics.record(
                BandDiagnosticEvent(
                    kind: .live,
                    outcome: .failed,
                    failureCategory: .storage
                )
            )
            throw BandFailureCategory.storage
        }
        guard receipt.committed,
              receipt.committedSamples
                >= pendingLive.expectedSampleCount
        else {
            self.pendingLive = nil
            await diagnostics.record(
                BandDiagnosticEvent(
                    kind: .live,
                    outcome: .failed,
                    failureCategory: .storage
                )
            )
            throw BandFailureCategory.storage
        }
        rememberDurableSampleIdentities(pendingLive.sampleIdentities)
        liveReceiptCompleting = true
        await diagnostics.recordCoalescingConsecutive(
            BandDiagnosticEvent(
                kind: .live,
                outcome: .completed,
                countBucket: BandCountBucket(
                    count: receipt.committedSamples
                )
            )
        )
        self.pendingLive = nil
        liveReceiptCompleting = false
    }

    public func beginOperation(
        _ operationClass: BandOperationClass,
        requiredCapability: BandCapability? = nil
    ) async throws -> BandOperationToken {
        let operationDiagnosticKind = diagnosticKind(for: operationClass)
        do {
            try ensureNotClosed()
        } catch let failure as BandFailureCategory {
            await diagnostics.record(
                BandDiagnosticEvent(
                    kind: operationDiagnosticKind,
                    outcome: .rejected,
                    failureCategory: failure,
                    operationClass: operationClass
                )
            )
            throw failure
        }
        guard activeOperation == nil else {
            await diagnostics.record(
                BandDiagnosticEvent(
                    kind: operationDiagnosticKind,
                    outcome: .rejected,
                    failureCategory: .busy,
                    operationClass: operationClass
                )
            )
            throw BandFailureCategory.busy
        }
        do {
            try ensureReadyForOperation()
        } catch let failure as BandFailureCategory {
            await diagnostics.record(
                BandDiagnosticEvent(
                    kind: operationDiagnosticKind,
                    outcome: .rejected,
                    failureCategory: failure,
                    operationClass: operationClass
                )
            )
            throw failure
        }
        if liveActive,
           capabilityReport?.operationsAllowedDuringLive.contains(
               operationClass
           ) != true
        {
            await diagnostics.record(
                BandDiagnosticEvent(
                    kind: operationDiagnosticKind,
                    outcome: .rejected,
                    failureCategory: .busy,
                    operationClass: operationClass
                )
            )
            throw BandFailureCategory.busy
        }
        if operationClass == .firmware, liveActive {
            await diagnostics.record(
                BandDiagnosticEvent(
                    kind: operationDiagnosticKind,
                    outcome: .rejected,
                    failureCategory: .busy,
                    operationClass: operationClass
                )
            )
            throw BandFailureCategory.busy
        }
        if operationClass == .firmware,
           capabilityReport?.capabilities.contains(.firmwareUpdate) != true
        {
            await diagnostics.record(
                BandDiagnosticEvent(
                    kind: operationDiagnosticKind,
                    outcome: .rejected,
                    failureCategory: .updateNotEligible,
                    operationClass: operationClass
                )
            )
            throw BandFailureCategory.updateNotEligible
        }
        if operationClass == .sampling {
            let negotiated = capabilityReport?.capabilities ?? []
            let eligible = if let requiredCapability {
                samplingCapabilities.contains(requiredCapability)
                    && negotiated.contains(requiredCapability)
            } else {
                !samplingCapabilities.isDisjoint(with: negotiated)
            }
            guard eligible else {
                await diagnostics.record(
                    BandDiagnosticEvent(
                        kind: operationDiagnosticKind,
                        outcome: .rejected,
                        failureCategory: .unsupported,
                        operationClass: operationClass
                    )
                )
                throw BandFailureCategory.unsupported
            }
        } else if operationClass == .history,
                  (capabilityReport?.historyDays ?? 0) <= 0
                    || (capabilityReport?.historyStreams.isEmpty ?? true)
        {
            await diagnostics.record(
                BandDiagnosticEvent(
                    kind: operationDiagnosticKind,
                    outcome: .rejected,
                    failureCategory: .unsupported,
                    operationClass: operationClass
                )
            )
            throw BandFailureCategory.unsupported
        } else {
            let capabilities = [
                impliedCapability(for: operationClass),
                requiredCapability,
            ].compactMap { $0 }
            for capability in capabilities {
                guard capabilityReport?.capabilities.contains(capability) == true
                else {
                    await diagnostics.record(
                        BandDiagnosticEvent(
                            kind: operationDiagnosticKind,
                            outcome: .rejected,
                            failureCategory: .unsupported,
                            operationClass: operationClass
                        )
                    )
                    throw BandFailureCategory.unsupported
                }
            }
        }

        nextOperationSequence &+= 1
        let token = BandOperationToken(
            sessionNonce: sessionNonce,
            generation: generation,
            sequence: nextOperationSequence,
            operationClass: operationClass
        )
        activeOperation = token
        switch operationClass {
        case .history:
            historyOperationReceivedDurableReceipt = false
            historyOperationLastReceiptComplete = nil
            state = .historyCollecting
        case .firmware:
            state = .updatingFirmware
        default:
            state = .executingCommand
        }
        await diagnostics.record(
            BandDiagnosticEvent(
                kind: operationDiagnosticKind,
                outcome: .began,
                operationClass: operationClass
            )
        )
        guard generation == token.generation,
              activeOperation == token
        else {
            await diagnostics.record(
                BandDiagnosticEvent(
                    kind: operationDiagnosticKind,
                    outcome: .stale,
                    failureCategory: .staleCallback,
                    operationClass: operationClass
                )
            )
            throw BandFailureCategory.staleCallback
        }
        return token
    }

    public func stageHistoryChunk(
        _ chunk: BandHistoryChunk,
        token: BandOperationToken,
        callbackGeneration: UInt64
    ) async throws -> HistoryAcceptance {
        try await validateCallbackGeneration(
            callbackGeneration,
            diagnosticKind: .history
        )
        do {
            try validateActiveToken(token, expected: .history)
        } catch let failure as BandFailureCategory {
            await diagnostics.record(
                BandDiagnosticEvent(
                    kind: .history,
                    outcome: .rejected,
                    failureCategory: failure
                )
            )
            throw failure
        }
        guard pendingHistory == nil, pendingLive == nil else {
            await diagnostics.record(
                BandDiagnosticEvent(
                    kind: .history,
                    outcome: .rejected,
                    failureCategory: .busy
                )
            )
            throw BandFailureCategory.busy
        }
        guard historyOperationLastReceiptComplete != true else {
            await diagnostics.record(
                BandDiagnosticEvent(
                    kind: .history,
                    outcome: .rejected,
                    failureCategory: .invalidState
                )
            )
            throw BandFailureCategory.invalidState
        }
        do {
            try chunk.validate()
        } catch {
            await diagnostics.record(
                BandDiagnosticEvent(
                    kind: .history,
                    outcome: .rejected,
                    failureCategory: .invalidInput
                )
            )
            throw BandFailureCategory.invalidInput
        }
        for batch in chunk.batches {
            try await validateNegotiatedBatch(
                batch,
                diagnosticKind: .history,
                allowedStreams: capabilityReport?.historyStreams ?? []
            )
        }
        guard let capabilityReport else {
            throw BandFailureCategory.invalidState
        }
        guard optionalStringsHaveIdenticalUTF8(
            chunk.previousCursor,
            acknowledgedHistoryCursor
        ) else {
            await diagnostics.record(
                BandDiagnosticEvent(
                    kind: .history,
                    outcome: .rejected,
                    failureCategory: .historyStalled
                )
            )
            throw BandFailureCategory.historyStalled
        }
        guard chunk.complete
            || (chunk.nextCursor != nil
                && !optionalStringsHaveIdenticalUTF8(
                    chunk.nextCursor,
                    chunk.previousCursor
                ))
        else {
            await diagnostics.record(
                BandDiagnosticEvent(
                    kind: .history,
                    outcome: .rejected,
                    failureCategory: .historyStalled
                )
            )
            throw BandFailureCategory.historyStalled
        }
        guard let sourceIdentity = identity?.sourceIdentity,
              chunk.batches.allSatisfy({
                  $0.sourceIdentity.hasIdenticalUTF8(to: sourceIdentity)
              })
        else {
            await diagnostics.record(
                BandDiagnosticEvent(
                    kind: .history,
                    outcome: .rejected,
                    failureCategory: .invalidInput
                )
            )
            throw BandFailureCategory.invalidInput
        }

        var uniqueSet: Set<BandSampleIdentity> = []
        var unique: [AcceptedHistorySample] = []
        var duplicateCount = 0
        for batch in chunk.batches {
            for sample in batch.samples {
                if durableSampleIdentities.contains(sample.identity)
                    || !uniqueSet.insert(sample.identity).inserted
                {
                    duplicateCount += 1
                } else {
                    unique.append(
                        AcceptedHistorySample(
                            batch: batch,
                            capabilityReportRevision:
                                capabilityReport.reportRevision,
                            sample: sample
                        )
                    )
                }
            }
        }
        nextHistoryReceiptSequence &+= 1
        let effectiveNextCursor =
            chunk.nextCursor ?? (chunk.complete ? chunk.previousCursor : nil)
        let acceptance = HistoryAcceptance(
            chunkIdentity: chunk.chunkIdentity,
            acknowledgementToken: chunk.acknowledgementToken,
            nextCursor: effectiveNextCursor,
            complete: chunk.complete,
            overflowed: chunk.overflowed,
            retainedRange: chunk.retainedRange,
            firstLostRange: chunk.firstLostRange,
            acceptedSamples: unique,
            duplicateSamples: duplicateCount,
            sessionNonce: sessionNonce,
            receiptSequence: nextHistoryReceiptSequence
        )
        pendingHistory = PendingHistory(
            acceptance: acceptance,
            sampleIdentities: unique.map(\.sample.identity),
            expectedSampleCount: unique.count
        )
        await diagnostics.record(
            BandDiagnosticEvent(
                kind: .history,
                outcome: .staged,
                countBucket: BandCountBucket(count: unique.count)
            )
        )
        return acceptance
    }

    public func acknowledgeHistory(
        receipt: DurableHistoryReceipt,
        token: BandOperationToken,
        callbackGeneration: UInt64
    ) async throws {
        try await validateCallbackGeneration(
            callbackGeneration,
            diagnosticKind: .history
        )
        try await validateSessionNonce(
            receipt.sessionNonce,
            diagnosticKind: .history
        )
        do {
            try validateActiveToken(token, expected: .history)
        } catch let failure as BandFailureCategory {
            await diagnostics.record(
                BandDiagnosticEvent(
                    kind: .history,
                    outcome: .rejected,
                    failureCategory: failure
                )
            )
            throw failure
        }
        guard let pendingHistory,
              receipt.receiptSequence
                == pendingHistory.acceptance.receiptSequence,
              receipt.chunkIdentity.hasIdenticalUTF8(
                  to: pendingHistory.acceptance.chunkIdentity
              ),
              receipt.acknowledgementToken.hasIdenticalUTF8(
                  to: pendingHistory.acceptance.acknowledgementToken
              ),
              optionalStringsHaveIdenticalUTF8(
                  receipt.nextCursor,
                  pendingHistory.acceptance.nextCursor
              ),
              receipt.complete == pendingHistory.acceptance.complete,
              receipt.overflowed == pendingHistory.acceptance.overflowed,
              receipt.retainedRange
                == pendingHistory.acceptance.retainedRange,
              receipt.firstLostRange
                == pendingHistory.acceptance.firstLostRange
        else {
            await diagnostics.record(
                BandDiagnosticEvent(
                    kind: .history,
                    outcome: .failed,
                    failureCategory: .storage
                )
            )
            throw BandFailureCategory.storage
        }
        guard receipt.committed,
              receipt.historyStateCommitted,
              receipt.committedSamples
                >= pendingHistory.expectedSampleCount
        else {
            self.pendingHistory = nil
            await diagnostics.record(
                BandDiagnosticEvent(
                    kind: .history,
                    outcome: .failed,
                    failureCategory: .storage
                )
            )
            throw BandFailureCategory.storage
        }

        rememberDurableSampleIdentities(pendingHistory.sampleIdentities)
        acknowledgedHistoryCursor = receipt.nextCursor
        lastDurableHistoryComplete = pendingHistory.acceptance.complete
        historyOperationReceivedDurableReceipt = true
        historyOperationLastReceiptComplete = pendingHistory.acceptance.complete
        self.pendingHistory = nil
        await diagnostics.record(
            BandDiagnosticEvent(
                kind: .history,
                outcome: .completed,
                countBucket: BandCountBucket(count: receipt.committedSamples)
            )
        )
    }

    public func completeOperation(_ token: BandOperationToken) async throws {
        let operationDiagnosticKind = diagnosticKind(for: token.operationClass)
        do {
            try validateActiveToken(token, expected: token.operationClass)
        } catch let failure as BandFailureCategory {
            await diagnostics.record(
                BandDiagnosticEvent(
                    kind: operationDiagnosticKind,
                    outcome: .rejected,
                    failureCategory: failure,
                    operationClass: token.operationClass
                )
            )
            throw failure
        }
        if token.operationClass == .history, pendingHistory != nil {
            await diagnostics.record(
                BandDiagnosticEvent(
                    kind: operationDiagnosticKind,
                    outcome: .failed,
                    failureCategory: .storage,
                    operationClass: token.operationClass
                )
            )
            throw BandFailureCategory.storage
        }
        if token.operationClass == .history,
           !historyOperationReceivedDurableReceipt
        {
            await diagnostics.record(
                BandDiagnosticEvent(
                    kind: operationDiagnosticKind,
                    outcome: .failed,
                    failureCategory: .storage,
                    operationClass: token.operationClass
                )
            )
            throw BandFailureCategory.storage
        }
        if token.operationClass == .history,
           historyOperationLastReceiptComplete != true
        {
            await diagnostics.record(
                BandDiagnosticEvent(
                    kind: operationDiagnosticKind,
                    outcome: .failed,
                    failureCategory: .historyStalled,
                    operationClass: token.operationClass
                )
            )
            throw BandFailureCategory.historyStalled
        }
        if token.operationClass == .firmware {
            invalidateNegotiationAfterFirmware()
        } else {
            clearActiveOperation()
        }
        await diagnostics.record(
            BandDiagnosticEvent(
                kind: operationDiagnosticKind,
                outcome: .completed,
                operationClass: token.operationClass
            )
        )
    }

    public func cancelOperation(_ token: BandOperationToken) async throws {
        let operationDiagnosticKind = diagnosticKind(for: token.operationClass)
        do {
            try validateActiveToken(token, expected: token.operationClass)
        } catch let failure as BandFailureCategory {
            await diagnostics.record(
                BandDiagnosticEvent(
                    kind: operationDiagnosticKind,
                    outcome: .rejected,
                    failureCategory: failure,
                    operationClass: token.operationClass
                )
            )
            throw failure
        }
        if token.operationClass == .history, pendingHistory != nil {
            await diagnostics.record(
                BandDiagnosticEvent(
                    kind: operationDiagnosticKind,
                    outcome: .rejected,
                    failureCategory: .busy,
                    operationClass: token.operationClass
                )
            )
            throw BandFailureCategory.busy
        }
        if token.operationClass == .firmware {
            invalidateNegotiationAfterFirmware()
        } else {
            clearActiveOperation()
        }
        await diagnostics.record(
            BandDiagnosticEvent(
                kind: operationDiagnosticKind,
                outcome: .cancelled,
                operationClass: token.operationClass
            )
        )
    }

    @discardableResult
    public func failOperation(
        _ token: BandOperationToken,
        category: BandFailureCategory,
        firmwareDisposition: BandFirmwareFailureDisposition = .recoverable
    ) async throws -> BandReconnectToken? {
        let operationDiagnosticKind = diagnosticKind(for: token.operationClass)
        do {
            try validateActiveToken(token, expected: token.operationClass)
        } catch let failure as BandFailureCategory {
            await diagnostics.record(
                BandDiagnosticEvent(
                    kind: operationDiagnosticKind,
                    outcome: .rejected,
                    failureCategory: failure,
                    operationClass: token.operationClass
                )
            )
            throw failure
        }
        guard token.operationClass == .firmware
                || firmwareDisposition == .recoverable
        else {
            await diagnostics.record(
                BandDiagnosticEvent(
                    kind: operationDiagnosticKind,
                    outcome: .rejected,
                    failureCategory: .invalidInput,
                    operationClass: token.operationClass
                )
            )
            throw BandFailureCategory.invalidInput
        }
        let terminalFirmwareFailure =
            token.operationClass == .firmware
            && firmwareDisposition == .terminal
        let invalidatesSession =
            category == .securityFailure
            || category == .authentication
            || category == .disconnected
            || terminalFirmwareFailure
        if (token.operationClass == .history && pendingHistory != nil)
            || (invalidatesSession && hasPendingPersistence)
        {
            await diagnostics.record(
                BandDiagnosticEvent(
                    kind: operationDiagnosticKind,
                    outcome: .rejected,
                    failureCategory: .busy,
                    operationClass: token.operationClass
                )
            )
            throw BandFailureCategory.busy
        }
        if category == .securityFailure {
            invalidateAuthenticatedSession(nextState: .securityFailure)
        } else if terminalFirmwareFailure {
            invalidateAuthenticatedSession(nextState: .firmwareFailure)
        } else if category == .authentication {
            invalidateAuthenticatedSession(nextState: .rejected)
        } else if token.operationClass == .firmware,
                  category == .disconnected
        {
            invalidateNegotiationAfterFirmware()
            let recoveryGeneration = generation
            await diagnostics.record([
                BandDiagnosticEvent(
                    kind: .firmware,
                    outcome: .interrupted,
                    failureCategory: .disconnected,
                    operationClass: .firmware
                ),
                BandDiagnosticEvent(
                    kind: .reconnect,
                    outcome: .interrupted,
                    failureCategory: .disconnected
                ),
            ])
            guard state == .recovering,
                  generation == recoveryGeneration
            else {
                await diagnostics.record(
                    BandDiagnosticEvent(
                        kind: .firmware,
                        outcome: .stale,
                        failureCategory: .staleCallback,
                        operationClass: .firmware
                    )
                )
                throw BandFailureCategory.staleCallback
            }
            return nil
        } else if token.operationClass == .firmware {
            invalidateNegotiationAfterFirmware()
        } else if category == .disconnected {
            nextReconnectSequence &+= 1
            generation &+= 1
            let reconnectToken = BandReconnectToken(
                sessionNonce: sessionNonce,
                generation: generation,
                sequence: nextReconnectSequence
            )
            activeReconnectToken = reconnectToken
            state = .recovering
            var interruptionEvents: [BandDiagnosticEvent] = [
                BandDiagnosticEvent(
                    kind: operationDiagnosticKind,
                    outcome: .failed,
                    failureCategory: category,
                    operationClass: token.operationClass
                ),
            ]
            if liveActive {
                interruptionEvents.append(
                    BandDiagnosticEvent(
                        kind: .live,
                        outcome: .interrupted
                    )
                )
            }
            interruptionEvents.append(
                BandDiagnosticEvent(
                    kind: .reconnect,
                    outcome: .interrupted,
                    failureCategory: .disconnected
                )
            )
            await diagnostics.record(interruptionEvents)
            guard generation == reconnectToken.generation,
                  state == .recovering,
                  activeOperation == token,
                  activeReconnectToken == reconnectToken
            else {
                await diagnostics.record(
                        BandDiagnosticEvent(
                            kind: operationDiagnosticKind,
                            outcome: .stale,
                            failureCategory: .staleCallback,
                            operationClass: token.operationClass
                        )
                )
                throw BandFailureCategory.staleCallback
            }
            clearOperationTracking()
            clearLiveTracking()
            activeConnectionToken = nil
            return reconnectToken
        } else {
            clearActiveOperation()
        }
        let operationOutcome: BandDiagnosticOutcome
        if terminalFirmwareFailure {
            operationOutcome = .terminal
        } else {
            operationOutcome = .failed
        }
        await diagnostics.record(
            BandDiagnosticEvent(
                kind: operationDiagnosticKind,
                outcome: operationOutcome,
                failureCategory: category,
                operationClass: token.operationClass
            )
        )
        if category == .disconnected && !terminalFirmwareFailure {
            await diagnostics.record(
                BandDiagnosticEvent(
                    kind: .reconnect,
                    outcome: .interrupted,
                    failureCategory: .disconnected
                )
            )
        }
        return nil
    }

    @discardableResult
    public func interruptForReconnect(
        token: BandConnectionToken,
        callbackGeneration: UInt64
    ) async throws -> BandReconnectToken {
        try ensureNotClosed()
        try await validateConnectionToken(
            token,
            callbackGeneration,
            diagnosticKind: .reconnect
        )
        guard identity != nil,
              capabilityReport != nil,
              activeOperation?.operationClass != .firmware
        else {
            await diagnostics.record(
                BandDiagnosticEvent(
                    kind: .reconnect,
                    outcome: .rejected,
                    failureCategory: .invalidState
                )
            )
            throw BandFailureCategory.invalidState
        }
        guard !hasPendingPersistence else {
            await diagnostics.record(
                BandDiagnosticEvent(
                    kind: .reconnect,
                    outcome: .rejected,
                    failureCategory: .busy
                )
            )
            throw BandFailureCategory.busy
        }
        let interruptedOperation = activeOperation
        nextReconnectSequence &+= 1
        generation &+= 1
        let reconnectToken = BandReconnectToken(
            sessionNonce: sessionNonce,
            generation: generation,
            sequence: nextReconnectSequence
        )
        activeReconnectToken = reconnectToken
        state = .recovering
        var interruptionEvents: [BandDiagnosticEvent] = []
        if let interruptedOperation {
            interruptionEvents.append(
                BandDiagnosticEvent(
                    kind: diagnosticKind(
                        for: interruptedOperation.operationClass
                    ),
                    outcome: .interrupted,
                    failureCategory: .disconnected,
                    operationClass: interruptedOperation.operationClass
                )
            )
        }
        if liveActive {
            interruptionEvents.append(
                BandDiagnosticEvent(
                    kind: .live,
                    outcome: .interrupted
                )
            )
        }
        interruptionEvents.append(
            BandDiagnosticEvent(kind: .reconnect, outcome: .interrupted)
        )
        await diagnostics.record(interruptionEvents)
        guard generation == reconnectToken.generation,
              state == .recovering,
              activeReconnectToken == reconnectToken
        else {
            await diagnostics.record(
                BandDiagnosticEvent(
                    kind: .reconnect,
                    outcome: .stale,
                    failureCategory: .staleCallback
                )
            )
            throw BandFailureCategory.staleCallback
        }
        clearOperationTracking()
        clearLiveTracking()
        activeConnectionToken = nil
        return reconnectToken
    }

    @discardableResult
    public func resumeAfterReconnect(
        token reconnectToken: BandReconnectToken,
        callbackGeneration: UInt64
    ) async throws -> BandConnectionToken {
        try ensureNotClosed()
        try await validateReconnectToken(
            reconnectToken,
            callbackGeneration,
            diagnosticKind: .reconnect
        )
        guard state == .recovering,
              let identity,
              capabilityReport != nil
        else {
            throw BandFailureCategory.invalidState
        }
        nextConnectionSequence &+= 1
        let token = BandConnectionToken(
            sessionNonce: sessionNonce,
            generation: generation,
            sequence: nextConnectionSequence,
            candidateHandle: identity.sourceIdentity
        )
        activeConnectionToken = token
        activeReconnectToken = nil
        state = .ready
        await diagnostics.record(
            BandDiagnosticEvent(kind: .reconnect, outcome: .completed)
        )
        guard generation == token.generation,
              activeConnectionToken == token
        else {
            await diagnostics.record(
                BandDiagnosticEvent(
                    kind: .reconnect,
                    outcome: .stale,
                    failureCategory: .staleCallback
                )
            )
            throw BandFailureCategory.staleCallback
        }
        return token
    }

    @discardableResult
    public func disconnect(
        reason: BandDisconnectReason,
        callbackGeneration: UInt64
    ) async throws -> UInt64 {
        try ensureNotClosed()
        try await validateCallbackGeneration(
            callbackGeneration,
            diagnosticKind: .disconnect,
            disconnectReason: reason
        )
        guard state != .idle,
              state != .disconnecting,
              state != .incompatible,
              state != .rejected,
              state != .securityFailure,
              state != .firmwareFailure
        else {
            await diagnostics.record(
                BandDiagnosticEvent(
                    kind: .disconnect,
                    outcome: .rejected,
                    failureCategory: .invalidState,
                    disconnectReason: reason
                )
            )
            throw BandFailureCategory.invalidState
        }
        guard !hasPendingPersistence else {
            await diagnostics.record(
                BandDiagnosticEvent(
                    kind: .disconnect,
                    outcome: .rejected,
                    failureCategory: .busy,
                    disconnectReason: reason
                )
            )
            throw BandFailureCategory.busy
        }
        guard activeOperation?.operationClass != .firmware else {
            await diagnostics.record(
                BandDiagnosticEvent(
                    kind: .disconnect,
                    outcome: .rejected,
                    failureCategory: .invalidState,
                    disconnectReason: reason
                )
            )
            throw BandFailureCategory.invalidState
        }

        let cancelledOperationClass = activeOperation?.operationClass
        let cancelledKinds = activeTerminalDiagnosticKinds()
        state = .disconnecting
        generation &+= 1
        let idleGeneration = generation
        await diagnostics.record(
            BandDiagnosticEvent(
                kind: .disconnect,
                outcome: .began,
                disconnectReason: reason
            )
        )
        guard generation == idleGeneration,
              state == .disconnecting
        else {
            await diagnostics.record(
                BandDiagnosticEvent(
                    kind: .disconnect,
                    outcome: .stale,
                    failureCategory: .staleCallback,
                    disconnectReason: reason
                )
            )
            throw BandFailureCategory.staleCallback
        }

        clearOperationTracking()
        clearLiveTracking()
        activeConnectionToken = nil
        activeReconnectToken = nil
        identity = nil
        capabilityReport = nil
        state = .idle
        await diagnostics.record(
            cancelledKinds.map { kind in
                BandDiagnosticEvent(
                    kind: kind,
                    outcome: .cancelled,
                    operationClass: cancelledOperationClass.flatMap {
                        operation in
                        diagnosticKind(for: operation) == kind
                            ? operation
                            : nil
                    }
                )
            } + [
                BandDiagnosticEvent(
                    kind: .disconnect,
                    outcome: .completed,
                    disconnectReason: reason
                ),
            ]
        )
        guard generation == idleGeneration,
              state == .idle
        else {
            await diagnostics.record(
                BandDiagnosticEvent(
                    kind: .disconnect,
                    outcome: .stale,
                    failureCategory: .staleCallback,
                    disconnectReason: reason
                )
            )
            throw BandFailureCategory.staleCallback
        }
        return idleGeneration
    }

    public func close() async throws {
        guard state != .closed else {
            return
        }
        guard !hasPendingPersistence else {
            let pendingKind: BandDiagnosticKind =
                pendingHistory == nil ? .live : .history
            await diagnostics.record(
                BandDiagnosticEvent(
                    kind: pendingKind,
                    outcome: .rejected,
                    failureCategory: .busy
                )
            )
            throw BandFailureCategory.busy
        }
        let terminalOperationClass = activeOperation?.operationClass
        let terminalKinds = activeTerminalDiagnosticKinds()
        generation &+= 1
        clearOperationTracking()
        clearLiveTracking()
        activeScanToken = nil
        activeConnectionToken = nil
        activeReconnectToken = nil
        identity = nil
        capabilityReport = nil
        state = .closed
        await diagnostics.record(
            terminalKinds.map { kind in
                BandDiagnosticEvent(
                    kind: kind,
                    outcome: .cancelled,
                    operationClass: terminalOperationClass.flatMap {
                        operation in
                        diagnosticKind(for: operation) == kind
                            ? operation
                            : nil
                    }
                )
            }
        )
    }

    private func validateCallbackGeneration(
        _ callbackGeneration: UInt64,
        diagnosticKind: BandDiagnosticKind,
        disconnectReason: BandDisconnectReason? = nil
    ) async throws {
        guard callbackGeneration == generation else {
            await diagnostics.record(
                BandDiagnosticEvent(
                    kind: diagnosticKind,
                    outcome: .stale,
                    failureCategory: .staleCallback,
                    disconnectReason: disconnectReason
                )
            )
            throw BandFailureCategory.staleCallback
        }
    }

    private func validateScanToken(
        _ token: BandScanToken,
        diagnosticKind: BandDiagnosticKind
    ) async throws {
        guard token.sessionNonce == sessionNonce,
              token.generation == generation,
              token == activeScanToken
        else {
            await diagnostics.record(
                BandDiagnosticEvent(
                    kind: diagnosticKind,
                    outcome: .stale,
                    failureCategory: .staleCallback
                )
            )
            throw BandFailureCategory.staleCallback
        }
    }

    private func validateConnectionToken(
        _ token: BandConnectionToken,
        _ callbackGeneration: UInt64,
        diagnosticKind: BandDiagnosticKind
    ) async throws {
        try await validateCallbackGeneration(
            callbackGeneration,
            diagnosticKind: diagnosticKind
        )
        guard token.sessionNonce == sessionNonce,
              token.generation == generation,
              token == activeConnectionToken
        else {
            await diagnostics.record(
                BandDiagnosticEvent(
                    kind: diagnosticKind,
                    outcome: .stale,
                    failureCategory: .staleCallback
                )
            )
            throw BandFailureCategory.staleCallback
        }
    }

    private func validateReconnectToken(
        _ token: BandReconnectToken,
        _ callbackGeneration: UInt64,
        diagnosticKind: BandDiagnosticKind
    ) async throws {
        try await validateCallbackGeneration(
            callbackGeneration,
            diagnosticKind: diagnosticKind
        )
        guard token.sessionNonce == sessionNonce,
              token.generation == generation,
              token == activeReconnectToken
        else {
            await diagnostics.record(
                BandDiagnosticEvent(
                    kind: diagnosticKind,
                    outcome: .stale,
                    failureCategory: .staleCallback
                )
            )
            throw BandFailureCategory.staleCallback
        }
    }

    private func validateActiveToken(
        _ token: BandOperationToken,
        expected: BandOperationClass
    ) throws {
        guard token.sessionNonce == sessionNonce,
              token.generation == generation
        else {
            throw BandFailureCategory.staleCallback
        }
        guard token.operationClass == expected,
              token == activeOperation
        else {
            throw BandFailureCategory.invalidState
        }
    }

    private func validateLiveToken(
        _ token: BandLiveToken
    ) async throws {
        guard token.sessionNonce == sessionNonce,
              token.generation == generation,
              token == activeLiveToken
        else {
            await diagnostics.record(
                BandDiagnosticEvent(
                    kind: .live,
                    outcome: .stale,
                    failureCategory: .staleCallback
                )
            )
            throw BandFailureCategory.staleCallback
        }
    }

    private func validateSessionNonce(
        _ candidate: UUID,
        diagnosticKind: BandDiagnosticKind
    ) async throws {
        guard candidate == sessionNonce else {
            await diagnostics.record(
                BandDiagnosticEvent(
                    kind: diagnosticKind,
                    outcome: .stale,
                    failureCategory: .staleCallback
                )
            )
            throw BandFailureCategory.staleCallback
        }
    }

    private func ensureReadyForOperation() throws {
        try ensureNotClosed()
        guard state == .ready || state == .liveCollecting else {
            throw BandFailureCategory.invalidState
        }
    }

    private func ensureNotClosed() throws {
        guard state != .closed else {
            throw BandFailureCategory.closed
        }
    }

    private var samplingCapabilities: Set<BandCapability> {
        [
            .heartRate,
            .rrIntervals,
            .steps,
            .spo2,
            .respiration,
            .temperature,
            .accelerometer,
        ]
    }

    private func diagnosticKind(
        for operationClass: BandOperationClass
    ) -> BandDiagnosticKind {
        switch operationClass {
        case .history:
            return .history
        case .firmware:
            return .firmware
        default:
            return .command
        }
    }

    private func clearActiveOperation() {
        clearOperationTracking()
        state = liveActive ? .liveCollecting : .ready
    }

    private func invalidateNegotiationAfterFirmware() {
        invalidateAuthenticatedSession(nextState: .recovering)
    }

    private func clearLiveTracking() {
        liveActive = false
        activeLiveToken = nil
        liveStreams.removeAll(keepingCapacity: true)
        pendingLive = nil
        liveReceiptCompleting = false
    }

    private func activeTerminalDiagnosticKinds() -> [BandDiagnosticKind] {
        var kinds: [BandDiagnosticKind] = []
        if let operation = activeOperation {
            kinds.append(diagnosticKind(for: operation.operationClass))
        }
        if liveActive {
            kinds.append(.live)
        }
        let phaseKind: BandDiagnosticKind?
        switch state {
        case .scanning:
            phaseKind = .discovery
        case .connecting:
            phaseKind = .connection
        case .authenticating:
            phaseKind = .authentication
        case .negotiatingCapabilities:
            phaseKind = .capability
        case .recovering:
            phaseKind = .reconnect
        case .disconnecting:
            phaseKind = .disconnect
        default:
            phaseKind = nil
        }
        if let phaseKind, !kinds.contains(phaseKind) {
            kinds.append(phaseKind)
        }
        return kinds
    }

    private func clearOperationTracking() {
        activeOperation = nil
        pendingHistory = nil
        historyOperationReceivedDurableReceipt = false
        historyOperationLastReceiptComplete = nil
    }

    private func clearConnectionAttempt(nextState: BandSessionState) {
        invalidateAuthenticatedSession(nextState: nextState)
    }

    private var hasPendingPersistence: Bool {
        pendingLive != nil || pendingHistory != nil
    }

    private func invalidateAuthenticatedSession(
        nextState: BandSessionState
    ) {
        clearOperationTracking()
        clearLiveTracking()
        activeConnectionToken = nil
        activeReconnectToken = nil
        identity = nil
        capabilityReport = nil
        generation &+= 1
        state = nextState
    }

    private func diagnosticKind(
        for phase: BandConnectionPhase
    ) -> BandDiagnosticKind {
        switch phase {
        case .connection:
            return .connection
        case .authentication:
            return .authentication
        }
    }

    private func sessionState(
        for phase: BandConnectionPhase
    ) -> BandSessionState {
        switch phase {
        case .connection:
            return .connecting
        case .authentication:
            return .authenticating
        }
    }

    private func clearDurableSampleIdentities() {
        durableSampleIdentities.removeAll(keepingCapacity: true)
        durableSampleIdentityOrder.removeAll(keepingCapacity: true)
        durableSampleIdentityNextEviction = 0
    }

    private func restoreDurableSampleIdentities(
        _ identities: Set<BandSampleIdentity>
    ) {
        clearDurableSampleIdentities()
        let ordered = identities.sorted(by: sampleIdentityPrecedes)
        rememberDurableSampleIdentities(ordered)
    }

    private func rememberDurableSampleIdentities(
        _ identities: [BandSampleIdentity]
    ) {
        for identity in identities where !durableSampleIdentities.contains(identity) {
            if durableSampleIdentities.count
                == BandContractLimits.historyCheckpointIdentities
            {
                let oldest =
                    durableSampleIdentityOrder[durableSampleIdentityNextEviction]
                durableSampleIdentities.remove(oldest)
                durableSampleIdentityOrder[durableSampleIdentityNextEviction] =
                    identity
                durableSampleIdentityNextEviction =
                    (durableSampleIdentityNextEviction + 1)
                    % BandContractLimits.historyCheckpointIdentities
            } else {
                durableSampleIdentityOrder.append(identity)
            }
            durableSampleIdentities.insert(identity)
        }
    }

    private func sampleIdentityPrecedes(
        _ lhs: BandSampleIdentity,
        _ rhs: BandSampleIdentity
    ) -> Bool {
        if lhs.deviceTimeMilliseconds != rhs.deviceTimeMilliseconds {
            return lhs.deviceTimeMilliseconds < rhs.deviceTimeMilliseconds
        }
        if lhs.sequence != rhs.sequence {
            return lhs.sequence < rhs.sequence
        }
        return lhs.stream.rawValue < rhs.stream.rawValue
    }

    private func validateNegotiatedBatch(
        _ batch: BandSampleBatch,
        diagnosticKind: BandDiagnosticKind,
        allowedStreams: Set<BandStreamKind>? = nil
    ) async throws {
        guard let capabilityReport,
              batch.samples.allSatisfy({ sample in
                  let stream = sample.identity.stream
                  return capabilityReport.capabilities.contains(
                      requiredCapability(for: stream)
                  )
                    && (allowedStreams?.contains(stream) ?? true)
                    && capabilityReport.streamSemantics.contains {
                        $0.lane == batch.lane
                            && $0.stream == stream
                            && $0.unit == sample.unit
                            && $0.parserRevision.hasIdenticalUTF8(
                                to: batch.parserRevision
                            )
                            && $0.calibrationRevision.hasIdenticalUTF8(
                                to: batch.calibrationRevision
                            )
                    }
              })
        else {
            await diagnostics.record(
                BandDiagnosticEvent(
                    kind: diagnosticKind,
                    outcome: .rejected,
                    failureCategory: .unsupported
                )
            )
            throw BandFailureCategory.unsupported
        }
    }

    private func impliedCapability(
        for operationClass: BandOperationClass
    ) -> BandCapability? {
        switch operationClass {
        case .battery:
            return .battery
        case .wearState:
            return .wearState
        case .haptic:
            return .haptics
        case .alarm:
            return .alarms
        case .history, .sampling, .firmware:
            return nil
        }
    }
}
