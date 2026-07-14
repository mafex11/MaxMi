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
            let latest = try Row.fetchOne(d, sql: "SELECT content_kind, parser_id, summary_status FROM latest_contexts WHERE thread_id=?", arguments: [m["thread_id"] as String])!
            XCTAssertEqual(latest["content_kind"] as String, "meeting")
            XCTAssertEqual(latest["parser_id"] as String, "MeetingTranscriber")
            XCTAssertEqual(latest["summary_status"] as String, "pending")
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

    func testVoiceNoteUsesDistinctSearchableEncryptedThread() throws {
        _ = try store.commitMeeting(
            id: "voice-1", app: "Voice Note", title: "Idea", transcript: "remember this thought",
            startedAtMs: t0, endedAtMs: t0 + 2_000, captureMode: "voice-note-mic",
            transcriptionStatus: "complete", nowMs: t0 + 2_000
        )
        try db.dbQueue.read { database in
            let row = try XCTUnwrap(Row.fetchOne(database, sql: """
                SELECT t.source_app, t.source_key, v.content
                FROM meetings m
                JOIN threads t ON t.id = m.thread_id
                JOIN versions v ON v.id = m.version_id
                WHERE m.id = 'voice-1'
                """))
            XCTAssertEqual(row["source_app"] as String, "Voice Note")
            XCTAssertTrue((row["source_key"] as String).hasPrefix("voice-note:"))
            XCTAssertTrue((row["content"] as String).hasPrefix("enc:v1:"))
        }
        let contexts = try store.latestContexts(limit: 10)
        XCTAssertEqual(contexts.first?.contentKind, .voiceNote)
        XCTAssertEqual(contexts.first?.parserID, "VoiceNoteTranscriber")
        XCTAssertEqual(try store.meetingContext(id: "voice-1")?.transcript, "remember this thought")
    }
}
