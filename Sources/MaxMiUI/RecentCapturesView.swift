import SwiftUI
import MaxMiCore

public struct RecentCapturesView: View {
    @Bindable private var viewModel: RecentCapturesViewModel

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
                            HStack(alignment: .top, spacing: Theme.spacing1) {
                                Image(systemName: icon(row.contentKind))
                                    .foregroundColor(Theme.accent)
                                    .frame(width: Theme.iconSizeSmall)

                                VStack(alignment: .leading, spacing: Theme.spacingHalf) {
                                    Text(row.summary)
                                        .font(.body)
                                        .foregroundColor(Theme.text)
                                        .lineLimit(2)
                                    HStack(spacing: Theme.spacingHalf) {
                                        Text(row.appLabel)
                                        Text("·")
                                        Text(row.sourceTitle)
                                            .lineLimit(1)
                                        Text("·")
                                        Text(row.timeAgo)
                                    }
                                    .font(.caption)
                                    .foregroundColor(Theme.secondaryText)
                                    Text(row.detail)
                                        .font(.caption2)
                                        .foregroundColor(Theme.tertiaryText)
                                        .lineLimit(1)
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

    private func icon(_ kind: CaptureContentKind) -> String {
        switch kind {
        case .webpage: return "globe"
        case .conversation: return "message.fill"
        case .document: return "doc.text.fill"
        case .terminal: return "terminal.fill"
        case .email: return "envelope.fill"
        case .calendar: return "calendar"
        case .task: return "checkmark.circle.fill"
        case .generic: return "app.fill"
        }
    }
}
