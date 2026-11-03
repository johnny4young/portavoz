import Foundation
import XCTest
@testable import portavoz_app

final class ResourceProbeDiskCapacityTests: XCTestCase {
    func testRequestsOnlyFreeCapacityAndDoesNotCacheSamples() throws {
        var capacities = [9_000, 3_000, 0]
        var requests = 0
        let read: ResourceProbeDiskCapacity.Reader = { keys in
            XCTAssertEqual(keys, [.volumeAvailableCapacityKey])
            XCTAssertFalse(keys.contains(.volumeAvailableCapacityForImportantUsageKey))
            requests += 1
            return capacities.removeFirst()
        }
        XCTAssertEqual(try ResourceProbeDiskCapacity.availableBytes(read: read), 9_000)
        XCTAssertEqual(try ResourceProbeDiskCapacity.availableBytes(read: read), 3_000)
        XCTAssertEqual(try ResourceProbeDiskCapacity.availableBytes(read: read), 0)
        XCTAssertEqual(requests, 3)
        XCTAssertTrue(capacities.isEmpty)
    }

    func testRejectsUnavailableAndNegativeCapacityInsteadOfInventingFreeSpace() {
        for capacity: Int? in [nil, -1, Int.min] {
            XCTAssertThrowsError(try ResourceProbeDiskCapacity.availableBytes(read: { _ in capacity })) {
                XCTAssertEqual($0 as? ResourceRunProbeError, .diskCapacityUnavailable)
            }
        }
    }

    func testPropagatesReadFailureWithoutFallbackOrRetry() {
        struct ReadFailure: Error {}
        var requests = 0
        XCTAssertThrowsError(try ResourceProbeDiskCapacity.availableBytes(read: { _ in
            requests += 1
            throw ReadFailure()
        })) {
            XCTAssertTrue($0 is ReadFailure)
        }
        XCTAssertEqual(requests, 1)
    }

    func testPreservesLargestRepresentableCapacityAndReadsTheActualVolume() throws {
        XCTAssertEqual(
            try ResourceProbeDiskCapacity.availableBytes(read: { _ in Int.max }),
            UInt64(Int.max))
        // No wall-clock or host free-space floor belongs in deterministic tests.
        // The actual Foundation adapter must still return a representable sample.
        let actual = try ResourceProbeDiskCapacity.availableBytes()
        XCTAssertLessThanOrEqual(actual, UInt64(Int.max))
    }
}
