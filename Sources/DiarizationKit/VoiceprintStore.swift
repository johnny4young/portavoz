import CryptoKit
import Foundation
import PortavozCore

/// Persists the user's enrolled voiceprint. Biometric-grade data (D8):
/// encrypted at rest (AES-GCM, key in the Keychain and nowhere else),
/// only ever on this device, never synced, and deletable in one action
/// that destroys both the file and the key.
public struct VoiceprintStore: Sendable {
    public enum VoiceprintError: Error, LocalizedError {
        case corruptKey

        public var errorDescription: String? {
            switch self {
            case .corruptKey:
                return "the voiceprint key in the Keychain is corrupt — delete and re-enroll"
            }
        }
    }

    private let secrets: any SecretStoring
    private let keyIdentifier: SecretIdentifier
    private let fileURL: URL

    /// `~/Library/Application Support/Portavoz/voiceprint.enc`
    public static var defaultDirectory: URL {
        let base =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
                "Library/Application Support")
        return base.appendingPathComponent("Portavoz", isDirectory: true)
    }

    public init(
        secrets: any SecretStoring,
        directory: URL = VoiceprintStore.defaultDirectory,
        keyIdentifier: SecretIdentifier = .voiceprintKey
    ) {
        self.secrets = secrets
        self.fileURL = directory.appendingPathComponent("voiceprint.enc")
        self.keyIdentifier = keyIdentifier
    }

    public var exists: Bool {
        FileManager.default.fileExists(atPath: fileURL.path)
    }

    public func save(_ voiceprint: Voiceprint) throws {
        let key = try loadOrCreateKey()
        let plaintext = try JSONEncoder().encode(voiceprint)
        let sealed = try AES.GCM.seal(plaintext, using: key)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try sealed.combined!.write(to: fileURL, options: .atomic)
    }

    public func load() throws -> Voiceprint? {
        guard exists else { return nil }
        guard let keyText = try secrets.value(for: keyIdentifier),
            let keyData = Data(base64Encoded: keyText)
        else {
            // File without key: unreadable by construction; treat as absent.
            return nil
        }
        let key = SymmetricKey(data: keyData)
        let combined = try Data(contentsOf: fileURL)
        let box = try AES.GCM.SealedBox(combined: combined)
        let plaintext = try AES.GCM.open(box, using: key)
        return try JSONDecoder().decode(Voiceprint.self, from: plaintext)
    }

    /// One action, both halves gone (D8: "deletable with one action").
    public func delete() throws {
        if exists {
            try FileManager.default.removeItem(at: fileURL)
        }
        try secrets.delete(keyIdentifier)
    }

    private func loadOrCreateKey() throws -> SymmetricKey {
        if let stored = try secrets.value(for: keyIdentifier) {
            guard let data = Data(base64Encoded: stored), data.count == 32 else {
                throw VoiceprintError.corruptKey
            }
            return SymmetricKey(data: data)
        }
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        try secrets.set(data.base64EncodedString(), for: keyIdentifier)
        return key
    }
}
