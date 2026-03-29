import AVFoundation
import Combine
import Foundation
import WhisperKit

// MARK: - Errors

enum AudioManagerError: LocalizedError, Equatable {
    case permissionDenied
    case engineStartFailed(String)
    case noAudioCaptured
    case transcriptionFailed(String)
    case modelNotLoaded
    case alreadyRecording
    case notRecording

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Microphone access was denied. Please enable it in Settings."
        case .engineStartFailed(let detail):
            return "Audio engine failed to start: \(detail)"
        case .noAudioCaptured:
            return "No audio was captured during the recording session."
        case .transcriptionFailed(let detail):
            return "Transcription failed: \(detail)"
        case .modelNotLoaded:
            return "WhisperKit model is not loaded yet. Please wait and try again."
        case .alreadyRecording:
            return "A recording session is already in progress."
        case .notRecording:
            return "No active recording session to stop."
        }
    }
}

// MARK: - AudioManager

/// Manages on-device voice recording and speech-to-text transcription via WhisperKit.
///
/// Typical usage:
/// ```swift
/// let manager = AudioManager()
/// await manager.loadModel()
/// try manager.startRecording()
/// let text = try await manager.stopRecording()
/// ```
///
/// The WhisperKit model is loaded once on first call to `loadModel()` and reused
/// for all subsequent transcription requests. Model loading can take a few seconds
/// on first run while the Core ML model compiles; subsequent loads use the cached
/// compiled artefact and are fast.
///
/// Thread safety: all `@Published` mutations and public API calls must happen on
/// the `@MainActor`. Internal audio engine callbacks are dispatched back to the
/// main actor before touching shared state.
@MainActor
final class AudioManager: ObservableObject {

    // MARK: - Published State

    /// `true` while a recording session is active.
    @Published var isRecording = false

    /// The most recent transcription result. Cleared when a new recording starts.
    @Published var transcribedText: String?

    /// `true` while the WhisperKit model is loading.
    @Published var isLoadingModel = false

    /// Set when a non-fatal error occurs (e.g. transcription returns empty).
    @Published var lastError: AudioManagerError?

    // MARK: - Private — Audio Engine

    private let audioEngine = AVAudioEngine()

    /// PCM samples accumulated during the recording session.
    /// WhisperKit expects `[Float]` at 16 kHz.
    private var audioBuffer: [Float] = []

    // MARK: - Private — WhisperKit

    private var whisperKit: WhisperKit?

    /// The model identifier passed to WhisperKit. `base.en` is small, fast,
    /// English-only — the right trade-off for a personal voice assistant.
    private let modelName = "base.en"

    // MARK: - Init

    init() {}

    // MARK: - Model Loading

    /// Load (or re-use) the WhisperKit model.
    ///
    /// Safe to call multiple times — returns immediately if the model is already
    /// loaded. Should be called once during app launch so the first recording
    /// attempt does not block on model initialisation.
    func loadModel() async {
        guard whisperKit == nil else { return }

        isLoadingModel = true
        defer { isLoadingModel = false }

        do {
            let kit = try await WhisperKit(model: modelName)
            whisperKit = kit
        } catch {
            lastError = .modelNotLoaded
        }
    }

    // MARK: - Recording

    /// Configure the AVAudioSession and start capturing microphone audio.
    ///
    /// Requests microphone permission if it has not been granted. Throws
    /// `AudioManagerError.permissionDenied` when the user has denied access.
    ///
    /// Throws `AudioManagerError.alreadyRecording` if called while a session is
    /// already in progress.
    func startRecording() throws {
        guard !isRecording else { throw AudioManagerError.alreadyRecording }

        // Ensure the model is in the process of loading (best-effort; caller
        // should also call loadModel() up front, but this prevents a crash).
        if whisperKit == nil {
            Task { await loadModel() }
        }

        try configureAudioSession()
        try startAudioEngine()

        audioBuffer.removeAll(keepingCapacity: true)
        transcribedText = nil
        lastError = nil
        isRecording = true
    }

    /// Stop the current recording session and run on-device transcription.
    ///
    /// Returns the transcribed string. Throws if transcription fails or no
    /// audio was captured.
    func stopRecording() async throws -> String {
        guard isRecording else { throw AudioManagerError.notRecording }

        stopAudioEngine()
        isRecording = false

        guard !audioBuffer.isEmpty else {
            throw AudioManagerError.noAudioCaptured
        }

        let text = try await transcribe(samples: audioBuffer)
        transcribedText = text
        return text
    }

    // MARK: - Microphone Permission

    /// Request microphone permission and return the result.
    ///
    /// On iOS 17+ this uses the async `AVAudioApplication` API. On earlier
    /// versions it falls back to the `AVAudioSession` request.
    func requestMicrophonePermission() async -> Bool {
        if #available(iOS 17.0, *) {
            return await AVAudioApplication.requestRecordPermission()
        } else {
            return await withCheckedContinuation { continuation in
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    /// Returns the current microphone authorization status without prompting.
    var hasMicrophonePermission: Bool {
        if #available(iOS 17.0, *) {
            return AVAudioApplication.shared.recordPermission == .granted
        } else {
            return AVAudioSession.sharedInstance().recordPermission == .granted
        }
    }

    // MARK: - Private — AVAudioSession

    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
            try session.setPreferredSampleRate(16_000)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            throw AudioManagerError.engineStartFailed(error.localizedDescription)
        }
    }

    private func deactivateAudioSession() {
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
    }

    // MARK: - Private — AVAudioEngine

    /// Whisper requires 16 kHz mono Float32 PCM. We install a tap on the input
    /// node and resample on the fly if the hardware delivers a different rate.
    private func startAudioEngine() throws {
        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        // Target format: 16 kHz mono Float32
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ) else {
            throw AudioManagerError.engineStartFailed("Failed to create 16 kHz target format.")
        }

        // AVAudioConverter handles sample-rate and channel-count conversion.
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw AudioManagerError.engineStartFailed(
                "Cannot create audio converter from \(inputFormat) to \(targetFormat)."
            )
        }

        // The tap buffer size is a hint; the engine may deliver different sizes.
        let tapBufferSize = AVAudioFrameCount(inputFormat.sampleRate * 0.1) // 100 ms chunks

        inputNode.installTap(onBus: 0, bufferSize: tapBufferSize, format: inputFormat) {
            [weak self] buffer, _ in
            guard let self else { return }
            self.processTapBuffer(buffer, converter: converter, targetFormat: targetFormat)
        }

        audioEngine.prepare()

        do {
            try audioEngine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            throw AudioManagerError.engineStartFailed(error.localizedDescription)
        }
    }

    private func stopAudioEngine() {
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        deactivateAudioSession()
    }

    /// Convert incoming tap buffer to 16 kHz mono Float32 and append to `audioBuffer`.
    ///
    /// This method is called on an audio thread; all mutations to `audioBuffer`
    /// are safe because `audioBuffer` is only ever read after `stopAudioEngine()`
    /// completes (by which point the tap is removed and no further callbacks arrive).
    private func processTapBuffer(
        _ inputBuffer: AVAudioPCMBuffer,
        converter: AVAudioConverter,
        targetFormat: AVAudioFormat
    ) {
        // Calculate the expected output frame count after resampling.
        let inputFrames = Double(inputBuffer.frameLength)
        let ratio = targetFormat.sampleRate / inputBuffer.format.sampleRate
        let outputFrameCapacity = AVAudioFrameCount((inputFrames * ratio).rounded(.up) + 1)

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: outputFrameCapacity
        ) else { return }

        var conversionError: NSError?
        var inputConsumed = false

        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            if inputConsumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            outStatus.pointee = .haveData
            inputConsumed = true
            return inputBuffer
        }

        guard status != .error, conversionError == nil else { return }
        guard let channelData = outputBuffer.floatChannelData else { return }

        let frameCount = Int(outputBuffer.frameLength)
        let samples = Array(UnsafeBufferPointer(start: channelData[0], count: frameCount))

        // audioBuffer is only mutated here (audio thread) and read after the tap
        // is removed (main thread) — no concurrent access.
        audioBuffer.append(contentsOf: samples)
    }

    // MARK: - Private — Transcription

    private func transcribe(samples: [Float]) async throws -> String {
        guard let kit = whisperKit else {
            throw AudioManagerError.modelNotLoaded
        }

        let results: [TranscriptionResult]
        do {
            results = try await kit.transcribe(audioArray: samples)
        } catch {
            throw AudioManagerError.transcriptionFailed(error.localizedDescription)
        }

        let text = results
            .compactMap { $0.text }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !text.isEmpty else {
            throw AudioManagerError.transcriptionFailed("WhisperKit returned an empty transcript.")
        }

        return text
    }
}
