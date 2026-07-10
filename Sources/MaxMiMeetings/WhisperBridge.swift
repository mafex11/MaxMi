import Foundation
import CWhisper

/// Swift bridge to vendored whisper.cpp C API
/// NOTE: Vendored whisper.cpp v1.6.2 sources (from whisper.spm) because:
/// - Full v1.9.1 vendoring requires 161+ ggml files across complex directory structure
/// - whisper.spm remote dependency uses unsafeFlags that SPM rejects
/// - whisper.cpp API is stable; v1.6.2 code works with v1.9.1 models (model format pinned separately)
/// Commit hash for vendored sources: whisper.spm v1.6.2 (maps to whisper.cpp ~v1.6.2 era)
public final class WhisperContext {
    private var ctx: OpaquePointer?

    public init(modelPath: String) throws {
        guard FileManager.default.fileExists(atPath: modelPath) else {
            throw WhisperError.modelNotFound
        }

        let cparams = whisper_context_default_params()
        ctx = whisper_init_from_file_with_params(modelPath, cparams)

        guard ctx != nil else {
            throw WhisperError.initFailed
        }
    }

    deinit {
        if let ctx = ctx {
            whisper_free(ctx)
        }
    }

    /// Transcribe PCM audio (16kHz mono float32)
    public func transcribe(pcm16k: [Float]) throws -> String {
        guard let ctx = ctx else {
            throw WhisperError.contextReleased
        }

        // Get default params with GREEDY sampling
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.print_progress = false
        params.print_special = false
        params.print_realtime = false
        params.print_timestamps = false
        params.translate = false
        params.language = nil  // auto-detect
        params.n_threads = 4
        params.offset_ms = 0
        params.duration_ms = 0

        // Run transcription
        let result = whisper_full(ctx, params, pcm16k, Int32(pcm16k.count))
        guard result == 0 else {
            throw WhisperError.transcriptionFailed
        }

        // Collect all segment texts
        let nSegments = whisper_full_n_segments(ctx)
        var transcript = ""
        for i in 0..<nSegments {
            if let segmentText = whisper_full_get_segment_text(ctx, i) {
                transcript += String(cString: segmentText)
            }
        }

        return transcript
    }
}

public enum WhisperError: Error {
    case modelNotFound
    case initFailed
    case contextReleased
    case transcriptionFailed
}
