import AppKit
import ApplicationServices

/// A session's destination and its delivery capability travel together. Names
/// are display-only; neither a name nor a bundle identifier authorizes a paste.
@MainActor
struct CapturedDictationDestination {
    let name: String?
    let canRetry: Bool
    let insert: (String) async -> TextInserter.InsertionResult

    static func unavailable(name: String?, result: TextInserter.InsertionResult) -> Self {
        Self(name: name, canRetry: false, insert: { _ in result })
    }
}

extension TextInserter {
    /// How the paste shortcut reaches the destination.
    enum EventRoute: Equatable {
        /// Posted only to the captured process: the pinned focused field was verified.
        case process
        /// The pre-destination session stream, used only when the application
        /// exposes no focused element to pin (some Electron, Java and remote
        /// clients). It keeps the previous delivery and checks instead of refusing.
        case session
    }

    @MainActor
    struct Target {
        let processID: pid_t
        /// Nil permits this exact attempt. Revalidation never activates an app.
        let validate: () -> InsertionResult?
        var route: EventRoute = .process
    }

    @MainActor
    static func captureDestination(
        pasteboard: NSPasteboard = .general, matching expectedApplication: NSRunningApplication? = nil
    ) -> CapturedDictationDestination {
        let application = NSWorkspace.shared.frontmostApplication
        guard canInsert(promptIfNeeded: false), let application,
              application.processIdentifier > 0, !application.isTerminated,
              expectedApplication.map({ application.isEqual($0) }) ?? true else {
            return .unavailable(name: application?.localizedName, result: .focusUnavailable)
        }
        guard let element = focusedElement(in: AXUIElementCreateApplication(application.processIdentifier)) else {
            // Nothing to pin. A fixture that names its receiver keeps waiting;
            // production never refuses where the previous delivery would work.
            guard expectedApplication == nil else {
                return .unavailable(name: application.localizedName, result: .focusUnavailable)
            }
            return sessionDestination(for: application, pasteboard: pasteboard)
        }
        let initialSecurity = fieldSecurity(of: element)
        guard initialSecurity == .regular else {
            return .unavailable(name: application.localizedName,
                                result: initialSecurity == .secure ? .secureField : .focusUnavailable)
        }
        let target = Target(processID: application.processIdentifier) {
            guard canInsert(promptIfNeeded: false) else { return .focusUnavailable }
            // Apple specifies NSRunningApplication equality for process identity,
            // not PID equality. launchDate is absent for non-LaunchServices apps.
            guard !application.isTerminated,
                  let current = NSWorkspace.shared.frontmostApplication,
                  application.isEqual(current), !current.isTerminated else { return .targetChanged }
            guard let focused = focusedElement(in: AXUIElementCreateApplication(current.processIdentifier)) else {
                return .focusUnavailable
            }
            guard CFEqual(element, focused) else { return .targetChanged }
            switch fieldSecurity(of: focused) {
            case .regular: return nil
            case .secure: return .secureField
            case .unavailable: return .focusUnavailable
            }
        }
        return CapturedDictationDestination(name: application.localizedName, canRetry: true) { text in
            await insert(text, into: target, pasteboard: pasteboard)
        }
    }

    /// The previous delivery contract for an application without an inspectable
    /// focused element at capture: same application still frontmost, then the
    /// system-wide focused field must be inspectable and not secure at delivery.
    @MainActor
    private static func sessionDestination(
        for application: NSRunningApplication, pasteboard: NSPasteboard
    ) -> CapturedDictationDestination {
        let target = Target(processID: application.processIdentifier, validate: {
            guard canInsert(promptIfNeeded: false) else { return .focusUnavailable }
            guard !application.isTerminated,
                  let current = NSWorkspace.shared.frontmostApplication,
                  application.isEqual(current), !current.isTerminated else { return .targetChanged }
            // Clicking Reinsert makes the non-activating panel key without
            // activating Portavoz; the session stream would paste there.
            let app = NSApplication.shared
            guard sessionStreamReachesFrontmostApplication(
                portavozIsActive: app.isActive, portavozHasKeyWindow: app.keyWindow != nil
            ) else { return .focusUnavailable }
            switch sessionFocusedFieldSecurity() {
            case .regular: return nil
            case .secure: return .secureField
            case .unavailable: return .focusUnavailable
            }
        }, route: .session)
        return CapturedDictationDestination(name: application.localizedName, canRetry: true) { text in
            await insert(text, into: target, pasteboard: pasteboard)
        }
    }

    /// Pure decision, split out for tests: an inactive Portavoz holds a key
    /// window only through its non-activating panel, which then receives the
    /// session keyboard stream instead of the frontmost application.
    static func sessionStreamReachesFrontmostApplication(
        portavozIsActive: Bool, portavozHasKeyWindow: Bool
    ) -> Bool {
        portavozIsActive || !portavozHasKeyWindow
    }

    /// Classification of whatever field currently owns system-wide keyboard
    /// focus; any failed or malformed inspection is unavailable, never regular.
    @MainActor
    static func sessionFocusedFieldSecurity() -> FocusedFieldSecurity {
        guard AXIsProcessTrusted(), let element = focusedElement(in: AXUIElementCreateSystemWide()) else {
            return .unavailable
        }
        return fieldSecurity(of: element)
    }
}
