import Foundation
import PortavozCore
import StorageKit

/// Carries a speaker rename into the stored summary without a model. The
/// old name is replaced only as a whole word, so "Ana" never touches "Anabel".
public enum SummarySpeakerRename {
    /// The summary with fresh row identities, or nil when the name does not appear.
    public static func renamed(
        _ draft: SummaryDraft,
        from oldName: String,
        to newName: String
    ) -> SummaryDraft? {
        let old = oldName.trimmingCharacters(in: .whitespacesAndNewlines)
        let new = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !old.isEmpty, !new.isEmpty, old != new,
              let pattern = try? NSRegularExpression(
                pattern: "(?<![\\p{L}\\p{N}_])"
                    + NSRegularExpression.escapedPattern(for: old)
                    + "(?![\\p{L}\\p{N}_])")
        else { return nil }
        let template = NSRegularExpression.escapedTemplate(for: new)
        func replace(_ text: String) -> String {
            pattern.stringByReplacingMatches(
                in: text,
                range: NSRange(text.startIndex..., in: text),
                withTemplate: template)
        }

        let markdown = replace(draft.markdown)
        let items = draft.actionItems.map { item in
            (old: item.id, new: ActionItem(
                text: replace(item.text),
                ownerSpeakerID: item.ownerSpeakerID,
                isDone: item.isDone))
        }
        guard markdown != draft.markdown
            || zip(draft.actionItems, items).contains(where: { $0.text != $1.new.text })
        else { return nil }

        // Snapshots are immutable rows, so the next version mints its own IDs.
        let itemIDs = Dictionary(uniqueKeysWithValues: items.map { ($0.old, $0.new.id) })
        return SummaryDraft(
            meetingID: draft.meetingID,
            recipeID: draft.recipeID,
            language: draft.language,
            markdown: markdown,
            actionItems: items.map(\.new),
            claims: draft.claims.map {
                SummaryClaim(
                    kind: $0.kind,
                    sourceTranscriptRevision: $0.sourceTranscriptRevision,
                    evidenceSegmentIDs: $0.evidenceSegmentIDs,
                    unavailableEvidenceCount: $0.unavailableEvidenceCount,
                    feedback: $0.feedback)
            },
            decisionEvidence: draft.decisionEvidence.map {
                SummaryDecisionEvidence(
                    sectionOrdinal: $0.sectionOrdinal,
                    bulletOrdinal: $0.bulletOrdinal,
                    sourceTranscriptRevision: $0.sourceTranscriptRevision,
                    evidenceSegmentIDs: $0.evidenceSegmentIDs,
                    unavailableEvidenceCount: $0.unavailableEvidenceCount)
            },
            actionItemEvidence: draft.actionItemEvidence.compactMap { evidence in
                itemIDs[evidence.actionItemID].map {
                    SummaryActionItemEvidence(
                        actionItemID: $0,
                        sourceTranscriptRevision: evidence.sourceTranscriptRevision,
                        evidenceSegmentIDs: evidence.evidenceSegmentIDs,
                        unavailableEvidenceCount: evidence.unavailableEvidenceCount)
                }
            })
    }
}

public protocol SummaryRewriteStore: Sendable {
    func rewriteCurrentSummary(
        meetingID: MeetingID,
        _ rewrite: @escaping @Sendable (SummaryDraft) -> SummaryDraft?
    ) async throws -> Int?
}

extension MeetingStore: SummaryRewriteStore {}

/// Saves the renamed summary as a new version; nil when it never named the speaker.
public struct ApplySpeakerRenameToSummary: Sendable {
    private let store: any SummaryRewriteStore

    public init(store: any SummaryRewriteStore) {
        self.store = store
    }

    @discardableResult
    public func execute(meetingID: MeetingID, from oldName: String, to newName: String) async throws -> Int? {
        try await store.rewriteCurrentSummary(meetingID: meetingID) {
            SummarySpeakerRename.renamed($0, from: oldName, to: newName)
        }
    }
}
