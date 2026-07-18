import ApplicationKit
import Foundation
import Observation

@MainActor
protocol FirstRunModelClient: AnyObject {
    func resolveFirstRun() async throws -> ResolveFirstRunExperience.Resolution
    func markFirstRunCompleted()
}

/// Process-scoped presentation owner for the welcome experience. Restored main
/// windows share one resolution and cannot present competing setup sheets.
@MainActor
@Observable
final class FirstRunModel {
    private(set) var isPresented = false
    private(set) var hasResolved = false
    private var presentationHostID: UUID?
    private var activeHostIDs: [UUID] = []

    private let client: any FirstRunModelClient
    @ObservationIgnored private var resolutionTask: Task<Void, Never>?

    init(client: any FirstRunModelClient) {
        self.client = client
    }

    func register(hostID: UUID) {
        guard !activeHostIDs.contains(hostID) else { return }
        activeHostIDs.append(hostID)
        if isPresented, presentationHostID == nil {
            presentationHostID = hostID
        }
    }

    func unregister(hostID: UUID) {
        activeHostIDs.removeAll { $0 == hostID }
        guard presentationHostID == hostID else { return }
        presentationHostID = isPresented ? activeHostIDs.first : nil
    }

    func resolve(in hostID: UUID) async {
        register(hostID: hostID)
        guard !hasResolved else { return }
        if let resolutionTask {
            await resolutionTask.value
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performResolution(in: hostID)
        }
        resolutionTask = task
        await task.value
    }

    private func performResolution(in hostID: UUID) async {
        defer { resolutionTask = nil }
        do {
            let resolution = try await client.resolveFirstRun()
            if resolution.shouldMarkCompleted {
                client.markFirstRunCompleted()
            }
            isPresented = resolution.shouldPresent
            presentationHostID = resolution.shouldPresent
                ? preferredPresentationHost(startingWith: hostID)
                : nil
            hasResolved = true
        } catch is CancellationError {
            // A later main window or relaunch may resolve the decision.
        } catch {
            // A failure must not silently hide first-run guidance.
            isPresented = true
            presentationHostID = preferredPresentationHost(startingWith: hostID)
            hasResolved = true
        }
    }

    private func preferredPresentationHost(startingWith hostID: UUID) -> UUID? {
        activeHostIDs.contains(hostID) ? hostID : activeHostIDs.first
    }

    func finish() {
        client.markFirstRunCompleted()
        hasResolved = true
        isPresented = false
        presentationHostID = nil
    }

    func isPresented(in hostID: UUID) -> Bool {
        isPresented && presentationHostID == hostID
    }

    func setPresented(_ value: Bool, in hostID: UUID) {
        guard presentationHostID == hostID else { return }
        isPresented = value
        if !value { presentationHostID = nil }
    }
}
