import SwiftUI

/// Reads CHANGELOG.md (bundled in the app). Sections start with "## <version>", newest first:
///
///     ## 1.1.0 — 2026-10-02
///     - Added …
enum Changelog {
    struct Entry: Identifiable {
        let version: String
        let title: String
        let notes: String
        var id: String { version }
    }

    static var entries: [Entry] {
        guard let url = Bundle.main.url(forResource: "CHANGELOG", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return parse(text)
    }

    static func parse(_ text: String) -> [Entry] {
        var entries: [Entry] = []
        var title: String?
        var lines: [String] = []
        func flush() {
            guard let title else { return }
            let version = title.split(separator: " ").first.map { AppVersion(String($0)).description } ?? title
            entries.append(Entry(version: version, title: title,
                                 notes: lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        for line in text.components(separatedBy: .newlines) {
            if line.hasPrefix("## ") {
                flush()
                title = String(line.dropFirst(3)).trimmingCharacters(in: CharacterSet(charactersIn: " []"))
                lines = []
            } else if title != nil {
                lines.append(line)
            }
        }
        flush()
        return entries
    }

    static func notes(for version: String) -> String? {
        entries.first { AppVersion($0.version) == AppVersion(version) }?.notes
    }

    /// Entries newer than `old`, up to and including `current`: what to show after an upgrade.
    static func entries(after old: String, upTo current: String) -> [Entry] {
        entries.filter { AppVersion($0.version) > AppVersion(old) && AppVersion($0.version) <= AppVersion(current) }
    }

    /// Bold, links and inline code from Markdown; lists and line breaks kept as written.
    static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

/// "What's New in Over&Out" — shown once after an upgrade, and from Settings.
struct WhatsNewView: View {
    let entries: [Changelog.Entry]
    var close: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text("What's New in Over&Out \(AppInfo.version)").font(.title2.bold())
                    Text("Here's what changed.").foregroundStyle(.secondary)
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if entries.isEmpty {
                        Text("No release notes found.").foregroundStyle(.secondary)
                    }
                    ForEach(entries) { entry in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(entry.title).font(.headline)
                            Text(Changelog.markdown(entry.notes))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(.trailing, 6)
            }
            HStack {
                Spacer()
                Button("Continue") { close() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520, height: 460)
    }
}
