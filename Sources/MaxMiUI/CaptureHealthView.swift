import SwiftUI
import MaxMiCore

public struct CaptureHealthView: View {
    @Bindable private var viewModel: CaptureHealthViewModel

    public init(viewModel: CaptureHealthViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacing2) {
            VStack(alignment: .leading, spacing: Theme.spacingHalf) {
                Text("Capture Health")
                    .font(.title2.bold())
                    .foregroundColor(Theme.text)
                Text("Recent capture outcomes only. Page titles, URLs, and captured text are never shown here.")
                    .font(.caption)
                    .foregroundColor(Theme.secondaryText)
            }

            HStack(spacing: Theme.spacing1) {
                summaryCard("Captured", value: viewModel.summary.captured, color: Theme.success)
                summaryCard("Unchanged", value: viewModel.summary.deduplicated, color: Theme.accent)
                summaryCard("Skipped", value: viewModel.summary.skipped, color: Theme.warning)
                summaryCard("Failed", value: viewModel.summary.failed, color: Theme.destructive)
            }

            if viewModel.rows.isEmpty {
                VStack(spacing: Theme.spacing2) {
                    Image(systemName: "waveform.path.ecg")
                        .font(.system(size: Theme.iconSizeLarge))
                        .foregroundColor(Theme.secondaryText)
                    Text("No capture attempts recorded yet")
                        .font(.title3)
                        .foregroundColor(Theme.text)
                    Text("Use a few apps, then reopen this window.")
                        .font(.caption)
                        .foregroundColor(Theme.secondaryText)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: Theme.spacing1) {
                        ForEach(viewModel.rows) { row in
                            captureRow(row)
                        }
                    }
                }
            }
        }
        .padding(Theme.spacing2)
        .frame(minWidth: 560, minHeight: 480)
        .background(Theme.background)
        .preferredColorScheme(.dark)
    }

    private func summaryCard(_ title: String, value: Int, color: Color) -> some View {
        VStack(alignment: .leading, spacing: Theme.spacingHalf) {
            Text("\(value)")
                .font(.title3.bold())
                .foregroundColor(color)
            Text(title)
                .font(.caption)
                .foregroundColor(Theme.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.spacing1)
        .background(Theme.surface)
        .cornerRadius(Theme.cornerRadius)
    }

    private func captureRow(_ row: CaptureHealthRow) -> some View {
        HStack(alignment: .top, spacing: Theme.spacing1) {
            Image(systemName: statusIcon(row.outcome))
                .foregroundColor(statusColor(row.outcome))
                .frame(width: Theme.iconSizeSmall)

            VStack(alignment: .leading, spacing: Theme.spacingHalf) {
                HStack {
                    Text(row.appLabel)
                        .font(.body.bold())
                        .foregroundColor(Theme.text)
                    Text(row.status)
                        .font(.caption.bold())
                        .foregroundColor(statusColor(row.outcome))
                    Spacer()
                    Text(row.timeAgo)
                        .font(.caption)
                        .foregroundColor(Theme.tertiaryText)
                }
                Text(row.detail)
                    .font(.caption)
                    .foregroundColor(Theme.secondaryText)
                Text("\(row.parser) · \(row.trigger) · \(row.duration)")
                    .font(.caption2)
                    .foregroundColor(Theme.tertiaryText)
            }
        }
        .padding(Theme.spacing1)
        .background(Theme.surface)
        .cornerRadius(Theme.cornerRadius)
    }

    private func statusIcon(_ outcome: CaptureOutcomeKind) -> String {
        switch outcome {
        case .captured: return "checkmark.circle.fill"
        case .deduplicated: return "equal.circle.fill"
        case .skipped: return "minus.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private func statusColor(_ outcome: CaptureOutcomeKind) -> Color {
        switch outcome {
        case .captured: return Theme.success
        case .deduplicated: return Theme.accent
        case .skipped: return Theme.warning
        case .failed: return Theme.destructive
        }
    }
}
