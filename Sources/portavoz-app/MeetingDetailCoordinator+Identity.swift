import ApplicationKit
import PortavozCore

extension MeetingDetailCoordinator {
    func renameMeeting(_ meeting: Meeting, title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        flow.sheet = nil
        guard !title.isEmpty else { return }
        Task { await model.send(.renameMeeting(meeting, title: title)) }
    }

    func acceptSuggestedTitle(_ suggestion: String, meeting: Meeting) {
        Task { await model.send(.renameMeeting(meeting, title: suggestion)) }
    }

    func dismissSuggestedTitle() {
        model.dismissSuggestedTitle()
    }

    func suggestNames() {
        Task {
            if case .operationFailed(let message) = await model.send(.loadNameSuggestions) {
                flow.alert = .failure(message)
            }
        }
    }

    func acceptNameSuggestion(
        _ suggestion: MeetingNameSuggestion,
        in detail: MeetingReviewReadModel
    ) {
        Task { await apply(suggestion, in: detail) }
    }

    func dismissNameSuggestion(_ label: String) {
        model.dismissNameSuggestion(label: label)
    }

    func acceptVoiceSuggestion(
        _ suggestion: MeetingVoiceSuggestion,
        in detail: MeetingReviewReadModel
    ) {
        Task { await apply(suggestion, in: detail) }
    }

    func dismissVoiceSuggestion(_ speakerLabel: String) {
        model.dismissVoiceSuggestion(speakerLabel: speakerLabel)
    }

    func findOrCreatePerson(for offer: PersonRememberOffer) {
        Task { await findOrCreatePerson(offer) }
    }

    func rememberVoice(of speaker: Speaker) {
        Task { await rememberVoice(speaker) }
    }

    func linkPerson(
        _ offer: PersonRememberOffer,
        selection: CanonicalPersonSelection
    ) {
        Task { await linkPerson(offer, selection: selection) }
    }

    func renameSpeaker(_ speaker: Speaker, to name: String) {
        Task {
            let effect = await model.send(.renameSpeaker(speaker, name: name))
            if case .speakerRenamed(let renamed) = effect {
                flow.alert = nil
                offerToRememberPerson(renamed, source: .manualName)
                await offerToRememberVoice(renamed)
            }
        }
    }

    private func apply(
        _ suggestion: MeetingNameSuggestion,
        in detail: MeetingReviewReadModel
    ) async {
        guard let speaker = detail.speakers.first(where: { $0.label == suggestion.label }) else {
            return
        }
        let effect = await model.send(.acceptNameSuggestion(speaker, name: suggestion.name))
        switch effect {
        case .nameSuggestionAccepted(let renamed):
            let source: PersonAliasSource = switch suggestion.evidence {
            case .transcript: .transcriptSuggestion
            case .calendarCandidate: .calendarSuggestion
            }
            offerToRememberPerson(renamed, source: source)
            await offerToRememberVoice(renamed)
        case .operationFailed(let message):
            flow.alert = .failure(message)
        default:
            break
        }
    }

    private func apply(
        _ suggestion: MeetingVoiceSuggestion,
        in detail: MeetingReviewReadModel
    ) async {
        guard let speaker = detail.speakers.first(
            where: { $0.label == suggestion.speakerLabel })
        else { return }
        let effect = await model.send(.acceptVoiceSuggestion(speaker, name: suggestion.name))
        switch effect {
        case .voiceSuggestionAccepted(let renamed):
            offerToRememberPerson(renamed, source: .voiceSuggestion)
        case .operationFailed(let message):
            flow.alert = .failure(message)
        default:
            break
        }
    }

    private func offerToRememberPerson(
        _ speaker: Speaker,
        source: PersonAliasSource
    ) {
        guard !speaker.isMe,
              speaker.personID == nil,
              let name = speaker.displayName,
              !name.isEmpty
        else {
            flow.personOffer = nil
            return
        }
        flow.personOffer = PersonRememberOffer(speaker: speaker, source: source)
    }

    private func findOrCreatePerson(_ offer: PersonRememberOffer) async {
        flow.isFindingPerson = true
        defer { flow.isFindingPerson = false }
        let effect = await model.send(
            .findCanonicalPeople(offer.speaker, source: offer.source))
        guard case .canonicalPeopleFound(_, _, let people) = effect else { return }
        if people.isEmpty {
            await linkPerson(offer, selection: .createDistinct)
        } else {
            flow.presentPersonChoice(offer, candidates: people)
        }
    }

    private func linkPerson(
        _ offer: PersonRememberOffer,
        selection: CanonicalPersonSelection
    ) async {
        let effect = await model.send(
            .linkCanonicalPerson(
                offer.speaker,
                source: offer.source,
                selection: selection))
        guard case .canonicalPersonLinked = effect else { return }
        flow.personOffer = nil
        flow.dialog = nil
    }

    private func offerToRememberVoice(_ speaker: Speaker) async {
        guard !speaker.isMe, let name = speaker.displayName, !name.isEmpty else {
            flow.rememberedVoiceOffer = nil
            return
        }
        let effect = await model.send(.checkVoiceMemoryOffer(name: name))
        guard case .voiceMemoryOfferChecked(true) = effect else {
            flow.rememberedVoiceOffer = nil
            return
        }
        flow.rememberedVoiceOffer = speaker
    }

    private func rememberVoice(_ speaker: Speaker) async {
        guard speaker.displayName?.isEmpty == false else { return }
        flow.isRememberingVoice = true
        defer {
            flow.isRememberingVoice = false
            flow.rememberedVoiceOffer = nil
        }
        let effect = await model.send(.rememberVoice(speaker.id))
        switch effect {
        case .voiceMemoryInsufficientAudio:
            flow.alert = .failure(L10n.text(
                "Not enough clear audio from that voice to remember it (about 5 seconds are needed)."))
        case .operationFailed(let message):
            flow.alert = .failure(message)
        default:
            break
        }
    }
}
