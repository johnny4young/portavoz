import Foundation
import PortavozCore
import Testing

struct CallEndedNotificationFenceTests {
    @Test
    func withdrawalInvalidatesASuspendedPostAndItsActions() {
        var fence = CallEndedNotificationFence()
        let session = UUID()
        let ticket = fence.begin(sessionID: session)
        #expect(fence.accepts(identifier: ticket.identifier, sessionID: session, isRecording: true))
        #expect(fence.withdraw() == ticket)
        #expect(fence.current != ticket)
        #expect(!fence.accepts(identifier: ticket.identifier, sessionID: session, isRecording: true))
    }

    @Test
    func previousQuestionCannotControlANewRecordingOrQuestion() {
        var fence = CallEndedNotificationFence()
        let first = UUID(), second = UUID()
        let old = fence.begin(sessionID: first)
        let current = fence.begin(sessionID: second)
        #expect(!fence.accepts(identifier: old.identifier, sessionID: second, isRecording: true))
        #expect(!fence.accepts(identifier: current.identifier, sessionID: first, isRecording: true))
        #expect(!fence.accepts(identifier: nil, sessionID: second, isRecording: true))
        #expect(!fence.accepts(identifier: current.identifier, sessionID: second, isRecording: false))
        #expect(fence.accepts(identifier: current.identifier, sessionID: second, isRecording: true))
        let repeated = fence.begin(sessionID: second)
        #expect(!fence.accepts(identifier: current.identifier, sessionID: second, isRecording: true))
        #expect(fence.accepts(identifier: repeated.identifier, sessionID: second, isRecording: true))
    }
}
