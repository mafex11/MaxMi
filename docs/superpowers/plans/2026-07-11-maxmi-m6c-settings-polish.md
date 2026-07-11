# MaxMi M6c Implementation Plan — Settings Window + Final Ship Polish

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Checkbox steps.

**Goal:** Ship M6c — a proper SwiftUI **Settings window** (Launch at Login, Check for Updates, per-app activity exclusion, status) matching Minimi's menu-app, plus a **final UX polish pass** so MaxMi is ~99% ship-ready — per the M6 spec §4 (M6c) and the user's ship-readiness goal (clean, animated, smooth).

**Architecture:** A SwiftUI `SettingsView` (always-dark Theme) hosted in a retained `NSWindow` (like ActivityWindow), reached from the menu-bar "Settings…" item. Launch-at-Login via `SMAppService.mainApp` (macOS 13+). Check-for-Updates is a lightweight version-check (MaxMi has no Sparkle; a simple "you're on vX; latest is Y" against a pinned/manual endpoint OR just a stub that opens the repo — honest about scope). Per-app exclusion needs an OBSERVED-APPS query (M6a's activityExcludedApps returns only excluded ids, not names) — add `Store.observedActivityApps() -> [(bundle,label)]` (distinct apps from activity_sessions/visits) merged with excluded ids; excluding an app is ONE transaction: persist exclusion + deleteActivityForApp (already exists) — the ViewModel calls a single `onToggleExcluded` that does both atomically so a crash can't leave exclusion-without-delete. A polish pass tightens animations/spacing/empty-states across ActivityView/ActionItemsView/RightLanePanel/privacy.

**Tech Stack:** Swift 6, SwiftUI, ServiceManagement (SMAppService), MaxMiUI Theme, existing Store settings APIs.

## Global Constraints
- Build/test: `DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" swift test`; zero new warnings; keep baseline green.
- Settings persist via the existing `settings` table (Store). Launch-at-Login via `SMAppService.mainApp.register()/unregister()` + reflect actual status.
- Always-dark branded Theme (reuse MaxMiUI Theme tokens); consistent with Activity/ActionItems windows.
- UI logic (view models / pure helpers) unit-tested; SwiftUI views + AppKit windows compile-checked + live per M4/M6a precedent.
- Honest scoping: "Check for Updates" — MaxMi is unsigned-for-distribution/no Sparkle; implement a truthful minimal version display + a manual check that reports current version (and, if a version endpoint is configured, compares) — do NOT fake an auto-updater. Document the limitation.
- ▲REV2 (Codex): `LaunchAtLoginState` + `UpdateStatus` enums live in **MaxMiCore** so `SettingsViewModel` (MaxMiUI, deps Core only) references them without importing the app target — same DTO-boundary discipline as M6a/M6b. The `SMAppService` impl stays in the app target.
- Commit conventional; NO Co-Authored-By/AI trailers. Branch `m6-settings` off main.

## File Structure
```
Sources/MaxMiCore/LaunchAtLoginState.swift     NEW: LaunchAtLoginState + UpdateStatus enums (so MaxMiUI can reference w/o app-target dep)
Sources/MaxMi/LaunchAtLogin.swift              NEW: SMAppService wrapper (app target; uses the Core enum)
Sources/MaxMi/UpdateChecker.swift              NEW: version string + optional latest-version check (honest)
Sources/MaxMiUI/SettingsView.swift             NEW: SwiftUI settings (always-dark, sections)
Sources/MaxMiUI/SettingsViewModel.swift        NEW: @MainActor @Observable over plain closures/DTOs
Sources/MaxMi/SettingsWindow.swift             NEW: retained NSWindow + NSHostingController
Sources/MaxMi/MenuBarController.swift          MODIFY: add "Settings…" item -> SettingsWindow.show()
Sources/MaxMi/AppWiring.swift                  MODIFY: construct SettingsWindow + wire closures
Sources/MaxMiUI/Theme.swift                    MODIFY (if needed): shared polish tokens
Tests/MaxMiUITests/SettingsViewModelTests.swift NEW
Tests/MaxMiTests? (none — glue)                 LaunchAtLogin/UpdateChecker pure bits tested where possible
```

Task order: 1 LaunchAtLogin + UpdateChecker (pure-ish helpers) → 2 SettingsViewModel + SettingsView + SettingsWindow + menu wiring → 3 polish pass → 4 live verify.

---

### Task 1: LaunchAtLogin + UpdateChecker helpers

**Files:** Create `Sources/MaxMi/LaunchAtLogin.swift`, `Sources/MaxMi/UpdateChecker.swift`; tests where feasible.

**Interfaces:**
```swift
public enum LaunchAtLoginState: Sendable, Equatable { case enabled, notRegistered, requiresApproval, unavailable }
public enum LaunchAtLogin {   // SMAppService.mainApp (macOS 13+)
    public static func status() -> LaunchAtLoginState        // maps the FULL SMAppService.mainApp.status
    public static func setEnabled(_ on: Bool) async throws   // register()/unregister(); async+throwing
    // (register is user-approval-subject + can throw already-registered/denied; caller reloads status)
}
public struct AppVersion: Sendable { public let current: String }   // from Bundle CFBundleShortVersionString
public struct UpdateChecker: Sendable {
    public static func currentVersion() -> String
    // Honest: if a version endpoint is set, fetch + compare; else return .upToDateUnknown.
    public func check() async -> UpdateStatus     // M6c: always .unknownManual
}
public enum UpdateStatus: Sendable, Equatable { case unknownManual }   // M6c: always manual, honest
```
- [ ] **Step 1: LaunchAtLogin** — wrap `SMAppService.mainApp`: `isEnabled` reads `.status == .enabled`; `setEnabled(true)` = `try register()`, `setEnabled(false)` = `try unregister()`. (Only works from a real .app bundle — in tests/CLI it may throw; the caller handles the error and the live check verifies.)
- [ ] **Step 2: UpdateChecker (▲REV — ONE honest behavior).** `currentVersion()` from CFBundleShortVersionString. `check()` ALWAYS returns `.unknown` in M6c (no endpoint, no trust policy, no auto-update). The Settings UI shows: "MaxMi vX · updates are manual" — it NEVER claims 'up to date' (can't verify without a trusted source). No versionEndpoint stub, no repo-opening pretense — just an honest version display + manual-update statement. (Real Developer-ID+notarized update delivery is out of M6c scope — noted in ship-readiness.)
- [ ] **Step 3: Test** the version-compare pure logic (`isNewer(_:than:)` semver-ish compare) if UpdateChecker has one; LaunchAtLogin is live-only (SMAppService needs a bundle) — compile-checked. Build + full suite green.
- [ ] **Step 4: Commit** `feat(settings): LaunchAtLogin (SMAppService) + UpdateChecker (honest version check)`

---

### Task 2: SettingsViewModel + SettingsView + SettingsWindow + menu wiring

**Files:** Create `Sources/MaxMiUI/SettingsViewModel.swift`, `Sources/MaxMiUI/SettingsView.swift`, `Sources/MaxMi/SettingsWindow.swift`; Modify `Sources/MaxMi/MenuBarController.swift`, `Sources/MaxMi/AppWiring.swift`; Create `Tests/MaxMiUITests/SettingsViewModelTests.swift`.

**Interfaces:**
```swift
public struct SettingsExcludedApp: Identifiable, Sendable { public let id: String; public let name: String; public let excluded: Bool }
@MainActor @Observable public final class SettingsViewModel {
    public private(set) var launchAtLoginStatus: LaunchAtLoginState   // authoritative, reloaded after set
    public var activityEnabled: Bool         // didSet -> onSetActivityEnabled (disabled if consent != granted)
    public private(set) var consentGranted: Bool                      // gates activityEnabled meaningfully
    public private(set) var excludedApps: [SettingsExcludedApp]        // observed apps + excluded flag
    public private(set) var version: String
    public private(set) var updateStatus: String   // "You're up to date" / "vX available" / "Up to date (vN)"
    public private(set) var statusLines: [String]   // permission/key/encryption status (from menu-bar state)
    public init(load: @escaping @Sendable () async -> SettingsSnapshot,
                onSetLaunchAtLogin: @escaping @Sendable (Bool) async throws -> Void,  // reloads status after
                onSetActivityEnabled: @escaping @Sendable (Bool) -> Void,
                onToggleExcluded: @escaping @Sendable (String, Bool) async -> Void,
                onCheckUpdates: @escaping @Sendable () async -> String)
    public func refresh() async; public func toggleExcluded(_ id: String) async; public func checkUpdates() async
    public func setLaunchAtLogin(_ on: Bool) async     // calls the throwing closure, reloads status, surfaces error/requiresApproval
}
public struct SettingsSnapshot: Sendable { public let launchAtLoginStatus: LaunchAtLoginState; public let activityEnabled: Bool; public let consentGranted: Bool; public let excludedApps: [SettingsExcludedApp]; public let version: String; public let statusLines: [String] }
```
- [ ] **Step 1: Failing SettingsViewModelTests** — inject a load snapshot (launchAtLogin=false, activityEnabled=true, 2 apps one excluded, version "1.0"); refresh → fields populated; toggleExcluded(id) → calls onToggleExcluded + reloads; checkUpdates → updateStatus set from onCheckUpdates. Pure.
- [ ] **Step 2: Run — FAIL. Step 3: Implement** SettingsViewModel + SettingsView (SwiftUI, always-dark Theme, sections: **General** (Launch at Login toggle), **Activity** (enable synthesis toggle + per-app exclusion list with checkboxes), **About** (version + Check for Updates button + status lines: Accessibility/API key/Encryption). Clean spacing, SF Symbols, smooth.) + SettingsWindow (retained NSWindow+NSHostingController, `show()`). Wire MenuBarController "Settings…" → SettingsWindow.show(); AppWiring builds the view model with Store/LaunchAtLogin/UpdateChecker-backed closures.
- [ ] **Step 4: Run — PASS; build; full suite green. Step 5: Commit** `feat(settings): SwiftUI settings window (launch-at-login, activity, per-app exclusion, about) + menu wiring`

---

### Task 3: Final polish pass (animations, spacing, empty states, consistency)

**Files:** Modify `Sources/MaxMiUI/Theme.swift`, `ActivityView.swift`, `ActionItemsView.swift`, `SettingsView.swift`, `Sources/MaxMi/RightLanePanel.swift` as needed.

- [ ] **Step 1: Audit + tighten with CONCRETE acceptance (▲REV — not a vague brief):** (a) ZERO custom colors/spacing literals outside Theme (grep the SwiftUI files — every color/spacing references a Theme token); (b) 8pt spacing + named corner/animation tokens across ActivityView/ActionItemsView/SettingsView; (c) activity + action rows have hover + pressed states; (d) NO synchronous DB/decrypt/date-format in any SwiftUI `body` (all precomputed in view models — verify); (e) spring animation on list insert/remove + tab switches; (f) empty states = friendly line + dog glyph; (g) RightLane AppKit controls visually checked against the same Theme typography/colors (list the specific RightLanePanel properties changed — no blanket 'no functional change'). Each is a checkable item.
- [ ] **Step 2: Build + full suite green** (views compile-checked; no logic change). If any Theme token change touches a tested view model, keep tests green.
- [ ] **Step 3: Commit** `polish(ui): consistent Theme + spring animations + empty states across all windows (ship pass)`

---

### Task 4: Live verification (controller/human — closes M6c + M6)

- [ ] **Step 1: Rebuild + relaunch.** Menu-bar dog → menu now has Settings…; open it.
- [ ] **Step 2: Settings** — General: toggle Launch at Login on → confirm it registers (appears in System Settings > General > Login Items after relaunch); Activity: toggle synthesis + exclude an app (confirm it stops appearing + rows deleted); About: shows version + Check for Updates (honest result) + accurate status lines.
- [ ] **Step 3: Polish** — visually confirm Activity/ActionItems/Settings/RightLane/privacy are consistent, dark, smooth (animations on list changes + tab switches, no jank), empty states friendly.
- [ ] **Step 4: Declare M6c + M6 complete** when 1-3 hold. MaxMi is ~99% ship-ready.

## Self-Review (at plan-writing time)
**Spec coverage:** M6c per spec §4 (settings window: launch-at-login, per-app disable, check-for-updates, status) → T1+T2; final animation/ship polish → T3; live → T4. Reuses M6a activityExcludedApps/activityEnabled store APIs + MaxMiUI Theme + the retained-window pattern from ActivityWindow. Honest about no-Sparkle (UpdateChecker returns .unknown, documented).
**Placeholders:** none — the one honest limitation (no update server) is explicit, not a placeholder. LaunchAtLogin/SettingsWindow are live-glue (compile-checked), view models tested.
**Type consistency:** SettingsSnapshot/SettingsExcludedApp/UpdateStatus used consistently T1↔T2; SettingsViewModel closures wired in T2; reuses Store.activityExcludedApps/activityEnabled/setActivityExcluded from M6a.
