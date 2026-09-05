import Foundation
import XCTest

extension XCUIApplication {
    func configureFeatureUITestHandshake(
        argument: String,
        name: String,
        readyEnvironmentKey: String,
        continueEnvironmentKey: String
    ) {
        if !launchArguments.contains(argument) {
            launchArguments.append(argument)
        }
        guard let processTemporaryPath = launchEnvironment["TMPDIR"],
              !processTemporaryPath.isEmpty
        else {
            XCTFail("the app launch must own an isolated TMPDIR before handshakes")
            return
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: processTemporaryPath,
            isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            XCTFail("the app launch TMPDIR must exist before handshakes")
            return
        }
        let signalID = UUID().uuidString
        let temporaryDirectory = URL(
            fileURLWithPath: processTemporaryPath,
            isDirectory: true)
        launchEnvironment[readyEnvironmentKey] =
            temporaryDirectory.appending(
                path: "portavoz-uitest-\(name)-ready-\(signalID)").path
        launchEnvironment[continueEnvironmentKey] =
            temporaryDirectory.appending(
                path: "portavoz-uitest-\(name)-continue-\(signalID)").path
    }

    @MainActor
    func waitForFeatureUITestHandshakeReady(
        readyEnvironmentKey: String,
        timeout: TimeInterval = 10
    ) -> Bool {
        guard let readyPath = launchEnvironment[readyEnvironmentKey] else {
            return false
        }
        return waitForUITestCondition(timeout: timeout, pollInterval: 0.02) {
            FileManager.default.fileExists(atPath: readyPath)
        }
    }

    @MainActor
    func waitForFeatureUITestHandshakeRelease(
        readyEnvironmentKey: String,
        timeout: TimeInterval = 10
    ) -> Bool {
        guard let readyPath = launchEnvironment[readyEnvironmentKey] else {
            return false
        }
        return waitForUITestCondition(timeout: timeout, pollInterval: 0.02) {
            !FileManager.default.fileExists(atPath: readyPath)
        }
    }

    @MainActor
    func continueFeatureUITestHandshake(
        readyEnvironmentKey: String,
        continueEnvironmentKey: String,
        timeout: TimeInterval = 10
    ) -> Bool {
        guard let readyPath = launchEnvironment[readyEnvironmentKey],
              let continuePath = launchEnvironment[continueEnvironmentKey]
        else {
            return false
        }
        let fileManager = FileManager.default
        defer {
            try? fileManager.removeItem(atPath: readyPath)
            try? fileManager.removeItem(atPath: continuePath)
        }
        guard waitForFeatureUITestHandshakeReady(
            readyEnvironmentKey: readyEnvironmentKey,
            timeout: timeout)
        else {
            return false
        }
        guard fileManager.createFile(atPath: continuePath, contents: Data()) else {
            return false
        }
        return waitForFeatureUITestHandshakeRelease(
            readyEnvironmentKey: readyEnvironmentKey,
            timeout: timeout)
    }
}
