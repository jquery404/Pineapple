import AVFoundation

/// Turns float PCM buffers of any rate / channel count into 16 kHz, 16-bit mono chunks of 50 ms.
/// Not thread safe: call `process` from one thread. Chunks are delivered on the main queue.
final class PCMResampler {
    var onChunk: ((Data) -> Void)?

    static let target = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                      sampleRate: Double(TranscribeClient.sampleRate),
                                      channels: 1, interleaved: true)!
    private static let chunkBytes = TranscribeClient.sampleRate * 2 / 20 // 50 ms

    private var mono: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var pending = Data()

    func process(_ buffer: AVAudioPCMBuffer) {
        guard let source = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard frames > 0, channels > 0 else { return }

        let rate = buffer.format.sampleRate
        if mono?.sampleRate != rate {
            mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)
            converter = mono.flatMap { AVAudioConverter(from: $0, to: Self.target) }
        }
        guard let mono, let converter,
              let monoBuffer = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: AVAudioFrameCount(frames)) else { return }
        monoBuffer.frameLength = AVAudioFrameCount(frames)

        // Mix all channels down to one.
        let dst = monoBuffer.floatChannelData![0]
        let interleaved = buffer.format.isInterleaved
        let stride = buffer.stride
        for i in 0..<frames {
            var sum: Float = 0
            for c in 0..<channels {
                sum += interleaved ? source[0][i * stride + c] : source[c][i]
            }
            dst[i] = sum / Float(channels)
        }

        let capacity = AVAudioFrameCount(Double(frames) * Self.target.sampleRate / rate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: Self.target, frameCapacity: capacity) else { return }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return monoBuffer
        }
        guard error == nil, out.frameLength > 0, let samples = out.int16ChannelData else { return }
        pending.append(Data(bytes: samples[0], count: Int(out.frameLength) * 2))

        while pending.count >= Self.chunkBytes {
            let chunk = Data(pending.prefix(Self.chunkBytes))
            pending.removeFirst(Self.chunkBytes)
            DispatchQueue.main.async { [weak self] in self?.onChunk?(chunk) }
        }
    }
}
