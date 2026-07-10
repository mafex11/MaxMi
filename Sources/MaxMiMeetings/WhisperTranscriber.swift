import Foundation

/// Protocol for whisper bridge to allow testing without real model
protocol WhisperBridging {
    func transcribe(pcm16k: [Float]) throws -> String
}

/// Real bridge wrapping WhisperContext
final class RealWhisperBridge: WhisperBridging {
    private let context: WhisperContext

    init(modelPath: String) throws {
        self.context = try WhisperContext(modelPath: modelPath)
    }

    func transcribe(pcm16k: [Float]) throws -> String {
        try context.transcribe(pcm16k: pcm16k)
    }
}

/// WhisperTranscriber actor implementing the Transcribing protocol
/// Windows: 30s chunks with 2s overlap, transcribes each window and stitches results
public actor WhisperTranscriber: Transcribing {
    private let modelURL: URL
    private let bridgeFactory: (String) throws -> any WhisperBridging

    private var bridge: (any WhisperBridging)?
    private var buffer: [Float] = []
    private var windowResults: [String] = []
    private var onPartial: (@Sendable (String) -> Void)?
    private var firstWindow = true

    private let windowSamples = 30 * 16_000  // 30 seconds at 16kHz
    private let overlapSamples = 2 * 16_000  // 2 seconds overlap

    /// Public convenience initializer using real WhisperContext
    public init(modelURL: URL) {
        self.modelURL = modelURL
        self.bridgeFactory = { path in try RealWhisperBridge(modelPath: path) }
    }

    /// Internal init for testing with custom bridge
    init(
        modelURL: URL,
        bridgeFactory: @escaping (String) throws -> any WhisperBridging
    ) {
        self.modelURL = modelURL
        self.bridgeFactory = bridgeFactory
    }

    public func start() async throws {
        // Create the bridge inside the actor
        self.bridge = try bridgeFactory(modelURL.path)
    }

    public func feed(_ frame: PCMFrame) async {
        buffer.append(contentsOf: frame.samples)

        // First window: trigger at windowSamples
        // Subsequent windows: trigger when we have overlap + windowSamples (i.e., new data fills a window)
        let threshold = firstWindow ? windowSamples : (overlapSamples + windowSamples)

        while buffer.count >= threshold {
            await processWindow()
        }
    }

    public func finish() async -> String {
        // Process any remaining partial window
        if !buffer.isEmpty {
            await processWindow()
        }

        // Stitch all windows together
        return RollingStitch.stitch(windowResults)
    }

    public func setOnPartial(_ cb: @escaping @Sendable (String) -> Void) async {
        self.onPartial = cb
    }

    // MARK: - Private

    private func processWindow() async {
        guard let bridge = bridge else { return }

        // Take window-sized chunk
        let windowData = Array(buffer.prefix(windowSamples))

        // Transcribe synchronously within the actor (WhisperBridge is actor-isolated)
        // The bridge is created inside this actor and never escapes, so it's safe to call here.
        // whisper.cpp is blocking but we accept that for now (session actor + UI updates are separate).
        let text: String
        do {
            text = try bridge.transcribe(pcm16k: windowData)
        } catch {
            text = "" // Failed transcription, continue
        }

        // Add to results
        windowResults.append(text)
        firstWindow = false

        // Keep overlap samples, drop the rest
        if buffer.count > overlapSamples {
            buffer.removeFirst(buffer.count - overlapSamples)
        } else {
            buffer.removeAll()
        }

        // Fire partial with stitched result so far
        if let onPartial = onPartial {
            let stitched = RollingStitch.stitch(windowResults)
            onPartial(stitched)
        }
    }
}
