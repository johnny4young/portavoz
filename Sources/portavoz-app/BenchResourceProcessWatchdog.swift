import Darwin
import Foundation

/// Last-resort process owner for autonomous resource evidence. Individual
/// model operations retain their tighter structured timeouts; this boundary
/// prevents AppKit, TCC, launch, or teardown from waiting forever.
enum BenchResourceProcessWatchdog {
    static let option = "--bench-resource-process-timeout"
    static let expirationStatus: Int32 = 124

    static func timeoutSeconds(arguments: [String]) throws -> Int? {
        let indexes = arguments.indices.filter { arguments[$0] == option }
        guard !indexes.isEmpty else { return nil }
        guard indexes.count == 1,
              let index = indexes.first,
              arguments.indices.contains(index + 1),
              let seconds = Int(arguments[index + 1]),
              (60...7_200).contains(seconds),
              arguments.contains("-use-temp-store"),
              BenchMode.runsIsolatedBenchmark(arguments: arguments)
        else {
            throw BenchResourceProcessWatchdogError.invalidAdmission
        }
        return seconds
    }

    static func runIfRequested(arguments: [String]) {
        let seconds: Int
        do {
            guard let parsed = try timeoutSeconds(arguments: arguments) else {
                return
            }
            seconds = parsed
        } catch {
            writeDiagnostic("resource benchmark watchdog admission failed\n")
            Darwin._exit(64)
        }
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + .seconds(seconds)
        ) {
            writeDiagnostic("resource benchmark watchdog expired\n")
            Darwin._exit(expirationStatus)
        }
    }

    private static func writeDiagnostic(_ value: String) {
        try? FileHandle.standardError.write(contentsOf: Data(value.utf8))
    }
}

enum BenchResourceProcessWatchdogError: Error, Equatable {
    case invalidAdmission
}
