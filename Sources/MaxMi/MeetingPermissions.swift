import Foundation
import AVFoundation
import CoreGraphics
import MaxMiMeetings

/// Permission adapter conforming to MeetingAuthorizing, injected into MeetingSession.
struct MeetingPermissions: MeetingAuthorizing {
    func requestMicrophone() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    func screenRecordingAuthorized() async -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    func requestScreenRecordingAccess() async -> Bool {
        CGRequestScreenCaptureAccess()
    }
}
