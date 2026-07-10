import Foundation
@preconcurrency import AVFoundation

/// AudioMixer normalizes all audio sources to 16kHz mono PCM and mixes them together.
/// Guards state with a serial DispatchQueue since SCStream delivery queue and AVAudioEngine
/// mic tap fire concurrently. Owns ALL resampling via AVAudioConverter per source.
public final class AudioMixer {
    private let targetSampleRate: Double
    private let mixQueue = DispatchQueue(label: "com.maxmi.audiomixer", qos: .userInitiated)

    // Per-source converters (created on-demand, keyed by format identifier)
    private var systemConverter: AVAudioConverter?
    private var micConverter: AVAudioConverter?

    // Running state
    private var currentLevel: Float = 0.0
    private let targetFormat: AVAudioFormat

    public var onFrame: (@Sendable (PCMFrame) -> Void)?

    public var level: Float {
        mixQueue.sync { currentLevel }
    }

    public init(targetSampleRate: Double = 16_000) {
        self.targetSampleRate = targetSampleRate
        // Target format: 16kHz mono float32
        self.targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: targetSampleRate, channels: 1, interleaved: false)!
    }

    public func mixSystem(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
        mixQueue.async { [weak self] in
            self?.processMix(buffer, time: time, isSystem: true)
        }
    }

    public func mixMic(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
        mixQueue.async { [weak self] in
            self?.processMix(buffer, time: time, isSystem: false)
        }
    }

    private func processMix(_ buffer: AVAudioPCMBuffer, time: AVAudioTime, isSystem: Bool) {
        // NOTE: do NOT early-return when onFrame is nil — the level meter must update regardless
        // of whether a frame handler is attached (the recorder UI polls `level` before wiring
        // a handler). onFrame is checked only at the emit step below.

        // Get or create converter for this source
        let converter: AVAudioConverter?
        if isSystem {
            if systemConverter == nil || systemConverter?.inputFormat != buffer.format {
                systemConverter = AVAudioConverter(from: buffer.format, to: targetFormat)
            }
            converter = systemConverter
        } else {
            if micConverter == nil || micConverter?.inputFormat != buffer.format {
                micConverter = AVAudioConverter(from: buffer.format, to: targetFormat)
            }
            converter = micConverter
        }

        guard let conv = converter else { return }

        // Calculate output frame capacity
        let inputFrames = AVAudioFrameCount(buffer.frameLength)
        let outputFrames = AVAudioFrameCount(Double(inputFrames) * targetSampleRate / buffer.format.sampleRate)
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrames) else { return }

        // Convert to target format
        var error: NSError?
        var inputUsed = false
        let status = conv.convert(to: outputBuffer, error: &error) { inNumPackets, outStatus in
            if inputUsed {
                outStatus.pointee = .noDataNow
                return nil
            }
            inputUsed = true
            outStatus.pointee = .haveData
            return buffer
        }

        guard status != .error, outputBuffer.frameLength > 0 else { return }

        // Extract samples (already mono after conversion)
        let channelData = outputBuffer.floatChannelData![0]
        let samples = Array(UnsafeBufferPointer(start: channelData, count: Int(outputBuffer.frameLength)))

        // Compute RMS level
        let rms = sqrt(samples.reduce(0.0) { $0 + $1 * $1 } / Float(samples.count))
        currentLevel = rms

        // Emit PCMFrame with host timestamp (only if a handler is attached; level already updated).
        if let onFrame = onFrame {
            let frame = PCMFrame(samples: samples, hostTimeNs: time.hostTime)
            onFrame(frame)
        }
    }
}
