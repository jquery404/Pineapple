import AVFoundation
import CoreGraphics
import ScreenCaptureKit

/// Captures everything the Mac is playing (Zoom, Meet, Teams, browser...) with ScreenCaptureKit,
/// audio only, and delivers 16 kHz, 16-bit mono PCM in 50 ms chunks on the main queue.
/// Needs the Screen Recording permission (macOS 13 has no audio-only permission).
final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    var onChunk: ((Data) -> Void)? {
        get { resampler.onChunk }
        set { resampler.onChunk = newValue }
    }
    var onStopped: ((String) -> Void)?

    private let resampler = PCMResampler()
    private let queue = DispatchQueue(label: "pineapple.system-audio")
    private var stream: SCStream?

    struct CaptureError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// Shows the macOS prompt (first time only). macOS needs the app reopened after it's granted.
    static func requestPermission() { CGRequestScreenCaptureAccess() }

    func start(completion: @escaping (Error?) -> Void) {
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, error in
            DispatchQueue.main.async {
                guard let display = content?.displays.first else {
                    completion(error ?? CaptureError(message: "No display found"))
                    return
                }
                let config = SCStreamConfiguration()
                config.capturesAudio = true
                config.excludesCurrentProcessAudio = true
                config.sampleRate = 48000
                config.channelCount = 2
                // Video can't be turned off; keep it as small and slow as possible.
                config.width = 2
                config.height = 2
                config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

                let filter = SCContentFilter(display: display, excludingWindows: [])
                let stream = SCStream(filter: filter, configuration: config, delegate: self)
                do {
                    try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: self.queue)
                } catch {
                    completion(error)
                    return
                }
                stream.startCapture { error in
                    DispatchQueue.main.async {
                        if error == nil { self.stream = stream }
                        completion(error)
                    }
                }
            }
        }
    }

    func stop() {
        stream?.stopCapture { _ in }
        stream = nil
    }

    // MARK: SCStreamOutput (runs on `queue`)

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid,
              var description = sampleBuffer.formatDescription?.audioStreamBasicDescription,
              let format = AVAudioFormat(streamDescription: &description) else { return }
        let frames = AVAudioFrameCount(sampleBuffer.numSamples)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        buffer.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
        guard status == noErr else { return }
        resampler.process(buffer)
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async {
            self.stream = nil
            self.onStopped?(error.localizedDescription)
        }
    }
}
