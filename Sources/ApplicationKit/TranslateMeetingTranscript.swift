import Foundation
import PortavozCore
import StorageKit
import TranscriptionKit

public protocol TranscriptTranslationStore: Sendable {
    func transcriptTranslationReading(_ meetingID: MeetingID) async throws -> MeetingReviewCore?
    func requestTranscriptTranslation(
        for meetingID: MeetingID, fingerprint: String, at timestamp: Date
    ) async throws -> ProcessingJob
    func cancelTranscriptTranslation(for meetingID: MeetingID, at timestamp: Date) async throws
    func validateTranscriptTranslationLease(
        _ jobID: ProcessingJobID, owner: String, at timestamp: Date
    ) async throws
    func publishTranscriptTranslation(
        _ jobID: ProcessingJobID, owner: String, artifact: TranscriptTranslationArtifact, at timestamp: Date
    ) async throws
}

/// Ends a translation for good: retrying cannot help until the user acts.
public enum TranscriptTranslationFailure: Error, Equatable, LocalizedError, Sendable {
    case languagesMissing
    case unsupported

    public var code: String {
        switch self {
        case .languagesMissing: "translation.languages-missing"
        case .unsupported: "translation.unsupported"
        }
    }

    public var errorDescription: String? {
        switch self {
        case .languagesMissing: "Apple's English and Spanish languages are not downloaded on this Mac."
        case .unsupported: "This language pair is not available on this Mac."
        }
    }
}

/// Requests a translation of the reading Meeting Detail shows now.
public struct RequestTranscriptTranslation: Sendable {
    private let store: any TranscriptTranslationStore

    public init(store: any TranscriptTranslationStore) {
        self.store = store
    }

    public func callAsFunction(
        _ core: MeetingReviewCore, into targetLanguage: String, at timestamp: Date = Date()
    ) async throws -> ProcessingJob {
        guard TranscriptTranslation.languages.contains(targetLanguage) else {
            throw TranscriptTranslationFailure.unsupported
        }
        return try await store.requestTranscriptTranslation(
            for: core.meeting.id,
            fingerprint: TranscriptTranslation.fingerprint(
                meetingID: core.meeting.id, targetLanguage: targetLanguage,
                transcriptRevision: core.meeting.transcriptRevision, correctionRevision: core.correctionRevision),
            at: timestamp)
    }
}

/// Translates one leased job row by row. Rows already in the target language, or whose
/// language is unclear, are left out and read as the original.
public struct TranscriptTranslationWorker: Sendable {
    private let store: any TranscriptTranslationStore
    private let translate: TranslateDictation

    public init(
        store: any TranscriptTranslationStore,
        translator: any DictationTextTranslating,
        lineTimeout: Duration = TranslateDictation.timeout
    ) {
        self.store = store
        translate = TranslateDictation(translator: translator, timeout: lineTimeout)
    }

    func process(_ job: ProcessingJob, owner: String, now: () -> Date) async throws {
        guard let core = try await store.transcriptTranslationReading(job.meetingID) else {
            throw PostCaptureProcessingError.meetingUnavailable
        }
        let target = TranscriptTranslation.languages.sorted().first { language in
            TranscriptTranslation.fingerprint(
                meetingID: core.meeting.id, targetLanguage: language,
                transcriptRevision: core.meeting.transcriptRevision,
                correctionRevision: core.correctionRevision) == job.inputFingerprint
        }
        // The transcript changed since the request: that reading no longer exists to translate.
        guard let target else { throw PostCaptureProcessingError.inputSuperseded(replacement: nil) }
        let rows = MeetingReviewReadModel(
            core: core, summary: nil, companionCards: [], privacyReceipt: nil, processingJobs: []
        ).transcriptContent().rows
        var lines: [UUID: String] = [:]
        for row in rows {
            try Task.checkCancellation()
            try await store.validateTranscriptTranslationLease(job.id, owner: owner, at: now())
            let text = row.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let source = Self.language(of: row, text: text), source != target else { continue }
            let outcome = await translate(text, source: source, target: target)
            try Task.checkCancellation()
            try await store.validateTranscriptTranslationLease(job.id, owner: owner, at: now())
            switch outcome {
            case .translated(let translated):
                lines[row.id] = String(translated.prefix(TranscriptTranslation.maximumLineLength))
            case .kept(.notInstalled):
                throw TranscriptTranslationFailure.languagesMissing
            case .kept(.unsupported):
                throw TranscriptTranslationFailure.unsupported
            case .kept(.timedOut), .kept(.failed):
                throw PostCaptureProcessingError.translationInterrupted
            case .kept(.sameLanguage), .kept(.unknownLanguage):
                continue
            }
        }
        try Task.checkCancellation()
        try await store.publishTranscriptTranslation(
            job.id, owner: owner,
            artifact: TranscriptTranslationArtifact(
                inputFingerprint: job.inputFingerprint,
                translation: TranscriptTranslation(
                    meetingID: core.meeting.id, targetLanguage: target,
                    sourceTranscriptRevision: core.meeting.transcriptRevision,
                    sourceCorrectionRevision: core.correctionRevision, lines: lines, createdAt: now())),
            at: now())
    }

    /// The row's recognized language, else a constrained English or Spanish guess.
    static func language(of row: MeetingTranscriptContent.Row, text: String) -> String? {
        if let recognized = LanguageCode(row.language)?.identifier {
            return TranscriptTranslation.languages.contains(recognized) ? recognized : nil
        }
        return SpokenLanguageDetector.dictationLanguage(in: text)
    }
}

extension MeetingStore: TranscriptTranslationStore {
    public func transcriptTranslationReading(
        _ meetingID: MeetingID
    ) async throws -> ApplicationKit.MeetingReviewCore? {
        try await transcriptTranslationSource(meetingID).map { core in
            ApplicationKit.MeetingReviewCore(
                meeting: core.meeting, speakers: core.speakers, segments: core.segments,
                corrections: core.corrections, correctionRevision: core.correctionRevision,
                isRefinedTranscript: core.isRefinedTranscript)
        }
    }

    public func publishTranscriptTranslation(
        _ jobID: ProcessingJobID, owner: String, artifact: TranscriptTranslationArtifact, at timestamp: Date
    ) async throws {
        _ = try await completeTranscriptTranslationJob(jobID, owner: owner, artifact: artifact, at: timestamp)
    }
}
