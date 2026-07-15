import Foundation
import MaxMiCore
@preconcurrency import AVFoundation
@preconcurrency import ScreenCaptureKit
@preconcurrency import CoreMedia
import CoreGraphics

/// AudioCapture captures system audio (via SCStream scoped to a meeting app) and microphone audio
/// (via AVAudioEngine input tap), feeding both into an AudioMixer that normalizes and emits 16kHz mono PCMFrames.
///
/// This class is LIVE-ONLY (requires real audio devices, screen recording permission, and shareable content).
/// It's compile-checked but not unit-tested. The AudioMixer offline-buffer tests provide CI coverage.
///
/// Algorithm (from spec Task 6):
/// 1. Get shareable content via SCShareableContent.getExcludingDesktopWindows(_:onScreenWindowsOnly:)
/// 2. Find the SCRunningApplication matching CaptureRequest.pid or bundleID
/// 3. Find its on-screen SCWindow, map that window's frame to the SCDisplay it's on (fallback: app's main display)
/// 4. Build SCContentFilter(display:includingApplications:exceptingWindows:) scoped to that display+app
/// 5. Start SCStream with capturesAudio=true, excludesCurrentProcessAudio=true -> feed mixer.mixSystem
/// 6. Start AVAudioEngine input tap -> feed mixer.mixMic
/// 7. Return "system+mic" on success, or "mic-only" if SCStream fails or captureSystem==false
/// 8. Store resolved window frame for resolvedWindowFrame() so the panel can dock to the meeting screen
/// 9. Handle AVAudioEngineConfigurationChange (device switch) by restarting the tap
public final class AudioCapture: NSObject, AudioCaptureControlling, @unchecked Sendable {
    private let mixer: AudioMixer
    private var stream: SCStream?
    private var engine: AVAudioEngine?
    private var resolvedFrame: CGRect?
    private let queue = DispatchQueue(label: "com.maxmi.audiocapture", qos: .userInitiated)

    public init(mixer: AudioMixer) {
        self.mixer = mixer
        super.init()
    }

    @MainActor
    public func start(_ request: CaptureRequest) async throws -> String {
        // If captureSystem is false, skip SCStream and go directly to mic-only
        if !request.captureSystem {
            try await startMicOnly()
            return "mic-only"
        }

        // Attempt system+mic capture
        do {
            // 1. Get shareable content (async API)
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

            // 2. Find the SCRunningApplication matching request.pid or bundleID
            guard let app = content.applications.first(where: { $0.processID == request.pid || $0.bundleIdentifier == request.bundleID }) else {
                // No shareable app found -> degrade to mic-only
                try await startMicOnly()
                return "mic-only"
            }

            // 3. Find its on-screen SCWindow and map to the SCDisplay it's on
            let appWindows = content.windows.filter { $0.owningApplication?.processID == app.processID }
            let window = appWindows.first(where: { $0.isOnScreen })

            guard let fallbackDisplay = content.displays.first else {
                try await startMicOnly()
                return "mic-only"
            }
            let display: SCDisplay
            if let win = window {
                // Map window frame to the display it's on
                resolvedFrame = win.frame
                display = content.displays.first { displayContains($0, window: win) } ?? fallbackDisplay
            } else {
                // Fallback: use the app's main display (first display)
                display = fallbackDisplay
            }

            // 4. Build SCContentFilter scoped to the display+app
            let filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])

            // 5. Configure and start SCStream
            let config = SCStreamConfiguration()
            config.capturesAudio = true
            config.excludesCurrentProcessAudio = true
            config.sampleRate = 48000  // Typical SCStream sample rate

            let stream = SCStream(filter: filter, configuration: config, delegate: self)
            self.stream = stream

            // Add audio stream output
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
            try await stream.startCapture()

            // 6. Start mic tap
            try await startMicTap()

            return "system+mic"
        } catch {
            SafeLogger.shared.log(
                .warning,
                subsystem: .meeting,
                event: .audioFallbackToMicrophone,
                error: error
            )
            // SCStream failed (permission denied, app not shareable, etc.) -> degrade to mic-only
            if let stream {
                try? await stream.stopCapture()
                self.stream = nil
            }
            if let engine {
                engine.inputNode.removeTap(onBus: 0)
                engine.stop()
                NotificationCenter.default.removeObserver(
                    self, name: .AVAudioEngineConfigurationChange, object: engine
                )
                self.engine = nil
            }
            try await startMicOnly()
            return "mic-only"
        }
    }

    @MainActor
    public func stop() async {
        // Stop SCStream
        if let stream = stream {
            do {
                try await stream.stopCapture()
            } catch {
                // Ignore stop errors
            }
            self.stream = nil
        }

        // Stop AVAudioEngine
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil

        NotificationCenter.default.removeObserver(self)
        mixer.flush()
    }

    public func setFrameHandler(_ cb: @escaping @Sendable (PCMFrame) -> Void) async {
        mixer.onFrame = cb
    }

    public func level() async -> Float {
        return await MainActor.run {
            mixer.level
        }
    }

    public func resolvedWindowFrame() async -> CGRect? {
        return await MainActor.run {
            resolvedFrame
        }
    }

    // MARK: - Private Helpers

    private func startMicOnly() async throws {
        try await startMicTap()
    }

    @MainActor
    private func startMicTap() async throws {
        let engine = AVAudioEngine()
        self.engine = engine

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        // Install tap on input node to capture mic audio
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, time in
            guard let self = self else { return }
            let duration = UInt64(Double(buffer.frameLength) / buffer.format.sampleRate * 1_000_000_000)
            let now = DispatchTime.now().uptimeNanoseconds
            self.mixer.mixMic(buffer, timestampNs: now - min(now, duration))
        }

        // Observe configuration changes (device switch)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioEngineConfigurationChange),
            name: .AVAudioEngineConfigurationChange,
            object: engine
        )

        try engine.start()
    }

    @objc private func handleAudioEngineConfigurationChange() {
        // Restart mic tap on device change
        Task { @MainActor in
            guard let engine = self.engine else { return }
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            NotificationCenter.default.removeObserver(
                self, name: .AVAudioEngineConfigurationChange, object: engine
            )
            self.engine = nil
            do {
                try await startMicTap()
            } catch {
                SafeLogger.shared.log(
                    .error,
                    subsystem: .meeting,
                    event: .audioDeviceRestartFailed,
                    error: error
                )
            }
        }
    }

    /// Check if a display contains a window (window frame intersects display frame)
    private func displayContains(_ display: SCDisplay, window: SCWindow) -> Bool {
        let displayFrame = CGRect(
            x: CGFloat(display.frame.origin.x),
            y: CGFloat(display.frame.origin.y),
            width: CGFloat(display.frame.width),
            height: CGFloat(display.frame.height)
        )
        return displayFrame.intersects(window.frame)
    }
}

// MARK: - SCStreamDelegate

extension AudioCapture: SCStreamDelegate {
    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        SafeLogger.shared.log(
            .error,
            subsystem: .meeting,
            event: .audioStreamStoppedWithError,
            error: error
        )
        // Don't crash; let the session handle error state
    }
}

// MARK: - SCStreamOutput

extension AudioCapture: SCStreamOutput {
    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }

        // Convert CMSampleBuffer to AVAudioPCMBuffer
        guard let audioBuffer = convertToAVAudioPCMBuffer(sampleBuffer) else { return }

        // Extract timestamp from sample buffer
        let duration = UInt64(Double(audioBuffer.frameLength) / audioBuffer.format.sampleRate * 1_000_000_000)
        let now = DispatchTime.now().uptimeNanoseconds
        mixer.mixSystem(audioBuffer, timestampNs: now - min(now, duration))
    }

    /// Convert CMSampleBuffer to AVAudioPCMBuffer
    /// Standard path for ScreenCaptureKit audio output
    private func convertToAVAudioPCMBuffer(_ sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else { return nil }
        guard let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else { return nil }

        let audioFormat = AVAudioFormat(streamDescription: asbd)!
        let numFrames = CMSampleBufferGetNumSamples(sampleBuffer)

        guard let audioBuffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: AVAudioFrameCount(numFrames)) else { return nil }
        audioBuffer.frameLength = AVAudioFrameCount(numFrames)

        // Copy audio data
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }
        var length: Int = 0
        var data: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &data)
        guard status == kCMBlockBufferNoErr, let audioData = data else { return nil }

        let bytesPerFrame = Int(asbd.pointee.mBytesPerFrame)
        let totalBytes = min(length, Int(numFrames) * bytesPerFrame)

        if let channelData = audioBuffer.floatChannelData {
            // Assume float32 interleaved or non-interleaved
            let floatData = audioData.withMemoryRebound(to: Float.self, capacity: totalBytes / MemoryLayout<Float>.size) { $0 }
            for ch in 0..<Int(audioFormat.channelCount) {
                for frame in 0..<Int(numFrames) {
                    channelData[ch][frame] = floatData[frame * Int(audioFormat.channelCount) + ch]
                }
            }
        }

        return audioBuffer
    }
}
