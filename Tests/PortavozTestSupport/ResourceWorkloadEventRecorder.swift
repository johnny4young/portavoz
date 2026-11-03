import Foundation
import PortavozCore

final class ResourceWorkloadEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ResourceWorkloadEvent] = []

    var events: [ResourceWorkloadEvent] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func receive(_ event: ResourceWorkloadEvent) {
        lock.lock()
        storage.append(event)
        lock.unlock()
    }
}
