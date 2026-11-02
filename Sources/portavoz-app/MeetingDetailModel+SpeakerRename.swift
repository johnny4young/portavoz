import Foundation
import PortavozCore

extension MeetingDetailModel {
    /// The rename already succeeded; a summary that cannot be rewritten keeps the old name.
    func carrySpeakerRenameIntoSummary(from original: Speaker, to renamed: Speaker) async {
        let oldName = original.displayName ?? original.label
        let newName = renamed.displayName ?? renamed.label
        guard oldName != newName else { return }
        _ = try? await client.applyMeetingDetailSpeakerRenameToSummary(
            meetingID: meetingID, from: oldName, to: newName)
    }
}
