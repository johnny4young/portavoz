import Foundation
import Observation

@MainActor
@Observable
final class SettingsSkillReceiptFocusState {
    typealias Sleep = @Sendable (Duration) async throws -> Void

    private(set) var requestID: UUID?

    private var inspectedReceiptID: UUID?
    @ObservationIgnored private var restorationGeneration = 0
    @ObservationIgnored private var restorationTask: Task<Void, Never>?
    @ObservationIgnored private let sleep: Sleep

    init(
        sleep: @escaping Sleep = { duration in
            try await Task.sleep(for: duration)
        }
    ) {
        self.sleep = sleep
    }

    func beginInspection(of receiptID: UUID) {
        invalidateRestoration()
        inspectedReceiptID = receiptID
        requestID = nil
    }

    func clear() {
        invalidateRestoration()
        inspectedReceiptID = nil
        requestID = nil
    }

    func restoreAfterDismissal(
        when isEligible: @escaping @MainActor () -> Bool
    ) {
        guard let receiptID = inspectedReceiptID else { return }
        inspectedReceiptID = nil
        invalidateRestoration()
        let generation = restorationGeneration
        let sleep = sleep

        restorationTask = Task { @MainActor [weak self] in
            do {
                // Let AppKit remove the sheet's focus scope first.
                try await sleep(.milliseconds(200))
            } catch {
                return
            }
            guard let self, restorationGeneration == generation else { return }
            restorationTask = nil
            guard isEligible() else { return }
            requestID = receiptID
        }
    }

    private func invalidateRestoration() {
        restorationGeneration &+= 1
        restorationTask?.cancel()
        restorationTask = nil
    }
}
