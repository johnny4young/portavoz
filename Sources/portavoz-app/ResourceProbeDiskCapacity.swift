import Foundation

/// A fresh, conservative free-space sample, without purgeable-space estimation.
/// The important-usage query can perform expensive storage accounting and must
/// not run inside the 10 Hz CPU/memory observer that it would itself perturb.
enum ResourceProbeDiskCapacity {
    typealias Reader = (Set<URLResourceKey>) throws -> Int?

    static func availableBytes(
        read: Reader = { keys in
            try URL(fileURLWithPath: "/").resourceValues(forKeys: keys)
                .volumeAvailableCapacity
        }
    ) throws -> UInt64 {
        guard let capacity = try read([.volumeAvailableCapacityKey]),
              capacity >= 0
        else {
            throw ResourceRunProbeError.diskCapacityUnavailable
        }
        return UInt64(capacity)
    }
}
