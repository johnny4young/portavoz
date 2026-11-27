import Foundation
import PortavozCore

/// A decision, commitment, note or voice match placed beside the transcript
/// row it belongs to.
public struct MeetingMarginNote: Sendable, Identifiable {
    public enum Kind: Sendable {
        case decision(SummaryDecisionEvidence, statement: String)
        case commitment(Commitment)
        /// Something you wrote while recording, beside the line playing then.
        case note(ContextItem)
        /// A voice named without a tap, beside that voice's first line.
        case voice(MeetingVoiceSuggestion)
    }

    public struct Commitment: Sendable {
        public let item: ActionItem
        /// Set while the item still waits for review; confirm, defer and
        /// dismiss act on it.
        public let candidate: CommitmentInboxCandidate?
        /// Who said the anchored line, who owns the item and its confirmed due date.
        public let source: OpenItemSource
    }

    public let rowID: UUID
    public let kind: Kind

    public var id: String {
        switch kind {
        case .decision(let evidence, _): "decision-\(evidence.id.rawValue.uuidString)"
        case .commitment(let commitment): "commitment-\(commitment.item.id.uuidString)"
        case .note(let item): "note-\(item.id.uuidString)"
        case .voice(let match): "voice-\(match.speakerLabel)"
        }
    }
}

/// Consecutive transcript items that lay out together. A line with notes is
/// several times taller than its neighbours, so it never shares their lazy
/// stack, whose size is estimated from the rows it has measured.
public struct TranscriptReadingRun: Sendable, Identifiable {
    public let items: ArraySlice<TranscriptReadingItem>
    public let holdsNotes: Bool
    public let id: TranscriptReadingItem.Key

    /// `items` must not be empty.
    init(items: ArraySlice<TranscriptReadingItem>, holdsNotes: Bool) {
        self.items = items
        self.holdsNotes = holdsNotes
        self.id = items[items.startIndex].id
    }
}

public struct MeetingMarginNotes: Sendable {
    public static let empty = MeetingMarginNotes(byRow: [:])

    public let byRow: [UUID: [MeetingMarginNote]]

    public init(byRow: [UUID: [MeetingMarginNote]]) {
        self.byRow = byRow
    }

    public func notes(forRow rowID: UUID) -> [MeetingMarginNote] {
        byRow[rowID] ?? []
    }

    /// The transcript in layout order: each line with notes alone, and the
    /// lines between them together.
    public func readingRuns(_ items: [TranscriptReadingItem]) -> [TranscriptReadingRun] {
        guard !items.isEmpty else { return [] }
        guard !byRow.isEmpty else { return [TranscriptReadingRun(items: items[...], holdsNotes: false)] }
        var runs: [TranscriptReadingRun] = []
        var start = items.startIndex
        for (index, item) in zip(items.indices, items) {
            guard case .row(let row, _) = item, byRow[row.id]?.isEmpty == false else { continue }
            if start < index { runs.append(TranscriptReadingRun(items: items[start..<index], holdsNotes: false)) }
            runs.append(TranscriptReadingRun(items: items[index...index], holdsNotes: true))
            start = index + 1
        }
        if start < items.endIndex { runs.append(TranscriptReadingRun(items: items[start...], holdsNotes: false)) }
        return runs
    }

    public var hasDecisions: Bool {
        byRow.values.joined().contains {
            if case .decision = $0.kind { return true }
            return false
        }
    }

    /// Action items that already sit beside their line.
    public var anchoredItemIDs: Set<UUID> {
        Set(byRow.values.joined().compactMap {
            if case .commitment(let commitment) = $0.kind { return commitment.item.id }
            return nil
        })
    }

    /// Adds each voice match beside the first line its speaker said, in one
    /// pass over the rows, and returns the matches with no shown line.
    public func addingVoiceMatches(
        _ matches: [MeetingVoiceSuggestion],
        speakers: [Speaker],
        in content: MeetingTranscriptContent
    ) -> (notes: MeetingMarginNotes, unplaced: [MeetingVoiceSuggestion]) {
        guard !matches.isEmpty else { return (self, []) }
        let labels = Set(matches.map(\.speakerLabel))
        var pending = Dictionary(
            speakers.filter { labels.contains($0.label) }.map { ($0.id, $0.label) },
            uniquingKeysWith: { first, _ in first })
        var firstRowByLabel: [String: UUID] = [:]
        for row in content.rows where !pending.isEmpty {
            guard let speakerID = row.speakerID, let label = pending.removeValue(forKey: speakerID) else { continue }
            firstRowByLabel[label] = row.id
        }
        var byRow = byRow
        var unplaced: [MeetingVoiceSuggestion] = []
        for match in matches {
            guard let rowID = firstRowByLabel[match.speakerLabel] else {
                unplaced.append(match)
                continue
            }
            byRow[rowID, default: []].append(MeetingMarginNote(rowID: rowID, kind: .voice(match)))
        }
        return (MeetingMarginNotes(byRow: byRow), unplaced)
    }

    /// The inbox keeps only candidates without a card beside their line, so
    /// each commitment shows in one place.
    public func inbox(_ candidates: [CommitmentInboxCandidate]) -> [CommitmentInboxCandidate] {
        let anchored = anchoredItemIDs
        return candidates.filter { !anchored.contains($0.id) }
    }
}

public extension MeetingReviewReadModel {
    /// Notes keyed by the visible row holding each item's first evidence line,
    /// and your notes keyed by the line playing when you wrote them. Only a
    /// current summary anchors decisions and commitments; dismissed or deferred
    /// commitments and items whose evidence no longer resolves stay out.
    func marginNotes(in content: MeetingTranscriptContent, at date: Date = Date()) -> MeetingMarginNotes {
        guard let firstRow = content.rows.first else { return .empty }
        let written = notes.contextItems.map { item in
            MeetingMarginNote(rowID: content.activeRowID(at: item.timestamp) ?? firstRow.id, kind: .note(item))
        }
        let summarized = summaryMarginNotes(in: content, at: date)
        return MeetingMarginNotes(byRow: Dictionary(grouping: summarized + written, by: \.rowID))
    }

    private func summaryMarginNotes(in content: MeetingTranscriptContent, at date: Date) -> [MeetingMarginNote] {
        guard let summary, summaryFreshness == .current else { return [] }
        let rows = Dictionary(content.rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        typealias Anchor = (row: MeetingTranscriptContent.Row, line: TranscriptSegment)
        func anchor(_ resolution: TranscriptEvidenceResolution) -> Anchor? {
            guard resolution.status == .current else { return nil }
            for line in resolution.segments {
                if let rowID = content.rowID(containingSourceSegmentID: line.id, at: line.startTime),
                   let row = rows[rowID] {
                    return (row, line)
                }
            }
            return nil
        }

        var decisions: [MeetingMarginNote] = []
        let outline = SummaryMarkdownOutline.parse(summary.draft.markdown)
        var placedBullets: Set<[Int]> = []
        for evidence in summary.draft.decisionEvidence {
            let bullet = [evidence.sectionOrdinal, evidence.bulletOrdinal]
            guard !placedBullets.contains(bullet),
                  let text = outline.bulletText(
                      sectionOrdinal: evidence.sectionOrdinal, bulletOrdinal: evidence.bulletOrdinal),
                  let anchor = anchor(evidence.resolveEvidence(
                      currentTranscriptRevision: meeting.transcriptRevision, segments: segments))
            else { continue }
            placedBullets.insert(bullet)
            decisions.append(MeetingMarginNote(
                rowID: anchor.row.id, kind: .decision(evidence, statement: text)))
        }

        // Open items reuse the inbox's resolved evidence and status; done ones resolve here.
        let states = Dictionary(
            commitmentReviewStates.map { ($0.actionItemID, $0) }, uniquingKeysWith: { first, _ in first })
        let evidenceByItem = Dictionary(
            summary.draft.actionItemEvidence.map { ($0.actionItemID, $0) }, uniquingKeysWith: { first, _ in first })
        let candidates = Dictionary(
            commitmentInboxCandidates(at: date).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var commitments: [MeetingMarginNote] = []
        for item in summary.draft.actionItems {
            let status = candidates[item.id]?.status ?? Self.commitmentInboxStatus(states[item.id], at: date)
            let confirmed: PortavozCore.Commitment?
            switch status {
            case .dismissed, .deferred: continue
            case .confirmed(let commitment): confirmed = commitment
            case .pending: confirmed = nil
            }
            guard let resolution = candidates[item.id]?.evidence ?? evidenceByItem[item.id]?.resolveEvidence(
                      currentTranscriptRevision: meeting.transcriptRevision, segments: segments),
                  let anchor = anchor(resolution)
            else { continue }
            commitments.append(MeetingMarginNote(
                rowID: anchor.row.id,
                kind: .commitment(MeetingMarginNote.Commitment(
                    item: item,
                    candidate: confirmed == nil ? candidates[item.id] : nil,
                    source: marginSource(item, row: anchor.row, line: anchor.line, confirmed: confirmed)))))
        }
        return decisions + commitments
    }

    private func marginSource(
        _ item: ActionItem,
        row: MeetingTranscriptContent.Row,
        line: TranscriptSegment,
        confirmed: PortavozCore.Commitment?
    ) -> OpenItemSource {
        func voice(_ speaker: Speaker) -> OpenItemSource.Voice {
            OpenItemSource.Voice(
                speakerID: speaker.id, isMe: speaker.isMe, label: speaker.label,
                displayName: speaker.displayName, personID: speaker.personID)
        }
        func voice(_ id: SpeakerID?) -> OpenItemSource.Voice? {
            id.flatMap { id in speakers.first { $0.id == id } }.map(voice)
        }
        let owner: OpenItemSource.Voice?
        switch confirmed?.assignee {
        case .me:
            owner = speakers.first(where: \.isMe).map(voice)
                ?? OpenItemSource.Voice(speakerID: nil, isMe: true, label: "Me", displayName: nil)
        case .person(let personID):
            owner = speakers.first { $0.personID == personID }.map(voice)
        case .unassigned:
            owner = nil
        case nil:
            // The proposal's owner was read off the line's speaker before any speaker fix.
            let proposed = item.ownerSpeakerID == line.speakerID ? row.speakerID : item.ownerSpeakerID
            owner = voice(proposed)
        }
        return OpenItemSource(
            saidBy: voice(row.speakerID), time: row.startTime, owner: owner, dueAt: confirmed?.dueAt)
    }
}
