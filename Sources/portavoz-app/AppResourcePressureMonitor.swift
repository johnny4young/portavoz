import Dispatch
import Foundation
import PortavozCore

/// Latest content-free host pressure observed by the macOS process.
struct AppResourcePressureSnapshot: Equatable, Sendable {
    let memory: ResourceMemoryPressure
    let thermal: ResourceThermalState

    static let nominal = AppResourcePressureSnapshot(
        memory: .nominal,
        thermal: .nominal)

    var requestsIdleModelRelease: Bool {
        memory != .nominal || thermal == .serious || thermal == .critical
    }
}

/// Process-scoped bridge from macOS pressure notifications to the pure
/// resource-governor policy. It observes only categorical host state and never
/// receives model identity, meeting content, paths, or audio callbacks.
final class AppResourcePressureMonitor: @unchecked Sendable {
    typealias Receiver = @Sendable (AppResourcePressureSnapshot) -> Void

    private let lock = NSLock()
    private let memorySource: DispatchSourceMemoryPressure
    private let receiver: Receiver
    private var thermalObserver: NSObjectProtocol?
    private var memoryPressure = ResourceMemoryPressure.nominal
    private var thermalState: ResourceThermalState

    init(
        processInfo: ProcessInfo = .processInfo,
        receiver: @escaping Receiver
    ) {
        self.receiver = receiver
        thermalState = Self.thermalState(processInfo.thermalState)
        memorySource = DispatchSource.makeMemoryPressureSource(
            eventMask: [.normal, .warning, .critical],
            queue: .main)
        memorySource.setEventHandler { [weak self, weak memorySource] in
            guard let self, let memorySource else { return }
            self.receiveMemoryPressure(memorySource.data)
        }
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: processInfo,
            queue: .main
        ) { [weak self, weak processInfo] _ in
            guard let self, let processInfo else { return }
            self.receiveThermalState(processInfo.thermalState)
        }
        memorySource.activate()
        publishCurrent()
    }

    deinit {
        memorySource.cancel()
        if let thermalObserver {
            NotificationCenter.default.removeObserver(thermalObserver)
        }
    }

    var current: AppResourcePressureSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return AppResourcePressureSnapshot(
            memory: memoryPressure,
            thermal: thermalState)
    }

    static func memoryPressure(
        _ event: DispatchSource.MemoryPressureEvent
    ) -> ResourceMemoryPressure {
        if event.contains(.critical) { return .critical }
        if event.contains(.warning) { return .warning }
        return .nominal
    }

    static func thermalState(
        _ state: ProcessInfo.ThermalState
    ) -> ResourceThermalState {
        switch state {
        case .nominal:
            .nominal
        case .fair:
            .fair
        case .serious:
            .serious
        case .critical:
            .critical
        @unknown default:
            .fair
        }
    }

    private func receiveMemoryPressure(
        _ event: DispatchSource.MemoryPressureEvent
    ) {
        lock.lock()
        memoryPressure = Self.memoryPressure(event)
        let snapshot = AppResourcePressureSnapshot(
            memory: memoryPressure,
            thermal: thermalState)
        lock.unlock()
        receiver(snapshot)
    }

    private func receiveThermalState(
        _ state: ProcessInfo.ThermalState
    ) {
        lock.lock()
        thermalState = Self.thermalState(state)
        let snapshot = AppResourcePressureSnapshot(
            memory: memoryPressure,
            thermal: thermalState)
        lock.unlock()
        receiver(snapshot)
    }

    private func publishCurrent() {
        receiver(current)
    }
}
