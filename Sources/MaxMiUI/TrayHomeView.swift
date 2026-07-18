import SwiftUI
import AppKit
import MaxMiCore

public struct TrayHomeView: View {
    @Bindable private var viewModel: TrayHomeViewModel
    @Bindable private var recentCapturesViewModel: RecentCapturesViewModel
    @Bindable private var activityViewModel: ActivityViewModel
    @Bindable private var actionItemsViewModel: ActionItemsViewModel
    private let onTogglePause: @MainActor () -> Void
    private let onStartVoiceNote: @MainActor () -> Void
    private let onOpenMaxMi: @MainActor () -> Void
    private let onOpenSettings: @MainActor () -> Void

    public init(
        viewModel: TrayHomeViewModel,
        recentCapturesViewModel: RecentCapturesViewModel,
        activityViewModel: ActivityViewModel,
        actionItemsViewModel: ActionItemsViewModel,
        onTogglePause: @escaping @MainActor () -> Void,
        onStartVoiceNote: @escaping @MainActor () -> Void,
        onOpenMaxMi: @escaping @MainActor () -> Void,
        onOpenSettings: @escaping @MainActor () -> Void
    ) {
        self.viewModel = viewModel
        self.recentCapturesViewModel = recentCapturesViewModel
        self.activityViewModel = activityViewModel
        self.actionItemsViewModel = actionItemsViewModel
        self.onTogglePause = onTogglePause
        self.onStartVoiceNote = onStartVoiceNote
        self.onOpenMaxMi = onOpenMaxMi
        self.onOpenSettings = onOpenSettings
    }

    /// Minimi shows a few recent activities; we cap the tray list at the top 5.
    private static let recentLimit = 5

    public var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacing1) {
            header
            sectionRow
            // Variant B (Timeline): rows sit flat on the background with hairline dividers — no card.
            RecentCapturesView(viewModel: recentCapturesViewModel, limit: Self.recentLimit)
            Spacer(minLength: 0)
            footer
        }
        .padding(.top, Theme.spacing2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.background)
        .preferredColorScheme(.dark)
        // Poll while the popover is open so the memory list stays live as new captures land.
        // The AppKit onWillShow hook doesn't reliably re-render a transient NSPopover's SwiftUI
        // content, so we drive refreshes from the view itself on a short interval.
        .task {
            while !Task.isCancelled {
                await recentCapturesViewModel.refresh()
                await viewModel.refresh()
                try? await Task.sleep(nanoseconds: 2_000_000_000)  // 2s
            }
        }
    }

    // Minimi-style header: brand icon + wordmark + status dot on the left; Actions + gear on the right.
    private var header: some View {
        HStack(spacing: Theme.spacing1) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: Theme.iconSizeMedium, height: Theme.iconSizeMedium)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            Text("MaxMi")
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(Theme.text)
            Circle()
                .fill(viewModel.status.state == .paused ? Theme.warning : Theme.success)
                .frame(width: 7, height: 7)
            Spacer()
            Button { onOpenSettings() } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 15))
            }
            .buttonStyle(.plain)
            .foregroundColor(Theme.secondaryText)
            .help("Settings")
        }
        .padding(.horizontal, Theme.spacing2)
    }

    // "Recent memories" heading on the left, "Record voice note" action on the right.
    private var sectionRow: some View {
        HStack {
            Text("Recent memories")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(Theme.text)
            Spacer()
            Button { onStartVoiceNote() } label: {
                HStack(spacing: Theme.spacingHalf) {
                    Text("Record voice note")
                    Image(systemName: "mic")
                }
                .font(.system(size: 13))
            }
            .buttonStyle(.plain)
            .foregroundColor(Theme.secondaryText)
        }
        .padding(.horizontal, Theme.spacing2)
    }

    private var statusCard: some View {
        HStack(spacing: Theme.spacing2) {
            ZStack {
                Circle().fill(statusColor.opacity(0.18)).frame(width: 38, height: 38)
                Image(systemName: statusIcon).foregroundColor(statusColor)
            }
            VStack(alignment: .leading, spacing: Theme.spacingHalf) {
                Text(viewModel.status.title).font(.headline).foregroundColor(Theme.text)
                Text(viewModel.status.detail).font(.caption).foregroundColor(Theme.secondaryText).lineLimit(2)
            }
            Spacer()
            Text("\(viewModel.status.captureCount)")
                .font(.title3.monospacedDigit())
                .foregroundColor(Theme.text)
            Button(viewModel.status.state == .paused ? "Resume" : "Pause") { onTogglePause() }
                .buttonStyle(.bordered)
        }
        .padding(Theme.spacing2)
        .background(Theme.surface)
        .cornerRadius(Theme.cornerRadius)
        .padding(.horizontal, Theme.spacing2)
    }

    private var searchField: some View {
        HStack(spacing: Theme.spacing1) {
            Image(systemName: "magnifyingglass").foregroundColor(Theme.secondaryText)
            TextField("Search local memory", text: $viewModel.query)
                .textFieldStyle(.plain)
                .onChange(of: viewModel.query) { _, _ in viewModel.scheduleSearch() }
            if viewModel.isSearching { ProgressView().controlSize(.small) }
            if !viewModel.query.isEmpty {
                Button { viewModel.query = ""; viewModel.scheduleSearch() } label: {
                    Image(systemName: "xmark.circle.fill")
                }.buttonStyle(.plain).foregroundColor(Theme.secondaryText)
            }
        }
        .padding(Theme.spacing1)
        .background(Theme.surface)
        .cornerRadius(Theme.cornerRadius)
        .padding(.horizontal, Theme.spacing2)
    }

    private var searchResults: some View {
        Group {
            if let error = viewModel.searchError {
                Text(error).foregroundColor(Theme.warning).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !viewModel.isSearching && viewModel.results.isEmpty {
                Text("No local memory matched").foregroundColor(Theme.secondaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: Theme.spacing1) {
                        ForEach(viewModel.results) { result in
                            HStack(alignment: .top, spacing: Theme.spacing1) {
                                Image(systemName: icon(result.contentKind)).foregroundColor(Theme.accent)
                                VStack(alignment: .leading, spacing: Theme.spacingHalf) {
                                    Text(result.title).font(.headline).foregroundColor(Theme.text).lineLimit(1)
                                    Text(result.snippet).font(.caption).foregroundColor(Theme.secondaryText).lineLimit(3)
                                    Text("\(result.appLabel) · \(result.matchKind)")
                                        .font(.caption2).foregroundColor(Theme.tertiaryText)
                                }
                                Spacer()
                            }
                            .padding(Theme.spacing1)
                            .background(Theme.surface)
                            .cornerRadius(Theme.cornerRadius)
                        }
                    }.padding(.horizontal, Theme.spacing2)
                }
            }
        }
    }

    // Minimi-style centered footer. "Open MaxMi" (separate window) and the standalone Voice Note
    // button are gone — voice note now lives in the section row, everything else in this popover.
    // The window plumbing (onOpenMaxMi, ActivityWindow) is left intact for later reuse.
    private var footer: some View {
        HStack(spacing: Theme.spacingHalf) {
            Text("made with")
            Image(systemName: "heart.fill").font(.system(size: 9))
            Text("by")
            // "mafex" links to the author's GitHub.
            Text("mafex")
                .foregroundColor(Theme.text)
                .underline()
                .onTapGesture {
                    if let url = URL(string: "https://github.com/mafex11") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .onHover { inside in
                    if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }
        }
        .font(.system(size: 11))
        .foregroundColor(Theme.secondaryText)
        .frame(maxWidth: .infinity)
        .padding(.bottom, Theme.spacing2)
    }

    private var statusColor: Color {
        switch viewModel.status.state {
        case .capturing: return Theme.accent
        case .paused: return Theme.warning
        case .needsAttention: return Theme.destructive
        }
    }

    private var statusIcon: String {
        switch viewModel.status.state {
        case .capturing: return "waveform.path.ecg"
        case .paused: return "pause.fill"
        case .needsAttention: return "exclamationmark.triangle.fill"
        }
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
