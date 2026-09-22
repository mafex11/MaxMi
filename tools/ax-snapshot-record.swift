#!/usr/bin/env swift
import Foundation

// The recorder lives in a package executable so it can call AXReader directly. A standalone
// `swift` script cannot import a local SwiftPM target.
let scriptURL = URL(fileURLWithPath: #filePath).standardizedFileURL
let packageRoot = scriptURL.deletingLastPathComponent().deletingLastPathComponent()

let process = Process()
process.currentDirectoryURL = packageRoot
process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
process.arguments = ["swift", "run", "AXSnapshotRecord"] + Array(CommandLine.arguments.dropFirst())

do {
    try process.run()
    process.waitUntilExit()
    exit(process.terminationStatus)
} catch {
    FileHandle.standardError.write(Data("could not run AXSnapshotRecord: \(error)\n".utf8))
    exit(1)
}
