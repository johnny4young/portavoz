import ApplicationKit
import Foundation
import PortavozCore
import SwiftUI

/// What one suggestion row in Radar's To review list draws, independent of SwiftUI.
enum CommitmentReviewPresentation {
    /// Times listed after the strip; every moment is still marked on it.
    static let shownMomentCount = 3

    struct Speaker: Equatable {
        let name: String
        let isMe: Bool
        let tint: VoiceCast.Tint

        /// "Marta said it" with the name in ink and semibold.
        var saidIt: AttributedString {
            var text = AttributedString(isMe ? L10n.text("You said it") : L10n.format("%@ said it", name))
            if let range = text.range(of: isMe ? L10n.text("You") : name, options: .caseInsensitive) {
                text[range].font = .subheadline.weight(.semibold)
                text[range].foregroundColor = PVDesign.ink
            }
            return text
        }
    }

    struct Row: Identifiable {
        let item: CommitmentReviewQueueItem
        /// Nil until the voices load, or when nobody is heard saying the evidence.
        let speaker: Speaker?
        let strip: VoiceStripColumns?
        let moments: [Double]

        var id: UUID { item.id }

        var ownerChip: String? {
            item.suggestedOwner.map { L10n.format("Owner: %@?", $0.displayName) }
        }

        /// Confirmation needs the complete source to still match the transcript.
        var canConfirm: Bool { !item.currentEvidence.isEmpty }

        var firstMoment: TimeInterval? { item.currentEvidence.first?.startTime }

        var shownSegments: ArraySlice<TranscriptSegment> {
            item.evidence.segments.prefix(CommitmentReviewPresentation.shownMomentCount)
        }

        var hiddenMomentCount: Int {
            max(0, item.evidenceCount - shownSegments.count)
        }

        /// "Planning Q4 · Mon 14 Sep", the day worked out when drawn so it never goes stale.
        func meeting(now: Date = Date(), calendar: Calendar = .current) -> String {
            let day = AskEvidencePresentation.day(item.meetingStartedAt, now: now, calendar: calendar)
            return "\(MeetingRowTitle.display(item.meetingTitle)) · \(day)"
        }
    }

    static func rows(_ items: [CommitmentReviewQueueItem], voices: CommitmentReviewVoices) -> [Row] {
        let cast = TodayPageCast(meetings: voices.strips.map { ($0.meetingID, $0.source) })
        return items.map { item in
            let loaded = voices.items[item.id]
            return Row(
                item: item,
                speaker: loaded?.voice.map { voice in
                    let isMe = voice.identity == .me
                    return Speaker(
                        name: VoiceName.of(isMe: isMe, name: voice.name, label: voice.label),
                        isMe: isMe,
                        tint: cast.tint(for: voice.speakerID, isMe: isMe, in: item.meetingID))
                },
                strip: cast.strip(for: item.meetingID),
                moments: loaded?.moments ?? [])
        }
    }

    @MainActor
    static func clock(_ seconds: TimeInterval) -> String {
        ClockFormat.mmss(seconds, paddedMinutes: false, locale: AppLanguage.current.locale)
    }
}
