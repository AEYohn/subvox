import AVFoundation

/// Collects microphone audio as 16 kHz mono while a dictation key is held. Fed from the audio
/// render thread through `AudioSink`, so everything here is behind a lock. Keeps a short
/// pre-roll so the first syllable isn't lost to key-press timing.
final class AudioClipRecorder: @unchecked Sendable {
    static let sampleRate: Double = 16_000
    static let prerollSeconds: Double = 0.3

    private let lock = NSLock()
    private let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                             channels: 1, interleaved: false)!
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private var isActive = false
    private var samples: [Float] = []
    /// Host time (seconds since boot) of `samples[0]`.
    private var startSeconds: TimeInterval?
    private var preroll: [Float] = []
    private var prerollStart: TimeInterval?

    func begin() {
        lock.withLock {
            samples = preroll
            startSeconds = prerollStart
            isActive = true
        }
    }

    /// Ends the clip; returns its samples and the time of its first sample on the motion clock.
    func end() -> (samples: [Float], start: TimeInterval?) {
        lock.withLock {
            isActive = false
            let clip = (samples, startSeconds)
            samples = []
            startSeconds = nil
            return clip
        }
    }

    func append(_ buffer: AVAudioPCMBuffer, _ time: AVAudioTime) {
        lock.withLock {
            guard let converted = convert(buffer) else { return }
            let bufferStart = time.isHostTimeValid ? AVAudioTime.seconds(forHostTime: time.hostTime) : nil
            if isActive {
                if startSeconds == nil { startSeconds = bufferStart }
                samples.append(contentsOf: converted)
            }
            // Pre-roll always runs, so the next clip can start a little before the key press.
            if preroll.isEmpty { prerollStart = bufferStart }
            preroll.append(contentsOf: converted)
            let limit = Int(Self.prerollSeconds * Self.sampleRate)
            if preroll.count > limit {
                let drop = preroll.count - limit
                preroll.removeFirst(drop)
                prerollStart = prerollStart.map { $0 + Double(drop) / Self.sampleRate }
            }
        }
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> [Float]? {
        if converter == nil || inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: outputFormat)
            inputFormat = buffer.format
        }
        guard let converter else { return nil }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * outputFormat.sampleRate / buffer.format.sampleRate) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return nil }
        var handed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if handed { status.pointee = .noDataNow; return nil }
            handed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let channel = output.floatChannelData?[0] else { return nil }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }
}
