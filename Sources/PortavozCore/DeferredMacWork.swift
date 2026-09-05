import Foundation

public enum DeferredMacWorkKind: String, Codable, CaseIterable, Sendable {
    case refine
    case diarization
    case summary
}

public enum DeferredMacWorkContractError: Error, Equatable, Sendable {
    case invalidRequest
    case invalidSnapshot
    case staleRevision
    case invalidTransition
    case leaseUnavailable
    case leaseExpired
    case attemptsExhausted
    case staleSource
}

/// Immutable, content-free request for work that a future mobile companion may
/// defer to a Mac. It contains no transcript, audio, path, prompt, model, key,
/// or provider material.
public struct DeferredMacWorkRequest: Codable, Equatable, Sendable, Identifiable {
    public static let currentFormatVersion = 1

    public let formatVersion: Int
    public let id: UUID
    public let meetingID: MeetingID
    public let sourceDeviceID: UUID
    public let kind: DeferredMacWorkKind
    public let sourceTranscriptRevision: Int
    public let inputFingerprint: String
    public let maxAttempts: Int
    public let requestedAt: Date

    public init(
        id: UUID = UUID(),
        meetingID: MeetingID,
        sourceDeviceID: UUID,
        kind: DeferredMacWorkKind,
        sourceTranscriptRevision: Int,
        inputFingerprint: String,
        maxAttempts: Int = 3,
        requestedAt: Date
    ) throws {
        formatVersion = Self.currentFormatVersion
        self.id = id
        self.meetingID = meetingID
        self.sourceDeviceID = sourceDeviceID
        self.kind = kind
        self.sourceTranscriptRevision = sourceTranscriptRevision
        self.inputFingerprint = inputFingerprint
        self.maxAttempts = maxAttempts
        self.requestedAt = requestedAt
        try validate()
    }

    public var idempotencyKey: String {
        OperationFingerprint.make(
            version: "deferred-mac-work-v1",
            components: [
                meetingID.rawValue.uuidString.lowercased(),
                kind.rawValue,
                String(sourceTranscriptRevision),
                inputFingerprint
            ])
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try container.decode(Int.self, forKey: .formatVersion)
        id = try container.decode(UUID.self, forKey: .id)
        meetingID = try container.decode(MeetingID.self, forKey: .meetingID)
        sourceDeviceID = try container.decode(UUID.self, forKey: .sourceDeviceID)
        kind = try container.decode(DeferredMacWorkKind.self, forKey: .kind)
        sourceTranscriptRevision = try container.decode(
            Int.self,
            forKey: .sourceTranscriptRevision)
        inputFingerprint = try container.decode(String.self, forKey: .inputFingerprint)
        maxAttempts = try container.decode(Int.self, forKey: .maxAttempts)
        requestedAt = try container.decode(Date.self, forKey: .requestedAt)
        try validate()
    }

    private func validate() throws {
        guard formatVersion == Self.currentFormatVersion,
              sourceTranscriptRevision >= 0,
              (1...3).contains(maxAttempts),
              requestedAt.timeIntervalSinceReferenceDate.isFinite,
              DeferredMacWorkPolicy.isFingerprint(inputFingerprint)
        else { throw DeferredMacWorkContractError.invalidRequest }
    }
}

public enum DeferredMacWorkState: String, Codable, CaseIterable, Sendable {
    case queued
    case claimed
    case running
    case succeeded
    case failed
    case cancelled
    case superseded
}

/// Versioned compare-and-swap snapshot. Claim identity remains visible after a
/// terminal worker outcome so retries can prove idempotency without retaining
/// result content.
public struct DeferredMacWorkSnapshot: Codable, Equatable, Sendable {
    public static let currentFormatVersion = 1

    public let formatVersion: Int
    public let request: DeferredMacWorkRequest
    public let state: DeferredMacWorkState
    public let revision: Int
    public let attempt: Int
    public let executionOwnerDeviceID: UUID?
    public let leaseToken: UUID?
    public let leaseExpiresAt: Date?
    public let resultFingerprint: String?
    public let failureCode: String?
    public let updatedAt: Date

    public static func queued(
        request: DeferredMacWorkRequest
    ) -> DeferredMacWorkSnapshot {
        DeferredMacWorkSnapshot(
            request: request,
            state: .queued,
            revision: 0,
            attempt: 0,
            executionOwnerDeviceID: nil,
            leaseToken: nil,
            leaseExpiresAt: nil,
            resultFingerprint: nil,
            failureCode: nil,
            updatedAt: request.requestedAt)
    }

    fileprivate init(
        request: DeferredMacWorkRequest,
        state: DeferredMacWorkState,
        revision: Int,
        attempt: Int,
        executionOwnerDeviceID: UUID?,
        leaseToken: UUID?,
        leaseExpiresAt: Date?,
        resultFingerprint: String?,
        failureCode: String?,
        updatedAt: Date
    ) {
        formatVersion = Self.currentFormatVersion
        self.request = request
        self.state = state
        self.revision = revision
        self.attempt = attempt
        self.executionOwnerDeviceID = executionOwnerDeviceID
        self.leaseToken = leaseToken
        self.leaseExpiresAt = leaseExpiresAt
        self.resultFingerprint = resultFingerprint
        self.failureCode = failureCode
        self.updatedAt = updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try container.decode(Int.self, forKey: .formatVersion)
        request = try container.decode(DeferredMacWorkRequest.self, forKey: .request)
        state = try container.decode(DeferredMacWorkState.self, forKey: .state)
        revision = try container.decode(Int.self, forKey: .revision)
        attempt = try container.decode(Int.self, forKey: .attempt)
        executionOwnerDeviceID = try container.decodeIfPresent(
            UUID.self,
            forKey: .executionOwnerDeviceID)
        leaseToken = try container.decodeIfPresent(UUID.self, forKey: .leaseToken)
        leaseExpiresAt = try container.decodeIfPresent(Date.self, forKey: .leaseExpiresAt)
        resultFingerprint = try container.decodeIfPresent(
            String.self,
            forKey: .resultFingerprint)
        failureCode = try container.decodeIfPresent(String.self, forKey: .failureCode)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        try DeferredMacWorkPolicy.validate(self)
    }
}

public enum DeferredMacWorkTransition: Equatable, Sendable {
    case claim(ownerDeviceID: UUID, leaseToken: UUID, leaseExpiresAt: Date)
    case renew(ownerDeviceID: UUID, leaseToken: UUID, leaseExpiresAt: Date)
    case start(ownerDeviceID: UUID, leaseToken: UUID)
    case succeed(
        ownerDeviceID: UUID,
        leaseToken: UUID,
        resultFingerprint: String,
        currentInputFingerprint: String,
        currentTranscriptRevision: Int)
    case fail(ownerDeviceID: UUID, leaseToken: UUID, code: String)
    case cancel
    case supersede
}

public enum DeferredMacWorkPolicy {
    public static let maximumLeaseDuration: TimeInterval = 15 * 60

    public static func apply(
        _ transition: DeferredMacWorkTransition,
        to snapshot: DeferredMacWorkSnapshot,
        expectedRevision: Int,
        at now: Date
    ) throws -> DeferredMacWorkSnapshot {
        try validate(snapshot)
        guard now.timeIntervalSinceReferenceDate.isFinite,
              now >= snapshot.updatedAt
        else { throw DeferredMacWorkContractError.invalidTransition }
        if isExactReplay(transition, of: snapshot) { return snapshot }
        guard expectedRevision == snapshot.revision else {
            throw DeferredMacWorkContractError.staleRevision
        }

        let next: DeferredMacWorkSnapshot
        switch transition {
        case .claim(let owner, let token, let expiry):
            next = try claim(snapshot, owner: owner, token: token, expiry: expiry, at: now)
        case .renew(let owner, let token, let expiry):
            next = try renew(snapshot, owner: owner, token: token, expiry: expiry, at: now)
        case .start(let owner, let token):
            next = try start(snapshot, owner: owner, token: token, at: now)
        case .succeed(let owner, let token, let result, let input, let sourceRevision):
            next = try succeed(
                snapshot,
                material: SuccessMaterial(
                    owner: owner,
                    token: token,
                    result: result,
                    currentInput: input,
                    currentTranscriptRevision: sourceRevision),
                at: now)
        case .fail(let owner, let token, let code):
            next = try fail(snapshot, owner: owner, token: token, code: code, at: now)
        case .cancel:
            next = try terminal(snapshot, state: .cancelled, at: now)
        case .supersede:
            next = try terminal(snapshot, state: .superseded, at: now)
        }
        try validate(next)
        return next
    }

    public static func validate(_ snapshot: DeferredMacWorkSnapshot) throws {
        let hasLease = snapshot.executionOwnerDeviceID != nil
            && snapshot.leaseToken != nil
            && snapshot.leaseExpiresAt?.timeIntervalSinceReferenceDate.isFinite == true
        let hasNoLease = snapshot.executionOwnerDeviceID == nil
            && snapshot.leaseToken == nil
            && snapshot.leaseExpiresAt == nil
        let noOutcome = snapshot.resultFingerprint == nil && snapshot.failureCode == nil
        let valid: Bool
        switch snapshot.state {
        case .queued:
            valid = snapshot.attempt == 0 && !hasLease && noOutcome
        case .claimed, .running:
            valid = snapshot.attempt > 0 && hasLease && noOutcome
        case .succeeded:
            valid = snapshot.attempt > 0 && hasLease
                && snapshot.resultFingerprint.map(isFingerprint) == true
                && snapshot.failureCode == nil
        case .failed:
            valid = snapshot.attempt > 0 && hasLease
                && snapshot.resultFingerprint == nil
                && snapshot.failureCode.map(isFailureCode) == true
        case .cancelled, .superseded:
            valid = noOutcome
        }
        guard snapshot.formatVersion == DeferredMacWorkSnapshot.currentFormatVersion,
              snapshot.revision >= 0,
              snapshot.attempt <= snapshot.request.maxAttempts,
              snapshot.updatedAt.timeIntervalSinceReferenceDate.isFinite,
              snapshot.updatedAt >= snapshot.request.requestedAt,
              hasLease || hasNoLease,
              valid
        else { throw DeferredMacWorkContractError.invalidSnapshot }
    }

    fileprivate static func isFingerprint(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }
}

private extension DeferredMacWorkPolicy {
    struct SuccessMaterial {
        let owner: UUID
        let token: UUID
        let result: String
        let currentInput: String
        let currentTranscriptRevision: Int
    }

    struct SnapshotMutation {
        let state: DeferredMacWorkState
        let attempt: Int
        let owner: UUID?
        let token: UUID?
        let expiry: Date?
        let result: String?
        let failure: String?
        let updatedAt: Date
    }

    static func claim(
        _ current: DeferredMacWorkSnapshot,
        owner: UUID,
        token: UUID,
        expiry: Date,
        at now: Date
    ) throws -> DeferredMacWorkSnapshot {
        let nextAttempt: Int
        switch current.state {
        case .queued:
            nextAttempt = 1
        case .failed:
            nextAttempt = current.attempt + 1
        case .claimed, .running:
            guard let currentExpiry = current.leaseExpiresAt,
                  now >= currentExpiry
            else { throw DeferredMacWorkContractError.leaseUnavailable }
            nextAttempt = current.attempt + 1
        case .succeeded, .cancelled, .superseded:
            throw DeferredMacWorkContractError.invalidTransition
        }
        guard nextAttempt <= current.request.maxAttempts else {
            throw DeferredMacWorkContractError.attemptsExhausted
        }
        try validateLease(expiry, at: now)
        return snapshot(
            from: current,
            mutation: SnapshotMutation(
                state: .claimed,
                attempt: nextAttempt,
                owner: owner,
                token: token,
                expiry: expiry,
                result: nil,
                failure: nil,
                updatedAt: now))
    }

    static func renew(
        _ current: DeferredMacWorkSnapshot,
        owner: UUID,
        token: UUID,
        expiry: Date,
        at now: Date
    ) throws -> DeferredMacWorkSnapshot {
        guard current.state == .claimed || current.state == .running else {
            throw DeferredMacWorkContractError.invalidTransition
        }
        try requireLease(current, owner: owner, token: token, at: now)
        try validateLease(expiry, at: now)
        return snapshot(
            from: current,
            mutation: SnapshotMutation(
                state: current.state,
                attempt: current.attempt,
                owner: owner,
                token: token,
                expiry: expiry,
                result: nil,
                failure: nil,
                updatedAt: now))
    }

    static func start(
        _ current: DeferredMacWorkSnapshot,
        owner: UUID,
        token: UUID,
        at now: Date
    ) throws -> DeferredMacWorkSnapshot {
        guard current.state == .claimed else {
            throw DeferredMacWorkContractError.invalidTransition
        }
        try requireLease(current, owner: owner, token: token, at: now)
        return snapshot(
            from: current,
            mutation: SnapshotMutation(
                state: .running,
                attempt: current.attempt,
                owner: owner,
                token: token,
                expiry: current.leaseExpiresAt,
                result: nil,
                failure: nil,
                updatedAt: now))
    }

    static func succeed(
        _ current: DeferredMacWorkSnapshot,
        material: SuccessMaterial,
        at now: Date
    ) throws -> DeferredMacWorkSnapshot {
        guard current.state == .running else {
            throw DeferredMacWorkContractError.invalidTransition
        }
        try requireLease(
            current,
            owner: material.owner,
            token: material.token,
            at: now)
        guard material.currentInput == current.request.inputFingerprint,
              material.currentTranscriptRevision == current.request.sourceTranscriptRevision
        else { throw DeferredMacWorkContractError.staleSource }
        guard isFingerprint(material.result) else {
            throw DeferredMacWorkContractError.invalidTransition
        }
        return snapshot(
            from: current,
            mutation: SnapshotMutation(
                state: .succeeded,
                attempt: current.attempt,
                owner: material.owner,
                token: material.token,
                expiry: current.leaseExpiresAt,
                result: material.result,
                failure: nil,
                updatedAt: now))
    }

    static func fail(
        _ current: DeferredMacWorkSnapshot,
        owner: UUID,
        token: UUID,
        code: String,
        at now: Date
    ) throws -> DeferredMacWorkSnapshot {
        guard current.state == .running, isFailureCode(code) else {
            throw DeferredMacWorkContractError.invalidTransition
        }
        try requireLease(current, owner: owner, token: token, at: now)
        return snapshot(
            from: current,
            mutation: SnapshotMutation(
                state: .failed,
                attempt: current.attempt,
                owner: owner,
                token: token,
                expiry: current.leaseExpiresAt,
                result: nil,
                failure: code,
                updatedAt: now))
    }

    static func terminal(
        _ current: DeferredMacWorkSnapshot,
        state: DeferredMacWorkState,
        at now: Date
    ) throws -> DeferredMacWorkSnapshot {
        guard ![.succeeded, .cancelled, .superseded].contains(current.state) else {
            throw DeferredMacWorkContractError.invalidTransition
        }
        return snapshot(
            from: current,
            mutation: SnapshotMutation(
                state: state,
                attempt: current.attempt,
                owner: current.executionOwnerDeviceID,
                token: current.leaseToken,
                expiry: current.leaseExpiresAt,
                result: nil,
                failure: nil,
                updatedAt: now))
    }

    static func requireLease(
        _ current: DeferredMacWorkSnapshot,
        owner: UUID,
        token: UUID,
        at now: Date
    ) throws {
        guard current.executionOwnerDeviceID == owner,
              current.leaseToken == token
        else { throw DeferredMacWorkContractError.leaseUnavailable }
        guard let expiry = current.leaseExpiresAt, now < expiry else {
            throw DeferredMacWorkContractError.leaseExpired
        }
    }

    static func validateLease(_ expiry: Date, at now: Date) throws {
        let duration = expiry.timeIntervalSince(now)
        guard expiry.timeIntervalSinceReferenceDate.isFinite,
              duration > 0,
              duration <= maximumLeaseDuration
        else { throw DeferredMacWorkContractError.invalidTransition }
    }

    static func isFailureCode(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...122).contains($0) || $0 == 45
        }
    }

    static func isExactReplay(
        _ transition: DeferredMacWorkTransition,
        of current: DeferredMacWorkSnapshot
    ) -> Bool {
        switch transition {
        case .claim(let owner, let token, let expiry):
            current.state == .claimed && sameLease(current, owner, token, expiry)
        case .renew(let owner, let token, let expiry):
            (current.state == .claimed || current.state == .running)
                && sameLease(current, owner, token, expiry)
        case .start(let owner, let token):
            current.state == .running && sameLeaseIdentity(current, owner, token)
        case .succeed(let owner, let token, let result, let input, let sourceRevision):
            current.state == .succeeded
                && sameLeaseIdentity(current, owner, token)
                && current.resultFingerprint == result
                && current.request.inputFingerprint == input
                && current.request.sourceTranscriptRevision == sourceRevision
        case .fail(let owner, let token, let code):
            current.state == .failed
                && sameLeaseIdentity(current, owner, token)
                && current.failureCode == code
        case .cancel:
            current.state == .cancelled
        case .supersede:
            current.state == .superseded
        }
    }

    static func sameLease(
        _ current: DeferredMacWorkSnapshot,
        _ owner: UUID,
        _ token: UUID,
        _ expiry: Date
    ) -> Bool {
        sameLeaseIdentity(current, owner, token) && current.leaseExpiresAt == expiry
    }

    static func sameLeaseIdentity(
        _ current: DeferredMacWorkSnapshot,
        _ owner: UUID,
        _ token: UUID
    ) -> Bool {
        current.executionOwnerDeviceID == owner && current.leaseToken == token
    }

    static func snapshot(
        from current: DeferredMacWorkSnapshot,
        mutation: SnapshotMutation
    ) -> DeferredMacWorkSnapshot {
        DeferredMacWorkSnapshot(
            request: current.request,
            state: mutation.state,
            revision: current.revision + 1,
            attempt: mutation.attempt,
            executionOwnerDeviceID: mutation.owner,
            leaseToken: mutation.token,
            leaseExpiresAt: mutation.expiry,
            resultFingerprint: mutation.result,
            failureCode: mutation.failure,
            updatedAt: mutation.updatedAt)
    }
}
