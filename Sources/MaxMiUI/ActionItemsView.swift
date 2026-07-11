import SwiftUI

public struct ActionItemsView: View {
    @Bindable var viewModel: ActionItemsViewModel
    @State private var selectedSegment = 0

    public init(viewModel: ActionItemsViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $selectedSegment) {
                Text("Open").tag(0)
                Text("Archived").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(Theme.spacing2)

            if selectedSegment == 0 {
                openItemsList
            } else {
                archivedItemsList
            }
        }
        .task {
            await viewModel.refresh()
        }
    }

    private var openItemsList: some View {
        Group {
            if viewModel.open.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: Theme.spacing2) {
                        ForEach(viewModel.open) { item in
                            itemRow(item, isArchived: false)
                                .transition(.asymmetric(
                                    insertion: .opacity.combined(with: .scale(scale: 0.95)),
                                    removal: .asymmetric(
                                        insertion: .identity,
                                        removal: .scale(scale: 0.8).combined(with: .opacity)
                                    )
                                ))
                        }
                    }
                    .padding(Theme.spacing2)
                    .animation(Theme.spring, value: viewModel.open.count)
                }
            }
        }
    }

    private var archivedItemsList: some View {
        Group {
            if viewModel.archived.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: Theme.spacing2) {
                        ForEach(viewModel.archived) { item in
                            itemRow(item, isArchived: true)
                        }
                    }
                    .padding(Theme.spacing2)
                }
            }
        }
    }

    private func itemRow(_ item: ActionItemDTO, isArchived: Bool) -> some View {
        HStack(alignment: .top, spacing: Theme.spacing2) {
            VStack(alignment: .leading, spacing: Theme.spacing1) {
                HStack(spacing: 4) {
                    if isArchived {
                        Text(statusLabel(item.status))
                            .font(.caption)
                            .foregroundColor(statusColor(item.status))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(statusColor(item.status).opacity(0.2))
                            .cornerRadius(4)
                    }

                    Text(item.title)
                        .font(.body)
                        .foregroundColor(Theme.text)
                        .lineLimit(nil)
                }

                if let details = item.details, !details.isEmpty {
                    Text(details)
                        .font(.caption)
                        .foregroundColor(Theme.secondaryText)
                        .lineLimit(3)
                }

                Text(item.timeAgo)
                    .font(.caption2)
                    .foregroundColor(Theme.secondaryText.opacity(0.8))
            }

            Spacer()

            if !isArchived {
                HStack(spacing: Theme.spacing1) {
                    Button {
                        Task {
                            await viewModel.resolve(item.id)
                        }
                    } label: {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 20))
                            .foregroundColor(.green)
                    }
                    .buttonStyle(.plain)
                    .help("Resolve")

                    Button {
                        Task {
                            await viewModel.dismiss(item.id)
                        }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 20))
                            .foregroundColor(.red)
                    }
                    .buttonStyle(.plain)
                    .help("Dismiss")
                }
            }
        }
        .padding(Theme.spacing2)
        .background(Theme.surface)
        .cornerRadius(8)
    }

    private var emptyState: some View {
        VStack(spacing: Theme.spacing2) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 48))
                .foregroundColor(Theme.secondaryText)

            Text("No action items")
                .font(.title3)
                .foregroundColor(Theme.text)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func statusLabel(_ status: String) -> String {
        switch status {
        case "resolved": return "Resolved"
        case "dismissed": return "Dismissed"
        default: return status.capitalized
        }
    }

    private func statusColor(_ status: String) -> Color {
        switch status {
        case "resolved": return .green
        case "dismissed": return .red
        default: return Theme.secondaryText
        }
    }
}
