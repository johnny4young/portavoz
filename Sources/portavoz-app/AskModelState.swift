import ApplicationKit
import Foundation
import PortavozCore

extension AskModel {
    enum Surface: Equatable {
        case conversation
        case personCommitments
        case topicDecisions
    }

    enum PendingPhase: Equatable {
        case findingEvidence
        case refiningEvidence
        case generatingAnswer
    }

    enum SourceMode: String, CaseIterable, Equatable {
        case library
        case meeting
        case notes
        case web
    }

    enum SourceCatalogState: Equatable {
        case idle
        case loading
        case loaded
        case failed
    }

    enum ExchangeSource: Equatable {
        case library
        case meeting(id: MeetingID, title: String)
        case notes
        case web(host: String)
    }

    struct Exchange: Identifiable, Equatable {
        let id: UUID
        let question: String
        let answer: String
        let citations: [AskCitation]
        let noteCitations: [AskNoteCitation]
        let webCitations: [AskWebCitation]
        let webSourceFailures: [AskWebSourceFailure]
        let generationOutcome: AskGenerationOutcome
        let source: ExchangeSource
        /// "Who said it" rows; nil until they load after the answer, or if the read fails.
        var evidence: AskEvidence? {
            didSet { rows = AskEvidencePresentation.rows(citations: citations, evidence: evidence) }
        }
        /// What the page draws, built once per change rather than per render.
        private(set) var rows: [AskEvidencePresentation.Row]
        let answerPieces: [AskEvidencePresentation.Piece]
        let askedAt: Date
        /// From the question to the answer, before evidence rows load.
        let answeredIn: Duration?
        /// Arrives after the answer; empty when no local model could suggest.
        var followUps: [String] = []

        init(
            id: UUID = UUID(),
            question: String,
            answer: String,
            citations: [AskCitation],
            noteCitations: [AskNoteCitation] = [],
            webCitations: [AskWebCitation] = [],
            webSourceFailures: [AskWebSourceFailure] = [],
            generationOutcome: AskGenerationOutcome,
            source: ExchangeSource = .library,
            evidence: AskEvidence? = nil,
            askedAt: Date = Date(),
            answeredIn: Duration? = nil
        ) {
            self.id = id
            self.question = question
            self.answer = answer
            self.citations = citations
            self.noteCitations = noteCitations
            self.webCitations = webCitations
            self.webSourceFailures = webSourceFailures
            self.generationOutcome = generationOutcome
            self.source = source
            self.evidence = evidence
            rows = AskEvidencePresentation.rows(citations: citations, evidence: evidence)
            answerPieces = AskEvidencePresentation.pieces(of: answer, citationCount: citations.count)
            self.askedAt = askedAt
            self.answeredIn = answeredIn
        }

        var hasCitations: Bool {
            !citations.isEmpty || !noteCitations.isEmpty || !webCitations.isEmpty
        }
    }

    struct State {
        var surface = Surface.conversation
        var draft = ""
        var exchanges: [Exchange] = []
        var isAsking = false
        var pendingQuestion: String?
        var pendingAskedAt: Date?
        var pendingCitations: [AskCitation] = []
        var pendingNoteCitations: [AskNoteCitation] = []
        var pendingWebCitations: [AskWebCitation] = []
        var pendingWebSourceFailures: [AskWebSourceFailure] = []
        var pendingAnswerText: String?
        var pendingPhase: PendingPhase?
        var pendingSource: ExchangeSource?
        var sourceMode = SourceMode.library
        var sourceMeetings: [AskSourceMeetingOption] = []
        var selectedSourceMeetingID: MeetingID?
        var sourceCatalogState = SourceCatalogState.idle
        var webSourceDraft = ""
        var webConsentApproved = false
    }
}
