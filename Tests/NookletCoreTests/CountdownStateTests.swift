import Foundation
import NookletCore

final class CountdownStateTests {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    func testDeadlineSurvivesSleepAndCompletesWithoutTicks() throws {
        var state = CountdownState(durationSeconds: 1500)
        state.start(now: start)
        try expectEqual(state.remainingSeconds(at: start.addingTimeInterval(300)), 1200)
        try expect(state.completeIfNeeded(now: start.addingTimeInterval(3600)))
        try expectEqual(state.phase, .finished)
        try expectEqual(state.remainingSeconds(at: start.addingTimeInterval(3600)), 0)
        try expectFalse(state.completeIfNeeded(now: start.addingTimeInterval(3601)))
    }

    func testPauseResumeDoesNotCountPausedTime() throws {
        var state = CountdownState(durationSeconds: 120)
        state.start(now: start)
        state.pause(now: start.addingTimeInterval(20))
        try expectEqual(state.phase, .paused)
        try expectEqual(state.remainingSeconds(at: start.addingTimeInterval(1000)), 100)
        state.resume(now: start.addingTimeInterval(1000))
        try expectEqual(state.remainingSeconds(at: start.addingTimeInterval(1050)), 50)
        state.reset()
        try expectEqual(state.phase, .idle)
        try expectEqual(state.remainingSeconds(at: start), 120)
    }

    func testPersistenceRetainsDeadlineRatherThanStaleRemainingTime() throws {
        var state = CountdownState(durationSeconds: 120)
        state.start(now: start)
        let restored = try JSONDecoder().decode(CountdownState.self, from: JSONEncoder().encode(state))
        try expectEqual(restored, state)
        try expectEqual(restored.remainingSeconds(at: start.addingTimeInterval(110)), 10)
    }

    func testInvalidPersistedStateIsRejected() throws {
        let json = Data(#"{"durationSeconds":120,"phase":"running"}"#.utf8)
        try expectError(try JSONDecoder().decode(CountdownState.self, from: json))
        let invalidPaused = Data(#"{"durationSeconds":120,"phase":"paused","pausedRemainingSeconds":150}"#.utf8)
        try expectError(try JSONDecoder().decode(CountdownState.self, from: invalidPaused))
    }

    func testPauseAfterDeadlineFinishes() throws {
        var state = CountdownState(durationSeconds: 10)
        state.start(now: start)
        state.pause(now: start.addingTimeInterval(11))
        try expectEqual(state.phase, .finished)
        try expectNil(state.pausedRemainingSeconds)
    }

    func testBackwardClockAdjustmentKeepsStateValid() throws {
        var state = CountdownState(durationSeconds: 120)
        state.start(now: start)
        let earlier = start.addingTimeInterval(-3600)
        try expectEqual(state.remainingSeconds(at: earlier), 120)
        state.pause(now: earlier)
        let restored = try JSONDecoder().decode(CountdownState.self, from: JSONEncoder().encode(state))
        try expectEqual(restored, state)
    }
}
