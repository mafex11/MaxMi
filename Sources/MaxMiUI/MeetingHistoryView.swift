import SwiftUI

public struct MeetingHistoryView: View {
    @Bindable private var viewModel: MeetingHistoryViewModel

    public init(viewModel: MeetingHistoryViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        Group {
            if viewModel.rows.isEmpty {
                VStack(spacing: Theme.spacing2) {
                    Image(systemName: "waveform.and.mic")
                        .font(.system(size: Theme.iconSizeLarge))
                        .foregroundColor(Theme.secondaryText)
                    Text("No recordings yet")
                        .font(.title3)
                        .foregroundColor(Theme.text)
                    Text("Start a voice note from the tray menu or record a detected meeting.")
                        .font(.caption)
                        .foregroundColor(Theme.secondaryText)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: Theme.spacing1) {
                        ForEach(viewModel.rows) { row in
                            HStack(spacing: Theme.spacing1) {
                                Image(systemName: row.isVoiceNote ? "mic.fill" : "person.2.wave.2.fill")
                                    .foregroundColor(Theme.accent)
                                    .frame(width: Theme.iconSizeMedium)
                                VStack(alignment: .leading, spacing: Theme.spacingHalf) {
                                    Text(row.title)
                                        .font(.body.bold())
                                        .foregroundColor(Theme.text)
                                        .lineLimit(1)
                                    Text("\(row.source) · \(row.duration) · \(row.status)")
                                        .font(.caption)
                                        .foregroundColor(Theme.secondaryText)
                                }
                                Spacer()
                                Text(row.timeAgo)
                                    .font(.caption2)
                                    .foregroundColor(Theme.tertiaryText)
                            }
                            .padding(Theme.spacing2)
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
}
