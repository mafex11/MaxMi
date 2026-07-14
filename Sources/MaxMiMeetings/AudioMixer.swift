import Foundation
@preconcurrency import AVFoundation

enum AudioSource: Sendable {
    case system
    case microphone
}

/// Pure timestamp-alignment core. Inputs are already 16 kHz mono. Frames are emitted
/// in chronological 100 ms buckets, with a short holdback so the other source can arrive.
struct TimestampAlignedAudioBuffer {
    struct Slot {
        var system: [Float]
        var microphone: [Float]
        var systemMask: [Bool]
        var microphoneMask: [Bool]

        init(count: Int) {
            system = .init(repeating: 0, count: count)
            microphone = .init(repeating: 0, count: count)
            systemMask = .init(repeating: false, count: count)
            microphoneMask = .init(repeating: false, count: count)
        }

        var hasSystem: Bool { systemMask.contains(true) }
        var hasMicrophone: Bool { microphoneMask.contains(true) }
    }

    let sampleRate: Double
    let frameSamples: Int
    let holdbackSamples: Int64
    private(set) var slots: [Int64: Slot] = [:]
    private(set) var latestEndSample: Int64 = 0

    init(sampleRate: Double = 16_000, frameDurationMs: Int = 100, holdbackMs: Int = 150) {
        self.sampleRate = sampleRate
        self.frameSamples = max(1, Int(sampleRate * Double(frameDurationMs) / 1_000))
        self.holdbackSamples = Int64(sampleRate * Double(holdbackMs) / 1_000)
    }

    mutating func ingest(source: AudioSource, samples: [Float], timestampNs: UInt64) -> [PCMFrame] {
        guard !samples.isEmpty else { return [] }
        let startSample = Int64((Double(timestampNs) / 1_000_000_000) * sampleRate)
        latestEndSample = max(latestEndSample, startSample + Int64(samples.count))

        var sourceOffset = 0
        var absoluteSample = startSample
        while sourceOffset < samples.count {
            let slotIndex = floorDiv(absoluteSample, Int64(frameSamples))
            let slotStart = slotIndex * Int64(frameSamples)
            let destinationOffset = Int(absoluteSample - slotStart)
            let count = min(frameSamples - destinationOffset, samples.count - sourceOffset)
            var slot = slots[slotIndex] ?? Slot(count: frameSamples)
            for index in 0..<count {
                let destination = destinationOffset + index
                let value = samples[sourceOffset + index]
                switch source {
                case .system:
                    slot.system[destination] = value
                    slot.systemMask[destination] = true
                case .microphone:
                    slot.microphone[destination] = value
                    slot.microphoneMask[destination] = true
                }
            }
            slots[slotIndex] = slot
            sourceOffset += count
            absoluteSample += Int64(count)
        }
        return drain(force: false)
    }

    mutating func flush() -> [PCMFrame] {
        drain(force: true)
    }

    private mutating func drain(force: Bool) -> [PCMFrame] {
        var output: [PCMFrame] = []
        let oldBefore = latestEndSample - holdbackSamples
        for slotIndex in slots.keys.sorted() {
            guard let slot = slots[slotIndex] else { continue }
            let slotEnd = (slotIndex + 1) * Int64(frameSamples)
            let ready = force || (slot.hasSystem && slot.hasMicrophone) || slotEnd <= oldBefore
            guard ready else { break }

            var mixed = [Float](repeating: 0, count: frameSamples)
            for index in 0..<frameSamples {
                switch (slot.systemMask[index], slot.microphoneMask[index]) {
                case (true, true):
                    mixed[index] = clamp((slot.system[index] + slot.microphone[index]) * 0.5)
                case (true, false):
                    mixed[index] = clamp(slot.system[index])
                case (false, true):
                    mixed[index] = clamp(slot.microphone[index])
                case (false, false):
                    mixed[index] = 0
                }
            }
            let startSample = slotIndex * Int64(frameSamples)
            let timestampNs = UInt64(max(0, Double(startSample) / sampleRate * 1_000_000_000))
            output.append(PCMFrame(samples: mixed, hostTimeNs: timestampNs))
            slots.removeValue(forKey: slotIndex)
        }
        return output
    }

    private func floorDiv(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let quotient = lhs / rhs
        let remainder = lhs % rhs
        return remainder < 0 ? quotient - 1 : quotient
    }

    private func clamp(_ value: Float) -> Float {
        min(1, max(-1, value))
    }
}

private final class ConversionInputState: @unchecked Sendable {
    var used = false
}

/// Normalizes system and microphone audio to 16 kHz mono, then aligns both sources
/// on one timestamped timeline before emitting PCM frames.
public final class AudioMixer: @unchecked Sendable {
    private let targetSampleRate: Double
    private let mixQueue = DispatchQueue(label: "com.maxmi.audiomixer", qos: .userInitiated)
    private var systemConverter: AVAudioConverter?
    private var micConverter: AVAudioConverter?
    private var currentLevel: Float = 0
    private let targetFormat: AVAudioFormat
    private var aligned: TimestampAlignedAudioBuffer
    private var frameHandler: (@Sendable (PCMFrame) -> Void)?

    public var onFrame: (@Sendable (PCMFrame) -> Void)? {
        get { mixQueue.sync { frameHandler } }
        set { mixQueue.sync { frameHandler = newValue } }
    }

    public var level: Float { mixQueue.sync { currentLevel } }

    public init(targetSampleRate: Double = 16_000) {
        self.targetSampleRate = targetSampleRate
        targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        )!
        aligned = TimestampAlignedAudioBuffer(sampleRate: targetSampleRate)
    }

    public func mixSystem(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
        enqueue(buffer, source: .system, timestampNs: timestampNs(for: time, buffer: buffer))
    }

    public func mixMic(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
        enqueue(buffer, source: .microphone, timestampNs: timestampNs(for: time, buffer: buffer))
    }

    public func mixSystem(_ buffer: AVAudioPCMBuffer, timestampNs: UInt64) {
        enqueue(buffer, source: .system, timestampNs: timestampNs)
    }

    public func mixMic(_ buffer: AVAudioPCMBuffer, timestampNs: UInt64) {
        enqueue(buffer, source: .microphone, timestampNs: timestampNs)
    }

    public func flush() {
        mixQueue.sync {
            emit(aligned.flush())
        }
    }

    private func enqueue(_ buffer: AVAudioPCMBuffer, source: AudioSource, timestampNs: UInt64) {
        mixQueue.async { [weak self] in
            self?.process(buffer, source: source, timestampNs: timestampNs)
        }
    }

    private func process(_ buffer: AVAudioPCMBuffer, source: AudioSource, timestampNs: UInt64) {
        let converter: AVAudioConverter?
        switch source {
        case .system:
            if systemConverter == nil || systemConverter?.inputFormat != buffer.format {
                systemConverter = AVAudioConverter(from: buffer.format, to: targetFormat)
            }
            converter = systemConverter
        case .microphone:
            if micConverter == nil || micConverter?.inputFormat != buffer.format {
                micConverter = AVAudioConverter(from: buffer.format, to: targetFormat)
            }
            converter = micConverter
        }
        guard let converter else { return }

        let ratio = targetSampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * ratio) + 32)
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }
        var error: NSError?
        let input = ConversionInputState()
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if input.used {
                outStatus.pointee = .noDataNow
                return nil
            }
            input.used = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, output.frameLength > 0, let channel = output.floatChannelData?[0] else {
            return
        }
        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
        let rms = sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count))
        currentLevel = max(rms, currentLevel * 0.8)
        emit(aligned.ingest(source: source, samples: samples, timestampNs: timestampNs))
    }

    private func emit(_ frames: [PCMFrame]) {
        guard let frameHandler else { return }
        for frame in frames { frameHandler(frame) }
    }

    private func timestampNs(for time: AVAudioTime, buffer: AVAudioPCMBuffer) -> UInt64 {
        if time.isHostTimeValid {
            return UInt64(max(0, AVAudioTime.seconds(forHostTime: time.hostTime) * 1_000_000_000))
        }
        let durationNs = UInt64(Double(buffer.frameLength) / buffer.format.sampleRate * 1_000_000_000)
        return DispatchTime.now().uptimeNanoseconds - min(durationNs, DispatchTime.now().uptimeNanoseconds)
    }
}
