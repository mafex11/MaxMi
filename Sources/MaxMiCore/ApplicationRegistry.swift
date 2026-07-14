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
    public let needsAccessibilityWarmup: Bool

    public init(
        bundleID: String,
        displayName: String,
        kind: ApplicationKind,
        captureStrategy: CaptureStrategy,
        defaultPolicy: DefaultCapturePolicy = .allow,
        browserEngine: BrowserEngine? = nil,
        meetingDetection: MeetingDetectionPolicy = .none,
        needsAccessibilityWarmup: Bool = false
    ) {
        self.bundleID = bundleID
        self.displayName = displayName
        self.kind = kind
        self.captureStrategy = captureStrategy
        self.defaultPolicy = defaultPolicy
        self.browserEngine = browserEngine
        self.meetingDetection = meetingDetection
        self.needsAccessibilityWarmup = needsAccessibilityWarmup
    }
}

public enum ApplicationRegistry {
    /// Browser inventory verified from installed Minimi 1.0.59. Aliases are separate
    /// descriptors because macOS reports the actual bundle identifier at runtime.
    public static let browsers: [ApplicationDescriptor] = [
        browser("com.google.Chrome", "Chrome", .chromium),
        browser("com.google.Chrome.canary", "Chrome Canary", .chromium),
        browser("org.chromium.Chromium", "Chromium", .chromium),
        browser("org.mozilla.firefox", "Firefox", .gecko),
        browser("org.mozilla.firefoxdeveloperedition", "Firefox Developer Edition", .gecko),
        browser("org.mozilla.nightly", "Firefox Nightly", .gecko),
        browser("company.thebrowser.Browser", "Arc", .chromium),
        browser("company.thebrowser.Browser.beta", "Arc Beta", .chromium),
        browser("company.thebrowser.dia", "Dia", .chromium),
        browser("com.apple.Safari", "Safari", .webkit),
        browser("com.apple.SafariTechnologyPreview", "Safari Technology Preview", .webkit),
        browser("com.brave.Browser", "Brave", .chromium),
        browser("com.brave.Browser.beta", "Brave Beta", .chromium),
        browser("com.brave.Browser.nightly", "Brave Nightly", .chromium),
        browser("com.microsoft.edgemac", "Microsoft Edge", .chromium),
        browser("com.microsoft.edgemac.Beta", "Microsoft Edge Beta", .chromium),
        browser("com.microsoft.edgemac.Dev", "Microsoft Edge Dev", .chromium),
        browser("com.microsoft.edgemac.Canary", "Microsoft Edge Canary", .chromium),
        browser("ai.perplexity.comet", "Comet", .chromium),
        browser("io.comet.Comet", "Comet", .chromium),
        browser("com.operasoftware.Opera", "Opera", .chromium),
        browser("com.operasoftware.OperaGX", "Opera GX", .chromium),
        browser("com.vivaldi.Vivaldi", "Vivaldi", .chromium),
        browser("app.zen-browser.zen", "Zen", .gecko),
        browser("app.zen-browser.twilight", "Zen Twilight", .gecko),
        browser("com.kagi.kagimacOS", "Orion", .webkit),
        browser("com.openai.atlas", "ChatGPT Atlas", .chromium),
    ]

    public static let nativeMeetingApps: [ApplicationDescriptor] = [
        meeting("us.zoom.xos", "Zoom"),
        meeting("com.microsoft.teams2", "Microsoft Teams"),
        meeting("com.microsoft.teams", "Microsoft Teams"),
        meeting("com.cisco.webexmeetingsapp", "Webex"),
        meeting("com.tinyspeck.slackmacgap", "Slack", kind: .chat),
        meeting("net.whatsapp.WhatsApp", "WhatsApp", kind: .chat),
    ]

    public static let highValueApps: [ApplicationDescriptor] = [
        ApplicationDescriptor(
            bundleID: "com.todesktop.230313mzl4w4u92",
            displayName: "Cursor",
            kind: .document,
            captureStrategy: .genericAX,
            needsAccessibilityWarmup: true
        ),
        ApplicationDescriptor(
            bundleID: "com.microsoft.VSCode",
            displayName: "Visual Studio Code",
            kind: .document,
            captureStrategy: .genericAX,
            needsAccessibilityWarmup: true
        ),
        ApplicationDescriptor(
            bundleID: "com.apple.dt.Xcode",
            displayName: "Xcode",
            kind: .document,
            captureStrategy: .genericAX
        ),
        native("com.apple.mail", "Mail", .email),
        native("com.apple.iCal", "Calendar", .calendar),
        native("com.flexibits.fantastical2.mac", "Fantastical", .calendar),
        native("com.apple.reminders", "Reminders", .task),
        native("com.microsoft.to-do-mac", "Microsoft To Do", .task, warmup: true),
        native("com.todoist.mac.Todoist", "Todoist", .task, warmup: true),
        native("com.omnigroup.OmniFocus3", "OmniFocus", .task),
        native("com.omnigroup.OmniFocus4", "OmniFocus", .task),
        native("com.toggl.toggldesktop", "Toggl", .task, warmup: true),
        native("com.microsoft.Word", "Microsoft Word", .document),
        native("com.apple.iWork.Pages", "Pages", .document),
        native("com.microsoft.Outlook", "Outlook", .email, warmup: true),
        native("com.readdle.smartemail-Mac", "Spark", .email),
        native("com.readdle.SparkDesktop", "Spark", .email, warmup: true),
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
            uniqueKeysWithValues: (browsers + nativeMeetingApps + highValueApps + excludedOrSensitiveApps)
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

    /// Unknown browser-looking processes must not fall through to generic AX capture,
    /// where they would bypass URL privacy checks. Add supported variants above after
    /// verifying their engine and Accessibility shape.
    public static func isUnsupportedBrowserLike(_ bundleID: String) -> Bool {
        guard !isBrowser(bundleID) else { return false }
        let id = bundleID.lowercased()
        let browserTokens = [
            "browser", "chrome", "chromium", "firefox", "safari", "brave",
            "edgemac", "opera", "vivaldi", "zen-browser", "orion",
        ]
        return browserTokens.contains { id.contains($0) }
    }

    public static func defaultCapturePolicy(for bundleID: String) -> DefaultCapturePolicy {
        descriptorsByBundleID[bundleID]?.defaultPolicy ?? .allow
    }

    public static func isExcludedByDefault(_ bundleID: String) -> Bool {
        defaultCapturePolicy(for: bundleID) != .allow
    }

    public static func needsAccessibilityWarmup(_ bundleID: String) -> Bool {
        descriptorsByBundleID[bundleID]?.needsAccessibilityWarmup == true
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
            meetingDetection: .browserURLRequired,
            needsAccessibilityWarmup: engine == .chromium
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
            meetingDetection: .nativeAudio,
            needsAccessibilityWarmup: [
                "com.microsoft.teams2", "com.tinyspeck.slackmacgap", "net.whatsapp.WhatsApp",
            ].contains(bundleID)
        )
    }

    private static func native(
        _ bundleID: String,
        _ name: String,
        _ kind: ApplicationKind,
        warmup: Bool = false
    ) -> ApplicationDescriptor {
        ApplicationDescriptor(
            bundleID: bundleID,
            displayName: name,
            kind: kind,
            captureStrategy: .nativeParser,
            needsAccessibilityWarmup: warmup
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
