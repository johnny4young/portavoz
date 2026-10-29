import PortavozCore
import TranscriptionKit
import XCTest

final class SpeakerEchoFilterTests: XCTestCase {
    private let meetingID = MeetingID()

    /// 0-10 s is all speaker echo; 10-20 s is the person at the microphone.
    private let profile = MicrophoneEchoProfile(
        frameDuration: 0.5,
        microphoneEnergy: Array(repeating: 1, count: 40),
        nearEndEnergy: (0..<40).map { $0 < 20 ? 0.01 : 0.9 })

    func testEchoAlreadyInTheSystemTranscriptIsDropped() {
        let system = [segment("Wir haben keine Site-ID", .system, 2, 6)]
        let microphone = [segment("We don't have a site ID", .microphone, 2.1, 6.1)]

        let resolution = SpeakerEchoFilter.resolve(
            microphone: microphone, system: system, profile: profile)

        XCTAssertTrue(resolution.microphone.isEmpty)
        XCTAssertTrue(resolution.recoveredSystem.isEmpty)
    }

    func testEchoTheSystemTranscriptMissedMovesToTheRemoteSide() {
        let echo = segment("I can create it for staging", .microphone, 3, 8)
        let system = [segment("Okay.", .system, 1, 3.5)]

        let resolution = SpeakerEchoFilter.resolve(
            microphone: [echo], system: system, profile: profile)

        XCTAssertTrue(resolution.microphone.isEmpty)
        XCTAssertEqual(resolution.recoveredSystem.map(\.id), [echo.id])
        XCTAssertEqual(resolution.recoveredSystem.map(\.channel), [.system])
        XCTAssertEqual(resolution.recoveredSystem.first?.text, echo.text)
        XCTAssertNil(resolution.recoveredSystem.first?.speakerID)
    }

    func testTheUsersOwnSpeechStaysOnTheMicrophone() {
        let mine = segment("Let me know in the chat", .microphone, 12, 15)
        let system = [segment("Thanks, everyone", .system, 12, 15)]

        let resolution = SpeakerEchoFilter.resolve(
            microphone: [mine], system: system, profile: profile)

        XCTAssertEqual(resolution.microphone.map(\.id), [mine.id])
        XCTAssertTrue(resolution.recoveredSystem.isEmpty)
    }

    func testWithoutMeasuredEchoNothingChanges() {
        let microphone = [segment("Okay", .microphone, 2, 3)]

        let resolution = SpeakerEchoFilter.resolve(
            microphone: microphone, system: [], profile: nil)

        XCTAssertEqual(resolution.microphone.map(\.id), microphone.map(\.id))
        XCTAssertTrue(resolution.recoveredSystem.isEmpty)
    }

    func testSegmentsBeyondTheMeasurementStayWithTheUser() {
        let late = segment("Bye", .microphone, 25, 26)

        let resolution = SpeakerEchoFilter.resolve(
            microphone: [late], system: [], profile: profile)

        XCTAssertEqual(resolution.microphone.map(\.id), [late.id])
    }

    func testAttenuationReadsTheEnergyShareInDecibels() throws {
        XCTAssertEqual(try XCTUnwrap(profile.echoAttenuationDB(from: 0, to: 10)), 20, accuracy: 1e-6)
        XCTAssertEqual(
            try XCTUnwrap(profile.echoAttenuationDB(from: 10, to: 20)), 0.4576, accuracy: 1e-3)
        XCTAssertNil(profile.echoAttenuationDB(from: 30, to: 31))
        XCTAssertNil(profile.echoAttenuationDB(from: 5, to: 5))
    }

    private func segment(
        _ text: String,
        _ channel: AudioChannel,
        _ start: TimeInterval,
        _ end: TimeInterval
    ) -> TranscriptSegment {
        TranscriptSegment(
            meetingID: meetingID, channel: channel, text: text,
            startTime: start, endTime: end, isFinal: true)
    }
}
