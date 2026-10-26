import ApplicationKit
import PortavozCore

/// What the transcript header shows and offers for translation, from one read model.
struct MeetingTranscriptTranslationState: Equatable {
    enum Activity: Equatable {
        case idle
        case translating
        case failed(missingLanguages: Bool)
    }

    let translations: [TranscriptTranslation]
    let activity: Activity
    private let transcriptRevision: Int
    private let correctionRevision: TranscriptCorrectionRevision

    init(_ detail: MeetingReviewReadModel) {
        translations = detail.translations
        transcriptRevision = detail.meeting.transcriptRevision
        correctionRevision = detail.core.correctionRevision
        activity = Self.activity(of: detail.processingJobs.filter { $0.kind == .transcriptTranslation })
    }

    var languages: [String] { translations.map(\.targetLanguage) }

    func translation(_ language: String?) -> TranscriptTranslation? {
        translations.first { $0.targetLanguage == language }
    }

    func isCurrent(_ language: String) -> Bool {
        translation(language)?.isCurrent(
            transcriptRevision: transcriptRevision, correctionRevision: correctionRevision) == true
    }

    /// The reading with translated rows in place; untranslated rows keep their original text.
    static func display(
        _ content: MeetingTranscriptContent, translation: TranscriptTranslation?
    ) -> MeetingTranscriptContent {
        guard let translation, !translation.lines.isEmpty else { return content }
        let rows = content.rows.map { row in
            guard let text = translation.lines[row.id] else { return row }
            return MeetingTranscriptContent.Row(
                id: row.id, sourceSegmentIDs: row.sourceSegmentIDs, speakerID: row.speakerID,
                channel: row.channel, text: text, language: translation.targetLanguage,
                startTime: row.startTime, endTime: row.endTime, confidence: row.confidence,
                isFinal: row.isFinal)
        }
        return MeetingTranscriptContent(
            baseTranscriptRevision: content.baseTranscriptRevision, rows: rows,
            chapters: content.chapters, lineage: content.lineage)
    }

    private static func activity(of jobs: [ProcessingJob]) -> Activity {
        guard let latest = jobs.max(by: { $0.updatedAt < $1.updatedAt }) else { return .idle }
        switch latest.state {
        case .pending, .running:
            return .translating
        case .failed:
            return .failed(missingLanguages: false)
        case .cancelled where latest.errorCode == TranscriptTranslationFailure.languagesMissing.code:
            return .failed(missingLanguages: true)
        case .cancelled where latest.errorCode == TranscriptTranslationFailure.unsupported.code:
            return .failed(missingLanguages: false)
        case .cancelled, .succeeded:
            return .idle
        }
    }
}
