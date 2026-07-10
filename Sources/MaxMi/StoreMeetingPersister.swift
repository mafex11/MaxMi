import Foundation
import MaxMiMeetings
import MaxMiStore
import MaxMiCore

/// @MainActor wrapper over Store conforming to MeetingPersisting.
/// Store is used single-threaded on the main actor throughout AppWiring.
/// This adapter calls back to the main actor to perform the DB write, avoiding
/// Sendable violations while keeping Store usage single-threaded.
///
/// @unchecked Sendable rationale:
/// 1. Store is only ever accessed from @MainActor context in AppWiring
/// 2. GRDB's DatabaseQueue serializes all DB access internally
/// 3. This persister's persist() hops back to MainActor to call commitMeeting
/// Single-threaded usage pattern, guarded by MainActor boundary.
struct StoreMeetingPersister: MeetingPersisting, @unchecked Sendable {
    private let store: Store

    init(store: Store) {
        self.store = store
    }

    func persist(app: String, title: String?, transcript: String, startedAtMs: Int64,
                 endedAtMs: Int64, captureMode: String, transcriptionStatus: String) async {
        await MainActor.run {
            do {
                // Generate a fresh UUIDv7 for the meeting ID
                let meetingID = Ident.uuidv7(nowMs: endedAtMs)
                _ = try store.commitMeeting(
                    id: meetingID,
                    app: app,
                    title: title,
                    transcript: transcript,
                    startedAtMs: startedAtMs,
                    endedAtMs: endedAtMs,
                    captureMode: captureMode,
                    transcriptionStatus: transcriptionStatus,
                    nowMs: endedAtMs
                )
            } catch {
                NSLog("MaxMi: meeting persist failed: \(error)")
            }
        }
    }
}
