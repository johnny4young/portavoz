import DictationOwnership
import Foundation
import Testing

@testable import portavoz_app

struct LegacyDictationOwnershipReleaseTests {
    private static func participant(_ identifier: String, root: URL) -> DictationOwnership {
        DictationOwnership(
            participant: identifier, root: root,
            conditions: {
                ParticipantConditions(preferenceIsOn: true, missingForReadiness: nil, legacyPeerIsActive: false)
            },
            notificationName: "app.portavoz.release-tests.\(root.lastPathComponent)")
    }

    @Test
    func onlyTheShippingBuildWithARealLibraryTouchesTheSharedState() {
        #expect(LegacyDictationOwnershipRelease.applies(identifier: "app.portavoz.mac", usesTemporaryStore: false))
        #expect(!LegacyDictationOwnershipRelease.applies(identifier: "app.portavoz.mac", usesTemporaryStore: true))
        #expect(!LegacyDictationOwnershipRelease.applies(identifier: "app.portavoz.mac.dev", usesTemporaryStore: false))
        #expect(!LegacyDictationOwnershipRelease.applies(identifier: nil, usesTemporaryStore: false))
    }

    @Test
    func aLastOwnerFromOneXIsFreedAndAnotherOwnerIsLeftAlone() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("portavoz-release-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let portavoz = Self.participant("app.portavoz.mac", root: root)
        #expect(portavoz.claimAtFirstRun() == .changed(generation: 1), "1.x claimed at its first run")
        #expect(portavoz.status() == .owned)

        #expect(await LegacyDictationOwnershipRelease.relinquish(portavoz) == .changed(generation: 2))
        #expect(portavoz.status() != .owned)
        #expect(await LegacyDictationOwnershipRelease.relinquish(portavoz) == .noChange, "it never claims back")
    }
}
