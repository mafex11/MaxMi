import SwiftUI
import MaxMiCore

public struct TodayCardView: View {
    @Bindable private var viewModel: CheckinViewModel

    public init(viewModel: CheckinViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        Group {
            switch viewModel.state {
            case .dismissed:
                EmptyView()
            case .pending:
                Text("Today’s check-in is being prepared.")
                    .font(.system(size: 13))
                    .foregroundColor(Theme.secondaryText)
                    .padding(Theme.spacing2)
            case .ready(let summary, let generatedAtMs), .empty(let summary, let generatedAtMs):
                VStack(alignment: .leading, spacing: Theme.spacing1) {
                    Text("Today")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(Theme.text)
                    Text(summary)
                        .font(.system(size: 13))
                        .foregroundColor(Theme.text)
                        .fixedSize(horizontal: false, vertical: true)
                    if !viewModel.openItems.isEmpty {
                        Divider()
                            .overlay(Theme.divider)
                        Text("Open items")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(Theme.secondaryText)
                        ForEach(Array(viewModel.openItems.enumerated()), id: \.offset) { _, item in
                            Text("\(item.title) · \(ageDescription(item.ageDays))")
                                .font(.system(size: 12))
                                .foregroundColor(Theme.secondaryText)
                                .lineLimit(1)
                        }
                    }
                    HStack {
                        Text(generatedTime(generatedAtMs))
                            .font(.caption)
                            .foregroundColor(Theme.secondaryText)
                        Spacer()
                        if viewModel.isRegenerating {
                            ProgressView()
                                .controlSize(.small)
                            Text("Regenerating…")
                                .font(.caption)
                                .foregroundColor(Theme.secondaryText)
                        } else {
                            Button("Dismiss") {
                                Task { await viewModel.dismissToday() }
                            }
                            Button("Regenerate") {
                                Task { await viewModel.regenerateToday() }
                            }
                        }
                    }
                }
                .padding(Theme.spacing2)
                .background(Theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
            }
        }
        .preferredColorScheme(.dark)
    }

    private func generatedTime(_ ms: EpochMs) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: Date(timeIntervalSince1970: Double(ms) / 1_000))
    }

    private func ageDescription(_ ageDays: Int) -> String {
        switch ageDays {
        case 0:
            "today"
        case 1:
            "1 day old"
        default:
            "\(ageDays) days old"
        }
    }
}
