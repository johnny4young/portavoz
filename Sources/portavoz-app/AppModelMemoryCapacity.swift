import Foundation

/// Catalog RAM guidance uses binary GiB, not rounded decimal disk units.
/// It is advisory capacity, not a measured footprint or an admission limit.
struct AppModelMemoryCapacity: Sendable {
    static let gibibyte: UInt64 = 1_073_741_824
    let bytes: UInt64

    init(bytes: UInt64 = ProcessInfo.processInfo.physicalMemory) {
        self.bytes = bytes
    }

    var wholeGiB: Int { Int(bytes / Self.gibibyte) }
    var recommendsLightweight: Bool { bytes > 0 && bytes <= 8 * Self.gibibyte }

    func isBelowCatalogRAM(_ minimumRAMGB: Int) -> Bool {
        guard bytes > 0, minimumRAMGB > 0 else { return false }
        return wholeGiB < minimumRAMGB
    }
}
