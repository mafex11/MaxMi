import Foundation

public enum ApplicationKind: String, Sendable, Codable {
    case browser
    case chat
    case email
    case document
    case task
    case calendar
    case terminal
    case meeting
    case system
    case sensitive
    case other
}

public enum BrowserEngine: String, Sendable, Codable {
    case chromium
    case webkit
    case gecko
}

public enum CaptureStrategy: String, Sendable, Codable {
    case browserAX
    case nativeParser
    case genericAX
    case appleEvents
    case excluded
}

public enum DefaultCapturePolicy: String, Sendable, Codable {
    case allow
    case exclude
    case sensitive
}

public enum MeetingDetectionPolicy: String, Sendable, Codable {
    case none
    case nativeAudio
    case browserURLRequired
}

/// One source of truth for app classification shared by capture, privacy, meetings,
/// diagnostics, and tests. Parser-specific details remain in MaxMiCapture's registry;
/// this registry owns cross-feature identity and safety policy.
public struct ApplicationDescriptor: Sendable, Equatable {
    public let bundleID: String
    public let displayName: String
    public let kind: ApplicationKind
    public let captureStrategy: CaptureStrategy
    public let defaultPolicy: DefaultCapturePolicy
    public let browserEngine: BrowserEngine?
    public let meetingDetection: MeetingDetectionPolicy

    public init(
        bundleID: String,
        displayName: String,
        kind: ApplicationKind,
        captureStrategy: CaptureStrategy,
        defaultPolicy: DefaultCapturePolicy = .allow,
        browserEngine: BrowserEngine? = nil,
        meetingDetection: MeetingDetectionPolicy = .none
    ) {
        self.bundleID = bundleID
        self.displayName = displayName
        self.kind = kind
        self.captureStrategy = captureStrategy
        self.defaultPolicy = defaultPolicy
        self.browserEngine = browserEngine
        self.meetingDetection = meetingDetection
    }
}

public enum ApplicationRegistry {
    /// Browser inventory verified from installed Minimi 1.0.59. Aliases are separate
    /// descriptors because macOS reports the actual bundle identifier at runtime.
    public static let browsers: [ApplicationDescriptor] = [
        browser("com.google.Chrome", "Chrome", .chromium),
        browser("org.mozilla.firefox", "Firefox", .gecko),
        browser("company.thebrowser.Browser", "Arc", .chromium),
        browser("company.thebrowser.dia", "Dia", .chromium),
        browser("com.apple.Safari", "Safari", .webkit),
        browser("com.brave.Browser", "Brave", .chromium),
        browser("com.microsoft.edgemac", "Microsoft Edge", .chromium),
        browser("ai.perplexity.comet", "Comet", .chromium),
        browser("io.comet.Comet", "Comet", .chromium),
        browser("com.operasoftware.Opera", "Opera", .chromium),
        browser("com.vivaldi.Vivaldi", "Vivaldi", .chromium),
        browser("app.zen-browser.zen", "Zen", .gecko),
        browser("com.kagi.kagimacOS", "Orion", .webkit),
        browser("com.openai.atlas", "ChatGPT Atlas", .chromium),
    ]

    public static let nativeMeetingApps: [ApplicationDescriptor] = [
        meeting("us.zoom.xos", "Zoom"),
        meeting("com.microsoft.teams2", "Microsoft Teams"),
        meeting("com.cisco.webexmeetingsapp", "Webex"),
        meeting("com.tinyspeck.slackmacgap", "Slack", kind: .chat),
        meeting("net.whatsapp.WhatsApp", "WhatsApp", kind: .chat),
    ]

    /// Apps that should never enter generic capture without an explicit future override.
    /// This includes MaxMi itself and transient system/security surfaces observed as noise.
    public static let excludedOrSensitiveApps: [ApplicationDescriptor] = [
        excluded("dev.mafex.maxmi", "MaxMi"),
        excluded("com.minimi.app", "Minimi"),
        excluded("com.electron.minimi", "Minimi"),
        excluded("com.apple.loginwindow", "Login Window", policy: .sensitive),
        excluded("com.apple.SecurityAgent", "Security Agent", policy: .sensitive),
        excluded("com.apple.UserNotificationCenter", "Notification Center"),
        excluded("com.apple.notificationcenterui", "Notification Center"),
        excluded("com.apple.ScreenSaver.Engine", "Screen Saver"),
        excluded("com.apple.systempreferences", "System Settings", policy: .sensitive),
        excluded("com.apple.keychainaccess", "Keychain Access", policy: .sensitive),
        excluded("com.apple.Passwords", "Passwords", policy: .sensitive),
        excluded("com.agilebits.onepassword7", "1Password", policy: .sensitive),
        excluded("com.1password.1password", "1Password", policy: .sensitive),
        excluded("com.bitwarden.desktop", "Bitwarden", policy: .sensitive),
        excluded("com.lastpass.LastPass", "LastPass", policy: .sensitive),
        excluded("com.dashlane.dashlanephonefinal", "Dashlane", policy: .sensitive),
        excluded("org.keepassxc.keepassxc", "KeePassXC", policy: .sensitive),
    ]

    private static let descriptorsByBundleID: [String: ApplicationDescriptor] = {
        Dictionary(
            uniqueKeysWithValues: (browsers + nativeMeetingApps + excludedOrSensitiveApps)
                .map { ($0.bundleID, $0) }
        )
    }()

    public static func descriptor(for bundleID: String) -> ApplicationDescriptor? {
        descriptorsByBundleID[bundleID]
    }

    public static func browser(for bundleID: String) -> ApplicationDescriptor? {
        guard let descriptor = descriptorsByBundleID[bundleID], descriptor.kind == .browser else {
            return nil
        }
        return descriptor
    }

    public static func isBrowser(_ bundleID: String) -> Bool {
        browser(for: bundleID) != nil
    }

    public static func defaultCapturePolicy(for bundleID: String) -> DefaultCapturePolicy {
        descriptorsByBundleID[bundleID]?.defaultPolicy ?? .allow
    }

    public static func isExcludedByDefault(_ bundleID: String) -> Bool {
        defaultCapturePolicy(for: bundleID) != .allow
    }

    private static func browser(
        _ bundleID: String,
        _ name: String,
        _ engine: BrowserEngine
    ) -> ApplicationDescriptor {
        ApplicationDescriptor(
            bundleID: bundleID,
            displayName: name,
            kind: .browser,
            captureStrategy: .browserAX,
            browserEngine: engine,
            meetingDetection: .browserURLRequired
        )
    }

    private static func meeting(
        _ bundleID: String,
        _ name: String,
        kind: ApplicationKind = .meeting
    ) -> ApplicationDescriptor {
        ApplicationDescriptor(
            bundleID: bundleID,
            displayName: name,
            kind: kind,
            captureStrategy: .nativeParser,
            meetingDetection: .nativeAudio
        )
    }

    private static func excluded(
        _ bundleID: String,
        _ name: String,
        policy: DefaultCapturePolicy = .exclude
    ) -> ApplicationDescriptor {
        ApplicationDescriptor(
            bundleID: bundleID,
            displayName: name,
            kind: policy == .sensitive ? .sensitive : .system,
            captureStrategy: .excluded,
            defaultPolicy: policy
        )
    }
}
