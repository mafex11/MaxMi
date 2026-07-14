import SwiftUI
import MaxMiCore

public struct SettingsView: View {
    @Bindable var viewModel: SettingsViewModel
    @Bindable var capturePrivacyViewModel: CapturePrivacyViewModel
    @Bindable var dataControlsViewModel: DataControlsViewModel
    @Bindable var setupViewModel: SetupViewModel

    public init(viewModel: SettingsViewModel, capturePrivacyViewModel: CapturePrivacyViewModel,
                dataControlsViewModel: DataControlsViewModel, setupViewModel: SetupViewModel) {
        self.viewModel = viewModel
        self.capturePrivacyViewModel = capturePrivacyViewModel
        self.dataControlsViewModel = dataControlsViewModel
        self.setupViewModel = setupViewModel
    }

    public var body: some View {
        VStack(spacing: Theme.spacing0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.spacing3) {
                    generalSection
                    Divider()
                        .background(Theme.divider)
                    SetupView(viewModel: setupViewModel)
                    Divider()
                        .background(Theme.divider)
                    activitySection
                    Divider()
                        .background(Theme.divider)
                    CapturePrivacyView(viewModel: capturePrivacyViewModel)
                    DataControlsView(viewModel: dataControlsViewModel)
                    Divider()
                        .background(Theme.divider)
                    aboutSection
                }
                .padding(Theme.spacing3)
            }
        }
        .frame(minWidth: 460, minHeight: 560)
        .background(Theme.background)
        .preferredColorScheme(.dark)
    }

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: Theme.spacing2) {
            Text("General")
                .font(.headline)
                .foregroundColor(Theme.text)

            Toggle(isOn: Binding(
                get: { viewModel.launchAtLoginStatus == .enabled },
                set: { newValue in Task { await viewModel.setLaunchAtLogin(newValue) } }
            )) {
                HStack(spacing: Theme.spacing1) {
                    Image(systemName: "power")
                        .foregroundColor(Theme.accent)
                    Text("Launch at Login")
                        .foregroundColor(Theme.text)
                }
            }

            if viewModel.launchAtLoginStatus == .requiresApproval {
                HStack(spacing: Theme.spacing1) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundColor(Theme.warning)
                    Text("Requires approval in System Settings")
                        .font(.caption)
                        .foregroundColor(Theme.secondaryText)
                    Button("Open Login Items") {
                        viewModel.openLoginItems()
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }

            if let error = viewModel.launchAtLoginError {
                HStack(spacing: Theme.spacing1) {
                    Image(systemName: "xmark.circle")
                        .foregroundColor(Theme.destructive)
                    Text(error)
                        .font(.caption)
                        .foregroundColor(Theme.secondaryText)
                }
            }
        }
    }

    private var activitySection: some View {
        VStack(alignment: .leading, spacing: Theme.spacing2) {
            Text("Activity")
                .font(.headline)
                .foregroundColor(Theme.text)

            Toggle(isOn: $viewModel.activityEnabled) {
                HStack(spacing: Theme.spacing1) {
                    Image(systemName: "chart.bar")
                        .foregroundColor(Theme.accent)
                    Text("Enable Activity Synthesis")
                        .foregroundColor(Theme.text)
                }
            }
            .disabled(!viewModel.consentGranted)

            if !viewModel.consentGranted {
                HStack(spacing: Theme.spacing1) {
                    Image(systemName: "hand.raised")
                        .foregroundColor(Theme.warning)
                    Text("Consent required")
                        .font(.caption)
                        .foregroundColor(Theme.secondaryText)
                    Button("Grant Consent") {
                        viewModel.openPrivacy()
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }

            if !viewModel.excludedApps.isEmpty {
                VStack(alignment: .leading, spacing: Theme.spacing1) {
                    Text("Exclude apps from activity capture")
                        .font(.subheadline)
                        .foregroundColor(Theme.secondaryText)

                    ForEach(viewModel.excludedApps) { app in
                        Toggle(isOn: Binding(
                            get: { app.excluded },
                            set: { newValue in Task { await viewModel.toggleExcluded(app.id) } }
                        )) {
                            Text(app.name)
                                .foregroundColor(Theme.text)
                        }
                    }
                }
            }
        }
    }

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: Theme.spacing2) {
            Text("About")
                .font(.headline)
                .foregroundColor(Theme.text)

            HStack(spacing: Theme.spacing1) {
                Image(systemName: "info.circle")
                    .foregroundColor(Theme.accent)
                VStack(alignment: .leading, spacing: Theme.spacingHalf) {
                    Text("MaxMi \(viewModel.version)")
                        .foregroundColor(Theme.text)
                    Text("Updates are manual")
                        .font(.caption)
                        .foregroundColor(Theme.secondaryText)
                }
            }

            Button("Check for Updates") {
                Task { await viewModel.checkUpdates() }
            }
            .buttonStyle(.borderedProminent)

            if !viewModel.updateStatus.isEmpty {
                Text(viewModel.updateStatus)
                    .font(.caption)
                    .foregroundColor(Theme.secondaryText)
            }

            if !viewModel.statusLines.isEmpty {
                VStack(alignment: .leading, spacing: Theme.spacingHalf) {
                    Text("Status")
                        .font(.subheadline)
                        .foregroundColor(Theme.secondaryText)
                    ForEach(viewModel.statusLines, id: \.self) { line in
                        Text(line)
                            .font(.caption)
                            .foregroundColor(Theme.secondaryText)
                    }
                }
            }
        }
    }
}
