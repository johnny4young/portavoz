import Darwin

/// Read-only, on-demand counters for this process only. No process identity,
/// paths or other applications' resource usage cross this platform boundary.
public struct OwnProcessResourceUsage: Equatable, Sendable {
    public let cpuAbsoluteTime: UInt64
    public let physicalFootprintBytes: UInt64
    public let energyNanojoules: UInt64?
    public let diskReadBytes: UInt64?
    public let diskWrittenBytes: UInt64?

    public enum ReadError: Error { case unavailable }

    /// The stable V0 prefix works on the deployment floor. Extended benchmark
    /// counters explicitly retain the current flavor and fail if unsupported.
    public static func current(extendedCounters: Bool = false) throws -> Self {
        var usage = rusage_info_current()
        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), extendedCounters ? RUSAGE_INFO_CURRENT : RUSAGE_INFO_V0, $0)
            }
        }
        let cpu = usage.ri_user_time.addingReportingOverflow(usage.ri_system_time)
        guard result == 0, !cpu.overflow else { throw ReadError.unavailable }
        return Self(
            cpuAbsoluteTime: cpu.partialValue,
            physicalFootprintBytes: usage.ri_phys_footprint,
            energyNanojoules: extendedCounters ? usage.ri_energy_nj : nil,
            diskReadBytes: extendedCounters ? usage.ri_diskio_bytesread : nil,
            diskWrittenBytes: extendedCounters ? usage.ri_diskio_byteswritten : nil)
    }

    public var cpuSeconds: Double? {
        var timebase = mach_timebase_info_data_t()
        guard mach_timebase_info(&timebase) == KERN_SUCCESS else { return nil }
        return Self.seconds(ticks: cpuAbsoluteTime, numerator: timebase.numer, denominator: timebase.denom)
    }

    static func seconds(ticks: UInt64, numerator: UInt32, denominator: UInt32) -> Double? {
        guard numerator > 0, denominator > 0 else { return nil }
        return Double(ticks) * Double(numerator) / Double(denominator) / 1_000_000_000
    }
}
