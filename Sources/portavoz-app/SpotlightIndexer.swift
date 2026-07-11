import CoreSpotlight
import Foundation
import PortavozCore
import StorageKit

/// M16: meetings in Spotlight — search a title or a phrase someone said
/// and jump straight to the meeting. The index lives in the LOCAL system
/// Spotlight store (never leaves the Mac, gone if the app is deleted).
/// Strategy: full rebuild at launch (delete + insert) — eventual-consistent
/// with deletes and cheap even for large libraries (metadata only), so no
/// per-mutation bookkeeping can drift.
enum SpotlightIndexer {
    static let domain = "app.portavoz.meetings"

    static func reindexAll(store: MeetingStore) async {
        guard !ProcessInfo.processInfo.arguments.contains("-use-temp-store") else { return }
        guard CSSearchableIndex.isIndexingAvailable() else { return }
        let meetings = (try? await store.meetings()) ?? []
        var items: [CSSearchableItem] = []
        items.reserveCapacity(meetings.count)
        for meeting in meetings {
            let attributes = CSSearchableItemAttributeSet(contentType: .content)
            attributes.title = meeting.title
            attributes.contentCreationDate = meeting.startedAt
            // The summary's first lines make the strongest search text;
            // fall back to the first transcript lines.
            if let detail = try? await store.detail(meeting.id) {
                let summaryText = (try? await store.summary(meeting.id))?.draft.markdown
                let transcript = detail.segments.prefix(40).map(\.text).joined(separator: " ")
                let body = [summaryText, transcript].compactMap { $0 }.joined(separator: "\n")
                attributes.contentDescription = String(body.prefix(4_000))
            }
            items.append(CSSearchableItem(
                uniqueIdentifier: meeting.id.rawValue.uuidString,
                domainIdentifier: domain,
                attributeSet: attributes))
        }
        let index = CSSearchableIndex.default()
        try? await index.deleteSearchableItems(withDomainIdentifiers: [domain])
        guard !items.isEmpty else { return }
        try? await index.indexSearchableItems(items)
    }
}
