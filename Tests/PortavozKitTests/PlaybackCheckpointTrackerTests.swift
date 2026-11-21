@testable import ApplicationKit
import XCTest

final class PlaybackCheckpointTrackerTests: XCTestCase {
    func testNothingIsSavedBeforePlaybackStarts() {
        var tracker = PlaybackCheckpointTracker()
        tracker.didSeek(at: 0)
        XCTAssertFalse(tracker.shouldCheckpoint(isPlaying: false, reachedEnd: false, at: 5))
        XCTAssertFalse(tracker.hasPlayed)
    }

    func testPauseSavesAtOnce() {
        var tracker = PlaybackCheckpointTracker()
        tracker.didPlay(at: 0)
        XCTAssertFalse(tracker.shouldCheckpoint(isPlaying: true, reachedEnd: false, at: 0))
        XCTAssertTrue(tracker.shouldCheckpoint(isPlaying: false, reachedEnd: false, at: 1))
        XCTAssertFalse(tracker.shouldCheckpoint(isPlaying: false, reachedEnd: false, at: 2))
    }

    func testPlaybackSavesPeriodically() {
        var tracker = PlaybackCheckpointTracker()
        tracker.didPlay(at: 100)
        XCTAssertFalse(tracker.shouldCheckpoint(isPlaying: true, reachedEnd: false, at: 109.8))
        XCTAssertTrue(tracker.shouldCheckpoint(isPlaying: true, reachedEnd: false, at: 110))
        XCTAssertFalse(tracker.shouldCheckpoint(isPlaying: true, reachedEnd: false, at: 115))
        XCTAssertTrue(tracker.shouldCheckpoint(isPlaying: true, reachedEnd: false, at: 120))
    }

    func testASeekSavesOnceItSettles() {
        var tracker = PlaybackCheckpointTracker()
        tracker.didPlay(at: 0)
        _ = tracker.shouldCheckpoint(isPlaying: false, reachedEnd: false, at: 0)
        tracker.didSeek(at: 1)
        XCTAssertFalse(tracker.shouldCheckpoint(isPlaying: false, reachedEnd: false, at: 1.4))
        tracker.didSeek(at: 1.6)  // still dragging
        XCTAssertFalse(tracker.shouldCheckpoint(isPlaying: false, reachedEnd: false, at: 2.4))
        XCTAssertTrue(tracker.shouldCheckpoint(isPlaying: false, reachedEnd: false, at: 2.6))
        XCTAssertFalse(tracker.shouldCheckpoint(isPlaying: false, reachedEnd: false, at: 4))
    }

    func testReachingTheEndSaves() {
        var tracker = PlaybackCheckpointTracker()
        tracker.didPlay(at: 0)
        _ = tracker.shouldCheckpoint(isPlaying: true, reachedEnd: false, at: 0)
        XCTAssertTrue(tracker.shouldCheckpoint(isPlaying: false, reachedEnd: true, at: 3))
    }
}
