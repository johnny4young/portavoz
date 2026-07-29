/// Lifecycle state of one heavyweight runtime family.
public enum ResourceModelResidencyStatus: String, CaseIterable, Sendable {
    case unloaded
    case loading
    case resident
    case releasing
}

/// Public, content-free view of one family. The ledger never stores model
/// names, paths, prompts, transcript content, or provider payloads.
public struct ResourceModelResidencyRecord: Equatable, Sendable {
    public let family: ResourceModelFamily
    public let status: ResourceModelResidencyStatus
    public let activeUseCount: Int
    public let measuredFootprintBytes: UInt64?

    public init(
        family: ResourceModelFamily,
        status: ResourceModelResidencyStatus,
        activeUseCount: Int,
        measuredFootprintBytes: UInt64?
    ) {
        self.family = family
        self.status = status
        self.activeUseCount = activeUseCount
        self.measuredFootprintBytes = measuredFootprintBytes
    }
}

/// Opaque identity for one accepted load attempt.
public struct ResourceModelLoadTicket: Equatable, Sendable {
    public let family: ResourceModelFamily
    fileprivate let generation: UInt64
}

/// Opaque identity for one active consumer of a resident runtime.
public struct ResourceModelUseLease: Equatable, Sendable {
    public let family: ResourceModelFamily
    fileprivate let generation: UInt64
}

/// Opaque identity for one accepted release transition.
public struct ResourceModelReleaseTicket: Equatable, Sendable {
    public let family: ResourceModelFamily
    fileprivate let generation: UInt64
}

/// Pure lifecycle ledger for heavyweight model families.
///
/// It is intentionally not a model cache, scheduler, timer, or platform
/// pressure observer. A process composition owner serializes mutations, keeps
/// the actual runtime instance in its capability module, and performs only the
/// transitions accepted here. Opaque generations reject stale async load,
/// use, and release completions.
public struct ResourceModelResidencyLedger: Equatable, Sendable {
    private struct Entry: Equatable, Sendable {
        var status: ResourceModelResidencyStatus = .unloaded
        var transitionGeneration: UInt64 = 0
        var activeUses: Set<UInt64> = []
        var measuredFootprintBytes: UInt64?
    }

    private var entries: [ResourceModelFamily: Entry] = [:]
    private var nextGeneration: UInt64 = 0

    public init() {}

    /// Starts one load only when no runtime or competing load exists.
    public mutating func beginLoad(
        _ family: ResourceModelFamily
    ) -> ResourceModelLoadTicket? {
        var entry = entry(for: family)
        guard entry.status == .unloaded else { return nil }
        let generation = makeGeneration()
        entry.status = .loading
        entry.transitionGeneration = generation
        entries[family] = entry
        return ResourceModelLoadTicket(
            family: family,
            generation: generation)
    }

    /// Publishes a runtime only for the current load attempt.
    @discardableResult
    public mutating func finishLoad(
        _ ticket: ResourceModelLoadTicket,
        measuredFootprintBytes: UInt64?
    ) -> Bool {
        var entry = entry(for: ticket.family)
        guard entry.status == .loading,
              entry.transitionGeneration == ticket.generation
        else { return false }
        entry.status = .resident
        entry.measuredFootprintBytes = measuredFootprintBytes
        entries[ticket.family] = entry
        return true
    }

    /// Returns a failed current load to the unloaded state. A late failure from
    /// an older attempt cannot remove a newer runtime.
    @discardableResult
    public mutating func failLoad(_ ticket: ResourceModelLoadTicket) -> Bool {
        var entry = entry(for: ticket.family)
        guard entry.status == .loading,
              entry.transitionGeneration == ticket.generation
        else { return false }
        entry = Entry()
        entries[ticket.family] = entry
        return true
    }

    /// Claims one resident runtime. Releasing and loading families reject new
    /// consumers until their current transition finishes or is cancelled.
    public mutating func beginUse(
        _ family: ResourceModelFamily
    ) -> ResourceModelUseLease? {
        var entry = entry(for: family)
        guard entry.status == .resident else { return nil }
        let generation = makeGeneration()
        entry.activeUses.insert(generation)
        entries[family] = entry
        return ResourceModelUseLease(
            family: family,
            generation: generation)
    }

    /// Ends exactly one active use. Duplicate or stale completions are inert.
    @discardableResult
    public mutating func finishUse(_ lease: ResourceModelUseLease) -> Bool {
        var entry = entry(for: lease.family)
        guard entry.status == .resident,
              entry.activeUses.remove(lease.generation) != nil
        else { return false }
        entries[lease.family] = entry
        return true
    }

    /// Moves an idle resident runtime into releasing. The caller must drop the
    /// actual instance and then finish this exact ticket.
    public mutating func beginRelease(
        _ family: ResourceModelFamily
    ) -> ResourceModelReleaseTicket? {
        var entry = entry(for: family)
        guard entry.status == .resident, entry.activeUses.isEmpty else {
            return nil
        }
        let generation = makeGeneration()
        entry.status = .releasing
        entry.transitionGeneration = generation
        entries[family] = entry
        return ResourceModelReleaseTicket(
            family: family,
            generation: generation)
    }

    /// Commits an accepted release after the runtime instance is gone.
    @discardableResult
    public mutating func finishRelease(
        _ ticket: ResourceModelReleaseTicket
    ) -> Bool {
        let current = entry(for: ticket.family)
        guard current.status == .releasing,
              current.transitionGeneration == ticket.generation
        else { return false }
        entries[ticket.family] = Entry()
        return true
    }

    /// Restores a runtime when the capability owner could not complete release.
    @discardableResult
    public mutating func cancelRelease(
        _ ticket: ResourceModelReleaseTicket
    ) -> Bool {
        var entry = entry(for: ticket.family)
        guard entry.status == .releasing,
              entry.transitionGeneration == ticket.generation
        else { return false }
        entry.status = .resident
        entry.transitionGeneration = makeGeneration()
        entries[ticket.family] = entry
        return true
    }

    public func record(
        for family: ResourceModelFamily
    ) -> ResourceModelResidencyRecord {
        let entry = entry(for: family)
        return ResourceModelResidencyRecord(
            family: family,
            status: entry.status,
            activeUseCount: entry.activeUses.count,
            measuredFootprintBytes: entry.measuredFootprintBytes)
    }

    /// Stable family order keeps diagnostics and policy fixtures deterministic.
    public var records: [ResourceModelResidencyRecord] {
        ResourceModelFamily.allCases.map(record)
    }

    /// Projection consumed by `ResourceGovernorSnapshot`. A releasing model
    /// remains resident until its capability owner confirms that the runtime
    /// instance is gone.
    public var residentModels: [ResourceResidentModel] {
        ResourceModelFamily.allCases.compactMap { family in
            let entry = entry(for: family)
            guard entry.status == .resident || entry.status == .releasing else {
                return nil
            }
            return ResourceResidentModel(
                family: family,
                measuredFootprintBytes: entry.measuredFootprintBytes,
                isIdle: entry.activeUses.isEmpty)
        }
    }

    private func entry(for family: ResourceModelFamily) -> Entry {
        entries[family] ?? Entry()
    }

    private mutating func makeGeneration() -> UInt64 {
        nextGeneration &+= 1
        if nextGeneration == 0 {
            nextGeneration = 1
        }
        return nextGeneration
    }
}
