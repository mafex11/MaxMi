import Foundation

public enum SafeLogLevel: String, Sendable {
    case debug
    case info
    case warning
    case error
}

public enum SafeLogSubsystem: String, Sendable {
    case app
    case capture
    case pipeline
    case store
    case activity
    case agent
    case meeting
    case mcp
    case settings
    case migration
    case diagnostics
}

/// Closed event vocabulary. Callers cannot pass free-form messages to the logger.
public enum SafeLogEventName: String, Sendable {
    case appStarted = "app_started"
    case appStopped = "app_stopped"
    case appCleanupStarted = "app_cleanup_started"
    case appCleanupCompleted = "app_cleanup_completed"
    case interruptedRecordingRecovered = "interrupted_recording_recovered"
    case encryptionKeyUnavailable = "encryption_key_unavailable"
    case databaseReadFailed = "database_read_failed"
    case databaseWriteFailed = "database_write_failed"
    case settingsDecodeFailed = "settings_decode_failed"
    case backfillProgress = "backfill_progress"
    case backfillFailed = "backfill_failed"
    case cloudReviewBootstrapFailed = "cloud_review_bootstrap_failed"
    case activityCrashRepairFailed = "activity_crash_repair_failed"
    case activityConsentReadFailed = "activity_consent_read_failed"
    case activityStateReadFailed = "activity_state_read_failed"
    case activityStateWriteFailed = "activity_state_write_failed"
    case activityCaptureFailed = "activity_capture_failed"
    case actionItemsReadFailed = "action_items_read_failed"
    case recentCapturesReadFailed = "recent_captures_read_failed"
    case meetingHistoryReadFailed = "meeting_history_read_failed"
    case captureHealthReadFailed = "capture_health_read_failed"
    case captureHealthWriteFailed = "capture_health_write_failed"
    case privacyStateReadFailed = "privacy_state_read_failed"
    case privacyStateWriteFailed = "privacy_state_write_failed"
    case parserNoContent = "parser_no_content"
    case parserFailed = "parser_failed"
    case captureCommitFailed = "capture_commit_failed"
    case capturePauseReadFailed = "capture_pause_read_failed"
    case capturePauseWriteFailed = "capture_pause_write_failed"
    case capturePolicyReadFailed = "capture_policy_read_failed"
    case modelDownloadFailed = "model_download_failed"
    case retryQueueReadFailed = "retry_queue_read_failed"
    case retryQueueWriteFailed = "retry_queue_write_failed"
    case retryClearFailed = "retry_clear_failed"
    case pendingWorkReadFailed = "pending_work_read_failed"
    case unreadableVersionSkipped = "unreadable_version_skipped"
    case extractionStateWriteFailed = "extraction_state_write_failed"
    case captureSummaryFailed = "capture_summary_failed"
    case activitySummaryFailed = "activity_summary_failed"
    case agentRunFailed = "agent_run_failed"
    case agentStatusReadFailed = "agent_status_read_failed"
    case meetingPersistFailed = "meeting_persist_failed"
    case meetingCaptureStartFailed = "meeting_capture_start_failed"
    case meetingListenerFailed = "meeting_listener_failed"
    case audioFallbackToMicrophone = "audio_fallback_to_microphone"
    case audioDeviceRestartFailed = "audio_device_restart_failed"
    case audioStreamStoppedWithError = "audio_stream_stopped_with_error"
    case mcpFrameDropped = "mcp_frame_dropped"
    case mcpKeychainUnavailable = "mcp_keychain_unavailable"
    case mcpDatabaseOpenFailed = "mcp_database_open_failed"
    case mcpEmbeddingFailed = "mcp_embedding_failed"
    case launchAtLoginWriteFailed = "launch_at_login_write_failed"
    case diagnosticsExported = "diagnostics_exported"
    case diagnosticsExportFailed = "diagnostics_export_failed"
}

/// A deliberately narrow token for parser IDs, triggers, outcomes, and fixed table names.
/// It rejects whitespace, query syntax, and punctuation commonly found in captured content.
public struct SafeLogToken: Sendable, Equatable {
    public let value: String

    public init?(validating value: String) {
        guard !value.isEmpty,
              value.utf8.count <= 96,
              !value.contains("://"),
              !value.hasPrefix("/") else { return nil }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._/-")
        guard value.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        self.value = value
    }
}

public struct SafeLogFields: Sendable, Equatable {
    public var parserID: SafeLogToken?
    public var trigger: SafeLogToken?
    public var outcome: SafeLogToken?
    public var operation: SafeLogToken?
    public var durationMs: Int?
    public var count: Int?
    public var attempts: Int?
    public var statusCode: Int?

    public init(
        parserID: SafeLogToken? = nil,
        trigger: SafeLogToken? = nil,
        outcome: SafeLogToken? = nil,
        operation: SafeLogToken? = nil,
        durationMs: Int? = nil,
        count: Int? = nil,
        attempts: Int? = nil,
        statusCode: Int? = nil
    ) {
        self.parserID = parserID
        self.trigger = trigger
        self.outcome = outcome
        self.operation = operation
        self.durationMs = durationMs
        self.count = count
        self.attempts = attempts
        self.statusCode = statusCode
    }
}

/// Synchronous, low-volume JSON-lines logger. MaxMi logs state transitions and failures,
/// not captured payloads, so a short locked file append keeps ordering deterministic.
public final class SafeLogger: @unchecked Sendable {
    public static let shared = SafeLogger()

    public static var defaultLogDirectory: URL {
        if ProcessInfo.processInfo.processName.lowercased().contains("xctest") {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("MaxMi-Test-Logs", isDirectory: true)
                .appendingPathComponent(String(ProcessInfo.processInfo.processIdentifier), isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MaxMi/Logs", isDirectory: true)
    }

    public let directoryURL: URL
    public let activeFileURL: URL

    private let maximumFileBytes: Int
    private let maximumFiles: Int
    private let lock = NSLock()
    private let fileManager: FileManager

    public init(
        directoryURL: URL = SafeLogger.defaultLogDirectory,
        processName: String = ProcessInfo.processInfo.processName,
        maximumFileBytes: Int = 5 * 1_024 * 1_024,
        maximumFiles: Int = 5,
        fileManager: FileManager = .default
    ) {
        self.directoryURL = directoryURL
        self.maximumFileBytes = max(256, maximumFileBytes)
        self.maximumFiles = max(1, maximumFiles)
        self.fileManager = fileManager
        let normalized = Self.normalizedProcessName(processName)
        activeFileURL = directoryURL.appendingPathComponent("\(normalized).log")
    }

    public func log(
        _ level: SafeLogLevel,
        subsystem: SafeLogSubsystem,
        event: SafeLogEventName,
        error: Error? = nil,
        fields: SafeLogFields = SafeLogFields()
    ) {
        lock.lock()
        defer { lock.unlock() }

        do {
            var object: [String: Any] = [
                "timestamp": Self.timestamp(),
                "level": level.rawValue,
                "subsystem": subsystem.rawValue,
                "event": event.rawValue,
            ]
            if let error { object["system_error_code"] = (error as NSError).code }
            if let value = fields.parserID?.value { object["parser_id"] = value }
            if let value = fields.trigger?.value { object["trigger"] = value }
            if let value = fields.outcome?.value { object["outcome"] = value }
            if let value = fields.operation?.value { object["operation"] = value }
            if let value = fields.durationMs { object["duration_ms"] = max(0, value) }
            if let value = fields.count { object["count"] = max(0, value) }
            if let value = fields.attempts { object["attempts"] = max(0, value) }
            if let value = fields.statusCode { object["status_code"] = value }

            var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            data.append(0x0A)
            try prepareForAppend(incomingBytes: data.count)
            let handle = try FileHandle(forWritingTo: activeFileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: activeFileURL.path)
        } catch {
            // Logging is best-effort and must never break capture or recursively log.
        }
    }

    public func logFilesNewestFirst() -> [URL] {
        lock.lock()
        defer { lock.unlock() }
        var files: [URL] = []
        if fileManager.fileExists(atPath: activeFileURL.path) { files.append(activeFileURL) }
        guard maximumFiles > 1 else { return files }
        for index in 1..<maximumFiles {
            let url = archiveURL(index)
            if fileManager.fileExists(atPath: url.path) { files.append(url) }
        }
        return files
    }

    private func prepareForAppend(incomingBytes: Int) throws {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)

        if !fileManager.fileExists(atPath: activeFileURL.path) {
            fileManager.createFile(atPath: activeFileURL.path, contents: nil)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: activeFileURL.path)
            return
        }

        let size = (try fileManager.attributesOfItem(atPath: activeFileURL.path)[.size] as? NSNumber)?.intValue ?? 0
        guard size > 0, size + incomingBytes > maximumFileBytes else { return }

        if maximumFiles == 1 {
            try fileManager.removeItem(at: activeFileURL)
        } else {
            for index in stride(from: maximumFiles - 1, through: 1, by: -1) {
                let destination = archiveURL(index)
                if fileManager.fileExists(atPath: destination.path) {
                    try fileManager.removeItem(at: destination)
                }
                let source = index == 1 ? activeFileURL : archiveURL(index - 1)
                if fileManager.fileExists(atPath: source.path) {
                    try fileManager.moveItem(at: source, to: destination)
                    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
                }
            }
        }

        fileManager.createFile(atPath: activeFileURL.path, contents: nil)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: activeFileURL.path)
    }

    private func archiveURL(_ index: Int) -> URL {
        URL(fileURLWithPath: activeFileURL.path + ".\(index)")
    }

    private static func normalizedProcessName(_ value: String) -> String {
        let scalars = value.lowercased().unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_"
                ? Character(String(scalar)) : "-"
        }
        let name = String(scalars).prefix(48)
        return name.isEmpty ? "maxmi" : String(name)
    }

    private static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
}
