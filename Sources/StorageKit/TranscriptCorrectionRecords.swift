import Foundation
import GRDB
import PortavozCore

struct TranscriptCorrectionRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "transcriptCorrection"

    var id: String
    var meetingID: String
    var baseTranscriptRevision: Int
    var kind: String
    var author: String
    var sourceDeviceID: String
    var supersedesCorrectionID: String?
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?

    init(_ event: TranscriptCorrectionEvent) {
        id = event.id.uuidString
        meetingID = event.meetingID.rawValue.uuidString
        baseTranscriptRevision = event.baseTranscriptRevision
        kind = event.kind.storageKind
        author = event.author.rawValue
        sourceDeviceID = event.sourceDeviceID.uuidString
        supersedesCorrectionID = event.supersedesCorrectionID?.uuidString
        createdAt = event.createdAt
        updatedAt = event.updatedAt
        deletedAt = event.deletedAt
    }
}

struct TranscriptCorrectionTargetRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "transcriptCorrectionTarget"

    var correctionID: String
    var segmentID: String
    var ordinal: Int
}

struct TranscriptCorrectionPayloadRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "transcriptCorrectionPayload"

    var correctionID: String
    var text: String?
    var language: String?
    var speakerID: String?
}

struct TranscriptCorrectionPartRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "transcriptCorrectionPart"

    var id: String
    var correctionID: String
    var ordinal: Int
    var text: String
    var speakerID: String?
    var language: String?
    var startTime: Double
    var endTime: Double
}

extension TranscriptCorrectionKind {
    var storageKind: String {
        switch self {
        case .replaceText: "replaceText"
        case .changeSpeaker: "changeSpeaker"
        case .split: "split"
        case .merge: "merge"
        case .suppress: "suppress"
        case .restore: "restore"
        }
    }
}
