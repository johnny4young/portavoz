import Darwin
import Foundation
import XCTest

final class UITestScratchTests: XCTestCase {
    func testOnlyUITestTargetReceivesTheExactSharedDirectoryEntitlement() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let key = "com.apple.security.temporary-exception.files.absolute-path.read-write"
        let entitlementPath = "packaging/portavoz-uitests.entitlements"
        let data = try Data(contentsOf: repository.appendingPathComponent(entitlementPath))
        let entitlement = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(Set(entitlement.keys), [key])
        XCTAssertEqual(entitlement[key] as? [String], [UITestScratch.sharedBase.path + "/"])
        for file in ["portavoz.entitlements", "portavoz-local.entitlements"] {
            let bytes = try Data(contentsOf: repository.appendingPathComponent("packaging/" + file))
            let production = try XCTUnwrap(
                PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any])
            XCTAssertNil(production[key])
        }
        let project = try String(contentsOf: repository.appendingPathComponent("project.yml"), encoding: .utf8)
        let targets = project.components(separatedBy: "\n  PortavozUITests:\n")
        XCTAssertEqual(targets.count, 2)
        XCTAssertFalse(try XCTUnwrap(targets.first).contains(entitlementPath))
        XCTAssertTrue(try XCTUnwrap(targets.last).contains("CODE_SIGN_ENTITLEMENTS: " + entitlementPath))
    }

    func testSharedRootIsPrivateAndIndependentOfRunnerContainer() throws {
        let scratch = try UITestScratch()
        defer { try? scratch.remove() }
        XCTAssertEqual(scratch.url.deletingLastPathComponent(), UITestScratch.sharedBase)
        var information = stat()
        XCTAssertEqual(lstat(scratch.url.path, &information), 0)
        XCTAssertEqual(information.st_uid, getuid())
        XCTAssertEqual(information.st_mode & 0o777, 0o700)
        let first = try UITestScratch(parent: scratch.url)
        let second = try UITestScratch(parent: scratch.url)
        XCTAssertNotEqual(first.url, second.url)
        XCTAssertEqual(first.url.deletingLastPathComponent(), scratch.url)
        let text = "Don’t delete this. No borres esto."
        let file = first.url.appendingPathComponent("señal.txt")
        try text.write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), text)
    }

    func testSharedBaseRejectsSymlinksFilesAndWidePermissionsWithoutMutatingThem() throws {
        let scratch = try UITestScratch()
        defer { try? scratch.remove() }
        let folder = scratch.url.appendingPathComponent("wide")
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        let file = scratch.url.appendingPathComponent("file")
        try Data("keep".utf8).write(to: file)
        let link = scratch.url.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: scratch.url)
        for candidate in [folder, file, link] {
            XCTAssertThrowsError(try UITestScratch.prepareSharedBase(at: candidate)) {
                XCTAssertEqual($0 as? UITestScratch.Failure, .unsafeSharedBase)
            }
        }
        let permissions = try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o755)
        XCTAssertEqual(try Data(contentsOf: file), Data("keep".utf8))
    }

    func testAllocationRejectsMissingOrNonDirectoryParents() throws {
        let scratch = try UITestScratch()
        defer { try? scratch.remove() }
        let file = scratch.url.appendingPathComponent("occupied")
        try Data().write(to: file)
        for parent in [file, scratch.url.appendingPathComponent("missing")] {
            XCTAssertThrowsError(try UITestScratch(parent: parent)) { error in
                guard case UITestScratch.Failure.allocation = error else {
                    return XCTFail("Unexpected allocation error: \(error)")
                }
            }
        }
        XCTAssertEqual(try Data(contentsOf: file), Data())
    }

    func testCleanupRefusesAReplacedRootAndNeverFollowsItsSymlink() throws {
        let parent = try UITestScratch()
        let outside = try UITestScratch()
        defer { try? parent.remove(); try? outside.remove() }
        let owned = try UITestScratch(parent: parent.url)
        let displaced = parent.url.appendingPathComponent("original")
        let marker = outside.url.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: marker)
        try FileManager.default.moveItem(at: owned.url, to: displaced)
        try FileManager.default.createSymbolicLink(at: owned.url, withDestinationURL: outside.url)
        XCTAssertThrowsError(try owned.remove()) {
            XCTAssertEqual($0 as? UITestScratch.Failure, .ownershipChanged)
        }
        XCTAssertEqual(try Data(contentsOf: marker), Data("keep".utf8))
        try FileManager.default.removeItem(at: owned.url)
        try FileManager.default.createDirectory(at: owned.url, withIntermediateDirectories: false)
        XCTAssertThrowsError(try owned.remove()) {
            XCTAssertEqual($0 as? UITestScratch.Failure, .ownershipChanged)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: displaced.path))
    }

    func testCleanupRemovesOnlyOwnedTreeAndIsIdempotent() throws {
        let owned = try UITestScratch()
        let outside = try UITestScratch()
        defer { try? owned.remove(); try? outside.remove() }
        let marker = outside.url.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: marker)
        try FileManager.default.createSymbolicLink(
            at: owned.url.appendingPathComponent("external"), withDestinationURL: outside.url)
        try owned.remove()
        try owned.remove()
        XCTAssertFalse(FileManager.default.fileExists(atPath: owned.url.path))
        XCTAssertEqual(try Data(contentsOf: marker), Data("keep".utf8))
    }
}
