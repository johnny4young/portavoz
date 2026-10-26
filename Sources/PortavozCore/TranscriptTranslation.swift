import Foundation

public extension ProcessingJobKind {
    /// An optional overlay requested from Meeting Detail. It never changes the meeting's lifecycle.
    static let transcriptTranslation = ProcessingJobKind(rawValue: "transcript-translation")
}

/// One meeting transcript translated into English or Spanish, fenced to the transcript
/// revision and correction overlay it was read from. Rows already in the target language,
/// or without a clear language, are absent: they read as the original.
public struct TranscriptTranslation: Sendable, Equatable {
    public static let languages: Set<String> = ["en", "es"]
    public static let maximumLineLength = 20_000

    public let meetingID: MeetingID
    public let targetLanguage: String
    public let sourceTranscriptRevision: Int
    public let sourceCorrectionRevision: TranscriptCorrectionRevision
    /// Translated text by transcript row identity.
    public let lines: [UUID: String]
    public let createdAt: Date

    public init(
        meetingID: MeetingID,
        targetLanguage: String,
        sourceTranscriptRevision: Int,
        sourceCorrectionRevision: TranscriptCorrectionRevision,
        lines: [UUID: String],
        createdAt: Date
    ) {
        self.meetingID = meetingID
        self.targetLanguage = targetLanguage
        self.sourceTranscriptRevision = sourceTranscriptRevision
        self.sourceCorrectionRevision = sourceCorrectionRevision
        self.lines = lines
        self.createdAt = createdAt
    }

    public func isCurrent(transcriptRevision: Int, correctionRevision: TranscriptCorrectionRevision) -> Bool {
        sourceTranscriptRevision == transcriptRevision && sourceCorrectionRevision == correctionRevision
    }

    /// The job identity for translating one exact transcript reading.
    public static func fingerprint(
        meetingID: MeetingID,
        targetLanguage: String,
        transcriptRevision: Int,
        correctionRevision: TranscriptCorrectionRevision
    ) -> String {
        OperationFingerprint.make(
            version: "transcript-translation-v1",
            components: [
                meetingID.rawValue.uuidString, targetLanguage,
                String(transcriptRevision), correctionRevision.rawValue
            ])
    }
}

public struct TranscriptTranslationArtifact: Sendable, Equatable {
    public let inputFingerprint: String
    public let translation: TranscriptTranslation

    public init(inputFingerprint: String, translation: TranscriptTranslation) {
        self.inputFingerprint = inputFingerprint
        self.translation = translation
    }
}
