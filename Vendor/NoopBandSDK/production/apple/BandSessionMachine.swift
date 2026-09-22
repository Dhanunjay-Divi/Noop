import Foundation

public actor BandSessionMachine {
    private struct PendingLive {
        let acceptance: LiveAcceptance
        let sampleIdentities: [BandSampleIdentity]
    }

    private struct PendingHistory {
        let acceptance: HistoryAcceptance
        let sampleIdentities: [BandSampleIdentity]
    }

    private let diagnostics: BandDiagnosticsRecorder
    private let restoredHistoryCheckpoint: BandHistoryCheckpoint?
    private let sessionNonce = UUID()
    private var state: BandSessionState = .idle
    private var generation: UInt64 = 0
    private var nextOperationSequence: UInt64 = 0
    private var nextLiveReceiptSequence: UInt64 = 0
    private var nextHistoryReceiptSequence: UInt64 = 0
    private var activeOperation: BandOperationToken?
    private var liveActive = false
    private var liveStreams: Set<BandStreamKind> = []
    private var identity: BandIdentity?
    private var capabilityReport: BandCapabilityReport?
    private var pendingLive: PendingLive?
    private var pendingHistory: PendingHistory?
    private var lastDurableHistoryComplete: Bool?
    private var historyOperationReceivedDurableReceipt = false
    private var historyOperationLastReceiptComplete: Bool?
    private var durableSampleIdentities: Set<BandSampleIdentity> = []
    private var durableSampleIdentityOrder: [BandSampleIdentity] = []
    private var durableSampleIdentityNextEviction = 0
    private var acknowledgedHistoryCursor: String?
    private var durableSourceIdentity: String?

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
    public func beginScan() async throws -> UInt64 {
        try ensureNotClosed()
        guard state == .idle
            || state == .recovering
            || state == .rejected
        else {
            throw BandFailureCategory.invalidState
        }
        generation &+= 1
        clearOperationTracking()
        clearLiveTracking()
        identity = nil
        capabilityReport = nil
        state = .scanning
        await diagnostics.record(
            BandDiagnosticEvent(kind: .discovery, outcome: .began)
        )
        return generation
    }

    public func selectCandidate(
        _ candidate: BandPairingCandidate,
        callbackGeneration: UInt64
    ) async throws {
        try ensureNotClosed()
        try await validateCallbackGeneration(
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
        state = .candidateSelected
        await diagnostics.record(
            BandDiagnosticEvent(
                kind: .discovery,
                outcome: .completed,
                countBucket: .one
            )
        )
    }

    public func cancelScan(callbackGeneration: UInt64) async throws {
        try ensureNotClosed()
        try await validateCallbackGeneration(
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
        state = .idle
        await diagnostics.record(
            BandDiagnosticEvent(kind: .discovery, outcome: .cancelled)
        )
    }

    public func failScan(
        _ category: BandFailureCategory,
        callbackGeneration: UInt64
    ) async throws {
        try ensureNotClosed()
        try await validateCallbackGeneration(
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
        callbackGeneration: UInt64
    ) async throws {
        try ensureNotClosed()
        try await validateCallbackGeneration(
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
    }

    public func beginAuthentication(
        callbackGeneration: UInt64
    ) async throws {
        try ensureNotClosed()
        try await validateCallbackGeneration(
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
            BandDiagnosticEvent(kind: .authentication, outcome: .began)
        )
    }

    public func completeConnection(
        _ newIdentity: BandIdentity,
        callbackGeneration: UInt64
    ) async throws {
        try ensureNotClosed()
        try await validateCallbackGeneration(
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
        if durableSourceIdentity == nil,
           let restoredHistoryCheckpoint,
           restoredHistoryCheckpoint.sourceIdentity == newIdentity.sourceIdentity
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
        } else if durableSourceIdentity != newIdentity.sourceIdentity {
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
    }

    public func cancelConnection(
        phase: BandConnectionPhase,
        callbackGeneration: UInt64
    ) async throws {
        try ensureNotClosed()
        let diagnosticKind = diagnosticKind(for: phase)
        try await validateCallbackGeneration(
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
        phase: BandConnectionPhase,
        callbackGeneration: UInt64
    ) async throws {
        try ensureNotClosed()
        let diagnosticKind = diagnosticKind(for: phase)
        try await validateCallbackGeneration(
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
        callbackGeneration: UInt64
    ) async throws {
        try ensureNotClosed()
        try await validateCallbackGeneration(
            callbackGeneration,
            diagnosticKind: .capability
        )
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
              identity?.hardwareRevision == report.hardwareRevision,
              identity?.firmwareVersion == report.firmwareVersion,
              identity?.protocolVersion == report.protocolVersion
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

        do {
            try report.validate()
        } catch {
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
    }

    public func beginLive(
        streams requestedStreams: Set<BandStreamKind>? = nil
    ) async throws {
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
        let negotiatedStreams = Set(
            BandStreamKind.allCases.filter { stream in
                capabilityReport?.capabilities.contains(
                    requiredCapability(for: stream)
                ) == true
            }
        )
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
        liveStreams = selectedStreams
        liveActive = true
        state = .liveCollecting
        await diagnostics.record(
            BandDiagnosticEvent(kind: .live, outcome: .began)
        )
    }

    public func stopLive() async throws {
        try ensureNotClosed()
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
        guard batch.sourceIdentity == identity?.sourceIdentity else {
            await diagnostics.record(
                BandDiagnosticEvent(
                    kind: .live,
                    outcome: .rejected,
                    failureCategory: .invalidInput
                )
            )
            throw BandFailureCategory.invalidInput
        }
        guard pendingLive == nil else {
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
        try await validateNegotiatedStreams(
            batch.samples,
            diagnosticKind: .live,
            allowedStreams: liveStreams
        )
        var acceptedIdentities: Set<BandSampleIdentity> = []
        let unique = batch.samples.filter { sample in
            !durableSampleIdentities.contains(sample.identity)
                && acceptedIdentities.insert(sample.identity).inserted
        }
        nextLiveReceiptSequence &+= 1
        let acceptance = LiveAcceptance(
            acceptedSamples: unique,
            duplicateSamples: batch.samples.count - unique.count,
            sessionNonce: sessionNonce,
            generation: generation,
            receiptSequence: nextLiveReceiptSequence
        )
        pendingLive = PendingLive(
            acceptance: acceptance,
            sampleIdentities: unique.map(\.identity)
        )
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
                >= pendingLive.acceptance.acceptedSamples.count
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
        self.pendingLive = nil
        await diagnostics.record(
            BandDiagnosticEvent(
                kind: .live,
                outcome: .completed,
                countBucket: BandCountBucket(
                    count: receipt.committedSamples
                )
            )
        )
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
                    failureCategory: failure
                )
            )
            throw failure
        }
        guard activeOperation == nil else {
            await diagnostics.record(
                BandDiagnosticEvent(
                    kind: operationDiagnosticKind,
                    outcome: .rejected,
                    failureCategory: .busy
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
                    failureCategory: failure
                )
            )
            throw failure
        }
        if operationClass == .firmware, liveActive {
            await diagnostics.record(
                BandDiagnosticEvent(
                    kind: operationDiagnosticKind,
                    outcome: .rejected,
                    failureCategory: .busy
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
                    failureCategory: .updateNotEligible
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
                        failureCategory: .unsupported
                    )
                )
                throw BandFailureCategory.unsupported
            }
        } else if operationClass == .history,
                  (capabilityReport?.historyDays ?? 0) <= 0
        {
            await diagnostics.record(
                BandDiagnosticEvent(
                    kind: operationDiagnosticKind,
                    outcome: .rejected,
                    failureCategory: .unsupported
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
                            failureCategory: .unsupported
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
                outcome: .began
            )
        )
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
        guard pendingHistory == nil else {
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
        try await validateNegotiatedStreams(
            chunk.batches.flatMap(\.samples),
            diagnosticKind: .history
        )
        guard chunk.previousCursor == acknowledgedHistoryCursor else {
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
                && chunk.nextCursor != chunk.previousCursor)
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
        guard chunk.batches.allSatisfy({
            $0.sourceIdentity == identity?.sourceIdentity
        }) else {
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
        var unique: [BandSampleIdentity] = []
        var duplicateCount = 0
        for sample in chunk.batches.flatMap(\.samples) {
            if durableSampleIdentities.contains(sample.identity)
                || !uniqueSet.insert(sample.identity).inserted
            {
                duplicateCount += 1
            } else {
                unique.append(sample.identity)
            }
        }
        nextHistoryReceiptSequence &+= 1
        let acceptance = HistoryAcceptance(
            chunkIdentity: chunk.chunkIdentity,
            acknowledgementToken: chunk.acknowledgementToken,
            nextCursor: chunk.nextCursor,
            complete: chunk.complete,
            overflowed: chunk.overflowed,
            acceptedSamples: unique.count,
            duplicateSamples: duplicateCount,
            sessionNonce: sessionNonce,
            receiptSequence: nextHistoryReceiptSequence
        )
        pendingHistory = PendingHistory(
            acceptance: acceptance,
            sampleIdentities: unique
        )
        await diagnostics.record(
            BandDiagnosticEvent(
                kind: .history,
                outcome: .completed,
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
              receipt.committed,
              receipt.chunkIdentity == pendingHistory.acceptance.chunkIdentity,
              receipt.acknowledgementToken
                == pendingHistory.acceptance.acknowledgementToken,
              receipt.nextCursor == pendingHistory.acceptance.nextCursor,
              receipt.complete == pendingHistory.acceptance.complete,
              receipt.overflowed == pendingHistory.acceptance.overflowed,
              receipt.historyStateCommitted,
              receipt.committedSamples >= pendingHistory.acceptance.acceptedSamples
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
                    failureCategory: failure
                )
            )
            throw failure
        }
        if token.operationClass == .history, pendingHistory != nil {
            await diagnostics.record(
                BandDiagnosticEvent(
                    kind: operationDiagnosticKind,
                    outcome: .failed,
                    failureCategory: .storage
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
                    failureCategory: .storage
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
                    failureCategory: .historyStalled
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
                outcome: .completed
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
                    failureCategory: failure
                )
            )
            throw failure
        }
        if token.operationClass == .firmware {
            invalidateNegotiationAfterFirmware()
        } else {
            clearActiveOperation()
        }
        await diagnostics.record(
            BandDiagnosticEvent(
                kind: operationDiagnosticKind,
                outcome: .cancelled
            )
        )
    }

    public func failOperation(
        _ token: BandOperationToken,
        category: BandFailureCategory
    ) async throws {
        let operationDiagnosticKind = diagnosticKind(for: token.operationClass)
        do {
            try validateActiveToken(token, expected: token.operationClass)
        } catch let failure as BandFailureCategory {
            await diagnostics.record(
                BandDiagnosticEvent(
                    kind: operationDiagnosticKind,
                    outcome: .rejected,
                    failureCategory: failure
                )
            )
            throw failure
        }
        if category == .securityFailure {
            invalidateAuthenticatedSession(nextState: .securityFailure)
        } else if token.operationClass == .firmware {
            invalidateNegotiationAfterFirmware()
        } else if category == .disconnected {
            clearOperationTracking()
            clearLiveTracking()
            generation &+= 1
            state = .recovering
        } else {
            clearActiveOperation()
        }
        await diagnostics.record(
            BandDiagnosticEvent(
                kind: operationDiagnosticKind,
                outcome: .failed,
                failureCategory: category
            )
        )
        if category == .disconnected {
            await diagnostics.record(
                BandDiagnosticEvent(
                    kind: .reconnect,
                    outcome: .interrupted,
                    failureCategory: .disconnected
                )
            )
        }
    }

    @discardableResult
    public func interruptForReconnect(
        callbackGeneration: UInt64
    ) async throws -> UInt64 {
        try ensureNotClosed()
        try await validateCallbackGeneration(
            callbackGeneration,
            diagnosticKind: .reconnect
        )
        guard state != .idle,
              state != .incompatible,
              state != .rejected,
              state != .securityFailure
        else {
            throw BandFailureCategory.invalidState
        }
        let interruptedOperationKind = activeOperation.map {
            diagnosticKind(for: $0.operationClass)
        }
        let firmwareWasActive =
            activeOperation?.operationClass == .firmware
        clearOperationTracking()
        clearLiveTracking()
        if firmwareWasActive {
            identity = nil
            capabilityReport = nil
        }
        generation &+= 1
        state = .recovering
        if let interruptedOperationKind {
            await diagnostics.record(
                BandDiagnosticEvent(
                    kind: interruptedOperationKind,
                    outcome: .interrupted,
                    failureCategory: .disconnected
                )
            )
        }
        await diagnostics.record(
            BandDiagnosticEvent(kind: .reconnect, outcome: .interrupted)
        )
        return generation
    }

    public func resumeAfterReconnect(
        callbackGeneration: UInt64
    ) async throws {
        try ensureNotClosed()
        try await validateCallbackGeneration(
            callbackGeneration,
            diagnosticKind: .reconnect
        )
        guard state == .recovering,
              identity != nil,
              capabilityReport != nil
        else {
            throw BandFailureCategory.invalidState
        }
        state = .ready
        await diagnostics.record(
            BandDiagnosticEvent(kind: .reconnect, outcome: .completed)
        )
    }

    public func close() async {
        generation &+= 1
        clearOperationTracking()
        clearLiveTracking()
        identity = nil
        capabilityReport = nil
        state = .closed
        await diagnostics.record(
            BandDiagnosticEvent(kind: .connection, outcome: .cancelled)
        )
    }

    private func validateCallbackGeneration(
        _ callbackGeneration: UInt64,
        diagnosticKind: BandDiagnosticKind
    ) async throws {
        guard callbackGeneration == generation else {
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
        liveStreams.removeAll(keepingCapacity: true)
        pendingLive = nil
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

    private func invalidateAuthenticatedSession(
        nextState: BandSessionState
    ) {
        clearOperationTracking()
        clearLiveTracking()
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

    private func validateNegotiatedStreams(
        _ samples: [BandSample],
        diagnosticKind: BandDiagnosticKind,
        allowedStreams: Set<BandStreamKind>? = nil
    ) async throws {
        guard let capabilities = capabilityReport?.capabilities,
              samples.allSatisfy({
                  capabilities.contains(requiredCapability(for: $0.identity.stream))
                    && (allowedStreams?.contains($0.identity.stream) ?? true)
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

    private func requiredCapability(
        for stream: BandStreamKind
    ) -> BandCapability {
        switch stream {
        case .heartRate:
            return .heartRate
        case .rrInterval:
            return .rrIntervals
        case .steps:
            return .steps
        case .spo2:
            return .spo2
        case .respiration:
            return .respiration
        case .temperature:
            return .temperature
        case .acceleration:
            return .accelerometer
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
