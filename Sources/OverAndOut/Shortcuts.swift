import AppKit
import Carbon
import SwiftUI

/// The actions that have global keyboard shortcuts (Settings → General → Keyboard shortcuts).
enum ShortcutAction: String, CaseIterable, Identifiable {
    case menu, enabled, camera, mic, panic
    var id: String { rawValue }

    var title: String {
        switch self {
        case .menu: return "Open Over&Out's menu (even if its icon is hidden)"
        case .enabled: return "Turn Over&Out on / off"
        case .camera: return "Over&Out camera on / off"
        case .mic: return "Mute / unmute microphone"
        case .panic: return "Panic: mute, video off, pause, lower volume"
        }
    }

    /// The shortcuts Over&Out always had: ⌃⌥⌘ + a letter.
    var defaultShortcut: KeyShortcut {
        let key: (Int, String)
        switch self {
        case .menu: key = (kVK_ANSI_H, "H")
        case .enabled: key = (kVK_ANSI_G, "G")
        case .camera: key = (kVK_ANSI_C, "C")
        case .mic: key = (kVK_ANSI_M, "M")
        case .panic: key = (kVK_ANSI_P, "P")
        }
        return KeyShortcut(keyCode: key.0, modifiers: HotKeys.controlOptionCommand, key: key.1)
    }
}

/// A key plus Carbon modifier flags, as RegisterEventHotKey wants them.
struct KeyShortcut: Codable, Equatable {
    var keyCode: Int
    var modifiers: UInt32
    /// The key as printed ("M", "F5", "Space").
    var key: String

    var display: String {
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + key
    }

    /// For the menu's key equivalents.
    var menuModifiers: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        if modifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if modifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        if modifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        return flags
    }

    var menuKey: String { key.count == 1 ? key.lowercased() : "" }

    init(keyCode: Int, modifiers: UInt32, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.key = key
    }

    /// From a key press in the recorder. nil without ⌃, ⌥ or ⌘ (a bare letter would fire while typing).
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var carbon: UInt32 = 0
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        guard carbon & UInt32(controlKey | optionKey | cmdKey) != 0 else { return nil }
        let names: [Int: String] = [kVK_Space: "Space", kVK_Return: "↩", kVK_Delete: "⌫", kVK_Tab: "⇥",
                                    kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5",
                                    kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10",
                                    kVK_F11: "F11", kVK_F12: "F12", kVK_LeftArrow: "←", kVK_RightArrow: "→",
                                    kVK_UpArrow: "↑", kVK_DownArrow: "↓"]
        let code = Int(event.keyCode)
        let key = names[code] ?? (event.charactersIgnoringModifiers ?? "").uppercased()
        guard !key.isEmpty else { return nil }
        self.init(keyCode: code, modifiers: carbon, key: key)
    }
}

/// Where the shortcuts are kept; posting `changed` makes the app re-register them.
enum ShortcutStore {
    static let changed = Notification.Name("OverAndOutShortcutsChanged")
    private static func key(_ action: ShortcutAction) -> String { "shortcut." + action.rawValue }

    /// nil: switched off ("None").
    static func shortcut(for action: ShortcutAction) -> KeyShortcut? {
        let defaults = UserDefaults.standard
        guard let data = defaults.data(forKey: key(action)) else { return action.defaultShortcut }
        if data.isEmpty { return nil }
        return (try? JSONDecoder().decode(KeyShortcut.self, from: data)) ?? action.defaultShortcut
    }

    static func set(_ shortcut: KeyShortcut?, for action: ShortcutAction) {
        let data = shortcut.flatMap { try? JSONEncoder().encode($0) } ?? Data()
        UserDefaults.standard.set(data, forKey: key(action))
        NotificationCenter.default.post(name: changed, object: nil)
    }

    static func reset(_ action: ShortcutAction) {
        UserDefaults.standard.removeObject(forKey: key(action))
        NotificationCenter.default.post(name: changed, object: nil)
    }

    /// Another action already using this combination.
    static func conflict(_ shortcut: KeyShortcut, except action: ShortcutAction) -> ShortcutAction? {
        ShortcutAction.allCases.first { other in
            other != action && self.shortcut(for: other).map {
                $0.keyCode == shortcut.keyCode && $0.modifiers == shortcut.modifiers
            } == true
        }
    }
}

/// One row: the action, its shortcut, and buttons to record a new one, switch it off or reset it.
struct ShortcutRecorderRow: View {
    let action: ShortcutAction
    @State private var current: KeyShortcut?
    @State private var recording = false
    @State private var monitor: Any?
    @State private var problem: String?

    init(action: ShortcutAction) {
        self.action = action
        _current = State(initialValue: ShortcutStore.shortcut(for: action))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(action.title)
                Spacer()
                Button(recording ? "Press keys…" : (current?.display ?? "None")) {
                    recording ? stopRecording() : startRecording()
                }
                .font(.system(.body, design: .monospaced))
                .help("Click, then press the new shortcut (with ⌃, ⌥ or ⌘). Esc cancels.")
                Menu {
                    Button("Switch Off") { save(nil) }
                    Button("Reset to \(action.defaultShortcut.display)") {
                        ShortcutStore.reset(action)
                        current = ShortcutStore.shortcut(for: action)
                        problem = nil
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            if let problem {
                Text(problem).font(.caption).foregroundStyle(.orange)
            }
        }
        .onDisappear { stopRecording() }
    }

    private func startRecording() {
        problem = nil
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape) {
                stopRecording()
                return nil
            }
            guard let shortcut = KeyShortcut(event: event) else {
                problem = "Use at least one of ⌃, ⌥ or ⌘ with the key."
                return nil
            }
            if let other = ShortcutStore.conflict(shortcut, except: action) {
                problem = "\(shortcut.display) is already used for “\(other.title)”."
                return nil
            }
            save(shortcut)
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func save(_ shortcut: KeyShortcut?) {
        ShortcutStore.set(shortcut, for: action)
        current = shortcut
    }
}
