import Foundation

/// Resolves this module's SwiftPM resource bundle where it is actually staged,
/// without trapping when it is missing.
///
/// The generated accessor checks only the `.app` root and one absolute build
/// directory from the machine that compiled the binary, then calls
/// `fatalError`. A packaged app therefore resolves its resources on the build
/// Mac alone and ends the process at first use everywhere else, instead of
/// disabling one optional feature.
public enum IntelligenceResourceBundle {
    static let bundleName = "Portavoz_IntelligenceKit"

    private final class BundleFinder {}

    /// Every location these resources are actually staged in, most specific
    /// first: `Contents/Resources` for the packaged app, the build directory
    /// for `swift test` and the command line.
    static func candidateURLs(
        mainResources: URL?,
        mainBundle: URL?,
        moduleResources: URL?,
        moduleContainer: URL?,
        executableDirectory: URL?
    ) -> [URL] {
        [mainResources, mainBundle, moduleResources, moduleContainer, executableDirectory]
            .compactMap { $0?.appendingPathComponent(bundleName + ".bundle") }
            .reduce(into: [URL]()) { unique, url in
                guard !unique.contains(where: {
                    $0.standardizedFileURL == url.standardizedFileURL
                }) else { return }
                unique.append(url)
            }
    }

    /// The first candidate that is a readable bundle, or `nil`. An entry only
    /// its builder can read reports `nil` here, exactly like a missing one.
    static func resolve(
        candidates: [URL],
        load: (URL) -> Bundle? = { Bundle(url: $0) }
    ) -> Bundle? {
        for candidate in candidates {
            if let bundle = load(candidate) { return bundle }
        }
        return nil
    }

    /// `nil` means the optional bundled assets are unavailable on this install.
    public static let resolved: Bundle? = {
        let module = Bundle(for: BundleFinder.self)
        return resolve(candidates: candidateURLs(
            mainResources: Bundle.main.resourceURL,
            mainBundle: Bundle.main.bundleURL,
            moduleResources: module.resourceURL,
            moduleContainer: module.bundleURL.deletingLastPathComponent(),
            executableDirectory: Bundle.main.executableURL?.deletingLastPathComponent()))
    }()

    static func url(forResource resource: String, withExtension extension: String) -> URL? {
        resolved?.url(forResource: resource, withExtension: `extension`)
    }
}
