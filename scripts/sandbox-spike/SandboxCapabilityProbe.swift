import ApplicationServices
import AVFAudio
import Carbon.HIToolbox
import CoreAudio
import EventKit
import Foundation
import Security

private enum Observation: String, Codable {
    case allowed
    case denied
    case observed
    case unsupported
    case error
}

private struct CapabilityResult: Codable {
    let capability: String
    let operation: String
    let observation: Observation
    let statusDomain: String?
    let statusCode: Int?
    let detail: String?

    init(
        _ capability: String,
        operation: String,
        observation: Observation,
        statusDomain: String? = nil,
        statusCode: Int? = nil,
        detail: String? = nil
    ) {
        self.capability = capability
        self.operation = operation
        self.observation = observation
        self.statusDomain = statusDomain
        self.statusCode = statusCode
        self.detail = detail
    }
}

private struct ProbeReport: Codable {
    let schemaVersion: Int
    let probeBundleIdentifier: String
    let operatingSystemVersion: String
    let results: [CapabilityResult]
    let sandboxEnforcementObserved: Bool
}

@main
private enum SandboxCapabilityProbe {
    static func main() async {
        let arguments = CommandLine.arguments
        if arguments.contains("--core-audio-tap-child") {
            writeSingleResult(coreAudioProcessTap())
        }
        guard
            let legacyDirectoryIndex = arguments.firstIndex(of: "--legacy-directory"),
            arguments.indices.contains(legacyDirectoryIndex + 1),
            let networkURLIndex = arguments.firstIndex(of: "--network-url"),
            arguments.indices.contains(networkURLIndex + 1),
            let networkURL = URL(string: arguments[networkURLIndex + 1])
        else {
            FileHandle.standardError.write(Data(
                "usage: SandboxCapabilityProbe --legacy-directory PATH --network-url URL\n".utf8))
            Foundation.exit(64)
        }

        let legacyDirectory = URL(fileURLWithPath: arguments[legacyDirectoryIndex + 1])
        var results: [CapabilityResult] = []
        progress("sandbox-entitlement")
        results.append(sandboxEntitlement())
        progress("container-filesystem")
        results.append(containerWrite())
        progress("legacy-filesystem")
        results.append(legacyRead(in: legacyDirectory))
        results.append(legacyWrite(in: legacyDirectory))
        progress("external-process")
        results.append(externalProcess())
        results.append(externalProcessInheritance(in: legacyDirectory))
        progress("shortcuts-cli")
        results.append(shortcutCLI())
        progress("network")
        results.append(await networkRequest(to: networkURL))
        progress("keychain")
        results.append(keychainRoundTrip())
        progress("global-hotkey")
        results.append(globalHotkeyRegistration())
        progress("microphone")
        results.append(microphoneCapture())
        progress("core-audio-process-catalog")
        results.append(coreAudioProcessCatalog())
        progress("core-audio-process-tap")
        results.append(coreAudioProcessTapWithTimeout())
        progress("authorization-state")
        results.append(accessibilityTrust())
        results.append(calendarAuthorization())

        let observations = Dictionary(uniqueKeysWithValues: results.map {
            ($0.capability, $0.observation)
        })
        let enforcementObserved = observations["sandbox-entitlement"] == .allowed
            && observations["container-filesystem"] == .allowed
            && observations["legacy-shared-filesystem-read"] == .denied
            && observations["legacy-shared-filesystem-write"] == .denied
            && observations["external-process-inherited-sandbox"] == .denied

        let report = ProbeReport(
            schemaVersion: 1,
            probeBundleIdentifier: Bundle.main.bundleIdentifier ?? "unknown",
            operatingSystemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            results: results,
            sandboxEnforcementObserved: enforcementObserved)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(report)
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
            Foundation.exit(enforcementObserved ? 0 : 1)
        } catch {
            FileHandle.standardError.write(Data("could not encode probe report\n".utf8))
            Foundation.exit(70)
        }
    }

    private static func sandboxEntitlement() -> CapabilityResult {
        guard let task = SecTaskCreateFromSelf(nil) else {
            return CapabilityResult(
                "sandbox-entitlement",
                operation: "read com.apple.security.app-sandbox from the running process",
                observation: .error,
                statusDomain: "Security")
        }
        let value = SecTaskCopyValueForEntitlement(
            task,
            "com.apple.security.app-sandbox" as CFString,
            nil)
        let enabled = value as? Bool == true
        return CapabilityResult(
            "sandbox-entitlement",
            operation: "read com.apple.security.app-sandbox from the running process",
            observation: enabled ? .allowed : .denied,
            detail: enabled ? "enabled" : "missing-or-false")
    }

    private static func progress(_ capability: String) {
        FileHandle.standardError.write(Data("probe: \(capability)\n".utf8))
    }

    private static func writeSingleResult(_ result: CapabilityResult) -> Never {
        do {
            let data = try JSONEncoder().encode(result)
            FileHandle.standardOutput.write(data)
            Foundation.exit(0)
        } catch {
            Foundation.exit(70)
        }
    }

    private static func containerWrite() -> CapabilityResult {
        guard let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return CapabilityResult(
                "container-filesystem",
                operation: "write inside the application support container",
                observation: .error,
                statusDomain: "Foundation")
        }
        let directory = support.appendingPathComponent(
            "PortavozSandboxCapabilityProbe",
            isDirectory: true)
        let file = directory.appendingPathComponent("container-write.txt")
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true)
            try Data("portavoz-sandbox-probe".utf8).write(to: file, options: .atomic)
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.removeItem(at: directory)
            return CapabilityResult(
                "container-filesystem",
                operation: "write inside the application support container",
                observation: .allowed,
                detail: support.path.contains("/Library/Containers/")
                    ? "container-path" : "non-container-path")
        } catch {
            return fileError(
                capability: "container-filesystem",
                operation: "write inside the application support container",
                error: error)
        }
    }

    private static func legacyRead(in directory: URL) -> CapabilityResult {
        let file = directory.appendingPathComponent("sentinel.txt")
        do {
            _ = try Data(contentsOf: file)
            return CapabilityResult(
                "legacy-shared-filesystem-read",
                operation: "read a pre-existing support file outside the app container",
                observation: .allowed)
        } catch {
            return fileError(
                capability: "legacy-shared-filesystem-read",
                operation: "read a pre-existing support file outside the app container",
                error: error)
        }
    }

    private static func legacyWrite(in directory: URL) -> CapabilityResult {
        let file = directory.appendingPathComponent("sandbox-write.txt")
        do {
            try Data("sandbox-write".utf8).write(to: file, options: .atomic)
            try? FileManager.default.removeItem(at: file)
            return CapabilityResult(
                "legacy-shared-filesystem-write",
                operation: "write a support file outside the app container",
                observation: .allowed)
        } catch {
            return fileError(
                capability: "legacy-shared-filesystem-write",
                operation: "write a support file outside the app container",
                error: error)
        }
    }

    private static func externalProcess() -> CapabilityResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return CapabilityResult(
                "external-process-launch",
                operation: "launch /usr/bin/true through Foundation.Process",
                observation: process.terminationStatus == 0 ? .allowed : .error,
                statusDomain: "Process",
                statusCode: Int(process.terminationStatus))
        } catch {
            let nsError = error as NSError
            return CapabilityResult(
                "external-process-launch",
                operation: "launch /usr/bin/true through Foundation.Process",
                observation: .denied,
                statusDomain: nsError.domain,
                statusCode: nsError.code)
        }
    }

    private static func externalProcessInheritance(in directory: URL) -> CapabilityResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/cat")
        process.arguments = [directory.appendingPathComponent("sentinel.txt").path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return CapabilityResult(
                "external-process-inherited-sandbox",
                operation: "ask /bin/cat to read the outside-container sentinel",
                observation: process.terminationStatus == 0 ? .allowed : .denied,
                statusDomain: "Process",
                statusCode: Int(process.terminationStatus))
        } catch {
            let nsError = error as NSError
            return CapabilityResult(
                "external-process-inherited-sandbox",
                operation: "ask /bin/cat to read the outside-container sentinel",
                observation: .denied,
                statusDomain: nsError.domain,
                statusCode: nsError.code)
        }
    }

    private static func shortcutCLI() -> CapabilityResult {
        guard let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return CapabilityResult(
                "shortcuts-cli-resolution",
                operation: "invoke /usr/bin/shortcuts with a nonexistent probe shortcut",
                observation: .error,
                statusDomain: "Foundation")
        }
        let input = support.appendingPathComponent("sandbox-shortcut-input.txt")
        do {
            try Data("sandbox capability probe".utf8).write(to: input, options: .atomic)
        } catch {
            return fileError(
                capability: "shortcuts-cli-resolution",
                operation: "create a container-local Shortcut input fixture",
                error: error)
        }
        defer { try? FileManager.default.removeItem(at: input) }

        let output = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = [
            "run",
            "__Portavoz_Sandbox_Capability_Probe_Does_Not_Exist__",
            "--input-path",
            input.path,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = output
        do {
            try process.run()
            process.waitUntilExit()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let message = String(decoding: data, as: UTF8.self).lowercased()
            if message.contains("not found")
                || message.contains("could not find")
                || message.contains("could not be found")
                || message.contains("does not exist")
            {
                return CapabilityResult(
                    "shortcuts-cli-resolution",
                    operation: "invoke /usr/bin/shortcuts with a nonexistent probe shortcut",
                    observation: .allowed,
                    statusDomain: "Process",
                    statusCode: Int(process.terminationStatus),
                    detail: "reached-shortcut-name-resolution")
            }
            if message.contains("not permitted")
                || message.contains("operation not permitted")
                || message.contains("sandbox")
            {
                return CapabilityResult(
                    "shortcuts-cli-resolution",
                    operation: "invoke /usr/bin/shortcuts with a nonexistent probe shortcut",
                    observation: .denied,
                    statusDomain: "Process",
                    statusCode: Int(process.terminationStatus),
                    detail: "permission-denied")
            }
            return CapabilityResult(
                "shortcuts-cli-resolution",
                operation: "invoke /usr/bin/shortcuts with a nonexistent probe shortcut",
                observation: .observed,
                statusDomain: "Process",
                statusCode: Int(process.terminationStatus),
                detail: "unclassified-cli-response")
        } catch {
            let nsError = error as NSError
            return CapabilityResult(
                "shortcuts-cli-resolution",
                operation: "invoke /usr/bin/shortcuts with a nonexistent probe shortcut",
                observation: .denied,
                statusDomain: nsError.domain,
                statusCode: nsError.code)
        }
    }

    private static func networkRequest(to url: URL) async -> CapabilityResult {
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode
            let allowed = status == 200 && data == Data("portavoz-sandbox-probe\n".utf8)
            return CapabilityResult(
                "outbound-network-client",
                operation: "GET a loopback HTTP fixture",
                observation: allowed ? .allowed : .error,
                statusDomain: "HTTP",
                statusCode: status,
                detail: allowed ? "fixture-matched" : "unexpected-response")
        } catch {
            let nsError = error as NSError
            return CapabilityResult(
                "outbound-network-client",
                operation: "GET a loopback HTTP fixture",
                observation: .denied,
                statusDomain: nsError.domain,
                statusCode: nsError.code)
        }
    }

    private static func keychainRoundTrip() -> CapabilityResult {
        let service = "app.portavoz.sandbox-spike.\(UUID().uuidString)"
        let account = "capability-probe"
        let secret = Data("temporary-secret".utf8)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        var insert = base
        insert[kSecValueData as String] = secret
        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            return securityResult(
                capability: "keychain-round-trip",
                operation: "add, read, and delete a unique generic password",
                status: addStatus)
        }
        defer { SecItemDelete(base as CFDictionary) }

        var query = base
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let readStatus = SecItemCopyMatching(query as CFDictionary, &item)
        guard readStatus == errSecSuccess, item as? Data == secret else {
            return securityResult(
                capability: "keychain-round-trip",
                operation: "add, read, and delete a unique generic password",
                status: readStatus)
        }
        let deleteStatus = SecItemDelete(base as CFDictionary)
        return securityResult(
            capability: "keychain-round-trip",
            operation: "add, read, and delete a unique generic password",
            status: deleteStatus)
    }

    private static func globalHotkeyRegistration() -> CapabilityResult {
        var hotKey: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x5056_5350), id: 1) // "PVSP"
        let status = RegisterEventHotKey(
            UInt32(kVK_F20),
            UInt32(optionKey | cmdKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKey)
        if let hotKey {
            UnregisterEventHotKey(hotKey)
        }
        return CapabilityResult(
            "global-hotkey-registration",
            operation: "register and unregister Option-Command-F20 with Carbon",
            observation: status == noErr ? .allowed : .denied,
            statusDomain: "Carbon",
            statusCode: Int(status))
    }

    private static func coreAudioProcessCatalog() -> CapabilityResult {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size)
        return CapabilityResult(
            "core-audio-process-catalog",
            operation: "read the Core Audio process-object list size",
            observation: status == noErr ? .allowed : .denied,
            statusDomain: "OSStatus",
            statusCode: Int(status),
            detail: status == noErr ? "bytes=\(size)" : nil)
    }

    private static func coreAudioProcessTapWithTimeout() -> CapabilityResult {
        guard let executable = Bundle.main.executableURL else {
            return CapabilityResult(
                "core-audio-process-tap",
                operation: "start and stop a private global process-tap graph",
                observation: .error,
                statusDomain: "Foundation",
                detail: "probe-executable-unavailable")
        }
        let output = Pipe()
        let diagnostics = Pipe()
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--core-audio-tap-child"]
        process.standardOutput = output
        process.standardError = diagnostics
        do {
            try process.run()
        } catch {
            let nsError = error as NSError
            return CapabilityResult(
                "core-audio-process-tap",
                operation: "start and stop a private global process-tap graph",
                observation: .error,
                statusDomain: nsError.domain,
                statusCode: nsError.code,
                detail: "could-not-launch-isolated-probe")
        }

        let deadline = Date().addingTimeInterval(5)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
            let data = diagnostics.fileHandleForReading.readDataToEndOfFile()
            let trace = String(decoding: data, as: UTF8.self)
            let stage = trace
                .split(separator: "\n")
                .last
                .map(String.init) ?? "unknown-stage"
            return CapabilityResult(
                "core-audio-process-tap",
                operation: "start and stop a private global process-tap graph",
                observation: .error,
                statusDomain: "CapabilityProbeTimeout",
                statusCode: 5,
                detail: stage.replacingOccurrences(
                    of: "probe: core-audio-process-tap.",
                    with: "timed-out-stage="))
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        do {
            return try JSONDecoder().decode(CapabilityResult.self, from: data)
        } catch {
            return CapabilityResult(
                "core-audio-process-tap",
                operation: "start and stop a private global process-tap graph",
                observation: .error,
                statusDomain: "Foundation",
                statusCode: process.terminationStatus == 0
                    ? nil : Int(process.terminationStatus),
                detail: "isolated-probe-returned-no-result")
        }
    }

    private static func microphoneCapture() -> CapabilityResult {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            return CapabilityResult(
                "microphone-capture",
                operation: "start and stop an AVAudioEngine input tap",
                observation: .unsupported,
                detail: "no-input-format")
        }
        input.installTap(
            onBus: 0,
            bufferSize: 512,
            format: format
        ) { _, _ in }
        defer {
            engine.stop()
            input.removeTap(onBus: 0)
        }
        do {
            engine.prepare()
            try engine.start()
            Thread.sleep(forTimeInterval: 0.2)
            return CapabilityResult(
                "microphone-capture",
                operation: "start and stop an AVAudioEngine input tap",
                observation: .allowed,
                detail: "graph-started-and-stopped")
        } catch {
            let nsError = error as NSError
            return CapabilityResult(
                "microphone-capture",
                operation: "start and stop an AVAudioEngine input tap",
                observation: .denied,
                statusDomain: nsError.domain,
                statusCode: nsError.code)
        }
    }

    private static func coreAudioProcessTap() -> CapabilityResult {
        guard #available(macOS 14.4, *) else {
            return CapabilityResult(
                "core-audio-process-tap",
                operation: "create and immediately destroy a private global process tap",
                observation: .unsupported)
        }
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.isPrivate = true
        description.muteBehavior = .unmuted
        var tap = AudioObjectID(kAudioObjectUnknown)
        progress("core-audio-process-tap.create-tap")
        let tapStatus = AudioHardwareCreateProcessTap(description, &tap)
        guard tapStatus == noErr else {
            return coreAudioResult(
                capability: "core-audio-process-tap",
                operation: "start and stop a private global process-tap graph",
                stage: "create-tap",
                status: tapStatus)
        }
        defer { AudioHardwareDestroyProcessTap(tap) }

        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Portavoz Sandbox Capability Probe",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true,
                ],
            ],
        ]
        var aggregate = AudioObjectID(kAudioObjectUnknown)
        progress("core-audio-process-tap.create-aggregate")
        let aggregateStatus = AudioHardwareCreateAggregateDevice(
            aggregateDescription as CFDictionary,
            &aggregate)
        guard aggregateStatus == noErr else {
            return coreAudioResult(
                capability: "core-audio-process-tap",
                operation: "start and stop a private global process-tap graph",
                stage: "create-aggregate",
                status: aggregateStatus)
        }
        defer { AudioHardwareDestroyAggregateDevice(aggregate) }

        var ioProc: AudioDeviceIOProcID?
        let queue = DispatchQueue(label: "app.portavoz.sandbox-spike.tap")
        progress("core-audio-process-tap.create-io-proc")
        let ioStatus = AudioDeviceCreateIOProcIDWithBlock(
            &ioProc,
            aggregate,
            queue
        ) { _, _, _, _, _ in }
        guard ioStatus == noErr, let ioProc else {
            return coreAudioResult(
                capability: "core-audio-process-tap",
                operation: "start and stop a private global process-tap graph",
                stage: "create-io-proc",
                status: ioStatus)
        }
        defer { AudioDeviceDestroyIOProcID(aggregate, ioProc) }

        progress("core-audio-process-tap.start")
        let startStatus = AudioDeviceStart(aggregate, ioProc)
        guard startStatus == noErr else {
            return coreAudioResult(
                capability: "core-audio-process-tap",
                operation: "start and stop a private global process-tap graph",
                stage: "start-aggregate",
                status: startStatus)
        }
        Thread.sleep(forTimeInterval: 0.2)
        progress("core-audio-process-tap.stop")
        let stopStatus = AudioDeviceStop(aggregate, ioProc)
        guard stopStatus == noErr else {
            return coreAudioResult(
                capability: "core-audio-process-tap",
                operation: "start and stop a private global process-tap graph",
                stage: "stop-aggregate",
                status: stopStatus)
        }
        progress("core-audio-process-tap.complete")
        return CapabilityResult(
            "core-audio-process-tap",
            operation: "start and stop a private global process-tap graph",
            observation: .allowed,
            statusDomain: "OSStatus",
            statusCode: Int(noErr),
            detail: "graph-started-and-stopped; TCC responsibility follows the launcher")
    }

    private static func accessibilityTrust() -> CapabilityResult {
        CapabilityResult(
            "accessibility-trust",
            operation: "read AXIsProcessTrusted without prompting",
            observation: .observed,
            detail: AXIsProcessTrusted() ? "trusted" : "not-trusted")
    }

    private static func calendarAuthorization() -> CapabilityResult {
        let status = EKEventStore.authorizationStatus(for: .event)
        return CapabilityResult(
            "calendar-authorization",
            operation: "read EventKit event authorization without prompting",
            observation: .observed,
            statusDomain: "EKAuthorizationStatus",
            statusCode: Int(status.rawValue))
    }

    private static func fileError(
        capability: String,
        operation: String,
        error: Error
    ) -> CapabilityResult {
        let nsError = error as NSError
        let permissionDenied = nsError.domain == NSCocoaErrorDomain
            && [NSFileReadNoPermissionError, NSFileWriteNoPermissionError]
                .contains(nsError.code)
        return CapabilityResult(
            capability,
            operation: operation,
            observation: permissionDenied ? .denied : .error,
            statusDomain: nsError.domain,
            statusCode: nsError.code)
    }

    private static func securityResult(
        capability: String,
        operation: String,
        status: OSStatus
    ) -> CapabilityResult {
        CapabilityResult(
            capability,
            operation: operation,
            observation: status == errSecSuccess ? .allowed : .denied,
            statusDomain: "OSStatus",
            statusCode: Int(status))
    }

    private static func coreAudioResult(
        capability: String,
        operation: String,
        stage: String,
        status: OSStatus
    ) -> CapabilityResult {
        CapabilityResult(
            capability,
            operation: operation,
            observation: .denied,
            statusDomain: "OSStatus",
            statusCode: Int(status),
            detail: "stage=\(stage); result can also reflect system-audio TCC state")
    }
}
