import AppKit
import SwiftUI

/// Turns a Focus (Do Not Disturb, Work…) on and off. macOS has no public API for that, so it runs
/// two shortcuts you make once in the Shortcuts app ("Set Focus … On" / "Turn Focus Off"), with
/// Apple's own `shortcuts` command. Names come from Settings → Calls & Media.
enum FocusShortcuts {
    static var onName: String { UserDefaults.standard.string(forKey: SettingsKey.focusOnShortcut) ?? "Over&Out Focus On" }
    static var offName: String { UserDefaults.standard.string(forKey: SettingsKey.focusOffShortcut) ?? "Over&Out Focus Off" }

    static func turnOn() { run(onName) }
    static func turnOff() { run(offName) }

    /// Runs in the background; `completion` gets an error message, or nil when it worked.
    static func run(_ name: String, completion: (@Sendable (String?) -> Void)? = nil) {
        DispatchQueue.global(qos: .userInitiated).async {
            let (status, output) = shortcuts(["run", name])
            let problem: String? = status == 0 ? nil
                : (output.isEmpty ? "The shortcut “\(name)” couldn't run." : output)
            completion?(problem)
        }
    }

    /// Which of the two shortcuts exist (for Settings).
    static func check(completion: @escaping @Sendable (_ on: Bool, _ off: Bool) -> Void) {
        let on = onName, off = offName
        DispatchQueue.global(qos: .utility).async {
            let (_, list) = shortcuts(["list"])
            let names = Set(list.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) })
            completion(names.contains(on), names.contains(off))
        }
    }

    static func openShortcutsApp() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.shortcuts") {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    private static func shortcuts(_ arguments: [String]) -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (-1, "The Shortcuts command isn't available on this Mac.") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (process.terminationStatus, text)
    }
}


/// Settings → Calls & Media → Focus.
struct FocusSection: View {
    @AppStorage(SettingsKey.focusDuringCalls) private var duringCalls = false
    @AppStorage(SettingsKey.focusWhenAway) private var whenAway = false
    @AppStorage(SettingsKey.focusOnShortcut) private var onName = "Over&Out Focus On"
    @AppStorage(SettingsKey.focusOffShortcut) private var offName = "Over&Out Focus Off"
    @State private var found: (on: Bool, off: Bool)?
    @State private var message: String?

    var body: some View {
        Section {
            Toggle("Turn on a Focus during calls", isOn: $duringCalls)
            Toggle("Turn on a Focus while I'm away", isOn: $whenAway)
            if duringCalls || whenAway {
                TextField("Shortcut that turns it on", text: $onName)
                TextField("Shortcut that turns it off", text: $offName)
                HStack {
                    Button("Open Shortcuts") { FocusShortcuts.openShortcutsApp() }
                    Button("Test") { test() }
                    Button("Check") { check() }
                    Spacer()
                    if let found {
                        Text(found.on && found.off ? "✅ Both shortcuts found" : "❌ Shortcut missing")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let message {
                    Text(message).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } header: {
            Text("Focus")
        } footer: {
            Text("macOS lets apps switch a Focus only through Shortcuts. Once: in the Shortcuts app make a shortcut named “\(onName)” with the action “Set Focus” → Do Not Disturb (or any Focus) → On, and one named “\(offName)” with “Set Focus” → Off. Over&Out runs them for you.")
        }
        .onAppear { if duringCalls || whenAway { check() } }
    }

    private func check() {
        FocusShortcuts.check { on, off in
            Task { @MainActor in
                found = (on, off)
                if !on || !off {
                    message = "Make the missing shortcut in the Shortcuts app (names must match exactly), then press Check."
                } else {
                    message = nil
                }
            }
        }
    }

    private func test() {
        message = "Turning the Focus on for 5 seconds…"
        FocusShortcuts.run(onName) { problem in
            Task { @MainActor in
                if let problem {
                    message = problem
                    return
                }
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                FocusShortcuts.run(offName) { problem in
                    Task { @MainActor in message = problem ?? "Worked: the Focus went on and off again." }
                }
            }
        }
    }
}
