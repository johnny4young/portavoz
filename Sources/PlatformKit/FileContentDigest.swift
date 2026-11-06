import CryptoKit
import Foundation

/// SHA-256 of a file read in bounded chunks. Each read returns an autoreleased
/// buffer, so every chunk drains its own pool: a synchronous loop never reaches
/// the caller's drain and would otherwise hold the whole file in memory.
/// A cancelled task stops between chunks with `CancellationError`.
public enum FileContentDigest {
    public static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try sha256(of: handle)
    }

    public static func sha256(of handle: FileHandle) throws -> String {
        var hasher = SHA256()
        while true {
            try Task.checkCancellation()
            let reachedEnd = try autoreleasepool { () throws -> Bool in
                guard let data = try handle.read(upToCount: 1 << 20), !data.isEmpty else { return true }
                hasher.update(data: data)
                return false
            }
            if reachedEnd { break }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
