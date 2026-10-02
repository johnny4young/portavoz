import Foundation
import GRDB
import PortavozCore

struct AudioImportInputRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "audioImportInput"
    var meetingID: String
    var jobID: String
    let inputFingerprint: String
    var payloadDigest: String
    var payload: Data

    static func admission(_ input: AudioImportRequest) throws -> Self {
        guard input.sourceBookmark != nil else {
            throw StorageError.invalidImportedMeeting("invalid external audio admission")
        }
        let data = try encode(input)
        let digest = Self.digest(data)
        return Self(
            meetingID: input.meetingID.rawValue.uuidString, jobID: "",
            inputFingerprint: digest, payloadDigest: digest, payload: data)
    }

    mutating func replacePayload(_ input: AudioImportRequest) throws {
        payload = try Self.encode(input)
        payloadDigest = Self.digest(payload)
    }

    private static func encode(_ input: AudioImportRequest) throws -> Data {
        try validate(input)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(input)
        guard data.count <= 1_048_576 else {
            throw StorageError.invalidImportedMeeting("import input exceeds the local capability limit")
        }
        return data
    }

    func decoded() throws -> AudioImportRequest {
        guard payload.count <= 1_048_576,
              Self.digest(payload) == payloadDigest,
              let value = try? JSONDecoder().decode(AudioImportRequest.self, from: payload),
              value.meetingID.rawValue.uuidString == meetingID else {
            throw StorageError.invalidImportedMeeting("invalid durable import input")
        }
        try Self.validate(value)
        if value.sourceBookmark != nil, payloadDigest != inputFingerprint {
            throw StorageError.invalidImportedMeeting("external import identity changed")
        }
        return value
    }

    private static func validate(_ input: AudioImportRequest) throws {
        guard input.sourceByteCount >= 0, input.sourceModifiedAt.timeIntervalSince1970.isFinite,
              input.title.utf8.count <= 1_048_576,
              !input.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              AudioImportRequest.isSafeFileExtension(input.fileExtension) else {
            throw StorageError.invalidImportedMeeting("invalid audio input metadata")
        }
        var remainingBytes = 1_048_576 - input.title.utf8.count
        for term in input.preferences.vocabulary {
            let count = term.utf8.count
            guard count < remainingBytes else {
                throw StorageError.invalidImportedMeeting("import text exceeds the local capability limit")
            }
            remainingBytes -= count + 1
        }
        if let bookmark = input.sourceBookmark {
            guard !bookmark.isEmpty, bookmark.count <= 1_048_576,
                  input.copiedAudioDirectory == nil, input.copiedAudioDigest == nil else {
                throw StorageError.invalidImportedMeeting("mixed external and owned source authority")
            }
        } else {
            guard let path = input.copiedAudioDirectory, let digest = input.copiedAudioDigest else {
                throw StorageError.invalidImportedMeeting("missing owned audio copy")
            }
            guard path == input.copyDirectory,
                  digest.utf8.count == 64,
                  digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                throw StorageError.invalidImportedMeeting("invalid owned audio identity")
            }
        }
    }

    private static func digest(_ data: Data) -> String {
        ContentDigest.sha256(data)
    }
}
