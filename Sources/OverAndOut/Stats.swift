import SwiftUI

/// What Over&Out did each day, counted on this Mac only (kept 30 days, never sent anywhere).
struct DayStats: Codable, Equatable {
    var awaySeconds: Double = 0
    var timesAway = 0
    var phoneCalls = 0
    var calls = 0
    var callSeconds: Double = 0
    /// You stepped away or took a phone call during a meeting, and Over&Out muted you / turned your
    /// camera off.
    var savedInCalls = 0
    /// Music or videos paused (or turned down) for you.
    var mediaPauses = 0
    var headphonePauses = 0
    var shoulderGuards = 0
}

@MainActor
enum Stats {
    private static let key = "dailyStats"
    private static let keepDays = 30
    private static var awayStart: Date?
    private static var callStart: Date?

    static func day(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    static var all: [String: DayStats] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let days = try? JSONDecoder().decode([String: DayStats].self, from: data) else { return [:] }
        return days
    }

    static var today: DayStats { all[day()] ?? DayStats() }

    private static func update(_ date: Date = Date(), _ change: (inout DayStats) -> Void) {
        var days = all
        change(&days[day(date), default: DayStats()])
        // Keep only the last 30 days.
        let cutoff = day(Date().addingTimeInterval(-Double(keepDays) * 86_400))
        days = days.filter { $0.key >= cutoff }
        if let data = try? JSONEncoder().encode(days) { UserDefaults.standard.set(data, forKey: key) }
        NotificationCenter.default.post(name: changed, object: nil)
    }

    static let changed = Notification.Name("OverAndOutStatsChanged")

    // MARK: Events (from the engine)

    static func steppedAway(phone: Bool, inCall: Bool) {
        if awayStart == nil { awayStart = Date() }
        update { day in
            if phone { day.phoneCalls += 1 } else { day.timesAway += 1 }
            if inCall { day.savedInCalls += 1 }
        }
    }

    static func cameBack() {
        guard let start = awayStart else { return }
        awayStart = nil
        update(start) { $0.awaySeconds += Date().timeIntervalSince(start) }
    }

    static func callStarted() {
        callStart = Date()
        update { $0.calls += 1 }
    }

    static func callEnded() {
        guard let start = callStart else { return }
        callStart = nil
        update(start) { $0.callSeconds += Date().timeIntervalSince(start) }
    }

    static func mediaPaused() { update { $0.mediaPauses += 1 } }
    static func headphonesPaused() { update { $0.headphonePauses += 1 } }
    static func shoulderGuarded() { update { $0.shoulderGuards += 1 } }

    static func reset() {
        UserDefaults.standard.removeObject(forKey: key)
        NotificationCenter.default.post(name: changed, object: nil)
    }

    /// "1 h 5 min", "12 min", "under a minute".
    static func duration(_ seconds: Double) -> String {
        let minutes = Int(seconds / 60)
        if minutes < 1 { return seconds > 0 ? "under a minute" : "0 min" }
        return minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h \(minutes % 60) min"
    }

    /// One line for the menu.
    static var summary: String {
        let today = self.today
        var parts = ["away \(duration(today.awaySeconds))"]
        parts.append(today.calls == 1 ? "1 call" : "\(today.calls) calls")
        if today.savedInCalls > 0 { parts.append("saved you \(today.savedInCalls)×") }
        return "📊  Today: " + parts.joined(separator: " · ")
    }
}

/// Settings → Stats.
struct StatsView: View {
    @State private var days = Stats.all
    @State private var confirmReset = false

    var body: some View {
        Form {
            Section {
                let today = days[Stats.day()] ?? DayStats()
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                    tile(Stats.duration(today.awaySeconds), "away from your desk")
                    tile("\(today.calls)", today.calls == 1 ? "call" : "calls")
                    tile("\(today.savedInCalls)×", "saved you in a call")
                    tile("\(today.phoneCalls)", "phone calls noticed")
                    tile("\(today.mediaPauses)", "times media paused")
                    tile("\(today.shoulderGuards)", "shoulder-surfers hidden from")
                }
                .padding(.vertical, 6)
            } header: {
                Text("Today")
            } footer: {
                Text("“Saved you” counts the times you stepped away or took a phone call during a meeting and Over&Out muted you and turned your camera off.")
            }

            Section("Last 7 days") {
                ForEach(lastWeek, id: \.self) { date in
                    let stats = days[Stats.day(date)] ?? DayStats()
                    HStack {
                        Text(date.formatted(.dateTime.weekday(.wide).day().month()))
                        Spacer()
                        Text("away \(Stats.duration(stats.awaySeconds)) · \(stats.calls) calls · saved \(stats.savedInCalls)×")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }

            Section {
                let total = days.values.reduce(into: DayStats()) { sum, day in
                    sum.awaySeconds += day.awaySeconds
                    sum.calls += day.calls
                    sum.callSeconds += day.callSeconds
                    sum.savedInCalls += day.savedInCalls
                    sum.mediaPauses += day.mediaPauses
                }
                Text("Last 30 days: \(total.calls) calls (\(Stats.duration(total.callSeconds))), away \(Stats.duration(total.awaySeconds)), saved you \(total.savedInCalls)× in calls, paused media \(total.mediaPauses)×.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text("Counted on this Mac only and never sent anywhere.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset Stats…") { confirmReset = true }
                }
            }
        }
        .formStyle(.grouped)
        .onReceive(NotificationCenter.default.publisher(for: Stats.changed)) { _ in days = Stats.all }
        .confirmationDialog("Reset all stats?", isPresented: $confirmReset) {
            Button("Reset", role: .destructive) { Stats.reset() }
        }
    }

    private var lastWeek: [Date] {
        (0..<7).map { Date().addingTimeInterval(-Double($0) * 86_400) }
    }

    private func tile(_ value: String, _ label: String) -> some View {
        VStack(spacing: 4) {
            Text(value).font(.title2.bold()).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }
}
