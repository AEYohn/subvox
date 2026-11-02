import Foundation

/// One dictated word with the head motion recorded while it was said.
struct AlignedWord: Sendable {
    var word: String
    var samples: [MotionSample]
}

/// Cuts the motion recorded during a dictation into one segment per Whisper word.
enum WordAligner {
    /// Whisper word times are good to roughly ±0.1 s; a little padding keeps onsets in.
    static let defaultPad: TimeInterval = 0.08
    /// Same floor as `CaptureController`: shorter segments are too thin to match.
    static let minSamples = 4
    static let minDuration: TimeInterval = 0.15

    /// - Parameters:
    ///   - clipStart: the clip's first audio sample, in seconds since boot (the motion clock).
    static func align(words: [WhisperWord], clipStart: TimeInterval, motion: [MotionSample],
                      pad: TimeInterval = defaultPad) -> [AlignedWord] {
        words.compactMap { word in
            guard let label = word.normalized else { return nil }
            let lo = clipStart + word.start - pad
            let hi = clipStart + word.end + pad
            let segment = motion.filter { $0.t >= lo && $0.t <= hi }
            guard segment.count >= minSamples, let first = segment.first, let last = segment.last,
                  last.t - first.t >= minDuration else { return nil }
            return AlignedWord(word: label, samples: segment)
        }
    }
}

/// 16-bit PCM mono WAV, the input whisper.cpp wants.
enum WAVFile {
    static func data(samples: [Float], sampleRate: Int) -> Data {
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let dataBytes = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36) + dataBytes)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); append(UInt32(16))
        append(UInt16(1))                       // PCM
        append(UInt16(1))                       // mono
        append(UInt32(sampleRate))
        append(UInt32(sampleRate * 2))          // byte rate
        append(UInt16(2))                       // block align
        append(UInt16(16))                      // bits per sample
        data.append(contentsOf: Array("data".utf8)); append(dataBytes)
        data.reserveCapacity(data.count + samples.count * 2)
        for sample in samples {
            append(Int16((max(-1, min(1, sample)) * Float(Int16.max)).rounded()))
        }
        return data
    }
}
