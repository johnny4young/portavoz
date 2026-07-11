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
    public static let defaultKeyService = "app.portavoz.voice-gallery-key"
    private let keyService: String
    private let fileURL: URL

    /// `~/Library/Application Support/Portavoz/voice-gallery.enc`
    public init(
        directory: URL = VoiceprintStore.defaultDirectory,
        keyService: String = VoiceGallery.defaultKeyService
    ) {
        self.fileURL = directory.appendingPathComponent("voice-gallery.enc")
        self.keyService = keyService
    }

    public var exists: Bool {
        FileManager.default.fileExists(atPath: fileURL.path)
    }

    public func voices() throws -> [RememberedVoice] {
        guard exists else { return [] }
        guard let keyText = try SecretStore.get(service: keyService),
            let keyData = Data(base64Encoded: keyText)
        else {
            // File without key: unreadable by construction; treat as empty.
            return []
        }
        let key = SymmetricKey(data: keyData)
        let combined = try Data(contentsOf: fileURL)
        let box = try AES.GCM.SealedBox(combined: combined)
        let plaintext = try AES.GCM.open(box, using: key)
        return try JSONDecoder().decode([RememberedVoice].self, from: plaintext)
    }

    /// Adds (or replaces, matching by name case-insensitively) a voice.
    /// Replacing keeps the gallery one-embedding-per-person: re-remembering
    /// someone refreshes their voice rather than accumulating stale ones.
    public func remember(_ voice: RememberedVoice) throws {
        var all = (try? voices()) ?? []
        all.removeAll { $0.name.compare(voice.name, options: .caseInsensitive) == .orderedSame }
        all.append(voice)
        try write(all)
    }

    public func remove(id: UUID) throws {
        let remaining = ((try? voices()) ?? []).filter { $0.id != id }
        if remaining.isEmpty {
            try deleteAll()
        } else {
            try write(remaining)
        }
    }

    /// One action, both halves gone (D8).
    public func deleteAll() throws {
        if exists {
            try FileManager.default.removeItem(at: fileURL)
        }
        try SecretStore.delete(service: keyService)
    }

    private func write(_ voices: [RememberedVoice]) throws {
        let key = try loadOrCreateKey()
        let plaintext = try JSONEncoder().encode(voices)
        let sealed = try AES.GCM.seal(plaintext, using: key)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try sealed.combined!.write(to: fileURL, options: .atomic)
    }

    private func loadOrCreateKey() throws -> SymmetricKey {
        if let stored = try SecretStore.get(service: keyService) {
            guard let data = Data(base64Encoded: stored), data.count == 32 else {
                throw VoiceprintStore.VoiceprintError.corruptKey
            }
            return SymmetricKey(data: data)
        }
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        try SecretStore.set(data.base64EncodedString(), service: keyService)
        return key
    }
}
