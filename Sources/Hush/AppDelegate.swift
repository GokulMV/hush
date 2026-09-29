import AppKit
import Carbon
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem!
    private var engine: HushEngine!
    private var timer: Timer?
    private var lastIcon = ""
    private var appearanceObservation: NSKeyValueObservation?
    private var settingsWindow: NSWindow?
    private var previewWindow: NSWindow?
    private var setupWindow: NSWindow?
    private let previewModel = CameraPreviewModel()
    private let updates = UpdateModel()
    private var whatsNewWindow: NSWindow?
    private let banner = Banner()
    private var settings: Settings { .shared }

    func applicationDidFinishLaunching(_ notification: Notification) {
        engine = HushEngine()
        PhoneDetector.shared.prepare() // loads, or downloads in the background (first launch only)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        engine.onChange = { [weak self] in self?.refreshIcon() }
        refreshIcon()
        watchAppearance()

        Notifier.requestPermission()
        if !Permissions.accessibilityGranted { Permissions.promptForAccessibility() }

        HotKeys.shared.register(keyCode: kVK_ANSI_M) { [weak self] in self?.engine.toggleMic() }
        HotKeys.shared.register(keyCode: kVK_ANSI_P) { [weak self] in self?.engine.togglePanic() }
        HotKeys.shared.register(keyCode: kVK_ANSI_G) { [weak self] in self?.engine.toggleEnabled() }
        HotKeys.shared.register(keyCode: kVK_ANSI_C) { [weak self] in self?.engine.toggleCamera() }

        timer = Timer.scheduledTimer(timeInterval: 0.5, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        tick()
        greet()
        showWhatsNewIfUpgraded()
        updates.startAutomaticChecks()
    }

    func applicationWillTerminate(_ notification: Notification) {
        engine.shutdown()
    }

    /// Opening the app again (Finder, Spotlight, Launchpad): Setup while something is missing,
    /// otherwise Settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if Self.setupNeeded { openSetup() } else { openSettings() }
        return false
    }

    /// Setup isn't finished, or a permission Hush can't work without is missing (every reinstall
    /// resets Accessibility, so this also brings Setup back after an update).
    static var setupNeeded: Bool {
        if !UserDefaults.standard.bool(forKey: SettingsKey.hasCompletedSetup) { return true }
        if !Permissions.accessibilityGranted { return true }
        if case .granted = Permissions.cameraStatus { return false }
        return UserDefaults.standard.bool(forKey: SettingsKey.presenceEnabled)
    }

    @objc private func tick() {
        engine.poll()
    }

    /// Welcome card on first launch, a brief toast afterwards: proof it's installed and where it lives.
    private func greet() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000) // let the status item get its on-screen frame
            let defaults = UserDefaults.standard
            if defaults.bool(forKey: SettingsKey.hasShownWelcome) {
                banner.showRunningToast(below: statusItem.button)
            } else {
                defaults.set(true, forKey: SettingsKey.hasShownWelcome)
                showWelcome()
                Notifier.post("Hush is installed", "It lives in your menu bar. Press ⌃⌥⌘G to turn it on or off.")
            }
            if Self.setupNeeded {
                openSetup()
            }
        }
    }

    private func showWelcome() {
        banner.showWelcome(below: statusItem.button) { [weak self] in self?.openSettings() }
    }

    // MARK: Menu bar icon

    private func refreshIcon() {
        guard let button = statusItem.button else { return }
        let dark = MenuBarIcon.isDark(button.effectiveAppearance)

        enum Look { case brand(slashed: Bool), symbol(String, MenuBarIcon.Alert?) }
        let (look, tip): (Look, String) = {
            if !settings.enabled && !engine.panicActive && !MicMuter.isMuted {
                return (.brand(slashed: true), "Hush is off (⌃⌥⌘G to turn on)")
            }
            if engine.panicActive {
                return (.symbol("exclamationmark.shield.fill", .warn), "Panic mode: everything muted and paused")
            }
            if engine.presence == .onPhone && engine.isSensing {
                return (.symbol("phone.fill", .warn), "On the phone: mic muted, media paused")
            }
            if engine.presence == .away && engine.isSensing {
                return (.symbol("figure.walk", .warn), "You're away: mic muted, camera off, media paused")
            }
            if MicMuter.isMuted {
                return (.symbol("mic.slash.fill", nil), "Mic muted by Hush")
            }
            if engine.callPhase == .inCall {
                return (.symbol("mic.fill", .live), "In a call. Your mic is LIVE")
            }
            return (.brand(slashed: false), "Hush is watching")
        }()

        let key: String
        switch look {
        case .brand(let slashed): key = "brand-\(slashed)"
        case .symbol(let name, let alert): key = "\(name)-\(String(describing: alert))-\(dark)"
        }
        guard key != lastIcon else { return }
        lastIcon = key

        let image: NSImage
        switch look {
        case .brand(let slashed):
            image = MenuBarIcon.brand(slashed: slashed)
        case .symbol(let name, let alert):
            // Fall back to the always-available drawn icon if this macOS lacks the symbol.
            image = MenuBarIcon.symbol(name, alert: alert, dark: dark, description: tip) ?? MenuBarIcon.brand(slashed: false)
        }
        button.image = image
        button.contentTintColor = nil
        button.toolTip = tip
        button.setAccessibilityLabel(tip)
    }

    /// Re-colour alert icons when the menu bar flips between light and dark
    /// (system appearance change, or a wallpaper that changes the bar's tint).
    private func watchAppearance() {
        guard let button = statusItem.button else { return }
        appearanceObservation = button.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in
                self?.lastIcon = ""
                self?.refreshIcon()
            }
        }
    }

    // MARK: Menu (rebuilt each time it opens, so it always shows live state)

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        menu.addItem(item(settings.enabled ? "Turn Hush Off" : "Turn Hush On", #selector(toggleEnabled), key: "g"))
        menu.addItem(.separator())
        if settings.enabled {
            menu.addItem(info(callLine))
            menu.addItem(info(presenceLine))
            if let seen = cameraLine { menu.addItem(info(seen)) }
            menu.addItem(info(micLine))
            if let paused = engine.describe(.media) { menu.addItem(info("⏸  Media paused: \(paused)")) }
            if let video = engine.describe(.meetingVideo) { menu.addItem(info("📷  Meeting camera off: \(video)")) }
            for mic in engine.unmutableMics { menu.addItem(info("⚠️  Can't mute “\(mic)”")) }
            menu.addItem(.separator())
        }

        menu.addItem(item(MicMuter.isMuted ? "Unmute Microphone" : "Mute Microphone", #selector(toggleMic), key: "m"))
        menu.addItem(item(engine.panicActive ? "End Panic Mode" : "Panic: Mute, Video Off, Pause", #selector(togglePanic), key: "p"))

        menu.addItem(.separator())
        menu.addItem(info(cameraStatusLine))
        menu.addItem(item(settings.cameraActive ? "Turn Hush Camera Off" : "Turn Hush Camera On", #selector(toggleCamera), key: "c"))
        let pauses = [15, 30, 60, 120].map { minutes -> NSMenuItem in
            let menuItem = item(minutes < 60 ? "\(minutes) minutes" : minutes == 60 ? "1 hour" : "\(minutes / 60) hours",
                                #selector(pauseCamera(_:)), modifiers: [])
            menuItem.representedObject = minutes
            return menuItem
        }
        menu.addItem(submenu("Pause Hush Camera For", pauses))

        menu.addItem(.separator())
        if !Permissions.accessibilityGranted {
            menu.addItem(item("⚠️ Allow Accessibility (for meeting camera/mute & media keys)…", #selector(openAccessibility), modifiers: []))
        }
        let cameraStatus = PresenceSensor.authorization
        if settings.cameraActive, cameraStatus == .denied || cameraStatus == .restricted {
            menu.addItem(item("⚠️ Allow Camera (for presence detection)…", #selector(openCamera), modifiers: []))
        }
        if let version = updates.availableVersion {
            menu.addItem(item("⬆️ Update Available: Hush \(version)…", #selector(openUpdates), modifiers: []))
        }
        menu.addItem(item("Setup Assistant…", #selector(openSetup), modifiers: []))
        menu.addItem(item("Test Meeting Controls…", #selector(testMeetingControls), modifiers: []))
        menu.addItem(item("Camera Preview (Test Detection)…", #selector(openCameraPreview), modifiers: []))
        menu.addItem(item("Settings…", #selector(openSettings), key: ",", modifiers: .command))
        menu.addItem(item("Check for Updates…", #selector(checkForUpdates), modifiers: []))
        menu.addItem(item("About Hush", #selector(openAbout), modifiers: []))
        menu.addItem(item("Quit Hush", #selector(quit), key: "q", modifiers: .command))
    }

    private var callLine: String {
        switch engine.callPhase {
        case .idle: return "📞  No call"
        case .ringing: return "📳  Phone ringing"
        case .inCall:
            let names = engine.callApps.map(HushEngine.displayName).sorted().joined(separator: ", ")
            return "📞  In a call (\(names))"
        }
    }

    private var presenceLine: String {
        guard settings.cameraActive, engine.isSensing else { return "👀  Presence: not checking" }
        return "👀  You're \(engine.presence.rawValue)"
    }

    private var cameraStatusLine: String {
        if !settings.presenceEnabled { return "📷  Hush camera: off" }
        if let until = settings.cameraPausedUntil {
            return "📷  Hush camera: paused until \(until.formatted(date: .omitted, time: .shortened))"
        }
        if engine.isSensing { return "📷  Hush camera: watching (green light on)" }
        return "📷  Hush camera: on, waits for a call or video"
    }

    /// Live view of the latest frame, so you can test the detection.
    private var cameraLine: String? {
        guard settings.cameraActive, engine.isSensing, let reading = engine.lastReading else { return nil }
        switch reading {
        case .present: return "📷  Camera sees: you"
        case .absent: return "📷  Camera sees: no one"
        case .phoneToEar: return "📷  Camera sees: you on the phone"
        }
    }

    private var micLine: String {
        if let why = engine.describe(.mic) { return "🔇  Mic muted: \(why)" }
        if MicMuter.isMuted { return "🔇  Mic muted" }
        return engine.callPhase == .inCall ? "🔴  Mic is LIVE" : "🎙  Mic not muted"
    }

    // MARK: Menu builders

    private func info(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu()
        for child in items { menu.addItem(child) }
        parent.submenu = menu
        return parent
    }

    private func item(_ title: String, _ action: Selector, key: String = "",
                      modifiers: NSEvent.ModifierFlags = [.control, .option, .command]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = self
        return item
    }

    // MARK: Settings window

    @objc private func openSettings() {
        if settingsWindow == nil {
            let view = SettingsView(showWelcome: { [weak self] in self?.showWelcome() },
                                    showSetup: { [weak self] in self?.openSetup() },
                                    setupNeeded: { AppDelegate.setupNeeded },
                                    showWhatsNew: { [weak self] in self?.showWhatsNew(since: nil) },
                                    updates: updates)
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "Hush Settings"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        present(settingsWindow)
    }

    // MARK: Updates, What's New, About

    @objc private func checkForUpdates() {
        openSettings(tab: .updates)
        updates.check(userInitiated: true)
    }

    @objc private func openUpdates() { openSettings(tab: .updates) }
    @objc private func openAbout() { openSettings(tab: .about) }

    private func openSettings(tab: SettingsTab) {
        openSettings()
        updates.tabRequest = tab
    }

    /// Once after an upgrade: the changelog entries since the version that ran last.
    private func showWhatsNewIfUpgraded() {
        let defaults = UserDefaults.standard
        let current = AppInfo.version
        let last = defaults.string(forKey: SettingsKey.lastRunVersion)
        defaults.set(current, forKey: SettingsKey.lastRunVersion)
        guard let last, AppVersion(current) > AppVersion(last) else { return } // fresh install or same version
        showWhatsNew(since: last)
    }

    /// `since`: show entries newer than that version; nil shows the latest few.
    private func showWhatsNew(since old: String?) {
        let entries = old.map { Changelog.entries(after: $0, upTo: AppInfo.version) } ?? Array(Changelog.entries.prefix(5))
        let view = WhatsNewView(entries: entries) { [weak self] in self?.whatsNewWindow?.close() }
        let window = whatsNewWindow ?? NSWindow(contentViewController: NSHostingController(rootView: view))
        window.contentViewController = NSHostingController(rootView: view)
        window.title = "What's New in Hush"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        whatsNewWindow = window
        present(window)
    }

    /// Shows a Hush window on the desktop (Space) you're on. Hush's windows appear on every
    /// desktop and over full-screen apps, so they follow you when you swipe between desktops
    /// instead of staying behind on the one where they were opened.
    private func present(_ window: NSWindow?) {
        guard let window else { return }
        if window.isVisible && !window.isOnActiveSpace {
            window.orderOut(nil) // re-show here rather than switching you back to its desktop
        }
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    // MARK: Setup assistant

    /// First-launch checklist (also in the menu and Settings). Finishing with a browser ready
    /// turns on browser control; skipping leaves things as they are.
    @objc private func openSetup() {
        if setupWindow == nil {
            let view = SetupView(model: SetupModel()) { [weak self] browsersReady in
                UserDefaults.standard.set(true, forKey: SettingsKey.hasCompletedSetup)
                if browsersReady { UserDefaults.standard.set(true, forKey: SettingsKey.browserScripting) }
                self?.setupWindow?.close()
            }
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "Hush Setup"
            window.styleMask = [.titled, .closable, .resizable]
            window.isReleasedWhenClosed = false
            window.center()
            setupWindow = window
        }
        present(setupWindow)
    }

    // MARK: Camera preview

    @objc private func openCameraPreview() {
        if !settings.cameraActive {
            engine.setCamera(on: true)
        }
        if previewWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: CameraPreviewView(model: previewModel)))
            window.title = "Hush Camera Preview"
            window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            previewWindow = window
        }
        engine.previewHandler = { [weak self] analysis, image in
            self?.previewModel.analysis = analysis
            if let image { self?.previewModel.image = image }
        }
        engine.poll() // start the camera now rather than on the next tick
        present(previewWindow)
    }

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === previewWindow else { return }
        engine.previewHandler = nil // stops preview frames; the camera follows the normal rules again
        previewModel.image = nil
        previewModel.analysis = nil
    }

    // MARK: Actions

    @objc private func toggleEnabled() { engine.toggleEnabled() }
    @objc private func toggleCamera() { engine.toggleCamera() }

    @objc private func pauseCamera(_ sender: NSMenuItem) {
        guard let minutes = sender.representedObject as? Int else { return }
        engine.pauseCamera(minutes: minutes)
    }
    @objc private func toggleMic() { engine.toggleMic() }
    @objc private func togglePanic() { engine.togglePanic() }

    /// Shows what Hush can see in each meeting app and browser, so a failure has a clear reason.
    @objc private func testMeetingControls() {
        MeetingControl.shared.diagnose(engine.meetingApps()) { meetingReport in
            BrowserMedia.status { mediaReport in
                Task { @MainActor in
                    let alert = NSAlert()
                    alert.messageText = "Meeting controls"
                    alert.informativeText = "CAMERA & MUTE BUTTONS\n" + meetingReport + "\n\nPAUSING VIDEOS\n" + mediaReport
                    alert.addButton(withTitle: "OK")
                    if !Permissions.accessibilityGranted {
                        alert.addButton(withTitle: "Open Accessibility Settings")
                    }
                    NSApp.activate(ignoringOtherApps: true)
                    if alert.runModal() == .alertSecondButtonReturn {
                        Permissions.openPrivacySettings("Privacy_Accessibility")
                    }
                }
            }
        }
    }

    @objc private func openAccessibility() {
        Permissions.promptForAccessibility()
        Permissions.openPrivacySettings("Privacy_Accessibility")
    }

    @objc private func openCamera() {
        Permissions.openPrivacySettings("Privacy_Camera")
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
