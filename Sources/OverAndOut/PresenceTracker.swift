import Foundation

/// One camera frame's verdict.
enum PresenceReading: Equatable {
    case present, absent, phoneToEar
}

/// Turns noisy per-frame readings into stable states. A state change needs the new
/// reading to hold for a while, so glancing away or scratching your ear does nothing.
struct PresenceTracker {
    enum State: String, Equatable {
        case present = "at your desk"
        case away = "away"
        case onPhone = "on the phone"
    }

    var awayAfter: TimeInterval = 2
    var phoneAfter: TimeInterval = 1.0
    var backAfter: TimeInterval = 0.75

    private(set) var state: State = .present
    private var candidate: State = .present
    private var candidateSince: Date?

    /// Feeds one reading; returns the new state only when it changes.
    mutating func update(_ reading: PresenceReading, at now: Date) -> State? {
        let wanted: State
        switch reading {
        case .present: wanted = .present
        case .absent: wanted = .away
        case .phoneToEar: wanted = .onPhone
        }

        guard wanted != state else {
            candidate = state
            candidateSince = nil
            return nil
        }
        if wanted != candidate || candidateSince == nil {
            candidate = wanted
            candidateSince = now
        }
        guard let since = candidateSince, now.timeIntervalSince(since) >= delay(for: wanted) else { return nil }

        state = wanted
        candidateSince = nil
        return wanted
    }

    mutating func reset() {
        state = .present
        candidate = .present
        candidateSince = nil
    }

    private func delay(for state: State) -> TimeInterval {
        switch state {
        case .present: return backAfter
        case .away: return awayAfter
        case .onPhone: return phoneAfter
        }
    }
}
