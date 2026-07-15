import SwiftUI

/// Compact day-grouped activity timeline for the menu-bar popover. Mirrors the timeline that used
/// to live only in the separate window, so Activity Timeline is now viewable without leaving the tray.
public struct ActivityTimelineView: View {
    @Bindable private var viewModel: ActivityViewModel
    @State private var expandedRowId: String?

    public init(viewModel: ActivityViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
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
                                }
                            } header: {
                                Text(group.day)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(Theme.secondaryText)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, Theme.spacing2)
                                    .padding(.vertical, Theme.spacingHalf)
                                    .background(Theme.background)
                            }
                        }
                    }
                    .padding(.horizontal, Theme.spacing2)
                    .padding(.bottom, Theme.spacing2)
                }
            }
        }
    }

    private func sessionRow(_ row: SessionRow) -> some View {
        VStack(alignment: .leading, spacing: Theme.spacingHalf) {
            Button {
                withAnimation(Theme.spring) {
                    expandedRowId = expandedRowId == row.id ? nil : row.id
                }
            } label: {
                HStack(alignment: .top, spacing: Theme.spacing1) {
                    VStack(alignment: .leading, spacing: Theme.spacingHalf) {
                        Text(row.summary)
                            .font(.system(size: 13))
                            .foregroundColor(Theme.text)
                            .lineLimit(expandedRowId == row.id ? nil : 2)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: Theme.spacingHalf) {
                            Text(row.appLabel)
                            Text("·")
                            Text(row.timeAgo)
                        }
                        .font(.caption2)
                        .foregroundColor(Theme.tertiaryText)
                    }
                    Spacer(minLength: 0)
                    if !row.evidence.isEmpty {
                        Image(systemName: expandedRowId == row.id ? "chevron.up" : "chevron.down")
                            .font(.caption2)
                            .foregroundColor(Theme.tertiaryText)
                    }
                }
                .padding(Theme.spacing1)
            }
            .buttonStyle(.plain)

            if expandedRowId == row.id, !row.evidence.isEmpty {
                VStack(alignment: .leading, spacing: Theme.spacingHalf) {
                    ForEach(Array(row.evidence.enumerated()), id: \.offset) { _, evidence in
                        Text("• \(evidence)")
                            .font(.caption2)
                            .foregroundColor(Theme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, Theme.spacing1)
                .padding(.bottom, Theme.spacing1)
            }
        }
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
    }

    private var emptyState: some View {
        VStack(spacing: Theme.spacing1) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: Theme.iconSizeLarge * 0.7))
                .foregroundColor(Theme.secondaryText)
            Text("No timeline yet")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(Theme.text)
            Text("Turn on “Build a timeline of my day” in Settings to see your activity here.")
                .font(.caption)
                .foregroundColor(Theme.secondaryText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Theme.spacing2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, Theme.spacing3)
    }
}
