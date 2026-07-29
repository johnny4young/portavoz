import Foundation
import PortavozCore

/// Thread-safe process owner for the pure Core residency ledger.
///
/// Most model adapters are MainActor-bound, while the semantic runtime is an
/// actor shared by Ask and Library. Keeping the lock in composition lets both
/// use the same ledger without moving platform scheduling into Core.
final class AppModelResidencyLedger: @unchecked Sendable {
    private let lock = NSLock()
    private var ledger = ResourceModelResidencyLedger()

    func beginLoad(
        _ family: ResourceModelFamily
    ) -> ResourceModelLoadTicket? {
        withLedger { $0.beginLoad(family) }
    }

    @discardableResult
    func finishLoad(
        _ ticket: ResourceModelLoadTicket,
        measuredFootprintBytes: UInt64?
    ) -> Bool {
        withLedger {
            $0.finishLoad(
                ticket,
                measuredFootprintBytes: measuredFootprintBytes)
        }
    }

    /// Publishes a cold runtime and claims its first borrower atomically.
    func finishLoadAndBeginUse(
        _ ticket: ResourceModelLoadTicket,
        measuredFootprintBytes: UInt64?
    ) -> ResourceModelUseLease? {
        withLedger {
            guard $0.finishLoad(
                ticket,
                measuredFootprintBytes: measuredFootprintBytes)
            else { return nil }
            return $0.beginUse(ticket.family)
        }
    }

    @discardableResult
    func failLoad(_ ticket: ResourceModelLoadTicket) -> Bool {
        withLedger { $0.failLoad(ticket) }
    }

    func beginUse(
        _ family: ResourceModelFamily
    ) -> ResourceModelUseLease? {
        withLedger { $0.beginUse(family) }
    }

    @discardableResult
    func finishUse(_ lease: ResourceModelUseLease) -> Bool {
        withLedger { $0.finishUse(lease) }
    }

    func beginRelease(
        _ family: ResourceModelFamily
    ) -> ResourceModelReleaseTicket? {
        withLedger { $0.beginRelease(family) }
    }

    @discardableResult
    func finishRelease(_ ticket: ResourceModelReleaseTicket) -> Bool {
        withLedger { $0.finishRelease(ticket) }
    }

    @discardableResult
    func cancelRelease(_ ticket: ResourceModelReleaseTicket) -> Bool {
        withLedger { $0.cancelRelease(ticket) }
    }

    func record(
        for family: ResourceModelFamily
    ) -> ResourceModelResidencyRecord {
        withLedger { $0.record(for: family) }
    }

    var records: [ResourceModelResidencyRecord] {
        withLedger(\.records)
    }

    var residentModels: [ResourceResidentModel] {
        withLedger(\.residentModels)
    }

    private func withLedger<Result>(
        _ operation: (inout ResourceModelResidencyLedger) throws -> Result
    ) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try operation(&ledger)
    }
}
