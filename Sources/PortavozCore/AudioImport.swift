import Foundation

/// Platform-backed preferences sampled once at the import boundary.
public struct ImportMeetingPreferencesSnapshot: Codable, Equatable, Sendable {
    public let transcriptLanguage: TranscriptLanguagePolicy
    public let summaryLanguage: SummaryLanguagePolicy
    public let summaryFallbackLanguage: LanguageCode
    public let vocabulary: [String]

    public init(
        transcriptLanguage: TranscriptLanguagePolicy,
        summaryLanguage: SummaryLanguagePolicy,
        summaryFallbackLanguage: LanguageCode,
        vocabulary: [String]
    ) {
        self.transcriptLanguage = transcriptLanguage
        self.summaryLanguage = summaryLanguage
        self.summaryFallbackLanguage = summaryFallbackLanguage
        self.vocabulary = vocabulary
    }
}

/// Explicitly selected external audio. The bookmark is a local capability,
/// never a portable path or authority for background microphone capture.
public struct AudioImportRequest: Codable, Equatable, Sendable {
    /// This is path safety, not a codec allowlist. The platform picker and
    /// decoder retain authority over which selected audio can be processed.
    public static func isSafeFileExtension(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 16
            && value.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) }
    }

    public let meetingID: MeetingID
    /// Reserved before touching the filesystem; retries reuse this exact stage.
    public let copyID: UUID
    public var copyDirectory: String {
        "Audio/\(meetingID.rawValue.uuidString)/Imports/\(copyID.uuidString)"
    }
    public let title: String
    public let fileExtension: String
    public let sourceByteCount: Int64
    public let sourceModifiedAt: Date
    public let preferences: ImportMeetingPreferencesSnapshot
    public var sourceBookmark: Data?
    public var copiedAudioDirectory: String?
    public var copiedAudioDigest: String?

    public init(
        meetingID: MeetingID = MeetingID(), copyID: UUID = UUID(), title: String, fileExtension: String,
        sourceByteCount: Int64, sourceModifiedAt: Date, sourceBookmark: Data,
        preferences: ImportMeetingPreferencesSnapshot
    ) {
        self.meetingID = meetingID
        self.copyID = copyID
        self.title = title
        self.fileExtension = fileExtension
        self.sourceByteCount = sourceByteCount
        self.sourceModifiedAt = sourceModifiedAt
        self.sourceBookmark = sourceBookmark
        self.preferences = preferences
    }
}
