import AppKit
import Observation

/// The real inserter must run in the app's process, not XCTest's sandboxed
/// runner. This explicit fixture can address only its disposable receiver and
/// UUID-named clipboard; it never requests trust or accesses the general board.
@MainActor
@Observable
final class DictationNativeUITestFixture {
    static let pasteboardPrefix = "app.portavoz.dictation-test."
    static let environmentKey = "PORTAVOZ_UI_TEST_DICTATION_PASTEBOARD"
    private let pasteboardName: String
    private(set) var status = "idle"
    @ObservationIgnored private var task: Task<Void, Never>?

    init?(arguments: [String], environment: [String: String], usesTemporaryStore: Bool) {
        guard usesTemporaryStore, arguments.contains("-seed-dictation-native"),
              let name = environment[Self.environmentKey], name.hasPrefix(Self.pasteboardPrefix),
              UUID(uuidString: String(name.dropFirst(Self.pasteboardPrefix.count))) != nil
        else { return nil }
        pasteboardName = name
    }

    func start() {
        guard task == nil else { return }
        status = "waiting-for-receiver"
        task = Task { [weak self] in await self?.deliverOnce() }
    }

    private func deliverOnce() async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline, !Task.isCancelled {
            if let receiver = NSWorkspace.shared.frontmostApplication,
               receiver.bundleIdentifier == "app.portavoz.dictation-test-receiver", !receiver.isTerminated {
                guard TextInserter.canInsert(promptIfNeeded: false) else {
                    status = "accessibility-required-for-app"
                    return
                }
                // Launch can precede first-responder installation. Read-only
                // readiness may repeat; the insertion itself never does.
                if TextInserter.focusedFieldSecurity() == .regular {
                    let board = NSPasteboard(name: .init(pasteboardName))
                    let result = await TextInserter.insert(
                        "Don't delete — no borres: café, C++, 1.250,50 €.", pasteboard: board,
                        eventTarget: .process(receiver.processIdentifier))
                    status = String(describing: result)
                    return
                }
            }
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
        }
        status = "receiver-unavailable"
    }
}
