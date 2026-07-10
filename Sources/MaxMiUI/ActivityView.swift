import SwiftUI

public struct ActivityView: View {
    @Bindable var viewModel: ActivityViewModel
    @State private var expandedRowId: String?
    @State private var selectedTab = 0

    public init(viewModel: ActivityViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Segmented control: Activity / Action Items
            Picker("", selection: $selectedTab) {
                Text("Activity").tag(0)
                Text("Action Items").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(Theme.spacing2)

            if selectedTab == 0 {
                activityTimeline
            } else {
                comingSoon
            }
        }
        .frame(minWidth: 400, minHeight: 500)
        .background(Theme.background)
        .preferredColorScheme(.dark)
    }

    private var activityTimeline: some View {
        Group {
            if viewModel.groups.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Theme.spacing2, pinnedViews: [.sectionHeaders]) {
                        ForEach(viewModel.groups, id: \.day) { group in
                            Section {
                                ForEach(group.rows) { row in
                                    sessionRow(row)
                                        .transition(.opacity)
                                }
                            } header: {
                                Text(group.day)
                                    .font(.headline)
                                    .foregroundColor(Theme.text)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, Theme.spacing2)
                                    .padding(.vertical, Theme.spacing1)
                                    .background(Theme.background)
                            }
                        }
                    }
                    .padding(.top, Theme.spacing1)
                    .animation(Theme.spring, value: viewModel.groups.count)
                }
            }
        }
    }

    private func sessionRow(_ row: SessionRow) -> some View {
        VStack(alignment: .leading, spacing: Theme.spacing1) {
            Button {
                withAnimation(Theme.spring) {
                    expandedRowId = expandedRowId == row.id ? nil : row.id
                }
            } label: {
                HStack(spacing: Theme.spacing1) {
                    // App glyph (SF Symbol)
                    Image(systemName: appIcon(for: row.appLabel))
                        .font(.system(size: 20))
                        .foregroundColor(Theme.accent)
                        .frame(width: 28, height: 28)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(row.summary)
                            .font(.body)
                            .foregroundColor(Theme.text)
                            .lineLimit(expandedRowId == row.id ? nil : 2)

                        HStack(spacing: 4) {
                            Text(row.appLabel)
                                .font(.caption)
                                .foregroundColor(Theme.secondaryText)
                            Text("·")
                                .foregroundColor(Theme.secondaryText)
                            Text(row.timeAgo)
                                .font(.caption)
                                .foregroundColor(Theme.secondaryText)
                        }
                    }

                    Spacer()

                    if !row.evidence.isEmpty {
                        Image(systemName: expandedRowId == row.id ? "chevron.up" : "chevron.down")
                            .font(.caption)
                            .foregroundColor(Theme.secondaryText)
                    }
                }
                .padding(Theme.spacing2)
                .background(Theme.surface)
                .cornerRadius(8)
            }
            .buttonStyle(.plain)

            // Expanded evidence
            if expandedRowId == row.id && !row.evidence.isEmpty {
                VStack(alignment: .leading, spacing: Theme.spacing1) {
                    Text("Why am I seeing this?")
                        .font(.caption.bold())
                        .foregroundColor(Theme.secondaryText)

                    ForEach(Array(row.evidence.enumerated()), id: \.offset) { _, evidence in
                        Text("• \(evidence)")
                            .font(.caption)
                            .foregroundColor(Theme.secondaryText)
                            .lineLimit(nil)
                    }
                }
                .padding(Theme.spacing2)
                .background(Theme.background)
                .cornerRadius(8)
                .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .top)))
            }
        }
        .padding(.horizontal, Theme.spacing2)
    }

    private var emptyState: some View {
        VStack(spacing: Theme.spacing2) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 48))
                .foregroundColor(Theme.secondaryText)

            Text("Nothing captured yet")
                .font(.title3)
                .foregroundColor(Theme.text)

            Text("Activity will appear here as you use your Mac")
                .font(.caption)
                .foregroundColor(Theme.secondaryText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var comingSoon: some View {
        VStack(spacing: Theme.spacing2) {
            Image(systemName: "sparkles")
                .font(.system(size: 48))
                .foregroundColor(Theme.accent)

            Text("Coming soon")
                .font(.title3)
                .foregroundColor(Theme.text)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func appIcon(for appLabel: String) -> String {
        let lower = appLabel.lowercased()
        if lower.contains("cursor") || lower.contains("code") || lower.contains("xcode") {
            return "chevron.left.forwardslash.chevron.right"
        } else if lower.contains("chrome") || lower.contains("safari") || lower.contains("firefox") {
            return "globe"
        } else if lower.contains("slack") || lower.contains("discord") {
            return "message.fill"
        } else if lower.contains("terminal") {
            return "terminal.fill"
        } else {
            return "app.fill"
        }
    }
}
