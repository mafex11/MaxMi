import SwiftUI

public struct DataControlsView: View {
    @Bindable private var viewModel: DataControlsViewModel

    public init(viewModel: DataControlsViewModel) { self.viewModel = viewModel }

    public var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacing2) {
            Text("Data Controls").sectionTitle()
            Text("Exports contain decrypted plaintext. Retention cleanup and deletion create a private SQLite backup before changing memory.")
                .font(.caption).foregroundColor(Theme.secondaryText)
            FlowLayout(spacing: Theme.spacing1) {
                Button("Export Memory…") { Task { await viewModel.export() } }
                    .buttonStyle(.bordered)
                Button("Apply Retention Now…") { Task { await viewModel.applyRetention() } }
                    .buttonStyle(.bordered)
                Button("Delete All Memory…", role: .destructive) { Task { await viewModel.deleteAll() } }
                    .buttonStyle(.bordered)
                Button("Restore Database Backup…", role: .destructive) {
                    Task { await viewModel.restore() }
                }
                .buttonStyle(.bordered)
            }
            .disabled(viewModel.isWorking)
            Divider().background(Theme.divider)
            Text("Diagnostics contain aggregate health, versions, permissions, process counts, and privacy-safe logs—never captured content.")
                .font(.caption).foregroundColor(Theme.secondaryText)
            FlowLayout(spacing: Theme.spacing1) {
                Button("Export Diagnostics…") { Task { await viewModel.exportDiagnostics() } }
                    .buttonStyle(.bordered)
                Button("Reveal Logs") { viewModel.revealLogs() }
                    .buttonStyle(.bordered)
            }
            .disabled(viewModel.isWorking)
            if viewModel.isWorking { ProgressView().controlSize(.small) }
            if !viewModel.status.isEmpty {
                Text(viewModel.status).font(.caption).foregroundColor(Theme.secondaryText)
            }
        }
    }
}
