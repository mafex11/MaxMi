import Foundation

public struct SafeDiagnosticsDatabase: Codable, Sendable, Equatable {
    public let latestMigration: SafeLogToken
    public let migrationCount: Int
    public let integrityOK: Bool
    public let databaseBytes: Int
    public let walBytes: Int
    public let shmBytes: Int
    public let threads: Int
    public let versions: Int
    public let facts: Int
    public let latestContexts: Int
    public let recordings: Int
    public let captureHealthEvents: Int
    public let retryTotal: Int
    public let retryOverdue: Int
    public let retryMaxAttempts: Int
    public let contextSummariesPending: Int
    public let contextSummariesFailed: Int
    public let activitySummariesPending: Int
    public let activitySummariesFailed: Int
    public let agentRunsRunning: Int
    public let agentRunsFailed: Int
    public let actionItemsOpen: Int

    public init(
        latestMigration: SafeLogToken,
        migrationCount: Int,
        integrityOK: Bool,
        databaseBytes: Int,
        walBytes: Int,
        shmBytes: Int,
        threads: Int,
        versions: Int,
        facts: Int,
        latestContexts: Int,
        recordings: Int,
        captureHealthEvents: Int,
        retryTotal: Int,
        retryOverdue: Int,
        retryMaxAttempts: Int,
        contextSummariesPending: Int,
        contextSummariesFailed: Int,
        activitySummariesPending: Int,
        activitySummariesFailed: Int,
        agentRunsRunning: Int,
        agentRunsFailed: Int,
        actionItemsOpen: Int
    ) {
        self.latestMigration = latestMigration
        self.migrationCount = max(0, migrationCount)
        self.integrityOK = integrityOK
        self.databaseBytes = max(0, databaseBytes)
        self.walBytes = max(0, walBytes)
        self.shmBytes = max(0, shmBytes)
        self.threads = max(0, threads)
        self.versions = max(0, versions)
        self.facts = max(0, facts)
        self.latestContexts = max(0, latestContexts)
        self.recordings = max(0, recordings)
        self.captureHealthEvents = max(0, captureHealthEvents)
        self.retryTotal = max(0, retryTotal)
        self.retryOverdue = max(0, retryOverdue)
        self.retryMaxAttempts = max(0, retryMaxAttempts)
        self.contextSummariesPending = max(0, contextSummariesPending)
        self.contextSummariesFailed = max(0, contextSummariesFailed)
        self.activitySummariesPending = max(0, activitySummariesPending)
        self.activitySummariesFailed = max(0, activitySummariesFailed)
        self.agentRunsRunning = max(0, agentRunsRunning)
        self.agentRunsFailed = max(0, agentRunsFailed)
        self.actionItemsOpen = max(0, actionItemsOpen)
    }
}

public struct SafeDiagnosticsPermissions: Codable, Sendable, Equatable {
    public let accessibility: Bool
    public let microphone: Bool
    public let screenRecording: Bool

    public init(accessibility: Bool, microphone: Bool, screenRecording: Bool) {
        self.accessibility = accessibility
        self.microphone = microphone
        self.screenRecording = screenRecording
    }
}

public struct SafeDiagnosticsProcesses: Codable, Sendable, Equatable {
    public let app: Int
    public let mcp: Int

    public init(app: Int, mcp: Int) {
        self.app = max(0, app)
        self.mcp = max(0, mcp)
    }
}

public struct SafeDiagnosticsResources: Codable, Sendable, Equatable {
    public let audioEngines: Int
    public let screenStreams: Int
    public let deviceObservers: Int
    public let meetingDetectors: Int
    public let helperProcesses: Int

    public init(
        audioEngines: Int,
        screenStreams: Int,
        deviceObservers: Int,
        meetingDetectors: Int,
        helperProcesses: Int
    ) {
        self.audioEngines = max(0, audioEngines)
        self.screenStreams = max(0, screenStreams)
        self.deviceObservers = max(0, deviceObservers)
        self.meetingDetectors = max(0, meetingDetectors)
        self.helperProcesses = max(0, helperProcesses)
    }
}

public struct SafeDiagnosticsManifest: Codable, Sendable, Equatable {
    public let formatVersion: Int
    public let generatedAtUTC: String
    public let appVersion: SafeLogToken
    public let appBuild: SafeLogToken
    public let encryptionAvailable: Bool
    public let permissions: SafeDiagnosticsPermissions
    public let processes: SafeDiagnosticsProcesses
    public let resources: SafeDiagnosticsResources
    public let database: SafeDiagnosticsDatabase

    public init(
        generatedAt: Date = Date(),
        appVersion: SafeLogToken,
        appBuild: SafeLogToken,
        encryptionAvailable: Bool,
        permissions: SafeDiagnosticsPermissions,
        processes: SafeDiagnosticsProcesses,
        resources: SafeDiagnosticsResources,
        database: SafeDiagnosticsDatabase
    ) {
        formatVersion = 1
        generatedAtUTC = Self.timestamp(generatedAt)
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.encryptionAvailable = encryptionAvailable
        self.permissions = permissions
        self.processes = processes
        self.resources = resources
        self.database = database
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

public enum SafeDiagnosticsError: Error, LocalizedError, Equatable {
    case destinationExists
    case invalidDestination

    public var errorDescription: String? {
        switch self {
        case .destinationExists: return "Choose a new diagnostics folder name"
        case .invalidDestination: return "The diagnostics destination is unavailable"
        }
    }
}

public enum SafeDiagnosticsBundleWriter {
    private static let maximumSourceLogFiles = 10
    private static let maximumSourceLogBytes = 6 * 1_024 * 1_024

    /// Creates a mode-0700 folder containing a fixed-schema manifest and sanitized JSON logs.
    /// Unknown keys, invalid enum values, malformed lines, and free-form values are discarded.
    @discardableResult
    public static func write(
        manifest: SafeDiagnosticsManifest,
        logDirectory: URL,
        to destination: URL,
        fileManager: FileManager = .default
    ) throws -> Int {
        guard !destination.path.isEmpty else { throw SafeDiagnosticsError.invalidDestination }
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw SafeDiagnosticsError.destinationExists
        }

        do {
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: false)
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: destination.path)

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let manifestURL = destination.appendingPathComponent("manifest.json")
            try encoder.encode(manifest).write(to: manifestURL, options: [.atomic])
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifestURL.path)

            let logsURL = destination.appendingPathComponent("logs", isDirectory: true)
            try fileManager.createDirectory(at: logsURL, withIntermediateDirectories: false)
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: logsURL.path)

            let entries = try sanitizeLogs(from: logDirectory, to: logsURL, fileManager: fileManager)
            return entries
        } catch {
            try? fileManager.removeItem(at: destination)
            throw error
        }
    }

    private static func sanitizeLogs(
        from sourceDirectory: URL,
        to destinationDirectory: URL,
        fileManager: FileManager
    ) throws -> Int {
        guard let files = try? fileManager.contentsOfDirectory(
            at: sourceDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        let candidates = files.filter { url in
            guard url.lastPathComponent.contains(".log") else { return false }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            return values?.isRegularFile == true && (values?.fileSize ?? Int.max) <= maximumSourceLogBytes
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            .prefix(maximumSourceLogFiles)

        var totalEntries = 0
        var outputIndex = 0
        for source in candidates {
            let data = try Data(contentsOf: source, options: [.mappedIfSafe])
            var sanitized = Data()
            var fileEntries = 0
            for line in data.split(separator: 0x0A) {
                guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                      let safe = sanitizeLogObject(object),
                      var encoded = try? JSONSerialization.data(withJSONObject: safe, options: [.sortedKeys])
                else { continue }
                encoded.append(0x0A)
                sanitized.append(encoded)
                fileEntries += 1
            }
            guard fileEntries > 0 else { continue }
            outputIndex += 1
            let destination = destinationDirectory.appendingPathComponent("runtime-\(outputIndex).jsonl")
            try sanitized.write(to: destination, options: [.atomic])
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            totalEntries += fileEntries
        }
        return totalEntries
    }

    private static func sanitizeLogObject(_ object: [String: Any]) -> [String: Any]? {
        guard let timestamp = object["timestamp"] as? String,
              isTimestamp(timestamp),
              let levelValue = object["level"] as? String,
              SafeLogLevel(rawValue: levelValue) != nil,
              let subsystemValue = object["subsystem"] as? String,
              SafeLogSubsystem(rawValue: subsystemValue) != nil,
              let eventValue = object["event"] as? String,
              SafeLogEventName(rawValue: eventValue) != nil
        else { return nil }

        var safe: [String: Any] = [
            "timestamp": timestamp,
            "level": levelValue,
            "subsystem": subsystemValue,
            "event": eventValue,
        ]
        for key in ["parser_id", "trigger", "outcome", "operation"] {
            if let value = object[key] as? String, let token = SafeLogToken(validating: value) {
                safe[key] = token.value
            }
        }
        for key in ["system_error_code", "duration_ms", "count", "attempts", "status_code"] {
            if let value = object[key] as? NSNumber { safe[key] = value }
        }
        return safe
    }

    private static func isTimestamp(_ value: String) -> Bool {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if fractional.date(from: value) != nil { return true }
        return ISO8601DateFormatter().date(from: value) != nil
    }
}

extension SafeLogToken: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let token = SafeLogToken(validating: value) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid safe token")
        }
        self = token
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}
