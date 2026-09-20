import Foundation
import IntelligenceKit

/// `portavoz-app --bundled-assets-status` reports where this install resolved
/// its bundled Apuntador classifier, then exits.
///
/// The release verifier runs it on the extracted app so a payload that only
/// resolves on the machine that built it fails before publication instead of
/// ending the app at a user's first recording. The output carries one absolute
/// path from the app's own bundle and no user data.
enum BundledAssetsStatus {
    static let flag = "--bundled-assets-status"

    /// Content-free, stable report the distribution verifier parses.
    static func report(bundleURL: URL?, loadable: Bool) -> String {
        let payload: [String: String] = [
            "classifierBundle": bundleURL?.path ?? "",
            "classifierLoadable": loadable ? "true" : "false"
        ]
        return payload
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "\n")
    }

    static func runIfRequested(arguments: [String] = ProcessInfo.processInfo.arguments) {
        guard arguments.contains(flag) else { return }
        let bundleURL = IntelligenceResourceBundle.resolved?.bundleURL
        let loadable = BundledLiveQuestionDetector.resourceIsLoadable
        print(report(bundleURL: bundleURL, loadable: loadable))
        exit(bundleURL != nil && loadable ? 0 : 1)
    }
}
