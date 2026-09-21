import Foundation

public actor BandSessionMachine {
    private struct PendingHistory {
        let acceptance: HistoryAcceptance
        let sampleIdentities: [BandSampleIdentity]
    }

    private let diagnostics: BandDiagnosticsRecorder
    private let restoredHistoryCheckpoint: BandHistoryCheckpoint?
    private var state: BandSessionState = .idle
    private var generation: UInt64 = 0
    private var nextOperationSequence: UInt64 = 0
    private var activeOperation: BandOperationToken?
    private var liveActive = false
    private var identity: BandIdentity?
    private var capabilityReport: BandCapabilityReport?
    private var pendingHistory: PendingHistory?
    private var lastDurableHistoryComplete: Bool?
    private var historyOperationReceivedDurableReceipt = false
    private var historyOperationLastReceiptComplete: Bool?
    private var durableSampleIdentities: Set<BandSampleIdentity> = []
    private var durableSampleIdentityOrder: [BandSampleIdentity] = []
    private var durableSampleIdentityNextEviction = 0
    private var acknowledgedHistoryCursor: String?

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
        guard let sourceIdentity = identity?.sourceIdentity else {
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
        guard state == .idle || state == .recovering else {
            throw BandFailureCategory.invalidState
        }
        generation &+= 1
        clearOperationTracking()
        liveActive = false
        state = .scanning
        await diagnostics.record(
            BandDiagnosticEvent(kind: .discovery, outcome: .began)
        )
        return generation
    }

    public func selectCandidate(_ candidate: BandPairingCandidate) async throws {
        try ensureNotClosed()
        do {
            try candidate.validate()
        } catch {
            await diagnostics.record(
                BandDiagnosticEvent(kind: .discovery, outcome: .rejected)
            )
            throw BandFailureCategory.invalidInput
        }
        guard state == .scanning,
              candidate.compatible,
              candidate.identifyEligible
        else {
            await diagnostics.record(
                BandDiagnosticEvent(kind: .discovery, outcome: .rejected)
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

    public func connect(_ newIdentity: BandIdentity) async throws {
        try ensureNotClosed()
        guard state == .candidateSelected else {
            throw BandFailureCategory.invalidState
        }
        try newIdentity.validate()
        if identity == nil,
           let restoredHistoryCheckpoint,
           restoredHistoryCheckpoint.sourceIdentity == newIdentity.sourceIdentity
        {
            try restoredHistoryCheckpoint.validate()
            restoreDurableSampleIdentities(
                restoredHistoryCheckpoint.durableSampleIdentities
            )
            acknowledgedHistoryCursor =
                restoredHistoryCheckpoint.acknowledgedCursor
            lastDurableHistoryComplete =
                restoredHistoryCheckpoint.lastHistoryComplete
        } else if identity?.sourceIdentity != newIdentity.sourceIdentity {
            clearDurableSampleIdentities()
            acknowledgedHistoryCursor = nil
            lastDurableHistoryComplete = nil
        }
        capabilityReport = nil
        state = .connecting
        identity = newIdentity
        state = .authenticating
        state = .negotiatingCapabilities
        await diagnostics.record(
            BandDiagnosticEvent(kind: .connection, outcome: .completed)
        )
    }

    public func acceptCapabilities(
        _ report: BandCapabilityReport,
        callbackGeneration: UInt64
    ) async throws {
        try ensureNotClosed()
        try await validateCallbackGeneration(callbackGeneration)
        guard state == .negotiatingCapabilities,
              identity?.hardwareRevision == report.hardwareRevision,
              identity?.firmwareVersion == report.firmwareVersion,
              identity?.protocolVersion == report.protocolVersion
        else {
            state = .incompatible
            capabilityReport = nil
            await diagnostics.record(
                BandDiagnosticEvent(kind: .capability, outcome: .rejected)
            )
            throw BandFailureCategory.incompatible
        }

        do {
            try report.validate()
        } catch {
            state = .incompatible
            capabilityReport = nil
            await diagnostics.record(
                BandDiagnosticEvent(kind: .capability, outcome: .rejected)
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

    public func beginLive() async throws {
        try ensureReadyForOperation()
        guard !liveActive else {
            throw BandFailureCategory.busy
        }
        guard capabilityReport?.capabilities.contains(.heartRate) == true else {
            throw BandFailureCategory.unsupported
        }
        liveActive = true
        state = .liveCollecting
        await diagnostics.record(
            BandDiagnosticEvent(kind: .live, outcome: .began)
        )
    }

    public func stopLive() async throws {
        try ensureNotClosed()
        guard liveActive, activeOperation == nil else {
            throw BandFailureCategory.invalidState
        }
        liveActive = false
        state = .ready
        await diagnostics.record(
            BandDiagnosticEvent(kind: .live, outcome: .completed)
        )
    }

    @discardableResult
    public func commitLiveBatch(
        _ batch: BandSampleBatch,
        callbackGeneration: UInt64
    ) async throws -> Int {
        try await validateCallbackGeneration(callbackGeneration)
        guard liveActive,
              state == .liveCollecting || activeOperation != nil,
              batch.sourceIdentity == identity?.sourceIdentity
        else {
            throw BandFailureCategory.invalidState
        }
        try batch.validate(expectedLane: .live)
        try await validateNegotiatedStreams(
            batch.samples,
            diagnosticKind: .live
        )
        var acceptedIdentities: Set<BandSampleIdentity> = []
        let unique = batch.samples.filter { sample in
            !durableSampleIdentities.contains(sample.identity)
                && acceptedIdentities.insert(sample.identity).inserted
        }
        rememberDurableSampleIdentities(unique.map(\.identity))
        await diagnostics.record(
            BandDiagnosticEvent(
                kind: .live,
                outcome: .completed,
                countBucket: BandCountBucket(count: unique.count)
            )
        )
        return unique.count
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
        try await validateCallbackGeneration(callbackGeneration)
        try validateActiveToken(token, expected: .history)
        guard pendingHistory == nil else {
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
        try chunk.validate()
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
        let acceptance = HistoryAcceptance(
            chunkIdentity: chunk.chunkIdentity,
            acknowledgementToken: chunk.acknowledgementToken,
            nextCursor: chunk.nextCursor,
            complete: chunk.complete,
            overflowed: chunk.overflowed,
            acceptedSamples: unique.count,
            duplicateSamples: duplicateCount
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
        try await validateCallbackGeneration(callbackGeneration)
        try validateActiveToken(token, expected: .history)
        guard let pendingHistory,
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
                BandDiagnosticEvent(kind: .history, outcome: .failed)
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
        clearActiveOperation()
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
        clearActiveOperation()
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
        if category == .disconnected {
            clearOperationTracking()
            liveActive = false
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
    public func interruptForReconnect() async throws -> UInt64 {
        try ensureNotClosed()
        guard state != .idle,
              state != .incompatible,
              state != .rejected,
              state != .securityFailure
        else {
            throw BandFailureCategory.invalidState
        }
        clearOperationTracking()
        liveActive = false
        generation &+= 1
        state = .recovering
        await diagnostics.record(
            BandDiagnosticEvent(kind: .reconnect, outcome: .interrupted)
        )
        return generation
    }

    public func resumeAfterReconnect() async throws {
        try ensureNotClosed()
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
        liveActive = false
        state = .closed
        await diagnostics.record(
            BandDiagnosticEvent(kind: .connection, outcome: .cancelled)
        )
    }

    private func validateCallbackGeneration(_ callbackGeneration: UInt64) async throws {
        guard callbackGeneration == generation else {
            await diagnostics.record(
                BandDiagnosticEvent(kind: .connection, outcome: .stale)
            )
            throw BandFailureCategory.staleCallback
        }
    }

    private func validateActiveToken(
        _ token: BandOperationToken,
        expected: BandOperationClass
    ) throws {
        guard token.generation == generation else {
            throw BandFailureCategory.staleCallback
        }
        guard token.operationClass == expected,
              token == activeOperation
        else {
            throw BandFailureCategory.invalidState
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

    private func clearOperationTracking() {
        activeOperation = nil
        pendingHistory = nil
        historyOperationReceivedDurableReceipt = false
        historyOperationLastReceiptComplete = nil
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
        diagnosticKind: BandDiagnosticKind
    ) async throws {
        guard let capabilities = capabilityReport?.capabilities,
              samples.allSatisfy({
                  capabilities.contains(requiredCapability(for: $0.identity.stream))
              })
        else {
            await diagnostics.record(
                BandDiagnosticEvent(kind: diagnosticKind, outcome: .rejected)
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
