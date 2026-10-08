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
    static let controlEnvironmentKey = "PORTAVOZ_UI_TEST_DICTATION_CONTROL_PASTEBOARD"
    private static let outputText = "Don't delete — no borres: café, C++, 1.250,50 €."
    private let pasteboardName: String
    private let runsController: Bool
    private let controlPasteboardName: String?
    private(set) var status = "idle"
    @ObservationIgnored private var task: Task<Void, Never>?

    init?(arguments: [String], environment: [String: String], usesTemporaryStore: Bool) {
        guard usesTemporaryStore, arguments.contains("-seed-dictation-native"),
              let name = Self.validPasteboardName(environment[Self.environmentKey])
        else { return nil }
        runsController = arguments.contains("-seed-dictation-native-controller")
        controlPasteboardName = Self.validPasteboardName(environment[Self.controlEnvironmentKey])
        guard !runsController || (arguments.contains("-seed-dictation")
            && arguments.contains("-seed-dictation-english")
            && controlPasteboardName != nil && controlPasteboardName != name) else { return nil }
        pasteboardName = name
    }

    static func validPasteboardName(_ name: String?) -> String? {
        guard let name, name.hasPrefix(pasteboardPrefix),
              UUID(uuidString: String(name.dropFirst(pasteboardPrefix.count))) != nil else { return nil }
        return name
    }

    func start(
        controller: DictationController? = nil, dependencies: DictationSessionDependencies? = nil,
        postingPreflight: () -> Bool = { CGPreflightPostEventAccess() }
    ) {
        guard task == nil else { return }
        guard !runsController || (controller != nil && dependencies != nil) else {
            status = "controller-required"
            return
        }
        // AX inspection and event synthesis have separate public preflights.
        // A constructed CGEvent is not proof that macOS will deliver it. This
        // fixture diagnoses denied posting without requesting or granting it.
        guard postingPreflight() else {
            status = "event-posting-required-for-app"
            return
        }
        status = "waiting-for-receiver"
        task = Task { [weak self, weak controller] in
            await self?.deliverOnce(controller: controller, dependencies: dependencies)
        }
    }

    private func deliverOnce(controller: DictationController?, dependencies: DictationSessionDependencies?) async {
        // Arming precedes the receiver's launch, so readiness is timed from its arrival.
        var deadline = ContinuousClock.now.advanced(by: .seconds(20))
        var receiverSeen = false
        while ContinuousClock.now < deadline, !Task.isCancelled {
            if let receiver = NSWorkspace.shared.frontmostApplication,
               receiver.bundleIdentifier == "app.portavoz.dictation-test-receiver", !receiver.isTerminated {
                if !receiverSeen {
                    receiverSeen = true
                    deadline = ContinuousClock.now.advanced(by: .seconds(5))
                }
                guard TextInserter.canInsert(promptIfNeeded: false) else {
                    status = "accessibility-required-for-app"
                    return
                }
                // A regular focused window/button can retry but cannot provide
                // the known receiver's text metadata. Probe before the one paste.
                if receiverHasReadableSelection(receiver) {
                    let board = NSPasteboard(name: .init(pasteboardName))
                    let destination = TextInserter.captureDestination(pasteboard: board, matching: receiver)
                    if destination.canRetry {
                        if runsController {
                            guard let controller, var dependencies, let controlPasteboardName else {
                                status = "controller-required"
                                return
                            }
                            // The controller still captures its destination at admission.
                            // The earlier capture witnesses only receiver readiness.
                            dependencies.canInsert = { TextInserter.canInsert(promptIfNeeded: false) }
                            dependencies.captureDestination = {
                                TextInserter.captureDestination(pasteboard: board, matching: receiver)
                            }
                            dependencies.copyText = { TextInserter.copy($0, to: board) }
                            status = "controller-listening"
                            status = await DictationNativeControllerUITestFixture.run(
                                controller: controller, dependencies: dependencies,
                                stopRequested: {
                                    NSPasteboard(name: .init(controlPasteboardName)).string(forType: .string) == "stop"
                                })
                        } else {
                            let result = await destination.insert(Self.outputText)
                            status = String(describing: result)
                        }
                        return
                    }
                }
            }
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
        }
        status = receiverSeen ? "receiver-focus-unavailable" : "receiver-unavailable"
    }

    private func receiverHasReadableSelection(_ receiver: NSRunningApplication) -> Bool {
        guard let element = TextInserter.focusedApplicationElement(receiver.processIdentifier),
              TextInserter.fieldSecurity(of: element) == .regular,
              let readback = DictationTextReadback.accessibility(element) else { return false }
        return readback.baseline(for: Self.outputText) != nil
    }
}
