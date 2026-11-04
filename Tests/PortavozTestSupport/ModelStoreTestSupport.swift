import Foundation
import ModelStoreKit

public extension ModelStore.Consumer {
    static let tests = ModelStore.Consumer(identifier: "app.portavoz.tests", displayName: "Portavoz tests")
}

public extension ModelStore {
    /// Real models for gated tests, cloned from the legacy install into a scratch
    /// store, so a test never claims or changes anything in the shared one.
    static func gatedTests() -> ModelStore {
        ModelStore(
            rootDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("portavoz-gated-models", isDirectory: true),
            consumer: .tests,
            legacyRoot: legacyRootDirectory)
    }
}
