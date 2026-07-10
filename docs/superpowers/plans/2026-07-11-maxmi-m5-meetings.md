# MaxMi M5 Meetings Implementation Plan — Detection + Right-Lane Recorder + Transcription

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship M5 — auto-detect meetings, show a right-edge recorder popup, capture+mix system/mic audio, transcribe (whisper.cpp default), store as first-class meeting memories, serve via `meeting_memory` MCP — per `docs/superpowers/specs/2026-07-11-maxmi-m5-meetings-design.md` (Codex gpt-5.6-terra: GO).

**Architecture:** New non-UI `MaxMiMeetings` module (CoreAudio detection, ScreenCaptureKit+AVAudioEngine capture, AVAudioConverter mixing, pluggable Transcriber, actor `MeetingSession` state machine). AppKit `NSPanel` right-lane popup in the app target. First-class `meetings` table (v3 migration) + `versions.metadata` link. Real `meeting_memory` MCP over the table. Meetings bypass fingerprint dedup (unique UUIDv7 session id per meeting).

**Tech Stack:** Swift 6, ScreenCaptureKit, AVFoundation/AVAudioEngine/AVAudioConverter, CoreAudio (public process-object API), whisper.cpp (C interop), GRDB, AppKit NSPanel.

## Global Constraints

- Build/test: `DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" swift test`; zero new warnings.
- Detection: **public** CoreAudio `kAudioHardwarePropertyProcessObjectList` + `kAudioProcessPropertyIsRunningInput`/`PID`/`BundleID` + `AudioObjectAddPropertyListenerBlock`. NOT the private responsibility SPI; NOT frontmost-app heuristic.
- Transcription default: **whisper.cpp**, multilingual **`ggml-base`** (~140 MB), downloaded+checksum-verified+atomically-installed to Application Support BEFORE Record arms (no recording-while-downloading; no raw-PCM buffer). Deepgram = opt-in key. SFSpeech = degraded fallback only (needs `NSSpeechRecognitionUsageDescription`).
- Audio: `SCStream` (`capturesAudio=true`, `excludesCurrentProcessAudio=true`) with `SCContentFilter(display:includingApplications:exceptingWindows:)` scoped to the detected `SCRunningApplication`; mic-only fallback when no shareable app OR Screen Recording denied. `AudioMixer` uses `AVAudioConverter` + timestamp alignment; handles device changes; NO raw-PCM retention for retry.
- Popup: `NSPanel` `.nonactivatingPanel`, borderless, `isFloatingPanel=true`, `level=.statusBar`, `collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary]`, `ignoresMouseEvents=false`, docked to the **meeting window's screen** `visibleFrame` (fallback cursor screen), reposition on `didChangeScreenParametersNotification`.
- Lifecycle: **manual Stop authoritative**; app-backgrounding/input-stop → debounced "Finish or keep recording?" prompt, never auto-truncate. Consent-first: never record without a Record click.
- Storage: each meeting = new `meetings` row (UUIDv7 id) + immutable encrypted transcript version linked via `versions.metadata` JSON `{"meetingId":"<uuid>"}`. Fingerprint dedup BYPASSED for meetings. `meetings` columns (app/title/times) cleartext for indexing; transcript content encrypted.
- `MeetingSession` is an `actor`; all CoreAudio/SCStream/transcriber/DB events funnel in; AppKit updates hop to `@MainActor`.
- Permissions requested lazily on first Record: Microphone, Screen Recording; Speech only if SFSpeech selected.
- Commit messages conventional; NO Co-Authored-By / AI attribution trailers.
- Repo `/Users/mafex/code/personal/MaxMi/`, branch `m5-meetings` off main.

## File Structure

```
Package.swift                                  MODIFY: add MaxMiMeetings target + MaxMiMeetingsTests
Sources/MaxMiMeetings/MeetingAppList.swift     NEW: meeting-app bundle-id allowlist + classification
Sources/MaxMiMeetings/MeetingDetector.swift    NEW: public CoreAudio process-object detector
Sources/MaxMiMeetings/Transcriber.swift        NEW: Transcriber protocol + TranscriptChunk
Sources/MaxMiMeetings/WhisperTranscriber.swift NEW: whisper.cpp-backed default engine
Sources/MaxMiMeetings/WhisperModelStore.swift  NEW: download/verify/install ggml-base
Sources/MaxMiMeetings/AudioMixer.swift         NEW: AVAudioConverter normalize + timestamp-align
Sources/MaxMiMeetings/AudioCapture.swift       NEW: SCStream + AVAudioEngine -> AudioMixer -> Transcriber
Sources/MaxMiMeetings/MeetingSession.swift     NEW: actor state machine
Sources/CWhisper/                              NEW: whisper.cpp C target (or SPM dep) — see Task 4
Sources/MaxMiStore/Migrations.swift            MODIFY: v3 (meetings table + versions.metadata)
Sources/MaxMiStore/MeetingStore.swift          NEW: commitMeeting + meeting queries
Sources/MaxMiMCP/MemoryQueries.swift           MODIFY: real meeting_memory over meetings table
Sources/MaxMiMCP/Tools.swift                   MODIFY: meeting_memory description + action routing
Sources/MaxMi/RightLanePanel.swift             NEW: NSPanel right-lane recorder
Sources/MaxMi/AppWiring.swift                  MODIFY: own MeetingSession; wire detector->panel->store
packaging/Info.plist                           MODIFY: mic/screen-capture/speech usage keys
Tests/MaxMiMeetingsTests/*                      NEW: detector, mixer, session, transcriber-protocol
Tests/MaxMiStoreTests/MeetingStoreTests.swift  NEW; MigrationTests.swift MODIFY
Tests/MaxMiMCPTests/MeetingMemoryTests.swift    NEW
```

Task order (dependency-first, each independently testable): **0 shared contracts** → 1 storage → 2 MCP → 3 detector → 4 whisper interop+model → 5 transcriber+mixer → 6 audio capture → 7 session actor → 8 popup UI → 9 wiring → 10 live verify. **Do not start Task 7 until Task 0's concurrency contracts + `CaptureTarget` exist** (Codex review).

---

### Task 0: Shared contracts (Sendable types + concurrency boundary) — do FIRST

**Why:** Codex review flagged Swift 6 isolation traps. Pin the cross-actor types ONCE so Tasks 5-9 compose without Sendable errors.

**Files:** Create `Sources/MaxMiMeetings/MeetingContracts.swift`; add `MaxMiMeetings` target to `Package.swift` (dep `MaxMiCore`) AND add `"MaxMiMeetings"` to the `MaxMi` executable target's dependencies (Codex #7). Create `Tests/MaxMiMeetingsTests/ContractsTests.swift` (trivial value tests).

**Produces (these exact types are used verbatim by later tasks):**
```swift
import Foundation

/// Normalized audio frame crossing actor boundaries — Sendable value type (16kHz mono).
public struct PCMFrame: Sendable {
    public let samples: [Float]           // 16kHz mono
    public let hostTimeNs: UInt64         // source timestamp for alignment
    public init(samples: [Float], hostTimeNs: UInt64) { self.samples = samples; self.hostTimeNs = hostTimeNs }
}

/// What to capture — resolved from SCShareableContent BEFORE recording. Holds the app+display
/// SCContentFilter(display:includingApplications:exceptingWindows:) needs. Non-Sendable SC types
/// stay on the capture side; the session passes only the Sendable `bundleID`/`captureSystem`.
public struct CaptureRequest: Sendable {
    public let bundleID: String           // meeting app to scope audio to
    public let title: String?
    public let captureSystem: Bool        // false => mic-only (denied screen-rec / no shareable app)
    public init(bundleID: String, title: String?, captureSystem: Bool) {
        self.bundleID = bundleID; self.title = title; self.captureSystem = captureSystem
    }
}

/// A single active-input process snapshot (PID + bundle id) — Codex #3: keep both, not just a Set.
public struct AudioInputProcess: Sendable, Equatable { public let pid: pid_t; public let bundleID: String
    public init(pid: pid_t, bundleID: String) { self.pid = pid; self.bundleID = bundleID } }

/// Capture control as an async Sendable protocol (no non-Sendable objects stored in the session actor).
public protocol AudioCaptureControlling: Sendable {
    func start(_ request: CaptureRequest) async throws -> String   // returns captureMode "system+mic"|"mic-only"
    func stop() async
    var onFrame: (@Sendable (PCMFrame) -> Void)? { get set }
    var level: Float { get }
}

/// Transcriber is an ACTOR-isolated async protocol (Codex #5) — receives only normalized PCMFrames.
public protocol Transcribing: Sendable {
    func start() async throws
    func feed(_ frame: PCMFrame) async
    func finish() async -> String
    func setOnPartial(_ cb: @escaping @Sendable (String) -> Void) async
}

/// Session -> UI callbacks are @MainActor; persistence is a Sendable async protocol (Codex #5).
@MainActor public protocol MeetingPanelPresenting: AnyObject {
    func showPrompt(app: String); func showRecording(); func showFinishing(); func hidePanel()
}
public protocol MeetingPersisting: Sendable {
    func persist(app: String, title: String?, transcript: String, startedAtMs: Int64,
                 endedAtMs: Int64, captureMode: String, transcriptionStatus: String) async
}

/// Injected clock so debounce is testable (Codex #3).
public protocol MeetingClock: Sendable { func nowMs() -> Int64; func sleep(ms: Int) async }
```

- [ ] **Step 1: Package.swift** — add:
```swift
        .target(name: "MaxMiMeetings", dependencies: ["MaxMiCore"]),
        .testTarget(name: "MaxMiMeetingsTests", dependencies: ["MaxMiMeetings"]),
```
and add `"MaxMiMeetings"` to the `.executableTarget(name: "MaxMi", dependencies: [...])` list.
- [ ] **Step 2: Write `MeetingContracts.swift`** with the exact types above.
- [ ] **Step 3: Trivial test** — `ContractsTests`: construct a `PCMFrame`, `CaptureRequest`, `AudioInputProcess`; assert field round-trip. Confirms the module compiles + types are Sendable.
- [ ] **Step 4: Run — PASS.** `swift build` + `swift test --filter ContractsTests`.
- [ ] **Step 5: Commit** `feat(meetings): shared Sendable contracts + concurrency boundary (Task 0)`

---

### Task 1: v3 migration + MeetingStore (storage foundation)

**Files:** Modify `Sources/MaxMiStore/Migrations.swift`; Create `Sources/MaxMiStore/MeetingStore.swift`; Create `Tests/MaxMiStoreTests/MeetingStoreTests.swift`; Modify `Tests/MaxMiStoreTests/MigrationTests.swift`.

**Interfaces:**
- Consumes: `Store` (db, cipher), `ContentHash`, `Ident.uuidv7`, `HourBucket` (existing).
- Produces:
```swift
public struct MeetingRecord: Sendable {
    public let id: String            // UUIDv7
    public let threadID: String      // ▲REV2 (Codex #1 — MCP needs these)
    public let versionID: String?
    public let app: String
    public let title: String?
    public let startedAtMs: EpochMs
    public let endedAtMs: EpochMs?
    public let state: String         // "recording"|"completed"|"failed"|"skipped"
    public let captureMode: String   // "system+mic"|"mic-only"
    public let transcriptionStatus: String  // "pending"|"complete"|"partial"
}
public struct MeetingContext: Sendable {   // ▲REV2 — full decrypted context for MCP get_context
    public let record: MeetingRecord
    public let transcript: String          // decrypted
    public let facts: [String]             // decrypted derivative summaries
}
extension Store {
    // Inserts a meetings row + an immutable transcript version (encrypted), linked via
    // versions.metadata JSON {"meetingId":id}. Bypasses fingerprint dedup. Returns meeting id.
    public func commitMeeting(id: String, app: String, title: String?, transcript: String,
                              startedAtMs: EpochMs, endedAtMs: EpochMs, captureMode: String,
                              transcriptionStatus: String, nowMs: EpochMs) throws -> String
    public func recentMeetings(limit: Int) throws -> [MeetingRecord]
    public func meeting(id: String) throws -> MeetingRecord?
    // ▲REV2 (Codex #1): MCP-facing APIs so MemoryQueries never touches db/cipher directly.
    public func meetingContext(id: String) throws -> MeetingContext?    // decrypts transcript + facts
    public func searchMeetings(query: String, limit: Int) throws -> [MeetingRecord]  // vec search filtered to meetings
}
```
The metadata is built with `JSONEncoder`/`JSONSerialization` (not string interpolation — Codex should-fix).

- [ ] **Step 1: Failing migration test** — add to `Tests/MaxMiStoreTests/MigrationTests.swift`:
```swift
    func testV3AddsMeetingsTableAndMetadata() throws {
        let db = try MaxMiDatabase.inMemory()
        try db.dbQueue.read { d in
            XCTAssertEqual(try Int.fetchOne(d, sql: "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='meetings'"), 1)
            let cols = try Row.fetchAll(d, sql: "PRAGMA table_info(versions)").map { $0["name"] as String }
            XCTAssertTrue(cols.contains("metadata"), "versions.metadata column must exist")
        }
    }
```
- [ ] **Step 2: Run — FAIL.** `swift test --filter testV3AddsMeetingsTableAndMetadata`
- [ ] **Step 3: Add v3 migration** — in `Migrations.swift`, after the v2 block, before `return m`:
```swift
        m.registerMigration("v3") { db in
            try db.execute(sql: "ALTER TABLE versions ADD COLUMN metadata TEXT;")
            try db.execute(sql: """
            CREATE TABLE meetings (
              id           TEXT PRIMARY KEY,
              thread_id    TEXT NOT NULL REFERENCES threads(id),
              version_id   TEXT REFERENCES versions(id),
              app          TEXT NOT NULL,
              title        TEXT,
              started_at   INTEGER NOT NULL,
              ended_at     INTEGER,
              state        TEXT NOT NULL,
              capture_mode TEXT NOT NULL,
              transcription_status TEXT NOT NULL DEFAULT 'pending',
              UNIQUE(version_id),
              UNIQUE(thread_id)
            );
            CREATE INDEX idx_meetings_started ON meetings(started_at DESC);
            """)
        }
```
(▲REV2 — `UNIQUE(version_id)`/`UNIQUE(thread_id)`: each meeting has exactly one transcript version/thread — Codex should-fix.)
- [ ] **Step 4: Run — migration test PASS.**
- [ ] **Step 5: Failing MeetingStore tests** — `Tests/MaxMiStoreTests/MeetingStoreTests.swift`:
```swift
import XCTest
import GRDB
@testable import MaxMiStore
import MaxMiCore

final class MeetingStoreTests: XCTestCase {
    var store: Store!; var db: MaxMiDatabase!
    override func setUpWithError() throws {
        db = try MaxMiDatabase.inMemory(); store = Store(db: db, cipher: AESGCMFieldCipher.testCipher)
    }
    let t0 = EpochMs(495_600) * 3_600_000
    func testCommitMeetingCreatesRowAndEncryptedVersion() throws {
        let id = try store.commitMeeting(id: "m-1", app: "Zoom", title: "Standup", transcript: "hello team let's begin",
            startedAtMs: t0, endedAtMs: t0 + 600_000, captureMode: "system+mic", transcriptionStatus: "complete", nowMs: t0 + 600_000)
        XCTAssertEqual(id, "m-1")
        try db.dbQueue.read { d in
            let m = try Row.fetchOne(d, sql: "SELECT * FROM meetings WHERE id=?", arguments: ["m-1"])!
            XCTAssertEqual(m["app"] as String, "Zoom")
            XCTAssertEqual(m["state"] as String, "completed")
            // transcript stored encrypted in the linked version
            let vid = m["version_id"] as String
            let content = try String.fetchOne(d, sql: "SELECT content FROM versions WHERE id=?", arguments: [vid])!
            XCTAssertTrue(content.hasPrefix("enc:v1:"), "transcript must be encrypted at rest")
            // metadata links version -> meeting
            let meta = try String.fetchOne(d, sql: "SELECT metadata FROM versions WHERE id=?", arguments: [vid])!
            XCTAssertTrue(meta.contains("m-1"))
        }
    }
    func testTwoSameTitleMeetingsStayDistinct() throws {
        _ = try store.commitMeeting(id: "m-a", app: "Zoom", title: "Standup", transcript: "one",
            startedAtMs: t0, endedAtMs: t0+1000, captureMode: "mic-only", transcriptionStatus: "complete", nowMs: t0+1000)
        _ = try store.commitMeeting(id: "m-b", app: "Zoom", title: "Standup", transcript: "two",
            startedAtMs: t0+2000, endedAtMs: t0+3000, captureMode: "mic-only", transcriptionStatus: "complete", nowMs: t0+3000)
        XCTAssertEqual(try store.recentMeetings(limit: 10).count, 2, "same-title meetings must NOT merge")
    }
    func testRecentMeetingsNewestFirst() throws {
        _ = try store.commitMeeting(id: "old", app: "Teams", title: "A", transcript: "x", startedAtMs: t0, endedAtMs: t0+1, captureMode: "mic-only", transcriptionStatus: "complete", nowMs: t0+1)
        _ = try store.commitMeeting(id: "new", app: "Teams", title: "B", transcript: "y", startedAtMs: t0+10_000, endedAtMs: t0+11_000, captureMode: "mic-only", transcriptionStatus: "complete", nowMs: t0+11_000)
        XCTAssertEqual(try store.recentMeetings(limit: 10).first?.id, "new")
    }
}
```
- [ ] **Step 6: Run — FAIL** (commitMeeting undefined).
- [ ] **Step 7: Implement MeetingStore.swift:**
```swift
import Foundation
import GRDB
import MaxMiCore

public struct MeetingRecord: Sendable {
    public let id: String; public let app: String; public let title: String?
    public let startedAtMs: EpochMs; public let endedAtMs: EpochMs?
    public let state: String; public let captureMode: String; public let transcriptionStatus: String
}

extension Store {
    public func commitMeeting(id: String, app: String, title: String?, transcript: String,
                              startedAtMs: EpochMs, endedAtMs: EpochMs, captureMode: String,
                              transcriptionStatus: String, nowMs: EpochMs) throws -> String {
        let threadKey = "meeting:\(id)"           // identity = immutable session id (no dedup/merge)
        let hash = ContentHash.sha256Hex(transcript)
        let bucket = HourBucket.bucket(forMs: startedAtMs)
        let words = transcript.split(whereSeparator: \.isWhitespace).count
        let storedContent = try cipher.encrypt(transcript)
        let meta = String(decoding: try JSONSerialization.data(withJSONObject: ["meetingId": id]), as: UTF8.self)
        return try db.dbQueue.write { d in
            let threadID = Ident.uuidv7(nowMs: nowMs)
            try d.execute(sql: """
                INSERT INTO threads (id, source_app, source_key, source_title, last_tree_hash, created_at, updated_at)
                VALUES (?,?,?,?,?,?,?)
                """, arguments: [threadID, "Meeting", threadKey, title, hash, startedAtMs, endedAtMs])
            let vid = Ident.uuidv7(nowMs: nowMs)
            try d.execute(sql: """
                INSERT INTO versions (id, thread_id, hour_bucket, content, content_hash, word_count, is_frozen, committed_at, extract_status, metadata)
                VALUES (?,?,?,?,?,?,1,?, 'pending', ?)
                """, arguments: [vid, threadID, bucket, storedContent, hash, words, nowMs, meta])
            try d.execute(sql: """
                INSERT INTO meetings (id, thread_id, version_id, app, title, started_at, ended_at, state, capture_mode, transcription_status)
                VALUES (?,?,?,?,?,?,?,?,?,?)
                """, arguments: [id, threadID, vid, app, title, startedAtMs, endedAtMs,
                                 transcriptionStatus == "partial" ? "failed" : "completed", captureMode, transcriptionStatus])
            return id
        }
    }
    public func recentMeetings(limit: Int) throws -> [MeetingRecord] {
        try db.dbQueue.read { d in
            try Row.fetchAll(d, sql: "SELECT * FROM meetings ORDER BY started_at DESC LIMIT ?", arguments: [limit]).map(Self.rec)
        }
    }
    public func meeting(id: String) throws -> MeetingRecord? {
        try db.dbQueue.read { d in try Row.fetchOne(d, sql: "SELECT * FROM meetings WHERE id=?", arguments: [id]).map(Self.rec) }
    }
    public func meetingContext(id: String) throws -> MeetingContext? {
        try db.dbQueue.read { d in
            guard let r = try Row.fetchOne(d, sql: "SELECT * FROM meetings WHERE id=?", arguments: [id]) else { return nil }
            let rec = Self.rec(r)
            var transcript = ""
            if let vid = rec.versionID, let enc = try String.fetchOne(d, sql: "SELECT content FROM versions WHERE id=?", arguments: [vid]) {
                transcript = (try? cipher.decrypt(enc)) ?? ""
            }
            let facts = try String.fetchAll(d, sql: "SELECT content FROM derivatives WHERE thread_id=?", arguments: [rec.threadID])
                .compactMap { try? cipher.decrypt($0) }
            return MeetingContext(record: rec, transcript: transcript, facts: facts)
        }
    }
    public func searchMeetings(query: String, limit: Int) throws -> [MeetingRecord] {
        // Reuse the existing semantic search, then keep only hits whose thread is a meeting.
        // (Implementer: call the existing vec-search entrypoint; filter thread_id IN (SELECT thread_id FROM meetings).)
        let meetingThreadIDs = Set(try recentMeetings(limit: 500).map { $0.threadID })
        return try semanticSearchThreadIDs(query: query, limit: limit)   // existing helper
            .filter { meetingThreadIDs.contains($0) }
            .prefix(limit).compactMap { tid in try meetingByThread(tid) }
    }
    private func meetingByThread(_ threadID: String) throws -> MeetingRecord? {
        try db.dbQueue.read { d in try Row.fetchOne(d, sql: "SELECT * FROM meetings WHERE thread_id=?", arguments: [threadID]).map(Self.rec) }
    }
    private static func rec(_ r: Row) -> MeetingRecord {
        MeetingRecord(id: r["id"], threadID: r["thread_id"], versionID: r["version_id"], app: r["app"],
                      title: r["title"], startedAtMs: r["started_at"], endedAtMs: r["ended_at"],
                      state: r["state"], captureMode: r["capture_mode"], transcriptionStatus: r["transcription_status"])
    }
}
```
(Implementer note: `semanticSearchThreadIDs` — reuse the existing vec-search path used by `search_memory`; if its current signature returns richer hits, adapt this filter to it. `cipher.decrypt` is the existing field-cipher decrypt.)
- [ ] **Step 8: Run — PASS** (3 MeetingStore + migration). Full suite green.
- [ ] **Step 9: Commit** `feat(store): v3 meetings table + MeetingStore.commitMeeting (unique session, encrypted transcript)`

---

### Task 2: Real meeting_memory MCP tool

**Files:** Modify `Sources/MaxMiMCP/MemoryQueries.swift`, `Sources/MaxMiMCP/Tools.swift`; Create `Tests/MaxMiMCPTests/MeetingMemoryTests.swift`.

**Interfaces (▲REV2 — Codex #1):**
- Consumes ONLY the new Store APIs from Task 1: `recentMeetings`, `meetingContext(id:)`, `searchMeetings(query:limit:)`. `MemoryQueries` does NOT touch `Store.db`/`cipher` directly.
- `MemoryQueries` real init is `init(store:relay:)` (NOT `cipher:`) — match the actual type. `meetingMemory` becomes **`async`** (semantic search is async); `Tools.call` must `await` it and forward the `query` arg.
- Produces: `func meetingMemory(action: String, query: String?) async -> ToolResult` for `list` / `search <q>` / `get_context <id>`.

- [ ] **Step 1: Failing test** — `Tests/MaxMiMCPTests/MeetingMemoryTests.swift` (read the REAL `MemoryQueries.init` + `ToolResult` shape first and match them; `relay:` param, `async` calls):
```swift
import XCTest
@testable import MaxMiMCP
@testable import MaxMiStore
import MaxMiCore

final class MeetingMemoryTests: XCTestCase {
    func makeQueries() throws -> MemoryQueries {
        let db = try MaxMiDatabase.inMemory()
        let store = Store(db: db, cipher: AESGCMFieldCipher.testCipher)
        let t0 = EpochMs(495_700) * 3_600_000
        _ = try store.commitMeeting(id: "mm-1", app: "Zoom", title: "Roadmap sync", transcript: "we decided to ship M5 next",
            startedAtMs: t0, endedAtMs: t0+600_000, captureMode: "system+mic", transcriptionStatus: "complete", nowMs: t0+600_000)
        return MemoryQueries(store: store, relay: /* the real relay/no-op used by other MCP tests */ .init())
    }
    func testListReturnsMeetings() async throws {
        let r = await makeQueries().meetingMemory(action: "list", query: nil)
        XCTAssertFalse(r.isError); XCTAssertTrue(r.text.contains("Roadmap sync")); XCTAssertTrue(r.text.contains("Zoom"))
    }
    func testGetContextReturnsTranscript() async throws {
        let r = await makeQueries().meetingMemory(action: "get_context", query: "mm-1")
        XCTAssertTrue(r.text.contains("ship M5 next"), "decrypted transcript in context")
    }
    func testUnknownActionErrors() async throws {
        XCTAssertTrue(await makeQueries().meetingMemory(action: "bogus", query: nil).isError)
    }
}
```
(Adapt `MemoryQueries.init`/`ToolResult` to the real signatures — inspect existing `search_memory` tests for the exact relay arg the test harness uses.)
- [ ] **Step 2: Run — FAIL.**
- [ ] **Step 3: Implement** — replace the `meetingMemory` stub in `MemoryQueries.swift` (make it `async`): `list` → `store.recentMeetings(limit:20)` → markdown; `get_context <id>` → `store.meetingContext(id:)` (already decrypted transcript+facts) → markdown; `search <q>` → `store.searchMeetings(query:limit:20)` → markdown. Update `Tools.swift`: `meeting_memory` description "Query captured meeting transcripts and summaries (list | search | get_context).", route the `query` arg, and `await` the now-async call.
- [ ] **Step 4: Run — PASS.** Full suite green.
- [ ] **Step 5: Commit** `feat(mcp): real meeting_memory over meetings table (list/search/get_context)`

---

### Task 3: MeetingDetector (public CoreAudio process-object detection)

**Files:** Create `Sources/MaxMiMeetings/MeetingAppList.swift`, `Sources/MaxMiMeetings/MeetingDetector.swift`; add `MaxMiMeetings` target to `Package.swift`; Create `Tests/MaxMiMeetingsTests/MeetingDetectorTests.swift`.

**Interfaces:**
- Produces:
```swift
public struct MeetingAppList {
    public static let bundleIDs: Set<String>  // us.zoom.xos, com.microsoft.teams2, com.cisco.webexmeetingsapp, browsers...
    public static func classify(bundleID: String) -> MeetingAppKind?  // .native(app) | .browser
}
public enum MeetingAppKind: Equatable { case native(String); case browser(String) }

public protocol MeetingDetecting: AnyObject {
    var onCandidate: ((_ bundleID: String, _ pid: pid_t) -> Void)? { get set }  // meeting app started input
    var onEnded: ((_ bundleID: String) -> Void)? { get set }
    func start(); func stop()
}
// ▲REV2 (Codex #3): evaluate takes PID+bundleID SNAPSHOTS (not a Set — a Set loses multi-process
// state and can fire a false 'end' when one helper stops while another meeting proc is still active).
// Clock injected so debounce is testable.
public final class MeetingDetector: MeetingDetecting {
    public init(clock: MeetingClock = SystemMeetingClock(), debounceMs: Int = 1500)
    // pure/testable seam:
    public func evaluate(active: [AudioInputProcess])
}
```
- CoreAudio wiring is live-only, but it must (Codex #3): listen to `kAudioHardwarePropertyProcessObjectList` AND, on each list change, add/remove a listener on **each process object's** `kAudioProcessPropertyIsRunningInput` (list-membership alone doesn't signal input start/stop). Each callback rebuilds the `[AudioInputProcess]` snapshot and calls `evaluate`. The **allowlist + classification + debounce** are unit-tested via `evaluate(active:)`.

- [ ] **Step 1: Add Package.swift target** — after the MaxMiCapture target:
```swift
        .target(name: "MaxMiMeetings", dependencies: ["MaxMiCore"]),
```
and a test target:
```swift
        .testTarget(name: "MaxMiMeetingsTests", dependencies: ["MaxMiMeetings"]),
```
- [ ] **Step 2: Failing tests** — `Tests/MaxMiMeetingsTests/MeetingDetectorTests.swift`:
```swift
import XCTest
@testable import MaxMiMeetings

final class MeetingDetectorTests: XCTestCase {
    func testClassifiesKnownApps() {
        XCTAssertEqual(MeetingAppList.classify(bundleID: "us.zoom.xos"), .native("Zoom"))
        XCTAssertEqual(MeetingAppList.classify(bundleID: "com.microsoft.teams2"), .native("Microsoft Teams"))
        XCTAssertEqual(MeetingAppList.classify(bundleID: "com.google.Chrome"), .browser("Chrome"))
        XCTAssertNil(MeetingAppList.classify(bundleID: "com.apple.Terminal"))
    }
    func testEvaluateFiresCandidateOnMeetingAppInput() {
        let d = MeetingDetector()
        var fired: String?
        d.onCandidate = { bid, _ in fired = bid }
        d.evaluate(active: [AudioInputProcess(pid: 123, bundleID: "us.zoom.xos")])
        XCTAssertEqual(fired, "us.zoom.xos")
    }
    func testEvaluateIgnoresNonMeetingInput() {
        let d = MeetingDetector(); var fired = false
        d.onCandidate = { _, _ in fired = true }
        d.evaluate(active: [AudioInputProcess(pid: 1, bundleID: "com.apple.VoiceMemos")])
        XCTAssertFalse(fired, "voice memo mic use is not a meeting")
    }
    func testEndFiresOnlyWhenAllMeetingProcsStop() {
        let d = MeetingDetector(); var ended: String?
        d.onEnded = { ended = $0 }
        // two zoom helper procs active; one stops -> NOT ended (Codex #3: multi-process state)
        d.evaluate(active: [AudioInputProcess(pid: 1, bundleID: "us.zoom.xos"),
                            AudioInputProcess(pid: 2, bundleID: "us.zoom.xos")])
        d.evaluate(active: [AudioInputProcess(pid: 2, bundleID: "us.zoom.xos")])
        XCTAssertNil(ended, "one of two zoom procs stopping is not meeting end")
        d.evaluate(active: [])
        XCTAssertEqual(ended, "us.zoom.xos", "all meeting procs stopped -> ended")
    }
}
```
- [ ] **Step 3: Run — FAIL.**
- [ ] **Step 4: Implement** `MeetingAppList.swift` (allowlist + `classify`), a `SystemMeetingClock` (real `MeetingClock`), and `MeetingDetector.swift`: the CoreAudio live path (`start()` listens on `kAudioHardwarePropertyProcessObjectList` AND per-process `kAudioProcessPropertyIsRunningInput`, rebuilding per-process listeners on list change; reads `kAudioProcessPropertyPID`+`BundleID`; builds `[AudioInputProcess]`; calls `evaluate`), and the **pure testable** `evaluate(active:)` that filters by the allowlist, tracks the set of active meeting-proc bundleIDs, fires `onCandidate` on first meeting-proc appearance and `onEnded` only when the LAST proc for a bundleID disappears, with clock-based debounce. On non-macOS/CoreAudio error, `start()` logs + no-ops.
- [ ] **Step 5: Run — PASS.** Full suite green.
- [ ] **Step 6: Commit** `feat(meetings): MeetingDetector via public CoreAudio process-object API + app allowlist`

---

### Task 4: whisper.cpp interop + WhisperModelStore

**Files:** Create `Sources/CWhisper/` (C target wrapping whisper.cpp) OR add an SPM dependency; Create `Sources/MaxMiMeetings/WhisperModelStore.swift`; Modify `Package.swift`; Create `Tests/MaxMiMeetingsTests/WhisperModelStoreTests.swift`.

**Interfaces:**
- Produces:
```swift
public struct WhisperModelStore {
    public init(dir: URL)                                  // Application Support/MaxMi/models
    public var isReady: Bool { get }                       // model present + checksum ok
    public func ensureModel(download: (URL) async throws -> URL) async throws  // atomic install
    public var modelURL: URL { get }
    public static let modelName = "ggml-base.bin"   // multilingual base
    // ▲REV2: exact pinned artifact. ggml-base (multilingual) from the official HF mirror.
    public static let modelURL = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin")!
    public static let sha256 = "60ed5bc3dd14eea856493d334349b405782 ... "  // IMPLEMENTER: curl the file, sha256sum it, paste the full 64-hex digest. Do NOT ship a partial.
}
```
- Model download itself is live (network); tests cover **isReady** (file present + checksum), **atomic install** (temp→rename), and **checksum rejection** using a fixture file — NOT a real download.

- [ ] **Step 1: Package.swift — add whisper (▲REV2, pinned — Codex #4).** Vendor whisper.cpp as a C/C++ target `CWhisper` (NOT a `systemLibrary` — nothing is preinstalled): pin **whisper.cpp tag `v1.7.2`** (fetch `ggml.c`, `whisper.cpp`, headers into `Sources/CWhisper/`), expose a tiny C shim header `cwhisper_shim.h` with just: `whisper_context* cw_init(const char* modelPath); void cw_feed(whisper_context*, const float* pcm, int n); const char* cw_result(whisper_context*); void cw_free(whisper_context*);`. Add `.target(name: "CWhisper")` and make `MaxMiMeetings` depend on it. Document the exact whisper.cpp commit hash in the commit message. If the C++ build fights the toolchain, fall back to the maintained SPM package `ggerganov/whisper.spm` pinned to a specific tag — but pin SOMETHING; no "pick at build time".
- [ ] **Step 2: Failing tests** — `WhisperModelStoreTests`: write a fake model file + its real sha256 → `isReady == true`; wrong checksum → `isReady == false`; `ensureModel` with a stub download that returns a temp file → installs atomically and becomes ready. (All local, no network.)
- [ ] **Step 3: Run — FAIL.**
- [ ] **Step 4: Implement WhisperModelStore** — `isReady` = file exists at `modelURL` AND its sha256 matches; `ensureModel` = if ready return; else call the injected `download` closure to fetch to a temp URL, verify checksum, `FileManager.moveItem` (atomic) into place, else throw; disk-space precheck.
- [ ] **Step 5: Run — PASS.** Build the CWhisper target (compile-only check).
- [ ] **Step 6: Commit** `feat(meetings): whisper.cpp interop + WhisperModelStore (verified atomic model install)`

---

### Task 5: Transcriber protocol + WhisperTranscriber + rolling SFSpeech fallback

**Files:** Create `Sources/MaxMiMeetings/Transcriber.swift`, `Sources/MaxMiMeetings/WhisperTranscriber.swift`; Create `Tests/MaxMiMeetingsTests/TranscriberTests.swift`.

**Interfaces (▲REV2 — conforms to Task 0 `Transcribing`; transcriber does NOT resample, receives normalized `PCMFrame`):**
```swift
// WhisperTranscriber is an ACTOR (Codex #5 — isolates the whisper context + onPartial callback).
public actor WhisperTranscriber: Transcribing {
    public init(modelURL: URL)
    // Transcribing: start(), feed(PCMFrame) async, finish() async -> String, setOnPartial(...) async
}
// Pure, testable overlap-stitch for the SFSpeech degraded fallback:
public enum RollingStitch { public static func stitch(_ windows: [String]) -> String }
```
Deepgram + SFSpeech engines are **deferred behind the `Transcribing` protocol** for v1 (Codex should-fix): only `WhisperTranscriber` + `RollingStitch` (the fallback's core logic) are built now; `DeepgramTranscriber`/`SFSpeechTranscriber` are follow-ups. State this in the commit.
- [ ] **Step 1: Failing tests** — a `MockTranscriber` (actor) conforms to `Transcribing`; test the contract (feed accumulates, finish returns joined text, setOnPartial fires) with `await`. `RollingStitch.stitch` tested as a pure function (overlap dedupe) with fixed inputs. For `WhisperTranscriber`, a test that transcribes a tiny bundled WAV → non-empty text IF the model fixture exists, else `throw XCTSkip`; ALSO a **mock C-shim seam** test so window-feed behavior is exercised without the real model (Codex should-fix).
- [ ] **Step 2: Run — FAIL.**
- [ ] **Step 3: Implement** `WhisperTranscriber` actor (feed `PCMFrame.samples` — already 16kHz mono from the mixer, NO resampling here — into a persistent whisper context in windows; partial results via the stored `onPartial`; `finish` returns full text) + `RollingStitch.stitch`. Transcriber assumes normalized input (mixer owns all resampling — Codex should-fix).
- [ ] **Step 4: Run — PASS.**
- [ ] **Step 5: Commit** `feat(meetings): Transcriber protocol + WhisperTranscriber + overlap-stitch fallback`

---

### Task 6: AudioMixer + AudioCapture (SCStream + mic)

**Files:** Create `Sources/MaxMiMeetings/AudioMixer.swift`, `Sources/MaxMiMeetings/AudioCapture.swift`; Create `Tests/MaxMiMeetingsTests/AudioMixerTests.swift`.

**Interfaces (▲REV2 — mixer owns ALL resampling + a serial queue; capture takes `CaptureRequest`, resolves `SCDisplay` itself, conforms to Task 0 `AudioCaptureControlling`):**
```swift
public final class AudioMixer {                    // serial-queue guarded (SC + mic callbacks are concurrent)
    public init(targetSampleRate: Double = 16_000)
    public func mixSystem(_ buf: AVAudioPCMBuffer, at: AVAudioTime)
    public func mixMic(_ buf: AVAudioPCMBuffer, at: AVAudioTime)
    public var onFrame: (@Sendable (PCMFrame) -> Void)?   // emits normalized 16k mono PCMFrame
    public var level: Float { get }
}
public final class AudioCapture: NSObject, AudioCaptureControlling, @unchecked Sendable {
    public init(mixer: AudioMixer)
    // Resolves SCShareableContent -> the CaptureRequest.bundleID's SCRunningApplication + its SCDisplay,
    // builds SCContentFilter(display:includingApplications:exceptingWindows:). Codex #2: needs display too.
    public func start(_ request: CaptureRequest) async throws -> String   // returns captureMode
    public func stop() async
    public var onFrame: (@Sendable (PCMFrame) -> Void)? { get set }        // forwards mixer.onFrame
    public var level: Float { get }
}
```

- [ ] **Step 1: Failing AudioMixer tests** — construct two `AVAudioPCMBuffer`s (48kHz stereo, 44.1kHz mono), feed both, assert `onFrame` emits `PCMFrame` at 16kHz mono and `level` reflects amplitude. Offline buffers, no devices. (Mixer isn't strictly "pure" — it uses `AVAudioConverter` — but offline-buffer tests are valid.)
- [ ] **Step 2: Run — FAIL.**
- [ ] **Step 3: Implement AudioMixer** — `AVAudioConverter` per source → 16kHz mono; **serial `DispatchQueue`** guarding converter/mix state (SC delivery queue + mic tap fire concurrently — Codex should-fix); timestamp-align via `hostTimeNs`; emit `PCMFrame`; RMS `level`. **Implement AudioCapture** — resolve `SCShareableContent.current` → find the `SCRunningApplication` whose bundleID matches + its `SCDisplay`; `SCContentFilter(display:includingApplications:[app],exceptingWindows:[])`, `capturesAudio=true`, `excludesCurrentProcessAudio=true`; `AVAudioEngine` input tap for mic; both feed the mixer; return `"system+mic"`; on no shareable app / `captureSystem=false` / SCStream failure → mic-only, return `"mic-only"`. Handle `AVAudioEngineConfigurationChange`.
- [ ] **Step 4: Run — PASS** (mixer tests; AudioCapture live-only, compile-checked). Full suite green.
- [ ] **Step 5: Commit** `feat(meetings): AudioMixer (converter+align) + AudioCapture (SCStream app-scoped + mic)`

---

### Task 7: MeetingSession actor (state machine)

**Files:** Create `Sources/MaxMiMeetings/MeetingSession.swift`; Create `Tests/MaxMiMeetingsTests/MeetingSessionTests.swift`.

**Interfaces (▲REV2 — uses Task 0 contracts; UI is `@MainActor`, persistence + capture + transcriber are Sendable; clock injected — Codex #5):**
```swift
public enum MeetingState: Equatable, Sendable { case idle, prompting, recording, finishing, failed, skipped }
public actor MeetingSession {
    public init(panel: any MeetingPanelPresenting,          // @MainActor protocol (Task 0)
                persister: any MeetingPersisting,            // Sendable async (Task 0)
                makeCapture: @Sendable @escaping () -> any AudioCaptureControlling,
                makeTranscriber: @Sendable @escaping () -> any Transcribing,
                clock: any MeetingClock)
    public func candidateDetected(bundleID: String, title: String?, captureSystem: Bool)  // -> prompting
    public func userAcceptedRecord() async                   // -> recording (capture.start(CaptureRequest))
    public func userSkipped() async                          // -> skipped, hide
    public func userStopped() async                          // -> finishing -> transcriber.finish -> persist
    public func inputStopped() async                         // -> debounced end SUGGESTION (NOT auto-stop)
    public var state: MeetingState { get }
}
```
All capture/transcriber objects are created inside the actor via the `@Sendable` factories and never escape; panel calls hop to `@MainActor`; `PCMFrame` (Sendable) is the only audio type crossing in. No non-Sendable object is stored across the boundary.

- [ ] **Step 1: Failing tests** — with a mock `MeetingPanelPresenting` (@MainActor), mock `MeetingPersisting`, mock `AudioCaptureControlling`, mock `Transcribing` (all actors/Sendable), and a fake `MeetingClock`, drive: detect→prompt (state prompting, showPrompt called); accept→recording (capture.start called with the right `CaptureRequest`, showRecording); stop→finishing→persist (transcript from transcriber.finish, persist called with it); skip path (no persist); **inputStopped does NOT persist/stop** (stays recording pending user confirm — assert state still `.recording`); error path (capture.start throws → failed, hidePanel, no persist). Use `await` throughout (actor).
- [ ] **Step 2: Run — FAIL.**
- [ ] **Step 3: Implement** the actor state machine per the transitions; `userStopped` awaits `transcriber.finish()` then `delegate.persist(...)`; `inputStopped` triggers a debounced end-suggestion (delegate can re-prompt) but never auto-finalizes.
- [ ] **Step 4: Run — PASS.**
- [ ] **Step 5: Commit** `feat(meetings): MeetingSession actor state machine (consent-first, manual-stop authoritative)`

---

### Task 8: RightLanePanel (NSPanel recorder UI)

**Files:** Create `Sources/MaxMi/RightLanePanel.swift`; Create `Tests/MaxMiTests/` is absent (app target untested per M4) → add a tiny pure helper test for placement math in an existing testable spot OR keep placement math in a `static func` in RightLanePanel and test via a new `Tests/MaxMiMeetingsTests` helper if the function is moved to the module.

**Interfaces:**
```swift
// Placement math is pure + testable; the NSPanel itself is AppKit glue (manual QA).
public enum RightLanePlacement {
    // Given a screen visibleFrame + panel size, return the docked right-edge origin.
    public static func origin(inScreen visibleFrame: CGRect, panelSize: CGSize, topInset: CGFloat = 80) -> CGPoint
    // Choose the screen: the one containing the meeting window frame, else the one with the cursor.
    public static func chooseScreen(meetingWindow: CGRect?, screens: [CGRect], cursor: CGPoint) -> CGRect
}
@MainActor final class RightLanePanel { /* NSPanel; states: nudge / recording / finishing */ }
```

- [ ] **Step 1: Failing placement tests** — put `RightLanePlacement` in `MaxMiMeetings` (testable module) and test: origin docks to the right edge (x = frame.maxX - panelWidth - margin) at the top inset; `chooseScreen` picks the screen containing the meeting window, falls back to the cursor's screen when meetingWindow is nil or off-screen. (Covers the "not NSScreen.main" fix.)
- [ ] **Step 2: Run — FAIL.**
- [ ] **Step 3: Implement** `RightLanePlacement` (pure), then `RightLanePanel` in the app target: `NSPanel(.nonactivatingPanel, borderless)`, `isFloatingPanel=true`, `level=.statusBar`, `collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary]`, `ignoresMouseEvents=false`; three state views (nudge with Record/Don't-record, recording with ●+timer+level bar+Stop, finishing spinner); positions via `RightLanePlacement.chooseScreen`/`origin`; observes `didChangeScreenParametersNotification`; auto-dismiss timer for the nudge.
- [ ] **Step 4: Run — PASS** (placement tests). Build the app target (panel compiles).
- [ ] **Step 5: Commit** `feat(ui): RightLanePanel meeting recorder popup + tested placement math`

---

### Task 9: Wire it all in AppWiring + Info.plist

**Files:** Modify `Sources/MaxMi/AppWiring.swift`, `packaging/Info.plist`.

**Interfaces:** Consumes everything above. Produces no new public API; AppWiring owns a `MeetingDetector`, a `MeetingSession` (whose delegate bridges to `RightLanePanel` + `Store.commitMeeting`), and the `WhisperModelStore`.

- [ ] **Step 1: Info.plist** — add `NSMicrophoneUsageDescription`, `NSScreenCaptureUsageDescription`, `NSSpeechRecognitionUsageDescription` with honest strings (e.g. "MaxMi records and transcribes meetings you choose to capture.").
- [ ] **Step 2: Permission seam (▲REV2 — Codex #6).** Add a `MeetingPermissions` helper (in the app target): `requestMicrophone() async -> Bool` (`AVCaptureDevice.requestAccess(for: .audio)`), `screenRecordingAuthorized() -> Bool` (`CGPreflightScreenCaptureAccess()`) + `requestScreenRecording()` (`CGRequestScreenCaptureAccess()`). Called from `MeetingSession.userAcceptedRecord` BEFORE `AudioCapture.start`: mic denied → abort with panel error; screen-recording not authorized → set `captureSystem=false` (mic-only) rather than block. Info.plist keys alone are NOT the permission handling.
- [ ] **Step 3: Wire AppWiring** — on start (after capture wiring), if meeting features enabled: create `WhisperModelStore`, `MeetingDetector`, and a `MeetingSession` wired to (a) a `RightLanePanel` adapter conforming to `@MainActor MeetingPanelPresenting`, (b) a `MeetingPersisting` adapter → `store.commitMeeting(...)`, (c) `@Sendable` factories for `AudioCapture`/`WhisperTranscriber`, (d) `SystemMeetingClock`. Detector `onCandidate` → `Task { await session.candidateDetected(...) }`; panel buttons → `session.userAccepted/Skipped/Stopped`. Ensure the whisper model (WhisperModelStore.ensureModel) before arming Record — panel shows "Preparing…" until ready. Guard meeting features behind the same encryption/permission availability as capture.
- [ ] **Step 3: Build** — `swift build` clean.
- [ ] **Step 4: Full suite** — all green, zero warnings.
- [ ] **Step 5: Commit** `feat(meetings): wire detector -> session -> right-lane panel -> MeetingStore + Info.plist perms`

---

### Task 10: Live verification (controller/human — closes M5)

**Files:** none. Do NOT run as a subagent.

- [ ] **Step 1: Rebuild + relaunch** (grant persists; no tccutil reset): `./packaging/make-app.sh && pkill -9 -f "MaxMi.app/Contents/MacOS/MaxMi"; sleep 2; open MaxMi.app`. Grant Microphone + Screen Recording when first prompted (on first Record).
- [ ] **Step 2: Model readiness** — first enable: confirm the popup shows "Preparing transcription…" then arms Record once `ggml-base` is downloaded+verified.
- [ ] **Step 3: Detection + popup** — join a Zoom (or Meet in Chrome) call → right-edge popup appears within a few seconds, buttons clickable, floats over fullscreen Zoom on the correct screen, doesn't steal focus.
- [ ] **Step 4: Record path** — click Record, speak for 2+ min (ideally test a 30+ min call once), click Stop → verify:
```bash
DB=~/Library/Application\ Support/MaxMi/maxmi.db
sqlite3 -header -column "$DB" "SELECT id, app, title, state, capture_mode, transcription_status, (ended_at-started_at)/1000 AS dur_s FROM meetings ORDER BY started_at DESC LIMIT 3;"
sqlite3 "$DB" "SELECT substr(content,1,12) FROM versions v JOIN meetings m ON m.version_id=v.id ORDER BY m.started_at DESC LIMIT 1;"  # expect enc:v1:
```
- [ ] **Step 5: MCP** — `meeting_memory` list/search/get_context returns the meeting + decrypted transcript; `search_memory` also finds it.
- [ ] **Step 6: Negatives** — "Don't record" → no meeting row; switch apps mid-record → recording continues (no auto-truncate); deny Screen Recording once → `capture_mode='mic-only'` + panel note.
- [ ] **Step 7: Distinctness** — two short back-to-back meetings → two distinct `meetings` rows.
- [ ] **Step 8: Declare M5 complete** when 1-7 hold.

---

## Self-Review (at plan-writing time)

**Spec coverage:** §3 detection→T3; transcription (whisper default/model-ready/Deepgram/SFSpeech-fallback)→T4,T5; audio (SCStream app-scoped + mixer + mic-only fallback)→T6; popup (clickable, meeting-window's-screen)→T8; storage (meetings table, unique id, no dedup, encrypted transcript, metadata link)→T1; MCP→T2; session actor (manual-stop, backgrounding-safe, consent)→T7; wiring+permissions→T9; exit criteria→T10. §4 non-goals honored (whisper default, no auto-record, no auto-end). §7 schema→T1 migration verbatim. §9 perms→T9. §12 tests map to each task's tests.

**Placeholder scan:** two deliberate implementer-choice points flagged, not placeholders: T4 (whisper SPM-dep vs vendored C target — "pick what builds, document in commit") and T4 model sha256 ("pin the checksum"). Both are genuine environment-dependent decisions the implementer must resolve with the real toolchain/model; every other step has concrete code.

**Type consistency:** `commitMeeting(...)` signature identical in T1 def, T2 test seed, T9 wiring. All cross-actor types (`PCMFrame`, `CaptureRequest`, `AudioInputProcess`, `AudioCaptureControlling`, `Transcribing`, `MeetingPanelPresenting`, `MeetingPersisting`, `MeetingClock`) defined ONCE in Task 0 and referenced verbatim by T3/T5/T6/T7/T9. `MeetingRecord`/`MeetingContext` fields match the meetings table columns + new Store APIs (T1) consumed by T2. `RightLanePlacement` in MaxMiMeetings (testable) used by T8. `meeting_memory` actions consistent T2↔spec §8↔T10.

**Codex review #1 (plan) — all 7 must-fixes applied:** #1 Store exposes `meetingContext`/`searchMeetings` + `MeetingRecord.threadID/versionID`, MCP uses only those, `relay:` init, async; #2 `AudioCapture` resolves `SCDisplay` + takes `CaptureRequest`; #3 detector uses `[AudioInputProcess]` PID+bundleID snapshots + per-process IsRunningInput listeners + injected clock; #4 whisper pinned (v1.7.2, vendored CWhisper shim, model URL+sha256 to fill); #5 Task 0 Sendable contracts (PCMFrame, actor transcriber, @MainActor panel, Sendable persister, async capture); #6 explicit `MeetingPermissions` seam before capture; #7 `MaxMiMeetings` added to the MaxMi executable deps. Should-fixes: UNIQUE(version_id/thread_id), JSON metadata, mixer serial queue + sole resampling owner, mock-shim transcriber test, Deepgram/SFSpeech deferred behind the protocol.
