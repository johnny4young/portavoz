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

        init(
            id: UUID = UUID(),
            question: String,
            answer: String,
            citations: [AskCitation],
            noteCitations: [AskNoteCitation] = [],
            webCitations: [AskWebCitation] = [],
            webSourceFailures: [AskWebSourceFailure] = [],
            generationOutcome: AskGenerationOutcome,
            source: ExchangeSource = .library
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
        }
    }

    struct State {
        var surface = Surface.conversation
        var draft = ""
        var exchanges: [Exchange] = []
        var isAsking = false
        var pendingQuestion: String?
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
