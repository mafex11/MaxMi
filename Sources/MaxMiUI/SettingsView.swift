import SwiftUI
import AppKit
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
                // Grouped-rows layout (variant 2): each section is an uppercase label above one
                // rounded container; sub-views keep their own content but sit inside a group card.
                VStack(alignment: .leading, spacing: Theme.spacing3) {
                    settingsGroup("General") { generalSection }
                    settingsGroup("Setup & Connections") { SetupView(viewModel: setupViewModel) }
                    // Activity Timeline group hidden — the Timeline UI was removed, so its opt-in
                    // toggle isn't surfaced. `activitySection` is kept for a possible return.
                    // settingsGroup("Activity Timeline") { activitySection }
                    settingsGroup("Capture & Privacy") { CapturePrivacyView(viewModel: capturePrivacyViewModel) }
                    settingsGroup("Data Controls") { DataControlsView(viewModel: dataControlsViewModel) }
                    settingsGroup("About") { aboutSection }
                }
                .padding(Theme.spacing2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .preferredColorScheme(.dark)
    }

    /// Grouped-rows section: an uppercase label above one rounded, bordered container (devmafex
    /// "grouped rows" style). The section titles that used to live inside each sub-view are now
    /// provided here, so the sub-views should render only their controls.
    @ViewBuilder
    private func settingsGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.spacing1) {
            Text(title).sectionTitle().padding(.horizontal, Theme.spacingHalf)
            VStack(alignment: .leading, spacing: Theme.spacing2) {
                content()
            }
            .padding(Theme.spacing2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cornerRadiusLarge, style: .continuous)
                    .stroke(Theme.divider, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadiusLarge, style: .continuous))
        }
    }

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: Theme.spacing2) {
            Toggle(isOn: Binding(
                get: { viewModel.launchAtLoginStatus == .enabled },
                set: { newValue in Task { await viewModel.setLaunchAtLogin(newValue) } }
            )) {
                settingLabel(
                    icon: "power",
                    title: "Open MaxMi when I log in",
                    description: "Start capturing automatically after you sign in to your Mac."
                )
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
            Toggle(isOn: $viewModel.activityEnabled) {
                settingLabel(
                    icon: "chart.bar",
                    title: "Build a timeline of my day",
                    description: "MaxMi groups what you did across apps into an hourly summary using Gemini AI. Screen content is sent to Google to build it. Off by default."
                )
            }
            .disabled(!viewModel.consentGranted)

            if !viewModel.consentGranted {
                HStack(spacing: Theme.spacing1) {
                    Image(systemName: "hand.raised")
                        .foregroundColor(Theme.warning)
                    Text("Needs your permission first")
                        .font(.caption)
                        .foregroundColor(Theme.secondaryText)
                    Button("Review & allow") {
                        viewModel.openPrivacy()
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }

            if !viewModel.excludedApps.isEmpty {
                VStack(alignment: .leading, spacing: Theme.spacing1) {
                    Text("Skip these apps")
                        .font(.subheadline)
                        .foregroundColor(Theme.secondaryText)
                    Text("Anything you do in these apps stays out of the timeline.")
                        .font(.caption)
                        .foregroundColor(Theme.tertiaryText)

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

    /// A toggle/label with an icon, a plain-language title, and a one-line description underneath —
    /// so each setting explains itself instead of relying on jargon.
    private func settingLabel(icon: String, title: String, description: String) -> some View {
        HStack(alignment: .top, spacing: Theme.spacing1) {
            Image(systemName: icon)
                .foregroundColor(Theme.accent)
                .frame(width: 18)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: Theme.spacingHalf) {
                Text(title)
                    .foregroundColor(Theme.text)
                Text(description)
                    .font(.caption)
                    .foregroundColor(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: Theme.spacing2) {
            HStack(spacing: Theme.spacing2) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: Theme.spacingHalf) {
                    Text("MaxMi \(viewModel.version)")
                        .foregroundColor(Theme.text)
                    Text("Updates are manual")
                        .font(.caption)
                        .foregroundColor(Theme.secondaryText)
                }
            }

            FlowLayout(spacing: Theme.spacing1) {
                Button("Release Information") {
                    Task { await viewModel.checkUpdates() }
                }
                .buttonStyle(.bordered)
                Button("Open Official Releases") {
                    viewModel.openReleasePage()
                }
                .buttonStyle(.borderedProminent)
            }

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

            Text("Dog icon “sitting-dog” by Delapouite, game-icons.net, licensed under CC BY 3.0.")
                .font(.caption2)
                .foregroundColor(Theme.secondaryText)
                .padding(.top, Theme.spacingHalf)
        }
    }
}
