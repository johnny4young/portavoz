import ApplicationKit
import PortavozCore
import SwiftUI

/// Library-owned wrapper around the reusable exact brief artifact.
struct MeetingBriefView: View {
    let brief: MeetingBrief
    @Binding var route: Route?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            MeetingBriefArtifactView(
                brief: brief,
                openMeeting: openMeeting)
            HStack {
                Spacer()
                Button("Close") { dismiss() }
                    .accessibilityIdentifier("brief-close-button")
                Button {
                    dismiss()
                    route = .recording(brief.event)
                } label: {
                    Label("Record this meeting", systemImage: "record.circle")
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("brief-record-button")
                .help("Starts recording linked to this event: the meeting gets its real title")
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func openMeeting(_ meetingID: MeetingID) {
        dismiss()
        route = .meeting(meetingID)
    }
}
