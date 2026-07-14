import SwiftUI

public struct DataControlsView: View {
    @Bindable private var viewModel: DataControlsViewModel

    public init(viewModel: DataControlsViewModel) { self.viewModel = viewModel }

    public var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacing2) {
            Text("Data Controls").font(.headline).foregroundColor(Theme.text)
            Text("Exports contain decrypted plaintext. Retention cleanup and deletion create a private SQLite backup before changing memory.")
                .font(.caption).foregroundColor(Theme.secondaryText)
            HStack {
                Button("Export Memory…") { Task { await viewModel.export() } }
                    .buttonStyle(.bordered)
                Button("Apply Retention Now…") { Task { await viewModel.applyRetention() } }
                    .buttonStyle(.bordered)
                Spacer()
                Button("Delete All Memory…", role: .destructive) { Task { await viewModel.deleteAll() } }
                    .buttonStyle(.bordered)
            }
            .disabled(viewModel.isWorking)
            if viewModel.isWorking { ProgressView().controlSize(.small) }
            if !viewModel.status.isEmpty {
                Text(viewModel.status).font(.caption).foregroundColor(Theme.secondaryText)
            }
        }
        .padding(Theme.spacing2).background(Theme.surface).cornerRadius(Theme.cornerRadius)
    }
}

