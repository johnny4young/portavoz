import CryptoKit
import Foundation
import ModelStoreKit
@testable import PortavozCLIKit
import Testing

struct CLIModelStoreTests {
    @Test func aModelsFolderFromBeforeTheSharedStoreKeepsItsModels() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data("old layout weights".utf8)
        let descriptor = ModelDescriptor(
            id: "cli-fixture", tasks: [.liveTranscription], displayName: "CLI fixture", folderName: "cli-fixture-folder",
            resolveBase: root.appendingPathComponent("no-such-source"), revision: "fixture",
            artifacts: [ModelArtifact(
                path: "weights.bin",
                sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
                sizeBytes: bytes.count)],
            minimumRAMGB: 0, license: "fixture")
        let folder = root.appendingPathComponent(descriptor.folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try bytes.write(to: folder.appendingPathComponent("weights.bin"))

        let installation = await CLISupport.modelStore(fromModelsDir: root.path).verifiedInstallation(descriptor)

        #expect(installation != nil)
    }
}
