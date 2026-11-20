import AVFoundation

/// Captures the default microphone and delivers 16 kHz, 16-bit mono PCM in 50 ms chunks on the main queue.
final class MicCapture {
    var onChunk: ((Data) -> Void)? {
        get { resampler.onChunk }
        set { resampler.onChunk = newValue }
    }

    private let engine = AVAudioEngine()
    private let echoCancellation: Bool
    private let resampler = PCMResampler()
    private var configObserver: NSObjectProtocol?

    struct CaptureError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    init(echoCancellation: Bool) {
        self.echoCancellation = echoCancellation
    }

    func start() throws {
        if echoCancellation {
            do { try engine.inputNode.setVoiceProcessingEnabled(true) }
            catch { NSLog("Pineapple: echo cancellation unavailable: \(error)") }
        }
        try installTapAndStart()
        // Headphones plugged in, input device changed, etc.: the engine stops; restart it.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.engine.inputNode.removeTap(onBus: 0)
            try? self.installTapAndStart()
        }
    }

    func stop() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        if echoCancellation { try? engine.inputNode.setVoiceProcessingEnabled(false) }
    }

    private func installTapAndStart() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw CaptureError(message: "No microphone found")
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.resampler.process(buffer)
        }
        engine.prepare()
        try engine.start()
    }
}
