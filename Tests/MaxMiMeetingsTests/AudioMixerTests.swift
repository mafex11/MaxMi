import XCTest
@preconcurrency import AVFoundation
@testable import MaxMiMeetings

final class AudioMixerTests: XCTestCase {
    func testMixesSystemAndMicBuffersTo16kHzMono() throws {
        let mixer = AudioMixer(targetSampleRate: 16_000)
        let expectation = self.expectation(description: "frame emitted")
        expectation.assertForOverFulfill = false   // two buffers (system+mic) each emit a frame
        let boxedFrame = Box<PCMFrame?>(nil)

        mixer.onFrame = { frame in
            boxedFrame.value = frame
            expectation.fulfill()
        }

        // Create a 48kHz stereo system buffer (typical SCStream audio)
        let systemFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!
        let systemBuffer = AVAudioPCMBuffer(pcmFormat: systemFormat, frameCapacity: 4800)!
        systemBuffer.frameLength = 4800  // 0.1 seconds at 48kHz
        // Fill with non-zero data (left channel 0.5, right channel 0.3)
        for i in 0..<Int(systemBuffer.frameLength) {
            systemBuffer.floatChannelData![0][i] = 0.5
            systemBuffer.floatChannelData![1][i] = 0.3
        }

        // Create a 44.1kHz mono mic buffer
        let micFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 1, interleaved: false)!
        let micBuffer = AVAudioPCMBuffer(pcmFormat: micFormat, frameCapacity: 4410)!
        micBuffer.frameLength = 4410  // 0.1 seconds at 44.1kHz
        for i in 0..<Int(micBuffer.frameLength) {
            micBuffer.floatChannelData![0][i] = 0.7
        }

        // Mix both with timestamps
        let time1 = AVAudioTime(hostTime: 1000)
        let time2 = AVAudioTime(hostTime: 1000)
        mixer.mixSystem(systemBuffer, at: time1)
        mixer.mixMic(micBuffer, at: time2)

        wait(for: [expectation], timeout: 1.0)

        // Verify we got a frame
        guard let frame = boxedFrame.value else {
            XCTFail("Should have emitted a frame")
            return
        }

        // Verify output is 16kHz mono
        XCTAssertGreaterThan(frame.samples.count, 0)
        // For 0.1s of audio at 16kHz, expect ~1600 samples
        XCTAssertGreaterThan(frame.samples.count, 1000, "should have ~1600 samples for 0.1s at 16kHz")
        XCTAssertLessThan(frame.samples.count, 2500)

        // Verify samples are non-zero (mixed signal)
        let hasSignal = frame.samples.contains { abs($0) > 0.01 }
        XCTAssertTrue(hasSignal, "mixed frame should contain non-zero audio signal")
    }

    func testLevelReflectsAmplitude() throws {
        let mixer = AudioMixer(targetSampleRate: 16_000)

        // Initial level should be zero
        XCTAssertEqual(mixer.level, 0.0, accuracy: 0.01)

        // Feed a buffer with known amplitude
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600)!
        buffer.frameLength = 1600
        for i in 0..<Int(buffer.frameLength) {
            buffer.floatChannelData![0][i] = 0.8  // high amplitude
        }

        let time = AVAudioTime(hostTime: 1000)
        mixer.mixSystem(buffer, at: time)

        // Wait for async processing
        Thread.sleep(forTimeInterval: 0.1)

        // Level should now be non-zero
        XCTAssertGreaterThan(mixer.level, 0.5, "level should reflect high amplitude signal")
    }

    func testHandlesConcurrentSystemAndMicCalls() throws {
        let mixer = AudioMixer(targetSampleRate: 16_000)
        let expectation = self.expectation(description: "frames emitted")
        expectation.expectedFulfillmentCount = 5
        expectation.assertForOverFulfill = false   // 20 concurrent frames may over-fulfill — that's fine
        let counter = Counter()                     // serialized counter (frames arrive on the mixer's serial queue)

        mixer.onFrame = { _ in
            counter.increment()
            expectation.fulfill()
        }

        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600)!
        buffer.frameLength = 1600
        for i in 0..<Int(buffer.frameLength) {
            buffer.floatChannelData![0][i] = 0.5
        }

        // Simulate concurrent calls from SC and mic tap
        DispatchQueue.global().async {
            for i in 0..<10 {
                let time = AVAudioTime(hostTime: UInt64(1000 + i * 100))
                mixer.mixSystem(buffer, at: time)
            }
        }

        DispatchQueue.global().async {
            for i in 0..<10 {
                let time = AVAudioTime(hostTime: UInt64(1000 + i * 100))
                mixer.mixMic(buffer, at: time)
            }
        }

        wait(for: [expectation], timeout: 2.0)

        // Should have emitted frames without crashes
        XCTAssertGreaterThanOrEqual(counter.value, 5, "should emit frames from concurrent input")
    }
}

/// Thread-safe counter for the concurrent-emit test (onFrame may fire from concurrent producers).
private final class Counter: @unchecked Sendable {
    private let lock = NSLock(); private var _v = 0
    func increment() { lock.lock(); _v += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return _v }
}

// Helper to box values for safe capture
final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) {
        self.value = value
    }
}
