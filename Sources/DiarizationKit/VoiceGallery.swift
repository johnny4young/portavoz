import CryptoKit
import Foundation
import PortavozCore

/// A voice the user explicitly asked Portavoz to remember, so future
/// meetings can suggest the participant's name from their voice alone.
public struct RememberedVoice: Codable, Sendable, Identifiable {
    public let id: UUID
    public let name: String
    public let embedding: [Float]
    public let createdAt: Date

    public init(id: UUID = UUID(), name: String, embedding: [Float], createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.embedding = embedding
        self.createdAt = createdAt
    }
}

/// Persists the voices of OTHER participants the user chose to remember.
/// Third-party voice embeddings are more sensitive than the user's own
/// (D8), so the rules are stricter than `VoiceprintStore`'s:
/// - a voice enters the gallery ONLY through an explicit user gesture
///   ("Remember this voice") — never automatically;
/// - encrypted at rest (AES-GCM, key only in the Keychain), never synced;
/// - each voice is individually removable, and `deleteAll()` destroys the
///   file and the key in one action;
/// - matches are SUGGESTIONS in the UI — a name is never applied by itself.
public struct VoiceGallery: Sendable {
    private let secrets: any SecretStoring
    private let keyIdentifier: SecretIdentifier
    private let fileURL: URL

    /// `~/Library/Application Support/Portavoz/voice-gallery.enc`
    public init(
        secrets: any SecretStoring,
        directory: URL = VoiceprintStore.defaultDirectory,
        keyIdentifier: SecretIdentifier = .voiceGalleryKey
    ) {
        self.secrets = secrets
        self.fileURL = directory.appendingPathComponent("voice-gallery.enc")
        self.keyIdentifier = keyIdentifier
    }

    /// A momentary presence snapshot. Authoritative operations re-check while
    /// holding the cross-process storage transaction.
    public var exists: Bool {
        fileExists
    }

    public func voices() throws -> [RememberedVoice] {
        guard fileExists else { return [] }
        return try VoiceIdentityStorageTransaction.withExclusiveAccess(to: fileURL) {
            try readWithoutLock()
        }
    }

    private func readWithoutLock() throws -> [RememberedVoice] {
        guard fileExists else { return [] }
        let key = try VoiceIdentityStorage.key(
            secrets: secrets,
            identifier: keyIdentifier,
            allowCreation: false)
        let combined = try Data(contentsOf: fileURL)
        let box = try AES.GCM.SealedBox(combined: combined)
        let plaintext = try AES.GCM.open(box, using: key)
        return try JSONDecoder().decode([RememberedVoice].self, from: plaintext)
    }

    /// Adds (or replaces, matching by name case-insensitively) a voice.
    /// Replacing keeps the gallery one-embedding-per-person: re-remembering
    /// someone refreshes their voice rather than accumulating stale ones.
    public func remember(_ voice: RememberedVoice) throws {
        try VoiceIdentityStorageTransaction.withExclusiveAccess(to: fileURL) {
            var all = try readWithoutLock()
            all.removeAll {
                $0.name.compare(voice.name, options: .caseInsensitive) == .orderedSame
            }
            all.append(voice)
            try writeWithoutLock(all)
        }
    }

    public func remove(id: UUID) throws {
        try VoiceIdentityStorageTransaction.withExclusiveAccess(to: fileURL) {
            let remaining = try readWithoutLock().filter { $0.id != id }
            if remaining.isEmpty {
                try deleteAllWithoutLock()
            } else {
                try writeWithoutLock(remaining)
            }
        }
    }

    /// One action, both halves gone (D8).
    public func deleteAll() throws {
        try VoiceIdentityStorageTransaction.withExclusiveAccess(to: fileURL) {
            try deleteAllWithoutLock()
        }
    }

    private var fileExists: Bool {
        FileManager.default.fileExists(atPath: fileURL.path)
    }

    private func deleteAllWithoutLock() throws {
        if fileExists {
            try FileManager.default.removeItem(at: fileURL)
        }
        try secrets.delete(keyIdentifier)
    }

    private func writeWithoutLock(_ voices: [RememberedVoice]) throws {
        let key = try VoiceIdentityStorage.key(
            secrets: secrets,
            identifier: keyIdentifier,
            allowCreation: !fileExists)
        let plaintext = try JSONEncoder().encode(voices)
        let sealed = try AES.GCM.seal(plaintext, using: key)
        let combined = try VoiceIdentityStorage.combinedData(from: sealed)
        try combined.write(to: fileURL, options: .atomic)
    }
}
