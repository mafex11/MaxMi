import Foundation

public enum MeetingRecordingKind: String, Codable, Sendable {
    case meeting
    case voiceNote = "voice_note"
}

public protocol MeetingLifecycleTracking: Sendable {
    func recordingStarted(kind: MeetingRecordingKind, startedAtMs: Int64) async
    func recordingEnded() async
}

public struct NoopMeetingLifecycleTracker: MeetingLifecycleTracking {
    public init() {}
    public func recordingStarted(kind: MeetingRecordingKind, startedAtMs: Int64) async {}
    public func recordingEnded() async {}
}

public struct InterruptedRecording: Codable, Equatable, Sendable {
    public let formatVersion: Int
    public let kind: MeetingRecordingKind
    public let startedAtMs: Int64

    public init(formatVersion: Int = 1, kind: MeetingRecordingKind, startedAtMs: Int64) {
        self.formatVersion = formatVersion
        self.kind = kind
        self.startedAtMs = startedAtMs
    }
}

/// Stores only enough state to detect that the previous process ended during recording.
/// It intentionally contains no application, title, transcript, URL, or audio data.
public actor FileMeetingLifecycleTracker: MeetingLifecycleTracking {
    public let markerURL: URL
    private let fileManager: FileManager

    public init(directoryURL: URL, fileManager: FileManager = .default) {
        markerURL = directoryURL.appendingPathComponent("active-recording.json")
        self.fileManager = fileManager
    }

    public func recordingStarted(kind: MeetingRecordingKind, startedAtMs: Int64) async {
        do {
            try fileManager.createDirectory(
                at: markerURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: markerURL.deletingLastPathComponent().path
            )
            let data = try JSONEncoder().encode(
                InterruptedRecording(kind: kind, startedAtMs: startedAtMs)
            )
            try data.write(to: markerURL, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: markerURL.path)
        } catch {
            // Recording must remain usable if diagnostics metadata cannot be written.
        }
    }

    public func recordingEnded() async {
        try? fileManager.removeItem(at: markerURL)
    }

    /// Returns and consumes a valid previous-run marker. Invalid markers are also removed
    /// so corrupt metadata cannot accumulate or block later recording.
    public func recoverInterrupted() async -> InterruptedRecording? {
        guard fileManager.fileExists(atPath: markerURL.path) else { return nil }
        defer { try? fileManager.removeItem(at: markerURL) }
        guard let data = try? Data(contentsOf: markerURL),
              let marker = try? JSONDecoder().decode(InterruptedRecording.self, from: data),
              marker.formatVersion == 1 else { return nil }
        return marker
    }
}

public struct MeetingResourceSnapshot: Codable, Equatable, Sendable {
    public let audioEngines: Int
    public let screenStreams: Int
    public let deviceObservers: Int
    public let meetingDetectors: Int
}

/// Content-free process-local counters used by diagnostics and cleanup tests.
public final class MeetingResourceTracker: @unchecked Sendable {
    public static let shared = MeetingResourceTracker()

    private let lock = NSLock()
    private var audioEngines = 0
    private var screenStreams = 0
    private var deviceObservers = 0
    private var meetingDetectors = 0

    public init() {}

    public func audioEngineStarted() { update(\.audioEngines, by: 1) }
    public func audioEngineStopped() { update(\.audioEngines, by: -1) }
    public func screenStreamStarted() { update(\.screenStreams, by: 1) }
    public func screenStreamStopped() { update(\.screenStreams, by: -1) }
    public func deviceObserverStarted() { update(\.deviceObservers, by: 1) }
    public func deviceObserverStopped() { update(\.deviceObservers, by: -1) }
    public func meetingDetectorStarted() { update(\.meetingDetectors, by: 1) }
    public func meetingDetectorStopped() { update(\.meetingDetectors, by: -1) }

    public func snapshot() -> MeetingResourceSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return MeetingResourceSnapshot(
            audioEngines: audioEngines,
            screenStreams: screenStreams,
            deviceObservers: deviceObservers,
            meetingDetectors: meetingDetectors
        )
    }

    private func update(_ keyPath: ReferenceWritableKeyPath<MeetingResourceTracker, Int>, by delta: Int) {
        lock.lock()
        self[keyPath: keyPath] = max(0, self[keyPath: keyPath] + delta)
        lock.unlock()
    }
}
