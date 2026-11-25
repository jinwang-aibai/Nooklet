import Foundation

public enum CountdownPhase: String, Codable, Sendable {
    case idle, running, paused, finished
}

/// Deadline-based state: the model owns no timers, queues, or UI subscriptions.
public struct CountdownState: Codable, Equatable, Sendable {
    public private(set) var durationSeconds: TimeInterval
    public private(set) var phase: CountdownPhase
    public private(set) var deadline: Date?
    public private(set) var pausedRemainingSeconds: TimeInterval?

    public init(durationSeconds: TimeInterval = 1500) {
        self.durationSeconds = durationSeconds.isFinite ? min(max(durationSeconds, 1), 86_400) : 1500
        phase = .idle
        deadline = nil
        pausedRemainingSeconds = nil
    }

    public func remainingSeconds(at now: Date = Date()) -> TimeInterval {
        switch phase {
        case .idle: return durationSeconds
        case .running: return min(durationSeconds, max(0, deadline?.timeIntervalSince(now) ?? 0))
        case .paused: return pausedRemainingSeconds ?? 0
        case .finished: return 0
        }
    }

    public mutating func start(now: Date = Date()) {
        phase = .running
        deadline = now.addingTimeInterval(durationSeconds)
        pausedRemainingSeconds = nil
    }

    public mutating func pause(now: Date = Date()) {
        guard phase == .running else { return }
        let remaining = remainingSeconds(at: now)
        deadline = nil
        pausedRemainingSeconds = remaining > 0 ? remaining : nil
        phase = remaining > 0 ? .paused : .finished
    }

    public mutating func resume(now: Date = Date()) {
        guard phase == .paused, let remaining = pausedRemainingSeconds else { return }
        deadline = now.addingTimeInterval(remaining)
        pausedRemainingSeconds = nil
        phase = .running
    }

    public mutating func reset() {
        phase = .idle
        deadline = nil
        pausedRemainingSeconds = nil
    }

    @discardableResult
    public mutating func completeIfNeeded(now: Date = Date()) -> Bool {
        guard phase == .running, remainingSeconds(at: now) <= 0 else { return false }
        phase = .finished
        deadline = nil
        pausedRemainingSeconds = nil
        return true
    }

    private enum CodingKeys: String, CodingKey {
        case durationSeconds, phase, deadline, pausedRemainingSeconds
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        durationSeconds = try container.decode(TimeInterval.self, forKey: .durationSeconds)
        phase = try container.decode(CountdownPhase.self, forKey: .phase)
        deadline = try container.decodeIfPresent(Date.self, forKey: .deadline)
        pausedRemainingSeconds = try container.decodeIfPresent(TimeInterval.self, forKey: .pausedRemainingSeconds)
        let validDuration = durationSeconds.isFinite && (1...86_400).contains(durationSeconds)
        let validState: Bool
        switch phase {
        case .idle, .finished:
            validState = deadline == nil && pausedRemainingSeconds == nil
        case .running:
            validState = deadline?.timeIntervalSinceReferenceDate.isFinite == true && pausedRemainingSeconds == nil
        case .paused:
            validState = deadline == nil && pausedRemainingSeconds.map {
                $0.isFinite && $0 > 0 && $0 <= durationSeconds
            } == true
        }
        guard validDuration && validState else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid countdown state"))
        }
    }
}
