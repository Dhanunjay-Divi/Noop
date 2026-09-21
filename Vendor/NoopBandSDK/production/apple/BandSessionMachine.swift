import Foundation

public actor BandSessionMachine {
    private struct PendingHistory {
        let acceptance: HistoryAcceptance
        let sampleIdentities: Set<BandSampleIdentity>
    }

    private let diagnostics: BandDiagnosticsRecorder
    private var state: BandSessionState = .idle
    private var generation: UInt64 = 0
    private var nextOperationSequence: UInt64 = 0
    private var activeOperation: BandOperationToken?
    private var liveActive = false
    private var identity: BandIdentity?
    private var capabilityReport: BandCapabilityReport?
    private var pendingHistory: PendingHistory?
    private var durableSampleIdentities: Set<BandSampleIdentity> = []
    private var acknowledgedHistoryCursor: String?

    public init(diagnostics: BandDiagnosticsRecorder = BandDiagnosticsRecorder()) {
        self.diagnostics = diagnostics
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

    @discardableResult
    public func beginScan() async throws -> UInt64 {
        try ensureNotClosed()
        guard state == .idle || state == .recovering else {
            throw BandFailureCategory.invalidState
        }
        generation &+= 1
        activeOperation = nil
        pendingHistory = nil
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
        if identity?.sourceIdentity != newIdentity.sourceIdentity {
            durableSampleIdentities.removeAll(keepingCapacity: true)
            acknowledgedHistoryCursor = nil
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

    public func acceptCapabilities(_ report: BandCapabilityReport) async throws {
        try ensureNotClosed()
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
        var acceptedIdentities: Set<BandSampleIdentity> = []
        let unique = batch.samples.filter { sample in
            !durableSampleIdentities.contains(sample.identity)
                && acceptedIdentities.insert(sample.identity).inserted
        }
        durableSampleIdentities.formUnion(unique.map(\.identity))
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
        try ensureNotClosed()
        guard activeOperation == nil else {
            await diagnostics.record(
                BandDiagnosticEvent(kind: .command, outcome: .rejected)
            )
            throw BandFailureCategory.busy
        }
        try ensureReadyForOperation()
        let capabilities = [impliedCapability(for: operationClass), requiredCapability]
            .compactMap { $0 }
        for capability in capabilities {
            guard capabilityReport?.capabilities.contains(capability) == true else {
                throw BandFailureCategory.unsupported
            }
        }
        if operationClass == .firmware,
           capabilityReport?.capabilities.contains(.firmwareUpdate) != true
        {
            throw BandFailureCategory.updateNotEligible
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
            state = .historyCollecting
        case .firmware:
            state = .updatingFirmware
        default:
            state = .executingCommand
        }
        await diagnostics.record(
            BandDiagnosticEvent(
                kind: operationClass == .history ? .history : .command,
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
        try chunk.validate()
        guard chunk.previousCursor == acknowledgedHistoryCursor else {
            await diagnostics.record(
                BandDiagnosticEvent(kind: .history, outcome: .rejected)
            )
            throw BandFailureCategory.historyStalled
        }
        guard chunk.batches.allSatisfy({
            $0.sourceIdentity == identity?.sourceIdentity
        }) else {
            throw BandFailureCategory.invalidInput
        }

        var unique: Set<BandSampleIdentity> = []
        var duplicateCount = 0
        for sample in chunk.batches.flatMap(\.samples) {
            if durableSampleIdentities.contains(sample.identity)
                || !unique.insert(sample.identity).inserted
            {
                duplicateCount += 1
            }
        }
        let acceptance = HistoryAcceptance(
            chunkIdentity: chunk.chunkIdentity,
            acknowledgementToken: chunk.acknowledgementToken,
            nextCursor: chunk.nextCursor,
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
              receipt.committedSamples >= pendingHistory.acceptance.acceptedSamples
        else {
            await diagnostics.record(
                BandDiagnosticEvent(kind: .history, outcome: .failed)
            )
            throw BandFailureCategory.storage
        }

        durableSampleIdentities.formUnion(pendingHistory.sampleIdentities)
        acknowledgedHistoryCursor = receipt.nextCursor
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
        try validateActiveToken(token, expected: token.operationClass)
        if token.operationClass == .history, pendingHistory != nil {
            throw BandFailureCategory.storage
        }
        activeOperation = nil
        state = liveActive ? .liveCollecting : .ready
        await diagnostics.record(
            BandDiagnosticEvent(
                kind: token.operationClass == .history ? .history : .command,
                outcome: .completed
            )
        )
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
        activeOperation = nil
        pendingHistory = nil
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
        activeOperation = nil
        pendingHistory = nil
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
        case .firmware:
            return .firmwareUpdate
        case .history, .sampling:
            return nil
        }
    }
}
