import Foundation

/// Why Hush is holding something (mic muted, media paused, …).
enum Reason: String, CaseIterable, Hashable {
    case ring = "phone ringing"
    case call = "call started"
    case away = "you stepped away"
    case phone = "phone at your ear"
    case panic = "panic mode"
    case manual = "you muted it"
}

/// Things Hush can take away and later give back.
enum Resource: String, CaseIterable, Hashable {
    case mic, meetingAudio, meetingVideo, media, volume
}

/// Reference-counts holds per resource so overlapping reasons never undo each other early:
/// if you walk away during a call, coming back must not resume media the call paused.
struct Ledger {
    private var holds: [Resource: Set<Reason>] = [:]

    /// Adds `reason` to each resource. Returns the resources that were free until now (they need applying).
    mutating func engage(_ reason: Reason, _ resources: [Resource]) -> [Resource] {
        var newlyHeld: [Resource] = []
        for resource in resources {
            if holds[resource, default: []].isEmpty { newlyHeld.append(resource) }
            holds[resource, default: []].insert(reason)
        }
        return newlyHeld
    }

    /// Drops `reason` everywhere. Returns the resources nobody holds any more (they need undoing).
    mutating func release(_ reason: Reason) -> [Resource] {
        var freed: [Resource] = []
        for (resource, reasons) in holds where reasons.contains(reason) {
            var remaining = reasons
            remaining.remove(reason)
            holds[resource] = remaining
            if remaining.isEmpty { freed.append(resource) }
        }
        return freed.sorted { $0.rawValue < $1.rawValue }
    }

    /// Removes one reason's hold on one resource without undoing anything: used when that reason
    /// didn't actually change anything (e.g. a call started with nothing playing), so it mustn't
    /// keep media "paused" and block resuming what a later reason pauses.
    mutating func drop(_ reason: Reason, from resource: Resource) {
        holds[resource]?.remove(reason)
    }

    /// Forgets every hold on one resource (user override, e.g. the unmute hotkey).
    mutating func clear(_ resource: Resource) {
        holds[resource] = []
    }

    func reasons(for resource: Resource) -> Set<Reason> {
        holds[resource] ?? []
    }

    func isHeld(_ resource: Resource) -> Bool {
        !reasons(for: resource).isEmpty
    }

    func isEngaged(_ reason: Reason) -> Bool {
        holds.values.contains { $0.contains(reason) }
    }
}
