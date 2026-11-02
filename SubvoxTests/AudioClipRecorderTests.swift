import AVFoundation
import XCTest
@testable import Subvox

/// The clip's start time must stay on the motion clock, or every Whisper word is cut from the
/// wrong stretch of head motion.
final class AudioClipRecorderTests: XCTestCase {
    private func buffer(seconds: Double) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AudioClipRecorder.sampleRate,
                                   channels: 1, interleaved: false)!
        let frames = AVAudioFrameCount(seconds * AudioClipRecorder.sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        return buffer
    }

    private func at(_ seconds: TimeInterval) -> AVAudioTime {
        AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: seconds))
    }

    func testStalePrerollFromBeforeAnAudioRestartIsDropped() throws {
        // Audio ran, was stopped, and the key press restarted it a minute later.
        let recorder = AudioClipRecorder()
        for i in 0..<3 { recorder.append(buffer(seconds: 0.1), at(1000 + 0.1 * Double(i))) }
        recorder.begin()
        recorder.append(buffer(seconds: 0.1), at(1060))
        let clip = recorder.end()
        XCTAssertEqual(clip.samples.count, 1600)
        XCTAssertEqual(try XCTUnwrap(clip.start), 1060, accuracy: 1e-3)
    }

    func testPrerollRestartsAfterABreakInTheStream() throws {
        let recorder = AudioClipRecorder()
        recorder.append(buffer(seconds: 0.1), at(1000))
        recorder.append(buffer(seconds: 0.1), at(1000.1))
        recorder.append(buffer(seconds: 0.1), at(1060))   // engine restarted
        recorder.begin()
        let clip = recorder.end()
        XCTAssertEqual(clip.samples.count, 1600)
        XCTAssertEqual(try XCTUnwrap(clip.start), 1060, accuracy: 1e-3)
    }

    func testPrerollStartFollowsHostClockNotSampleCount() throws {
        // The device clock runs 1% slow against the host clock: 0.1 s of samples every 0.101 s.
        let recorder = AudioClipRecorder()
        for i in 0..<40 { recorder.append(buffer(seconds: 0.1), at(1000 + 0.101 * Double(i))) }
        recorder.begin()
        let clip = recorder.end()
        let lastEnd = 1000 + 0.101 * 39 + 0.1
        XCTAssertEqual(clip.samples.count, Int(AudioClipRecorder.prerollSeconds * AudioClipRecorder.sampleRate))
        XCTAssertEqual(try XCTUnwrap(clip.start), lastEnd - AudioClipRecorder.prerollSeconds, accuracy: 1e-3)
    }

    func testContiguousBuffersAreNotABreak() {
        XCTAssertFalse(AudioClipRecorder.isBreak(start: 10, count: 1600, next: 10.1))
        XCTAssertFalse(AudioClipRecorder.isBreak(start: 10, count: 1600, next: 10.15))
        XCTAssertTrue(AudioClipRecorder.isBreak(start: 10, count: 1600, next: 10.5))
        XCTAssertTrue(AudioClipRecorder.isBreak(start: 10, count: 1600, next: 9.0))
        XCTAssertFalse(AudioClipRecorder.isBreak(start: nil, count: 1600, next: 10.5))
        XCTAssertFalse(AudioClipRecorder.isBreak(start: 10, count: 0, next: 99))
    }
}
