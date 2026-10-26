import ApplicationKit

extension MeetingDetailModel {
    /// The exact artifact one offer would produce — read-only, computed for
    /// the confirmation sheet before anything durable exists.
    func skillPreview(_ offer: MeetingSkillOffer, destination: String?) async -> MeetingSkillPreview? {
        do {
            return try await client.meetingDetailSkillPreview(
                offer,
                destination: destination)
        } catch {
            recordLastActionError(L10n.text(
                "Could not build this action's preview."))
            return nil
        }
    }
}
