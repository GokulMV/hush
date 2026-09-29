import SwiftUI

/// Settings → About.
struct AboutView: View {
    var showWhatsNew: @MainActor () -> Void = {}

    private var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    }

    private var repoURL: URL { URL(string: "https://github.com/\(AppInfo.repo)")! }

    var body: some View {
        Form {
            Section {
                VStack(spacing: 10) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 96, height: 96)
                    Text("Over&Out").font(.largeTitle.bold())
                    Text("Version \(AppInfo.version) (\(build))")
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Text("Mutes your mic, turns off your meeting camera and pauses videos when you step away or pick up your phone, and puts everything back when you return.")
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }

            Section("Privacy") {
                Label("The camera is analysed on this Mac, a few frames a second, and nothing is saved or sent anywhere.",
                      systemImage: "lock.shield")
                Label("Over&Out never listens to your microphone; it only checks whether an app is using it.",
                      systemImage: "mic.slash")
                Label("Network use: checking GitHub for updates, and a one-time download of the phone detector from Apple.",
                      systemImage: "network")
            }

            Section("Links") {
                Link(destination: repoURL) { Label("Over&Out on GitHub", systemImage: "chevron.left.forwardslash.chevron.right") }
                Link(destination: repoURL.appendingPathComponent("releases")) { Label("All releases", systemImage: "shippingbox") }
                Link(destination: repoURL.appendingPathComponent("issues/new")) { Label("Report a problem or suggest a feature", systemImage: "exclamationmark.bubble") }
                Button { showWhatsNew() } label: { Label("What's new in this version", systemImage: "sparkles") }
                    .buttonStyle(.link)
            }

            Section("Credits") {
                Text("Phone detection uses Apple's Core ML YOLOv3-Tiny model (from developer.apple.com/machine-learning/models). Presence detection uses Apple's Vision framework.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("© \(Calendar.current.component(.year, from: Date())) Gokul MV")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
