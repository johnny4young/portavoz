import AppKit
import CryptoKit
import Darwin
import Foundation
import IOKit

enum ProductionSyncQualificationRunner {
    @MainActor
    static func runIfRequested() {
        let arguments = ProcessInfo.processInfo.arguments
        let configuration: ProductionSyncQualificationConfiguration?
        do {
            configuration = try ProductionSyncQualificationConfiguration.requested(
                arguments: arguments,
                environment: ProcessInfo.processInfo.environment)
        } catch {
            emitFailure(.invalidAdmission)
            exit(64)
        }
        guard let configuration else { return }
        setbuf(stdout, nil)
        Task { @MainActor in
            do {
                let session = try ProductionSyncQualificationSession(
                    configuration: configuration)
                try await session.run()
                print("production-sync stage PASS")
                exit(0)
            } catch let error as ProductionSyncQualificationError {
                emitFailure(error)
                exit(1)
            } catch {
                emitFailure(.invalidLifecycle)
                exit(1)
            }
        }
    }

    private static func emitFailure(_ error: ProductionSyncQualificationError) {
        let value = "production-sync stage failed: \(error)\n"
        try? FileHandle.standardError.write(contentsOf: Data(value.utf8))
    }
}

@MainActor
enum ProductionSyncQualificationPushBridge {
    static var didRegister: (() -> Void)?
    static var didFailRegistration: (() -> Void)?
    static var didReceiveRemoteChange: (() -> Void)?

    static func clear() {
        didRegister = nil
        didFailRegistration = nil
        didReceiveRemoteChange = nil
    }
}

enum ProductionSyncProcessWatchdog {
    static let expirationStatus: Int32 = 124

    static func runIfRequested(arguments: [String]) {
        guard ProductionSyncQualificationConfiguration.isRequested(
            arguments: arguments)
        else { return }
        let configuration: ProductionSyncQualificationConfiguration
        do {
            guard let parsed = try ProductionSyncQualificationConfiguration.requested(
                arguments: arguments,
                environment: ProcessInfo.processInfo.environment)
            else {
                Darwin._exit(64)
            }
            configuration = parsed
        } catch {
            Darwin._exit(64)
        }
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + .seconds(configuration.timeoutSeconds)
        ) {
            let diagnostic = Data("production-sync qualification timed out\n".utf8)
            try? FileHandle.standardError.write(contentsOf: diagnostic)
            Darwin._exit(expirationStatus)
        }
    }
}

enum ProductionSyncQualificationIdentity {
    static func deviceID(runID: UUID, role: String) -> UUID {
        let data = Data(
            "portavoz-production-sync-device-v1\u{0}\(runID)\u{0}\(role)".utf8)
        var bytes = Array(SHA256.hash(data: data).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

enum ProductionSyncQualificationHost {
    static func scope(runNonce: String) throws -> String {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPlatformExpertDevice"))
        guard service != IO_OBJECT_NULL else {
            throw ProductionSyncQualificationError.invalidWorkspace
        }
        defer { IOObjectRelease(service) }
        guard let value = IORegistryEntryCreateCFProperty(
            service,
            kIOPlatformUUIDKey as CFString,
            kCFAllocatorDefault,
            0)?.takeRetainedValue() as? String,
              !value.isEmpty
        else {
            throw ProductionSyncQualificationError.invalidWorkspace
        }
        return ProductionSyncQualificationDigest.scoped(
            namespace: "portavoz-production-sync-host-v1",
            runNonce: runNonce,
            value: value)
    }

    static func operatingSystem() throws -> ProductionSyncQualificationReceipt.OperatingSystem {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        var systemInfo = utsname()
        guard uname(&systemInfo) == 0 else {
            throw ProductionSyncQualificationError.invalidWorkspace
        }
        let architecture = withUnsafePointer(to: &systemInfo.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(cString: $0)
            }
        }
        guard ["arm64", "x86_64"].contains(architecture) else {
            throw ProductionSyncQualificationError.invalidWorkspace
        }
        let build = try operatingSystemBuild()
        guard version.majorVersion == 15 || version.majorVersion >= 26,
              build.range(
                of: "^[0-9]{2}[A-Z][0-9A-Za-z]{1,15}$",
                options: .regularExpression) != nil
        else {
            throw ProductionSyncQualificationError.invalidWorkspace
        }
        return ProductionSyncQualificationReceipt.OperatingSystem(
            major: version.majorVersion,
            minor: version.minorVersion,
            patch: version.patchVersion,
            build: build,
            architecture: architecture)
    }

    private static func operatingSystemBuild() throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sw_vers")
        process.arguments = ["-buildVersion"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw ProductionSyncQualificationError.invalidWorkspace
            }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            guard let decoded = String(data: data, encoding: .utf8) else {
                throw ProductionSyncQualificationError.invalidWorkspace
            }
            let value = decoded
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else {
                throw ProductionSyncQualificationError.invalidWorkspace
            }
            return value
        } catch {
            throw ProductionSyncQualificationError.invalidWorkspace
        }
    }
}

extension ProductionSyncQualificationFile {
    static func requireRegularFileOrAbsent(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        guard try isRegularFile(url) else {
            throw ProductionSyncQualificationError.invalidWorkspace
        }
    }

    static func requireSafeScratchTree(_ root: URL) throws {
        guard try isOwnerOnlyDirectory(root),
              let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [
                    .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey
                ],
                options: [])
        else {
            throw ProductionSyncQualificationError.invalidWorkspace
        }
        for case let url as URL in enumerator {
            let values = try url.resourceValues(
                forKeys: [
                    .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey
                ])
            guard values.isSymbolicLink != true,
                  values.isDirectory == true || values.isRegularFile == true
            else {
                throw ProductionSyncQualificationError.invalidWorkspace
            }
            if values.isDirectory == true,
               try permissions(url) != 0o700 {
                throw ProductionSyncQualificationError.invalidWorkspace
            }
        }
    }
}
