import SwiftUI
import Observation

public enum MenuPopoverPage: Sendable, Equatable {
    case home
    case settings
}

@MainActor
@Observable
public final class MenuPopoverViewModel {
    public var page: MenuPopoverPage = .home
    public init() {}
    public func showHome() { page = .home }
    public func showSettings() { page = .settings }
}

public struct MenuPopoverView: View {
    @Bindable private var navigation: MenuPopoverViewModel
    @Bindable private var trayHomeViewModel: TrayHomeViewModel
    @Bindable private var recentCapturesViewModel: RecentCapturesViewModel
    @Bindable private var settingsViewModel: SettingsViewModel
    @Bindable private var capturePrivacyViewModel: CapturePrivacyViewModel
    @Bindable private var dataControlsViewModel: DataControlsViewModel
    @Bindable private var setupViewModel: SetupViewModel
    private let onTogglePause: @MainActor () -> Void
    private let onOpenMaxMi: @MainActor () -> Void

    public init(
        navigation: MenuPopoverViewModel,
        trayHomeViewModel: TrayHomeViewModel,
        recentCapturesViewModel: RecentCapturesViewModel,
        settingsViewModel: SettingsViewModel,
        capturePrivacyViewModel: CapturePrivacyViewModel,
        dataControlsViewModel: DataControlsViewModel,
        setupViewModel: SetupViewModel,
        onTogglePause: @escaping @MainActor () -> Void,
        onOpenMaxMi: @escaping @MainActor () -> Void
    ) {
        self.navigation = navigation
        self.trayHomeViewModel = trayHomeViewModel
        self.recentCapturesViewModel = recentCapturesViewModel
        self.settingsViewModel = settingsViewModel
        self.capturePrivacyViewModel = capturePrivacyViewModel
        self.dataControlsViewModel = dataControlsViewModel
        self.setupViewModel = setupViewModel
        self.onTogglePause = onTogglePause
        self.onOpenMaxMi = onOpenMaxMi
    }

    public var body: some View {
        Group {
            switch navigation.page {
            case .home:
                TrayHomeView(
                    viewModel: trayHomeViewModel,
                    recentCapturesViewModel: recentCapturesViewModel,
                    onTogglePause: onTogglePause,
                    onOpenMaxMi: onOpenMaxMi,
                    onOpenSettings: { navigation.showSettings() }
                )
            case .settings:
                VStack(spacing: Theme.spacing0) {
                    HStack {
                        Button { navigation.showHome() } label: {
                            Label("Back", systemImage: "chevron.left")
                        }
                        .buttonStyle(.plain)
                        Spacer()
                        Text("Settings").font(.headline).foregroundColor(Theme.text)
                        Spacer()
                        Color.clear.frame(width: 44, height: 1)
                    }
                    .padding(Theme.spacing2)
                    .background(Theme.surface)

                    SettingsView(
                        viewModel: settingsViewModel,
                        capturePrivacyViewModel: capturePrivacyViewModel,
                        dataControlsViewModel: dataControlsViewModel,
                        setupViewModel: setupViewModel
                    )
                }
            }
        }
        .frame(width: 520, height: 650)
        .background(Theme.background)
        .preferredColorScheme(.dark)
        .onChange(of: navigation.page) { _, page in
            Task {
                switch page {
                case .home:
                    await recentCapturesViewModel.refresh()
                    await trayHomeViewModel.refresh()
                case .settings:
                    await settingsViewModel.refresh()
                    await capturePrivacyViewModel.refresh()
                    await setupViewModel.refresh()
                }
            }
        }
    }
}
