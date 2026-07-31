import Foundation

enum LibraryMarkdownBackupRecoveryValidation {
    static func isValid(
        _ state: LibraryMarkdownBackupRecoveryState,
        for source: any LibraryMarkdownBackupSourceSession,
        phase: LibraryMarkdownBackupRecoveryPhase
    ) -> Bool {
        guard state.operationID == source.id,
              state.phase == phase,
              state.pendingPublication == nil,
              state.completedPublications.indices.allSatisfy({
                  state.completedPublications[$0].sequence == $0
                      && state.completedPublications[$0].sourceCursor != nil
              }),
              state.failures.indices.allSatisfy({
                  state.failures[$0].sequence == $0
              })
        else { return false }

        let outcomeCount = state.completedPublications.count
            + state.failures.count
        guard phase == .active
                ? outcomeCount <= source.totalMeetings
                : outcomeCount == source.totalMeetings
        else { return false }

        let fileNames = state.completedPublications.map(\.fileName)
        guard Set(fileNames).count == fileNames.count else { return false }

        let outcomeCursors = state.completedPublications.compactMap(\.sourceCursor)
            + state.failures.map(\.sourceCursor)
        let cursorKeys = outcomeCursors.map {
            "\($0.startedAt.timeIntervalSince1970)|\($0.recordID)"
        }
        guard Set(cursorKeys).count == cursorKeys.count else { return false }
        guard var furthest = outcomeCursors.first else {
            return state.sourceCursor == nil
        }
        for candidate in outcomeCursors.dropFirst()
        where isAfter(candidate, furthest) {
            furthest = candidate
        }
        return state.sourceCursor == furthest
    }

    private static func isAfter(
        _ candidate: LibraryMarkdownBackupSourceCursor,
        _ current: LibraryMarkdownBackupSourceCursor
    ) -> Bool {
        candidate.startedAt < current.startedAt
            || (
                candidate.startedAt == current.startedAt
                    && candidate.recordID > current.recordID
            )
    }
}
