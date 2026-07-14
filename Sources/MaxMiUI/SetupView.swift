import SwiftUI

public struct SetupView: View {
    @Bindable private var viewModel: SetupViewModel

    public init(viewModel: SetupViewModel) { self.viewModel = viewModel }

    public var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacing2) {
            Text("Setup & Connections").font(.headline).foregroundColor(Theme.text)
            VStack(spacing: Theme.spacing1) {
                ForEach(viewModel.snapshot.permissions) { item in statusRow(item) }
                statusRow(viewModel.snapshot.encryption)
                statusRow(viewModel.snapshot.mcp)
            }
            mcpCard
            if !viewModel.message.isEmpty {
                Text(viewModel.message).font(.caption).foregroundColor(Theme.secondaryText)
            }
        }
    }

    private func statusRow(_ item: SetupStatusItem) -> some View {
        HStack(spacing: Theme.spacing1) {
            Image(systemName: icon(item.state)).foregroundColor(color(item.state)).frame(width: 18)
            VStack(alignment: .leading, spacing: Theme.spacingHalf) {
                Text(item.title).foregroundColor(Theme.text)
                Text(item.detail).font(.caption).foregroundColor(Theme.secondaryText)
            }
            Spacer()
            if let action = item.actionTitle {
                Button(action) { Task { await viewModel.handlePermission(item.id) } }.buttonStyle(.bordered)
            }
        }
        .padding(Theme.spacing1).background(Theme.surface).cornerRadius(Theme.cornerRadius)
    }

    private var mcpCard: some View {
        VStack(alignment: .leading, spacing: Theme.spacing1) {
            Text("Claude connection").font(.subheadline).foregroundColor(Theme.text)
            Text("Copy a reviewed setup command. MaxMi never edits Claude configuration from this screen.")
                .font(.caption).foregroundColor(Theme.secondaryText)
            HStack {
                Button("Copy Claude Code command") { viewModel.copyMCPSetup(.claudeCode) }.buttonStyle(.bordered)
                Button("Copy Desktop JSON") { viewModel.copyMCPSetup(.claudeDesktop) }.buttonStyle(.bordered)
            }
        }
        .padding(Theme.spacing2).background(Theme.surface).cornerRadius(Theme.cornerRadius)
    }

    private func icon(_ state: SetupState) -> String {
        switch state {
        case .ready: return "checkmark.circle.fill"
        case .attention: return "exclamationmark.triangle.fill"
        case .unavailable: return "xmark.circle.fill"
        }
    }

    private func color(_ state: SetupState) -> Color {
        switch state {
        case .ready: return Theme.accent
        case .attention: return Theme.warning
        case .unavailable: return Theme.destructive
        }
    }
}
