import AppKit
import Darwin
import Foundation
import MaxMiCapture

let maximumNodes = 20_000
let maximumDepth = 40

func writeError(_ message: String) {
    fputs(message, stderr)
}

guard CommandLine.arguments.count == 3 else {
    writeError("usage: ax-snapshot-record.swift <bundle-id> <out.json>\n")
    exit(2)
}

let bundleID = CommandLine.arguments[1]
let outputPath = CommandLine.arguments[2]

guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
    writeError("application is not running\n")
    exit(3)
}

guard let snapshot = AXReader.snapshotFrontmostWindow(
    pid: app.processIdentifier,
    maxNodes: maximumNodes,
    maxDepth: maximumDepth
) else {
    writeError("focused window is unavailable\n")
    exit(4)
}

var encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
let data = try encoder.encode(snapshot.window)
try data.write(to: URL(fileURLWithPath: outputPath))
writeError("""
wrote \(outputPath)
HAND-SCRUB IT before committing: no real page text, messages, file contents, URLs, names or tokens.
""")
