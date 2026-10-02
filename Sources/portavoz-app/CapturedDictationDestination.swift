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
    @MainActor
    struct Target {
        let processID: pid_t
        /// Nil permits this exact attempt. Revalidation never activates an app.
        let validate: () -> InsertionResult?
    }

    @MainActor
    static func captureDestination(
        pasteboard: NSPasteboard = .general, matching expectedApplication: NSRunningApplication? = nil
    ) -> CapturedDictationDestination {
        let application = NSWorkspace.shared.frontmostApplication
        guard canInsert(promptIfNeeded: false), let application,
              application.processIdentifier > 0, !application.isTerminated,
              expectedApplication.map({ application.isEqual($0) }) ?? true,
              let element = focusedElement(in: AXUIElementCreateApplication(application.processIdentifier)) else {
            return .unavailable(name: application?.localizedName, result: .focusUnavailable)
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

}
