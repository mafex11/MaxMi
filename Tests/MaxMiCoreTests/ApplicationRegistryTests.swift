import XCTest
@testable import MaxMiCore

final class ApplicationRegistryTests: XCTestCase {
    func testAllMinimiBrowsersUseBrowserCapture() {
        let bundleIDs = [
            "com.google.Chrome", "org.mozilla.firefox", "company.thebrowser.Browser",
            "company.thebrowser.dia", "com.apple.Safari", "com.brave.Browser",
            "com.microsoft.edgemac", "ai.perplexity.comet", "io.comet.Comet",
            "com.operasoftware.Opera", "com.vivaldi.Vivaldi", "app.zen-browser.zen",
            "com.kagi.kagimacOS", "com.openai.atlas",
        ]

        for bundleID in bundleIDs {
            let app = ApplicationRegistry.browser(for: bundleID)
            XCTAssertNotNil(app, "missing browser \(bundleID)")
            XCTAssertEqual(app?.captureStrategy, .browserAX)
            XCTAssertEqual(app?.meetingDetection, .browserURLRequired)
        }
    }

    func testBrowserEnginesAreClassifiedForWakeupBehavior() {
        XCTAssertEqual(ApplicationRegistry.browser(for: "com.google.Chrome")?.browserEngine, .chromium)
        XCTAssertEqual(ApplicationRegistry.browser(for: "app.zen-browser.zen")?.browserEngine, .gecko)
        XCTAssertEqual(ApplicationRegistry.browser(for: "com.apple.Safari")?.browserEngine, .webkit)
        XCTAssertEqual(ApplicationRegistry.browser(for: "com.google.Chrome.canary")?.browserEngine, .chromium)
        XCTAssertEqual(ApplicationRegistry.browser(for: "org.mozilla.firefoxdeveloperedition")?.browserEngine, .gecko)
        XCTAssertEqual(ApplicationRegistry.browser(for: "com.apple.SafariTechnologyPreview")?.browserEngine, .webkit)
    }

    func testUnknownBrowserLikeAppsFailSafeInsteadOfUsingGenericCapture() {
        XCTAssertTrue(ApplicationRegistry.isUnsupportedBrowserLike("com.example.ExperimentalBrowser"))
        XCTAssertTrue(ApplicationRegistry.isUnsupportedBrowserLike("org.example.firefox.fork"))
        XCTAssertFalse(ApplicationRegistry.isUnsupportedBrowserLike("com.microsoft.VSCode"))
        XCTAssertFalse(ApplicationRegistry.isUnsupportedBrowserLike("com.google.Chrome"))
    }

    func testSelfAndTransientSystemAppsAreExcludedByDefault() {
        for bundleID in [
            "dev.mafex.maxmi", "com.minimi.app", "com.apple.loginwindow",
            "com.apple.UserNotificationCenter", "com.apple.SecurityAgent",
        ] {
            XCTAssertTrue(ApplicationRegistry.isExcludedByDefault(bundleID), bundleID)
        }
        XCTAssertFalse(ApplicationRegistry.isExcludedByDefault("com.todesktop.230313mzl4w4u92"))
    }

    func testNativeMeetingAppsShareTheRegistry() {
        XCTAssertEqual(
            ApplicationRegistry.descriptor(for: "us.zoom.xos")?.meetingDetection,
            .nativeAudio
        )
        XCTAssertEqual(
            ApplicationRegistry.descriptor(for: "net.whatsapp.WhatsApp")?.meetingDetection,
            .nativeAudio
        )
        XCTAssertEqual(
            ApplicationRegistry.descriptor(for: "com.microsoft.teams")?.meetingDetection,
            .nativeAudio
        )
    }

    func testElectronEditorsUseWarmupAndDocumentCaptureProfile() {
        let cursor = ApplicationRegistry.descriptor(for: "com.todesktop.230313mzl4w4u92")
        XCTAssertEqual(cursor?.kind, .document)
        XCTAssertEqual(cursor?.captureStrategy, .genericAX)
        XCTAssertTrue(ApplicationRegistry.needsAccessibilityWarmup("com.todesktop.230313mzl4w4u92"))
        XCTAssertTrue(ApplicationRegistry.needsAccessibilityWarmup("com.google.Chrome"))
        XCTAssertFalse(ApplicationRegistry.needsAccessibilityWarmup("com.apple.dt.Xcode"))
    }

    func testPhase3AppsHaveStructuredKindsAndNativeRouting() {
        let expected: [(String, ApplicationKind)] = [
            ("com.apple.mail", .email),
            ("com.apple.iCal", .calendar),
            ("com.flexibits.fantastical2.mac", .calendar),
            ("com.apple.reminders", .task),
            ("com.microsoft.Word", .document),
            ("com.apple.iWork.Pages", .document),
            ("com.microsoft.Outlook", .email),
        ]
        for (bundleID, kind) in expected {
            XCTAssertEqual(ApplicationRegistry.descriptor(for: bundleID)?.kind, kind)
            XCTAssertEqual(ApplicationRegistry.descriptor(for: bundleID)?.captureStrategy, .nativeParser)
        }
    }
}
