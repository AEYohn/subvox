import AVFoundation
import XCTest
@testable import Subvox

/// Runs the real whisper-cli on speech made by `say`. Skipped when whisper.cpp or a model is missing.
final class WhisperIntegrationTests: XCTestCase {
    func testTranscribesSpokenWordsWithTimes() async throws {
        try XCTSkipIf(WhisperEngine.binary == nil || WhisperEngine.model == nil, "whisper.cpp or model not installed")
        let dir = FileManager.default.temporaryDirectory.appending(path: "subvox-it-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let aiff = dir.appending(path: "speech.aiff")
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", aiff.path, "yes. no. next. back. stop."]
        try say.run()
        say.waitUntilExit()

        // Through the same 16 kHz mono path the app uses.
        let file = try AVAudioFile(forReading: aiff)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let recorder = AudioClipRecorder()
        recorder.begin()
        recorder.append(buffer, AVAudioTime(hostTime: mach_absolute_time()))
        let clip = recorder.end()
        XCTAssertNotNil(clip.start)
        XCTAssertEqual(Double(clip.samples.count) / 16_000, Double(file.length) / file.processingFormat.sampleRate, accuracy: 0.05)

        let wav = dir.appending(path: "speech.wav")
        try WAVFile.data(samples: clip.samples, sampleRate: 16_000).write(to: wav)
        let result = try await WhisperEngine.transcribe(wav)
        let words = result.words.compactMap(\.normalized)
        XCTAssertEqual(words, ["yes", "no", "next", "back", "stop"], "got: \(result.text)")
        XCTAssertTrue(zip(result.words, result.words.dropFirst()).allSatisfy { $0.start <= $1.start })
    }
}
