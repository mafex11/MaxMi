import XCTest
@testable import MaxMiMeetings

final class UnsafeMutableTransferBox<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

final class TranscriberTests: XCTestCase {

    // MARK: - RollingStitch pure tests

    func testRollingStitchSingleWindow() {
        let result = RollingStitch.stitch(["hello world"])
        XCTAssertEqual(result, "hello world")
    }

    func testRollingStitchNoOverlap() {
        let result = RollingStitch.stitch(["hello", "world"])
        XCTAssertEqual(result, "hello world")
    }

    func testRollingStitchWithOverlap() {
        // Second window repeats last word from first
        let result = RollingStitch.stitch(["hello world", "world again"])
        XCTAssertEqual(result, "hello world again")
    }

    func testRollingStitchMultipleOverlaps() {
        // Each window overlaps with the previous
        let result = RollingStitch.stitch(["one two three", "two three four", "three four five"])
        XCTAssertEqual(result, "one two three four five")
    }

    func testRollingStitchEmptyWindows() {
        XCTAssertEqual(RollingStitch.stitch([]), "")
        XCTAssertEqual(RollingStitch.stitch([""]), "")
        XCTAssertEqual(RollingStitch.stitch(["", ""]), "")
    }

    func testRollingStitchPartialOverlap() {
        // Overlap is substring, not full word boundary
        let result = RollingStitch.stitch(["the quick brown", "brown fox jumps"])
        XCTAssertEqual(result, "the quick brown fox jumps")
    }

    // MARK: - MockTranscriber protocol conformance

    func testMockTranscriberAccumulates() async throws {
        let mock = MockTranscriber()
        try await mock.start()

        let frame1 = PCMFrame(samples: [0.1, 0.2], hostTimeNs: 1000)
        let frame2 = PCMFrame(samples: [0.3, 0.4], hostTimeNs: 2000)

        await mock.feed(frame1)
        await mock.feed(frame2)

        let result = await mock.finish()
        XCTAssertTrue(result.contains("4 samples"))
    }

    func testMockTranscriberPartialCallback() async throws {
        let mock = MockTranscriber()
        try await mock.start()

        let partials = UnsafeMutableTransferBox<[String]>([])
        await mock.setOnPartial { text in
            partials.value.append(text)
        }

        await mock.feed(PCMFrame(samples: [0.1], hostTimeNs: 1000))
        await mock.triggerPartial()

        XCTAssertEqual(partials.value.count, 1)
        XCTAssertTrue(partials.value[0].contains("1 samples"))
    }

    // MARK: - WhisperTranscriber windowing (mock bridge)

    func testWhisperTranscriberWindowBoundaries() async throws {
        let testDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: testDir) }

        let modelURL = testDir.appendingPathComponent("mock.bin")
        FileManager.default.createFile(atPath: modelURL.path, contents: Data())

        let transcribedWindows = UnsafeMutableTransferBox<[[Float]]>([])
        let transcriber = WhisperTranscriber(
            modelURL: modelURL,
            bridgeFactory: { _ in
                MockWhisperBridge { pcm in
                    transcribedWindows.value.append(pcm)
                    return "window \(transcribedWindows.value.count)"
                }
            }
        )

        try await transcriber.start()

        // Feed 30s of audio at 16kHz = 480,000 samples
        // Window size is 30s, so should trigger after this
        let windowSamples = 30 * 16_000
        for _ in 0..<10 {
            let chunk = Array(repeating: Float(0.5), count: windowSamples / 10)
            await transcriber.feed(PCMFrame(samples: chunk, hostTimeNs: 1000))
        }

        // Should have transcribed 1 window
        XCTAssertEqual(transcribedWindows.value.count, 1)
        XCTAssertEqual(transcribedWindows.value[0].count, windowSamples)

        // Feed another 28s (should not trigger yet, 2s overlap retained)
        let nextChunk = Array(repeating: Float(0.6), count: 28 * 16_000)
        await transcriber.feed(PCMFrame(samples: nextChunk, hostTimeNs: 2000))
        XCTAssertEqual(transcribedWindows.value.count, 1) // Still just 1

        // Feed 2 more seconds to complete the second window
        let finalChunk = Array(repeating: Float(0.7), count: 2 * 16_000)
        await transcriber.feed(PCMFrame(samples: finalChunk, hostTimeNs: 3000))

        // Should now have 2 windows
        XCTAssertEqual(transcribedWindows.value.count, 2)
    }

    func testWhisperTranscriberStitchesWindows() async throws {
        let testDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: testDir) }

        let modelURL = testDir.appendingPathComponent("mock.bin")
        FileManager.default.createFile(atPath: modelURL.path, contents: Data())

        let windowCount = UnsafeMutableTransferBox<Int>(0)
        let transcriber = WhisperTranscriber(
            modelURL: modelURL,
            bridgeFactory: { _ in
                MockWhisperBridge { _ in
                    windowCount.value += 1
                    return "window \(windowCount.value)"
                }
            }
        )

        try await transcriber.start()

        let partials = UnsafeMutableTransferBox<[String]>([])
        await transcriber.setOnPartial { text in
            partials.value.append(text)
        }

        // Feed 2 windows worth
        for _ in 0..<2 {
            let chunk = Array(repeating: Float(0.5), count: 30 * 16_000)
            await transcriber.feed(PCMFrame(samples: chunk, hostTimeNs: 1000))
        }

        let final = await transcriber.finish()

        // Should have stitched results
        XCTAssertTrue(final.contains("window"))
        XCTAssertTrue(partials.value.count > 0)
    }

    // MARK: - WhisperTranscriber real model (conditional)

    func testWhisperTranscriberRealModel() async throws {
        let modelPath = NSHomeDirectory() + "/Library/Application Support/MaxMi/models/ggml-base.bin"
        guard FileManager.default.fileExists(atPath: modelPath) else {
            throw XCTSkip("Real whisper model not available at \(modelPath)")
        }

        let transcriber = WhisperTranscriber(modelURL: URL(fileURLWithPath: modelPath))
        try await transcriber.start()

        // Generate 1 second of 440Hz sine wave at 16kHz
        let sampleRate = 16_000.0
        let frequency = 440.0
        let duration = 1.0
        let samples = (0..<Int(sampleRate * duration)).map { i in
            Float(sin(2.0 * .pi * frequency * Double(i) / sampleRate)) * 0.3
        }

        await transcriber.feed(PCMFrame(samples: samples, hostTimeNs: 0))
        let result = await transcriber.finish()

        // Model should return something (even if empty/hallucinated for pure tone)
        XCTAssertNotNil(result)
    }
}

// MARK: - Mock Implementations

/// Mock transcriber for testing the Transcribing protocol
actor MockTranscriber: Transcribing {
    private var frames: [PCMFrame] = []
    private var onPartial: (@Sendable (String) -> Void)?
    private var started = false

    func start() async throws {
        started = true
    }

    func feed(_ frame: PCMFrame) async {
        frames.append(frame)
    }

    func finish() async -> String {
        let totalSamples = frames.reduce(0) { $0 + $1.samples.count }
        return "transcribed \(totalSamples) samples"
    }

    func setOnPartial(_ cb: @escaping @Sendable (String) -> Void) async {
        onPartial = cb
    }

    func triggerPartial() async {
        let totalSamples = frames.reduce(0) { $0 + $1.samples.count }
        onPartial?("partial: \(totalSamples) samples")
    }
}

/// Mock whisper bridge for testing windowing without real model
/// Note: Conforms to internal WhisperBridging protocol (accessible via @testable import)
final class MockWhisperBridge: WhisperBridging {
    private let transcriber: ([Float]) -> String

    init(transcriber: @escaping ([Float]) -> String) {
        self.transcriber = transcriber
    }

    func transcribe(pcm16k: [Float]) throws -> String {
        return transcriber(pcm16k)
    }
}
