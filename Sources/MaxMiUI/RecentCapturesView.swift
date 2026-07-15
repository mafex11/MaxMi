import SwiftUI
import AppKit
import MaxMiCore

public struct RecentCapturesView: View {
    @Bindable private var viewModel: RecentCapturesViewModel

    /// Per-capture cloud-processing controls ("Allow AI" / "Keep Local") are hidden from the
    /// main dashboard. Minimi keeps capture privacy to a simple per-app on/off, so these controls
    /// aren't surfaced here. Flip to `true` to bring them back — the logic below is intact.
    private static let showsCloudControls = false

    public init(viewModel: RecentCapturesViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        Group {
            if viewModel.rows.isEmpty {
                VStack(spacing: Theme.spacing2) {
                    Image(systemName: "waveform.path.ecg")
                        .font(.system(size: Theme.iconSizeLarge))
                        .foregroundColor(Theme.secondaryText)
                    Text("No local captures yet")
                        .font(.title3)
                        .foregroundColor(Theme.text)
                    Text("Focus an app for a few seconds, then reopen MaxMi.")
                        .font(.caption)
                        .foregroundColor(Theme.secondaryText)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: Theme.spacing1) {
                        ForEach(viewModel.rows) { row in
                            HStack(alignment: .center, spacing: Theme.spacing1) {
                                // Minimi-style row: real app icon + summary only.
                                appIcon(for: row)

                                VStack(alignment: .leading, spacing: Theme.spacingHalf) {
                                    Text(row.summary)
                                        .font(.body)
                                        .foregroundColor(Theme.text)
                                        .lineLimit(2)
                                    // Metadata line (app · title · time), detail line (kind · count ·
                                    // parser), and per-capture cloud controls are hidden to match Minimi's
                                    // minimal dashboard. Kept for easy restore.
                                    //
                                    // HStack(spacing: Theme.spacingHalf) {
                                    //     Text(row.appLabel)
                                    //     Text("·")
                                    //     Text(row.sourceTitle)
                                    //         .lineLimit(1)
                                    //     Text("·")
                                    //     Text(row.timeAgo)
                                    // }
                                    // .font(.caption)
                                    // .foregroundColor(Theme.secondaryText)
                                    // Text(row.detail)
                                    //     .font(.caption2)
                                    //     .foregroundColor(Theme.tertiaryText)
                                    //     .lineLimit(1)
                                    if Self.showsCloudControls {
                                        cloudControls(row)
                                    }
                                }
                                Spacer()
                            }
                            .padding(Theme.spacing1)
                            .background(Theme.surface)
                            .cornerRadius(Theme.cornerRadius)
                        }
                    }
                    .padding(.horizontal, Theme.spacing2)
                    .padding(.bottom, Theme.spacing2)
                }
            }
        }
    }

    @ViewBuilder
    private func cloudControls(_ row: RecentCaptureRow) -> some View {
        switch row.cloudState {
        case .pendingReview:
            HStack {
                Button("Allow AI") { Task { await viewModel.setCloudProcessing(for: row, allowed: true) } }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                Button("Keep Local") { Task { await viewModel.setCloudProcessing(for: row, allowed: false) } }
                    .buttonStyle(.bordered).controlSize(.small)
            }
        case .localOnly:
            Button("Allow AI for \(row.appLabel)") {
                Task { await viewModel.setCloudProcessing(for: row, allowed: true) }
            }.buttonStyle(.link).font(.caption)
        case .allowed:
            Button("Keep \(row.appLabel) local only") {
                Task { await viewModel.setCloudProcessing(for: row, allowed: false) }
            }.buttonStyle(.link).font(.caption)
        }
    }

    /// Real macOS app icon for the capture's source app, mirroring Minimi. When the source app can't
    /// be resolved to an installed app (unknown name, or an internal capture category like "Voice
    /// Note"), we fall back to a neutral brain glyph so every row still reads consistently.
    @ViewBuilder
    private func appIcon(for row: RecentCaptureRow) -> some View {
        if let path = Self.iconPath(for: row) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                .resizable()
                .interpolation(.high)
                .frame(width: Theme.iconSizeMedium, height: Theme.iconSizeMedium)
        } else {
            Image(systemName: Self.fallbackSymbol)
                .font(.system(size: Theme.iconSizeMedium * 0.68, weight: .regular))
                .foregroundColor(Theme.secondaryText)
                .frame(width: Theme.iconSizeMedium, height: Theme.iconSizeMedium)
        }
    }

    /// Picks the best icon path for a capture row. Web captures all share the source label "Web"
    /// (no single app), so we resolve the actual browser — first from the browser name macOS appends
    /// to the window title ("… - Google Chrome"), then from the system default browser. Everything
    /// else resolves by the source app's name.
    private static func iconPath(for row: RecentCaptureRow) -> String? {
        if row.appLabel.caseInsensitiveCompare("Web") == .orderedSame {
            if let browser = browserPath(fromTitle: row.sourceTitle) { return browser }
            return NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!)?.path
        }
        return applicationPath(for: row.appLabel)
    }

    /// Known browsers, checked against window titles. Restricting to this set means a page whose
    /// title merely ends in "- Notes" can't be mistaken for the Notes app.
    private static let knownBrowsers = [
        "Google Chrome", "Safari", "Zen", "Arc", "Firefox", "Microsoft Edge",
        "Brave Browser", "Brave", "Opera", "Vivaldi", "Chromium", "Orion",
    ]

    /// macOS appends the browser's name to window titles ("Page Title - Google Chrome",
    /// "Page Title – Zen"). Scan the title for a known browser name and resolve it.
    private static func browserPath(fromTitle title: String) -> String? {
        for browser in knownBrowsers where title.localizedCaseInsensitiveContains(browser) {
            if let path = applicationPath(for: browser) { return path }
        }
        return nil
    }

    /// Neutral glyph shown for any capture whose source app can't be resolved to an installed app.
    private static let fallbackSymbol = "brain.head.profile"

    /// Known label → app-display-name fixups for cases where the captured source label doesn't match
    /// the installed app's name (e.g. Chrome reports as "Chrome" but installs as "Google Chrome").
    private static let nameAliases: [String: String] = [
        "chrome": "Google Chrome",
        "google chrome": "Google Chrome",
        "code": "Visual Studio Code",
        "vscode": "Visual Studio Code",
        "vs code": "Visual Studio Code",
    ]

    /// Resolves a source-app label to an installed app's path. Works for ANY app the user has, since
    /// LaunchServices resolves by display name; tries, in order: bundle ID, an alias fixup, the raw
    /// name, and finally an exact match against currently-running apps. Returns nil if nothing matches.
    private static func applicationPath(for label: String) -> String? {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: trimmed) {
            return url.path
        }
        if let alias = nameAliases[trimmed.lowercased()],
           let path = NSWorkspace.shared.fullPath(forApplication: alias) {
            return path
        }
        if let path = NSWorkspace.shared.fullPath(forApplication: trimmed) {
            return path
        }
        // Exact (case-insensitive) match against running apps — catches renamed/variant labels
        // without the false positives a prefix match would introduce.
        if let running = NSWorkspace.shared.runningApplications.first(where: {
            $0.localizedName?.caseInsensitiveCompare(trimmed) == .orderedSame
        }), let path = running.bundleURL?.path {
            return path
        }
        return nil
    }

    private func icon(_ kind: CaptureContentKind) -> String {
        switch kind {
        case .webpage: return "globe"
        case .conversation: return "message.fill"
        case .document: return "doc.text.fill"
        case .terminal: return "terminal.fill"
        case .email: return "envelope.fill"
        case .calendar: return "calendar"
        case .task: return "checkmark.circle.fill"
        case .meeting: return "person.2.wave.2.fill"
        case .voiceNote: return "mic.fill"
        case .generic: return "app.fill"
        }
    }
}
