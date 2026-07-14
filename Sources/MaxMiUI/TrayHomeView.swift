import SwiftUI
import MaxMiCore

public struct TrayHomeView: View {
    @Bindable private var viewModel: TrayHomeViewModel
    @Bindable private var recentCapturesViewModel: RecentCapturesViewModel
    private let onTogglePause: @MainActor () -> Void
    private let onOpenMaxMi: @MainActor () -> Void
    private let onOpenSettings: @MainActor () -> Void

    public init(
        viewModel: TrayHomeViewModel,
        recentCapturesViewModel: RecentCapturesViewModel,
        onTogglePause: @escaping @MainActor () -> Void,
        onOpenMaxMi: @escaping @MainActor () -> Void,
        onOpenSettings: @escaping @MainActor () -> Void
    ) {
        self.viewModel = viewModel
        self.recentCapturesViewModel = recentCapturesViewModel
        self.onTogglePause = onTogglePause
        self.onOpenMaxMi = onOpenMaxMi
        self.onOpenSettings = onOpenSettings
    }

    public var body: some View {
        VStack(spacing: Theme.spacing2) {
            statusCard
            searchField
            Group {
                if viewModel.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    VStack(alignment: .leading, spacing: Theme.spacing1) {
                        Text("Recent memory")
                            .font(.headline)
                            .foregroundColor(Theme.text)
                            .padding(.horizontal, Theme.spacing2)
                        RecentCapturesView(viewModel: recentCapturesViewModel)
                    }
                } else {
                    searchResults
                }
            }
            footer
        }
        .padding(.top, Theme.spacing2)
        .frame(minWidth: 380, minHeight: 520)
        .background(Theme.background)
        .preferredColorScheme(.dark)
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

    private var footer: some View {
        HStack {
            Button("Open MaxMi") { onOpenMaxMi() }.buttonStyle(.borderedProminent)
            Spacer()
            Button { onOpenSettings() } label: { Image(systemName: "gearshape") }
                .buttonStyle(.bordered)
        }
        .padding(.horizontal, Theme.spacing2)
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

