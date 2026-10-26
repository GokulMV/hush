import SwiftUI

/// Settings → Sound: which app plays on which speakers or headphones.
struct SoundRoutingView: View {
    @AppStorage(SoundRoutes.enabledKey) private var enabled = true
    @State private var routes = SoundRoutes.all
    @State private var devices = AudioDevices.outputDevices
    @State private var tick = 0
    private let refresh = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                Toggle("Send apps' sound to the devices below", isOn: $enabled)
                    .onChange(of: enabled) { _ in SoundRouter.shared.reconcileInBackground() }
            } footer: {
                Group {
                    Text("For example Spotify on your Bluetooth headset, a movie player on wired earphones, and everything else (your meetings too) on the Mac's speakers. If a device isn't connected, that app simply plays where it normally would.")
                }
                .footerNote()
            }

            Section {
                ForEach($routes) { $route in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(route.appName).font(.headline)
                            Spacer()
                            Button(role: .destructive) {
                                routes.removeAll { $0.bundleID == route.bundleID }
                                save()
                            } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                                .help("Remove this rule")
                        }
                        Picker("Play on", selection: $route.deviceUID) {
                            ForEach(deviceChoices(including: route)) { device in
                                Text(device.name).tag(device.uid)
                            }
                        }
                        .onChange(of: route.deviceUID) { uid in
                            if let device = devices.first(where: { $0.uid == uid }) { route.deviceName = device.name }
                            save()
                        }
                        Text(statusText(route))
                            .font(.caption).foregroundStyle(.secondary)
                            .id(tick)
                    }
                    .padding(.vertical, 2)
                }
                Button("Add App…") { add() }
                    .disabled(devices.isEmpty)
            } header: {
                Text("Rules")
            } footer: {
                Group {
                    Text("Works per app, not per browser tab: a video and a meeting in the same browser can't go to different devices (use two browsers, or the meeting's own app). Meeting apps (Zoom, Teams, Meet, FaceTime) can also choose their speaker in their own settings.")
                }
                .footerNote()
            }

            Section {
                HStack {
                    Button("Open Privacy Settings") { Permissions.openPrivacySettings("Privacy_ScreenCapture") }
                    Button("Try Again") { SoundRouter.shared.retry(); SoundRouter.shared.reconcileInBackground() }
                    Spacer()
                }
            } header: {
                Text("Permission")
            } footer: {
                Group {
                    Text("macOS asks once to allow Over&Out under System Audio Recording, because routing takes the app's sound to play it elsewhere. Nothing is recorded or saved. If an app goes quiet through a route, Over&Out removes the route at once so you always hear it.")
                }
                .footerNote()
            }
        }
        .formStyle(.grouped)
        .onReceive(refresh) { _ in
            devices = AudioDevices.outputDevices
            tick += 1
        }
    }

    /// Connected devices, plus the rule's device when it isn't connected right now.
    private func deviceChoices(including route: SoundRoute) -> [AudioDevices.OutputDevice] {
        var choices = devices
        if !choices.contains(where: { $0.uid == route.deviceUID }) {
            choices.append(AudioDevices.OutputDevice(objectID: 0, uid: route.deviceUID,
                                                     name: route.deviceName + " (not connected)"))
        }
        return choices
    }

    private func statusText(_ route: SoundRoute) -> String {
        SoundRouter.shared.status(for: route.bundleID)?.text ?? "Starting…"
    }

    private func add() {
        guard let app = IgnoredApps.chooseApp(title: "Choose an app to send somewhere else"),
              !routes.contains(where: { $0.bundleID == app.bundleID }) else { return }
        // Default to a device that isn't the current output (that's the point of a rule).
        let current = AudioDevices.defaultOutputUID
        let device = devices.first { $0.uid != current } ?? devices[0]
        routes.append(SoundRoute(bundleID: app.bundleID, appName: app.name, deviceUID: device.uid, deviceName: device.name))
        save()
    }

    private func save() {
        SoundRoutes.save(routes)
        SoundRouter.shared.reconcileInBackground()
    }
}
