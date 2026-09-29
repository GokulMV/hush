import AppKit
import ApplicationServices

/// Helps set up browsers for Over&Out from the Setup Assistant: checks whether a browser runs
/// JavaScript sent by Over&Out, and can switch on "Allow JavaScript from Apple Events" by clicking
/// that item in the browser's own menu (View → Developer, or Safari's Develop menu).
/// Everything here is synchronous; call it off the main thread.
enum BrowserSetup {
    enum State: Equatable {
        case notRunning, ready, needsJavaScript, needsAutomation, noWindow, unknown
    }

    /// Supported browsers installed on this Mac, with their display names.
    static var installed: [(id: String, name: String)] {
        BrowserMedia.supported.keys.sorted().compactMap { id in
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
            return (id, FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""))
        }
    }

    /// Installed browsers that can't run JavaScript for Over&Out (listed in Setup so nobody wonders).
    static var installedUnsupported: [String] {
        BrowserMedia.unsupported.keys.sorted().compactMap { id in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) == nil ? nil : BrowserMedia.unsupported[id]
        }
    }

    static func isRunning(_ id: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty
    }

    /// Runs a harmless script ("1") in the front tab. The first time, macOS asks
    /// "Over&Out wants to control <browser>".
    static func check(_ id: String) -> State {
        checkDetailed(id).state
    }

    /// The state plus the browser's exact reply, for showing when it isn't ready.
    static func checkDetailed(_ id: String) -> (state: State, reply: String) {
        guard isRunning(id) else { return (.notRunning, "") }
        let (outcome, reply) = BrowserMedia.probeDetailed(id)
        switch outcome {
        case .count: return (.ready, reply)
        case .blocked: return (.needsJavaScript, reply)
        case .notAuthorized: return (.needsAutomation, reply)
        case .failed: return (.noWindow, reply)
        }
    }

    /// Is the menu item ticked? nil when it can't be read.
    static func javaScriptMenuItemTicked(_ id: String) -> Bool? {
        guard AXIsProcessTrusted(),
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first else { return nil }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 2.0)
        guard let menuBar = element(root, kAXMenuBarAttribute),
              let item = findItem(in: menuBar, depth: 0) else { return nil }
        return !(string(item, kAXMenuItemMarkCharAttribute) ?? "").isEmpty
    }

    enum ToggleResult {
        case pressed, alreadyOn, notFound, disabled, pressFailed, noAccessibility

        /// Shown in the Setup row when the setting still isn't on afterwards.
        func hint(_ id: String) -> String {
            let manual = BrowserMedia.howToAllow(id)
            switch self {
            case .noAccessibility: return "Over&Out needs Accessibility to do this. " + manual
            case .notFound: return "Couldn't find the setting in the menu. " + manual
            case .disabled: return "The menu item is greyed out (click a \(BrowserMedia.name(id)) window first). " + manual
            case .pressFailed: return "The browser didn't accept the click. " + manual
            case .pressed, .alreadyOn: return "Over&Out ticked the setting, but the browser still refuses."
            }
        }
    }

    /// Clicks "Allow JavaScript from Apple Events" in the browser's menu if it isn't ticked yet.
    /// The browser must be the active app (its menu commands act on the front window), so the
    /// caller brings it forward first. Needs Accessibility.
    static func enableJavaScriptMenuItem(_ id: String) -> ToggleResult {
        guard AXIsProcessTrusted() else { return .noAccessibility }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first else { return .notFound }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 2.0)
        guard let menuBar = element(root, kAXMenuBarAttribute),
              let path = findPath(in: menuBar, depth: 0), let item = path.last else { return .notFound }
        if !(string(item, kAXMenuItemMarkCharAttribute) ?? "").isEmpty { return .alreadyOn }

        // Open the menus the way a person does (View, then Developer), then click the item.
        // Brave and Chrome ignore a click on the item while its menu is closed.
        for opener in path.dropLast() {
            _ = AXUIElementPerformAction(opener, kAXPressAction as CFString)
            Thread.sleep(forTimeInterval: 0.35)
        }
        if bool(item, kAXEnabledAttribute) == false {
            cancelMenus(path)
            return .disabled
        }
        return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success ? .pressed : .pressFailed
    }

    /// Opens the menu that holds "Allow JavaScript from Apple Events" (View in Chrome, Brave, Edge,
    /// Vivaldi; Develop in Safari) and leaves it open for the user to finish the click. Returns the
    /// path of menu names, e.g. ["View", "Developer"], or nil if the item isn't in the menus.
    @discardableResult
    static func openMenuForUser(_ id: String) -> [String]? {
        guard AXIsProcessTrusted(),
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first else { return nil }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 1.0)
        guard let menuBar = element(root, kAXMenuBarAttribute), let path = findPath(in: menuBar, depth: 0),
              let barItem = path.first else { return nil }
        let names = path.dropLast().compactMap { string($0, kAXTitleAttribute) }
        _ = AXUIElementPerformAction(barItem, kAXPressAction as CFString)
        return names
    }

    private static func cancelMenus(_ path: [AXUIElement]) {
        for opener in path.dropLast().reversed() {
            _ = AXUIElementPerformAction(opener, kAXCancelAction as CFString)
        }
    }

    /// Menu bar item → … → the "Allow JavaScript from Apple Events" item, skipping the AXMenu
    /// containers in between (only elements that can be pressed are returned).
    private static func findPath(in element: AXUIElement, depth: Int) -> [AXUIElement]? {
        guard depth < 6 else { return nil }
        for child in children(element) {
            let role = string(child, kAXRoleAttribute) ?? ""
            if let title = string(child, kAXTitleAttribute)?.lowercased(),
               title.contains("allow javascript from apple events") {
                return [child]
            }
            if let rest = findPath(in: child, depth: depth + 1) {
                return role == "AXMenu" ? rest : [child] + rest
            }
        }
        return nil
    }

    private static func bool(_ of: AXUIElement, _ attribute: String) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(of, attribute as CFString, &value) == .success else { return nil }
        return (value as? NSNumber)?.boolValue
    }

    private static func findItem(in element: AXUIElement, depth: Int) -> AXUIElement? {
        guard depth < 6 else { return nil }
        for child in children(element) {
            if let title = string(child, kAXTitleAttribute)?.lowercased(),
               title.contains("allow javascript from apple events") {
                return child
            }
            if let found = findItem(in: child, depth: depth + 1) { return found }
        }
        return nil
    }

    private static func element(_ from: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(from, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func children(_ of: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(of, kAXChildrenAttribute as CFString, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    private static func string(_ of: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(of, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
}
