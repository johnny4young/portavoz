import CryptoKit
import Foundation
import PortavozCore

/// Persists the user's enrolled voiceprint. Biometric-grade data (D8):
/// encrypted at rest (AES-GCM, key in the Keychain and nowhere else),
/// only ever on this device, never synced, and deletable in one action
/// that destroys both the file and the key.
public struct VoiceprintStore: Sendable {
    public enum VoiceprintError: Error, Equatable, LocalizedError, Sendable {
        case missingKey
        case corruptKey
        case sealedRepresentationUnavailable

        public var errorDescription: String? {
            switch self {
            case .missingKey:
                return "the encrypted voice data has no matching Keychain key — delete it before enrolling again"
            case .corruptKey:
                return "the voice identity key in the Keychain is corrupt — delete it before enrolling again"
            case .sealedRepresentationUnavailable:
                return "the encrypted voice data could not be serialized"
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
        let fileExists = exists
        let key = try VoiceIdentityStorage.key(
            secrets: secrets,
            identifier: keyIdentifier,
            allowCreation: !fileExists)
        if fileExists {
            _ = try decodeVoiceprint(using: key)
        }
        let plaintext = try JSONEncoder().encode(voiceprint)
        let sealed = try AES.GCM.seal(plaintext, using: key)
        let combined = try VoiceIdentityStorage.combinedData(from: sealed)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try combined.write(to: fileURL, options: .atomic)
    }

    public func load() throws -> Voiceprint? {
        guard exists else { return nil }
        let key = try VoiceIdentityStorage.key(
            secrets: secrets,
            identifier: keyIdentifier,
            allowCreation: false)
        return try decodeVoiceprint(using: key)
    }

    private func decodeVoiceprint(using key: SymmetricKey) throws -> Voiceprint {
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
}

/// One fail-closed key/serialization boundary shared by both encrypted voice
/// stores. An existing ciphertext can never authorize a replacement key: the
/// user must explicitly delete the unreadable biometric file first.
enum VoiceIdentityStorage {
    static func key(
        secrets: any SecretStoring,
        identifier: SecretIdentifier,
        allowCreation: Bool
    ) throws -> SymmetricKey {
        if let stored = try secrets.value(for: identifier) {
            guard let data = Data(base64Encoded: stored), data.count == 32 else {
                throw VoiceprintStore.VoiceprintError.corruptKey
            }
            return SymmetricKey(data: data)
        }
        guard allowCreation else {
            throw VoiceprintStore.VoiceprintError.missingKey
        }
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        try secrets.set(data.base64EncodedString(), for: identifier)
        return key
    }

    static func combinedData(from box: AES.GCM.SealedBox) throws -> Data {
        guard let combined = box.combined else {
            throw VoiceprintStore.VoiceprintError.sealedRepresentationUnavailable
        }
        return combined
    }
}
