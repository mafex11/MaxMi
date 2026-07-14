import SwiftUI

public struct ActivityView: View {
    @Bindable var viewModel: ActivityViewModel
    @Bindable var actionItemsViewModel: ActionItemsViewModel
    @Bindable var recentCapturesViewModel: RecentCapturesViewModel
    @Bindable var meetingHistoryViewModel: MeetingHistoryViewModel
    @State private var expandedRowId: String?
    @State private var selectedTab = 0
    @State private var hoveredRowId: String?

    public init(
        viewModel: ActivityViewModel,
        actionItemsViewModel: ActionItemsViewModel,
        recentCapturesViewModel: RecentCapturesViewModel,
        meetingHistoryViewModel: MeetingHistoryViewModel
    ) {
        self.viewModel = viewModel
        self.actionItemsViewModel = actionItemsViewModel
        self.recentCapturesViewModel = recentCapturesViewModel
        self.meetingHistoryViewModel = meetingHistoryViewModel
    }

    public var body: some View {
        VStack(spacing: Theme.spacing0) {
            // Local captures are always available. AI Activity remains an opt-in view.
            Picker("", selection: $selectedTab) {
                Text("Captures").tag(0)
                Text("Activity").tag(1)
                Text("Actions").tag(2)
                Text("Recordings").tag(3)
            }
            .pickerStyle(.segmented)
            .padding(Theme.spacing2)
            .animation(Theme.spring, value: selectedTab)

            if selectedTab == 0 {
                RecentCapturesView(viewModel: recentCapturesViewModel)
            } else if selectedTab == 1 {
                activityTimeline
            } else if selectedTab == 2 {
                ActionItemsView(viewModel: actionItemsViewModel)
            } else {
                MeetingHistoryView(viewModel: meetingHistoryViewModel)
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
                        .font(.system(size: Theme.iconSizeSmall))
                        .foregroundColor(Theme.accent)
                        .frame(width: Theme.iconSizeMedium, height: Theme.iconSizeMedium)

                    VStack(alignment: .leading, spacing: Theme.spacingHalf) {
                        Text(row.summary)
                            .font(.body)
                            .foregroundColor(Theme.text)
                            .lineLimit(expandedRowId == row.id ? nil : 2)

                        HStack(spacing: Theme.spacingHalf) {
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
                .background(hoveredRowId == row.id ? Theme.surface.opacity(0.85) : Theme.surface)
                .cornerRadius(Theme.cornerRadius)
            }
            .buttonStyle(.plain)
            .onHover { isHovering in
                hoveredRowId = isHovering ? row.id : nil
            }

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
                .cornerRadius(Theme.cornerRadius)
                .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .top)))
            }
        }
        .padding(.horizontal, Theme.spacing2)
        .animation(Theme.spring, value: expandedRowId == row.id)
    }

    private var emptyState: some View {
        VStack(spacing: Theme.spacing2) {
            Image(systemName: "dog")
                .font(.system(size: Theme.iconSizeLarge))
                .foregroundColor(Theme.secondaryText)

            Text("No synthesized activity yet")
                .font(.title3)
                .foregroundColor(Theme.text)

            Text("Activity Synthesis is opt-in under Activity Privacy")
                .font(.caption)
                .foregroundColor(Theme.secondaryText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var comingSoon: some View {
        VStack(spacing: Theme.spacing2) {
            Image(systemName: "sparkles")
                .font(.system(size: Theme.iconSizeLarge))
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
