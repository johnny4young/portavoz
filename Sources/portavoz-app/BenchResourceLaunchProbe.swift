import Darwin
import Foundation

/// Proves that the copied resource benchmark bundle reached application code.
///
/// `open -W` reports LaunchServices admission rather than the launched process's
/// exit status. A dyld failure can therefore look like a successful launch and
/// surface later as three missing resource fragments. This process-owning probe
/// publishes one fixed, content-free marker before any application service is
/// composed, then exits.
enum BenchResourceLaunchProbe {
    enum Marker: String {
        case launchReady = "portavoz-resource-benchmark-ready-v1\n"
        case refineRuntimePrepared =
            "portavoz-resource-refine-runtime-prepared-v1\n"
    }

    static let marker = Marker.launchReady.rawValue
    private static let option = "--bench-resource-launch-probe"

    static func runIfRequested(
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) {
        do {
            guard let output = try requested(arguments: arguments) else {
                return
            }
            try writeMarker(to: output)
            exit(EXIT_SUCCESS)
        } catch {
            exit(EXIT_FAILURE)
        }
    }

    static func requested(arguments: [String]) throws -> URL? {
        let indices = arguments.indices.filter { arguments[$0] == option }
        guard !indices.isEmpty else { return nil }
        guard indices.count == 1 else {
            throw BenchResourceLaunchProbeError.duplicateOption
        }
        guard arguments.contains("-use-temp-store") else {
            throw BenchResourceLaunchProbeError.temporaryStoreRequired
        }
        let optionIndex = indices[0]
        guard arguments.indices.contains(optionIndex + 1) else {
            throw BenchResourceLaunchProbeError.missingOutput
        }
        let path = arguments[optionIndex + 1]
        guard path.hasPrefix("/"), !path.isEmpty else {
            throw BenchResourceLaunchProbeError.absoluteOutputRequired
        }
        return URL(fileURLWithPath: path).standardizedFileURL
    }

    static func writeMarker(
        to output: URL,
        marker: Marker = .launchReady
    ) throws {
        let descriptor = output.path.withCString {
            Darwin.open(
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else {
            if errno == EEXIST {
                throw BenchResourceLaunchProbeError.outputAlreadyExists
            }
            throw BenchResourceLaunchProbeError.writeFailed
        }

        var completed = false
        defer {
            _ = Darwin.close(descriptor)
            if !completed {
                _ = output.path.withCString(Darwin.unlink)
            }
        }

        let data = Data(marker.rawValue.utf8)
        try data.withUnsafeBytes { rawBuffer in
            guard var cursor = rawBuffer.baseAddress else {
                throw BenchResourceLaunchProbeError.writeFailed
            }
            var remaining = rawBuffer.count
            while remaining > 0 {
                let written = Darwin.write(descriptor, cursor, remaining)
                if written < 0, errno == EINTR {
                    continue
                }
                guard written > 0 else {
                    throw BenchResourceLaunchProbeError.writeFailed
                }
                remaining -= written
                cursor = cursor.advanced(by: written)
            }
        }
        guard Darwin.fsync(descriptor) == 0 else {
            throw BenchResourceLaunchProbeError.writeFailed
        }
        completed = true
    }
}

enum BenchResourceLaunchProbeError: Error, Equatable {
    case absoluteOutputRequired
    case duplicateOption
    case missingOutput
    case outputAlreadyExists
    case temporaryStoreRequired
    case writeFailed
}
