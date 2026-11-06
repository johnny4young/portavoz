import CryptoKit
import Foundation
import PlatformKit
import XCTest

final class FileContentDigestTests: XCTestCase {
    private var workspace: URL!

    override func setUpWithError() throws {
        workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspace,
            withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: workspace)
    }

    func testDigestMatchesTheWholeFileAcrossChunkBoundaries() throws {
        let block = Data((0..<251).map { UInt8($0) })
        var bytes = Data()
        while bytes.count < (3 << 20) + 17 { bytes.append(block) }
        let url = workspace.appendingPathComponent("audio.caf")
        try bytes.write(to: url)

        XCTAssertEqual(
            try FileContentDigest.sha256(of: url),
            SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
    }

    func testEmptyFileHasTheEmptyDigest() throws {
        let url = workspace.appendingPathComponent("empty.md")
        try Data().write(to: url)

        XCTAssertEqual(
            try FileContentDigest.sha256(of: url),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    func testHashingALargeFileKeepsTheFootprintSmall() throws {
        let size: UInt64 = 128 << 20
        let url = workspace.appendingPathComponent("long-meeting.wav")
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
        let writer = try FileHandle(forWritingTo: url)
        try writer.truncate(atOffset: size)
        try writer.close()

        // The outer pool keeps any buffer the digest leaks alive until the measurement.
        let growth = try autoreleasepool { () throws -> Int64 in
            let before = try OwnProcessResourceUsage.current().physicalFootprintBytes
            _ = try FileContentDigest.sha256(of: url)
            let after = try OwnProcessResourceUsage.current().physicalFootprintBytes
            return Int64(after) - Int64(before)
        }

        XCTAssertLessThan(growth, Int64(size / 4))
    }

    func testCancelledTaskStopsReading() async throws {
        let url = workspace.appendingPathComponent("audio.caf")
        try Data(repeating: 1, count: 1 << 20).write(to: url)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try FileContentDigest.sha256(of: url)
        }

        do {
            _ = try await task.value
            XCTFail("A cancelled digest must not finish")
        } catch is CancellationError {}
    }
}
