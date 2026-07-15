import Darwin
import Foundation
import MaxMiStore

private struct RecoveryRequest {
    let backupURL: URL
    let databaseURL: URL
    let archiveDirectory: URL
    let resultURL: URL
    let parentPID: pid_t
    let appURL: URL?
}

private struct RecoveryOutcome: Codable {
    let status: String
    let preservedFilename: String?
}

private enum ArgumentError: LocalizedError {
    case invalid

    var errorDescription: String? {
        "Invalid MaxMi recovery request."
    }
}

private func request(arguments: [String]) throws -> RecoveryRequest {
    var values: [String: String] = [:]
    var index = 1
    while index + 1 < arguments.count {
        let key = arguments[index]
        guard key.hasPrefix("--") else { throw ArgumentError.invalid }
        values[key] = arguments[index + 1]
        index += 2
    }
    guard index == arguments.count,
          let backup = values["--backup"],
          let database = values["--database"],
          let archive = values["--archive"],
          let result = values["--result"],
          let pidText = values["--wait-for-pid"], let pid = Int32(pidText), pid > 1 else {
        throw ArgumentError.invalid
    }
    return RecoveryRequest(
        backupURL: URL(fileURLWithPath: backup),
        databaseURL: URL(fileURLWithPath: database),
        archiveDirectory: URL(fileURLWithPath: archive, isDirectory: true),
        resultURL: URL(fileURLWithPath: result),
        parentPID: pid,
        appURL: values["--relaunch"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    )
}

private func waitForExit(of pid: pid_t) {
    while kill(pid, 0) == 0 || errno == EPERM {
        Thread.sleep(forTimeInterval: 0.1)
    }
}

private func write(_ outcome: RecoveryOutcome, to url: URL) {
    do {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(outcome)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    } catch {
        // Recovery itself has already completed or failed; status persistence is best effort.
    }
}

private func relaunch(_ appURL: URL) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = [appURL.path]
    try? process.run()
}

do {
    let recovery = try request(arguments: CommandLine.arguments)
    waitForExit(of: recovery.parentPID)
    do {
        let result = try DatabaseRecovery.restore(
            backupURL: recovery.backupURL,
            databaseURL: recovery.databaseURL,
            archiveDirectory: recovery.archiveDirectory
        )
        write(
            RecoveryOutcome(
                status: "restore_succeeded",
                preservedFilename: result.preservedDatabaseURL.lastPathComponent
            ),
            to: recovery.resultURL
        )
        if let appURL = recovery.appURL { relaunch(appURL) }
    } catch {
        write(
            RecoveryOutcome(status: "restore_failed", preservedFilename: nil),
            to: recovery.resultURL
        )
        if let appURL = recovery.appURL { relaunch(appURL) }
        exit(EXIT_FAILURE)
    }
} catch {
    exit(EXIT_FAILURE)
}
