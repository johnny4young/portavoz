import ApplicationKit
import Foundation
import Observation

enum SettingsTransferFileOperation {
    case exportFile
    case importFile
}

@MainActor
protocol SettingsTransferClient: AnyObject {
    func portableSettingsSnapshot() throws -> [PortableSettingsKey: PortableSettingsValue]
    func applyPortableSettings(_ review: PortableSettingsReview) throws -> Int
    func selectSettingsFile(_ operation: SettingsTransferFileOperation) -> URL?
    func readSettingsFile(_ url: URL) async throws -> Data
    func writeSettingsFile(_ data: Data, to url: URL) async throws
}

@MainActor
@Observable
final class SettingsTransferModel {
    private(set) var isWorking = false
    private(set) var review: PortableSettingsReview?
    private(set) var status: String?
    @ObservationIgnored private var generation = UUID()

    func export(using client: any SettingsTransferClient) async {
        guard !isWorking, review == nil else { return }
        isWorking = true
        status = nil
        defer { isWorking = false }
        do {
            let data = try PortableSettingsTransfer.export(client.portableSettingsSnapshot())
            guard let destination = client.selectSettingsFile(.exportFile) else { return }
            try await client.writeSettingsFile(data, to: destination)
            status = L10n.text("Settings file saved. Keep it private: it includes your vocabulary and replacements.")
        } catch {
            status = L10n.text(
                "Could not export settings. Check your saved preferences and destination, then try again.")
        }
    }

    func importFile(using client: any SettingsTransferClient) async {
        guard !isWorking, review == nil else { return }
        isWorking = true
        status = nil
        let request = UUID()
        generation = request
        defer { isWorking = false }
        do {
            guard let source = client.selectSettingsFile(.importFile) else { return }
            let current = try client.portableSettingsSnapshot()
            let data = try await client.readSettingsFile(source)
            let prepared = try await Task.detached(priority: .utility) {
                try PortableSettingsTransfer.review(data, current: current)
            }.value
            try Task.checkCancellation()
            guard generation == request else { return }
            if prepared.changes.isEmpty {
                status = L10n.text("No settings to change. Your current preferences are unchanged.")
            } else {
                review = prepared
            }
        } catch {
            guard generation == request else { return }
            status = L10n.text("Could not import settings. Choose a supported Portavoz settings file.")
        }
    }

    func apply(using client: any SettingsTransferClient) {
        guard !isWorking, let review else { return }
        do {
            let count = try client.applyPortableSettings(review)
            self.review = nil
            status = L10n.format("Imported %lld settings. Permissions and feature activation are unchanged.", count)
        } catch PortableSettingsFailure.captureActive {
            status = L10n.text("Finish recording or dictation before applying settings. Your review is still open.")
        } catch PortableSettingsFailure.staleReview {
            status = L10n.text(
                "Preferences changed during review. Cancel and import again to review the current values.")
        } catch {
            status = L10n.text("Could not apply settings. Cancel and review the file again.")
        }
    }

    func cancelReview() {
        generation = UUID()
        review = nil
        status = nil
    }
}
