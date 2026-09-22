import SwiftUI
import MaxMiCore

public enum TodoPanelRowState {
    public static func showsPendingReminder(for item: TodoPanelItem) -> Bool {
        item.remindAtMs != nil && item.remindedAtMs == nil
    }

    public static func ageDescription(detectedAtMs: EpochMs, nowMs: EpochMs) -> String {
        let elapsedHours = max(0, nowMs - detectedAtMs) / 3_600_000
        if elapsedHours < 24 {
            return "\(elapsedHours)h"
        }
        return "\(elapsedHours / 24)d"
    }
}

public struct TodoPanelView: View {
    @Bindable private var viewModel: TodoPanelViewModel
    private let onClose: @MainActor () -> Void

    public init(
        viewModel: TodoPanelViewModel,
        onClose: @escaping @MainActor () -> Void
    ) {
        self.viewModel = viewModel
        self.onClose = onClose
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacing2) {
            header
            if viewModel.items.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: Theme.spacing1) {
                        ForEach(Array(viewModel.items.enumerated()), id: \.element.id) { index, item in
                            row(item: item, index: index)
                        }
                    }
                }
            }
        }
        .padding(Theme.spacing2)
        .background(Theme.background)
        .preferredColorScheme(.dark)
        .onMoveCommand { direction in
            switch direction {
            case .up:
                viewModel.moveSelection(by: -1)
            case .down:
                viewModel.moveSelection(by: 1)
            default:
                break
            }
        }
        .onKeyPress(.return) {
            Task { await viewModel.markSelectedDone() }
            return .handled
        }
        .onKeyPress(.delete) {
            Task { await viewModel.dismissSelected() }
            return .handled
        }
        .onExitCommand {
            onClose()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.spacing0) {
            Text("\(viewModel.items.count) open")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(Theme.text)
            if let checkinFirstLine = viewModel.checkinFirstLine {
                Text(checkinFirstLine)
                    .font(.system(size: 12))
                    .foregroundColor(Theme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: Theme.spacing1) {
            Text("Nothing open.")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(Theme.text)
            if let checkinFirstLine = viewModel.checkinFirstLine {
                Text(checkinFirstLine)
                    .font(.system(size: 12))
                    .foregroundColor(Theme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, Theme.spacing3)
    }

    private func row(item: TodoPanelItem, index: Int) -> some View {
        let isSelected = viewModel.selectedIndex == index
        return HStack(alignment: .top, spacing: Theme.spacing2) {
            VStack(alignment: .leading, spacing: Theme.spacing0) {
                HStack(spacing: Theme.spacing1) {
                    Text(item.title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(Theme.text)
                        .lineLimit(2)
                    if TodoPanelRowState.showsPendingReminder(for: item) {
                        Image(systemName: "clock")
                            .font(.system(size: 11))
                            .foregroundColor(Theme.secondaryText)
                    }
                }
                Text("\(item.sourceApp ?? "MaxMi") · \(ageDescription(item.detectedAtMs))")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.secondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: Theme.spacing1)
            HStack(spacing: Theme.spacing1) {
                Button("Done") {
                    viewModel.select(index: index)
                    Task { await viewModel.markSelectedDone() }
                }
                .buttonStyle(.borderedProminent)
                Button("Dismiss") {
                    viewModel.select(index: index)
                    Task { await viewModel.dismissSelected() }
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(Theme.spacing2)
        .background(isSelected ? Theme.accent.opacity(0.55) : Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture {
            viewModel.select(index: index)
        }
    }

    private func ageDescription(_ detectedAtMs: EpochMs) -> String {
        TodoPanelRowState.ageDescription(detectedAtMs: detectedAtMs, nowMs: epochNowMs())
    }
}
