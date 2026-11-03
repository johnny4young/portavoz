import ApplicationKit
import Foundation
import PortavozCore
import XCTest

final class CanonicalPeopleUseCaseTests: XCTestCase {
    func testLookupAndBothExplicitSelectionsDelegateWithoutImplicitMerge() async throws {
        let fixture = CanonicalPeopleFixture()
        let store = CanonicalPeopleStoreFake(
            person: fixture.person,
            speaker: fixture.speaker)

        let candidates = try await FindCanonicalPeople(store: store).execute(" Ana ")
        let created = try await LinkObservedSpeaker(store: store).execute(
            fixture.request(selection: .createDistinct))
        let existing = try await LinkObservedSpeaker(store: store).execute(
            fixture.request(selection: .existing(fixture.person.id)))

        XCTAssertEqual(candidates.map(\.id), [fixture.person.id])
        XCTAssertEqual(created.person.id, fixture.person.id)
        XCTAssertEqual(existing.speaker.id, fixture.speaker.id)
        let events = await store.events()
        XCTAssertEqual(events, [
            .lookup(" Ana "),
            .create(fixture.speaker.id, "Ana", .manualName),
            .link(fixture.speaker.id, fixture.person.id, "Ana", .manualName),
        ])
    }

    func testUseCasesPropagateStoreFailure() async {
        let fixture = CanonicalPeopleFixture()
        let store = CanonicalPeopleStoreFake(
            person: fixture.person,
            speaker: fixture.speaker,
            shouldFail: true)

        await assertCanonicalPeopleFailure {
            _ = try await FindCanonicalPeople(store: store).execute("Ana")
        }
        await assertCanonicalPeopleFailure {
            _ = try await LinkObservedSpeaker(store: store).execute(
                fixture.request(selection: .createDistinct))
        }
    }
}

private struct CanonicalPeopleFixture {
    let meeting: Meeting
    let person: Person
    let speaker: Speaker

    init() {
        let meeting = Meeting(title: "Planning", startedAt: Date())
        self.meeting = meeting
        person = Person(preferredName: "Ana")
        speaker = Speaker(meetingID: meeting.id, label: "S1", displayName: "Ana")
    }

    func request(selection: CanonicalPersonSelection) -> LinkObservedSpeakerRequest {
        LinkObservedSpeakerRequest(
            speakerID: speaker.id,
            observedName: "Ana",
            source: .manualName,
            selection: selection)
    }
}

private enum CanonicalPeopleEvent: Equatable {
    case lookup(String)
    case create(SpeakerID, String, PersonAliasSource)
    case link(SpeakerID, PersonID, String, PersonAliasSource)
}

private enum CanonicalPeopleFailure: Error {
    case injected
}

private actor CanonicalPeopleStoreFake: CanonicalPeopleStore {
    private let person: Person
    private let speaker: Speaker
    private let shouldFail: Bool
    private var recordedEvents: [CanonicalPeopleEvent] = []

    init(person: Person, speaker: Speaker, shouldFail: Bool = false) {
        self.person = person
        self.speaker = speaker
        self.shouldFail = shouldFail
    }

    func people(matchingAlias alias: String) throws -> [Person] {
        recordedEvents.append(.lookup(alias))
        if shouldFail { throw CanonicalPeopleFailure.injected }
        return [person]
    }

    func createPersonAndLink(
        speakerID: SpeakerID,
        preferredName: String,
        source: PersonAliasSource
    ) throws -> ConfirmedPersonLink {
        recordedEvents.append(.create(speakerID, preferredName, source))
        if shouldFail { throw CanonicalPeopleFailure.injected }
        return ConfirmedPersonLink(person: person, speaker: speaker)
    }

    func linkSpeaker(
        _ speakerID: SpeakerID,
        to personID: PersonID,
        observedAlias: String,
        source: PersonAliasSource
    ) throws -> ConfirmedPersonLink {
        recordedEvents.append(.link(speakerID, personID, observedAlias, source))
        if shouldFail { throw CanonicalPeopleFailure.injected }
        return ConfirmedPersonLink(person: person, speaker: speaker)
    }

    func events() -> [CanonicalPeopleEvent] { recordedEvents }
}

private func assertCanonicalPeopleFailure(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("expected canonical people failure", file: file, line: line)
    } catch CanonicalPeopleFailure.injected {
        // Expected.
    } catch {
        XCTFail("unexpected error: \(error)", file: file, line: line)
    }
}
