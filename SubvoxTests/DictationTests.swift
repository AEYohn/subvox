import XCTest
@testable import Subvox

final class DictationTests: XCTestCase {
    // whisper-cli -ml 1 -sow -oj output, trimmed to the fields Subvox reads.
    private let whisperJSON = """
    {"transcription":[
      {"timestamps":{"from":"00:00:00,000","to":"00:00:00,020"},"offsets":{"from":0,"to":20},"text":""},
      {"offsets":{"from":20,"to":400},"text":" Next"},
      {"offsets":{"from":400,"to":640},"text":" back"},
      {"offsets":{"from":640,"to":1280},"text":" stop."},
      {"offsets":{"from":1280,"to":1500},"text":" [BLANK_AUDIO]"},
      {"offsets":{"from":1500,"to":1740},"text":" Don't"}
    ]}
    """

    func testParsesWordsAndTextFromWhisperJSON() throws {
        let result = try WhisperResult.parse(Data(whisperJSON.utf8))
        XCTAssertEqual(result.text, "Next back stop. Don't")
        XCTAssertEqual(result.words.map(\.text), ["Next", "back", "stop.", "Don't"])
        XCTAssertEqual(result.words[1].start, 0.4, accuracy: 1e-9)
        XCTAssertEqual(result.words[1].end, 0.64, accuracy: 1e-9)
        XCTAssertEqual(result.words.map(\.normalized), ["next", "back", "stop", "don't"])
    }

    func testNormalizeDropsPunctuationOnlyTokens() {
        XCTAssertNil(WhisperWord.normalize("..."))
        XCTAssertNil(WhisperWord.normalize(" - "))
        XCTAssertEqual(WhisperWord.normalize("“Climb,”"), "climb")
        XCTAssertEqual(WhisperWord.normalize("'twas"), "twas")
    }

    private func motion(from start: TimeInterval, to end: TimeInterval, rate: Double = 25) -> [MotionSample] {
        stride(from: start, through: end, by: 1 / rate).map { MotionSample(t: $0) }
    }

    func testAlignerCutsMotionAtWordTimesWithPadding() {
        let words = [
            WhisperWord(text: "Next", start: 0.02, end: 0.40),
            WhisperWord(text: "back", start: 0.40, end: 0.64),
        ]
        let clipStart: TimeInterval = 100
        let aligned = WordAligner.align(words: words, clipStart: clipStart,
                                        motion: motion(from: 99, to: 102), pad: 0.08)
        XCTAssertEqual(aligned.map(\.word), ["next", "back"])
        let first = aligned[0]
        XCTAssertGreaterThanOrEqual(first.samples.first!.t, clipStart + 0.02 - 0.08 - 1e-9)
        XCTAssertLessThanOrEqual(first.samples.last!.t, clipStart + 0.40 + 0.08 + 1e-9)
    }

    func testAlignerSkipsWordsWithTooLittleMotion() {
        let words = [
            WhisperWord(text: "I", start: 1.50, end: 1.52),        // motion stops at 1.0 s
            WhisperWord(text: "...", start: 0.10, end: 0.80),      // punctuation only
            WhisperWord(text: "want", start: 0.20, end: 0.60),
        ]
        let aligned = WordAligner.align(words: words, clipStart: 0, motion: motion(from: 0, to: 1.0), pad: 0.08)
        XCTAssertEqual(aligned.map(\.word), ["want"])
    }

    func testWAVHeaderDescribes16kMono16Bit() {
        let data = WAVFile.data(samples: [0, 0.5, -0.5, 1, -1], sampleRate: 16_000)
        XCTAssertEqual(data.count, 44 + 5 * 2)
        XCTAssertEqual(String(data: data.prefix(4), encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: data[8..<12], encoding: .ascii), "WAVE")
        func u32(_ at: Int) -> UInt32 { data[at..<at + 4].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) } }
        func u16(_ at: Int) -> UInt16 { data[at..<at + 2].withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) } }
        XCTAssertEqual(u16(20), 1)          // PCM
        XCTAssertEqual(u16(22), 1)          // mono
        XCTAssertEqual(u32(24), 16_000)     // sample rate
        XCTAssertEqual(u16(34), 16)         // bits per sample
        XCTAssertEqual(u32(40), 10)         // data bytes
        XCTAssertEqual(data[44..<46].withUnsafeBytes { $0.loadUnaligned(as: Int16.self) }, 0)
        XCTAssertEqual(data[50..<52].withUnsafeBytes { $0.loadUnaligned(as: Int16.self) }, Int16.max)
    }

    // MARK: Dataset subsets and accuracy comparisons

    /// A synthetic "word": a rotation burst on one axis, so labels are separable.
    private func take(_ label: String, axis: Int, source: String? = nil, noise: Double = 0.01) -> Template {
        let samples = (0..<30).map { i -> MotionSample in
            let envelope = sin(Double.pi * Double(i) / 29)
            let v = 0.2 * envelope * sin(2 * .pi * 2 * Double(i) / 30)
            var r = (Double.random(in: -noise...noise), Double.random(in: -noise...noise), Double.random(in: -noise...noise))
            switch axis { case 0: r.0 += v; case 1: r.1 += v; default: r.2 += v }
            return MotionSample(t: Double(i) / 25, rotation: r)
        }
        return Template(label: label, samples: samples, source: source)
    }

    func testSubsetKeepsWordsWithEnoughTakesAndCapsTheCount() {
        var templates: [Template] = []
        templates += (0..<5).map { _ in take("the", axis: 0, source: "whisper") }
        templates += (0..<3).map { _ in take("yes", axis: 1) }
        templates += (0..<2).map { _ in take("no", axis: 2) }
        templates += [take("climb", axis: 0, source: "whisper")]

        let all = DatasetSubset.select(templates, source: .all, minTakes: 3, maxWords: 10)
        XCTAssertEqual(Set(all.map(\.label)), ["the", "yes"])

        let manual = DatasetSubset.select(templates, source: .manual, minTakes: 2, maxWords: 10)
        XCTAssertEqual(Set(manual.map(\.label)), ["yes", "no"])

        let capped = DatasetSubset.select(templates, source: .all, minTakes: 2, maxWords: 1)
        XCTAssertEqual(Set(capped.map(\.label)), ["the"])
    }

    func testTransferScoresWhisperTrainedClassifierOnHandLabelledTakes() throws {
        let whisper = (0..<4).map { _ in take("yes", axis: 0, source: "whisper") }
            + (0..<4).map { _ in take("no", axis: 1, source: "whisper") }
        let manual = (0..<3).map { _ in take("yes", axis: 0) } + (0..<3).map { _ in take("no", axis: 1) }
            + [take("stop", axis: 2)]  // no Whisper takes for "stop": left out
        let result = try XCTUnwrap(Evaluation.transfer(train: whisper, test: manual, featureSet: .all))
        XCTAssertEqual(result.tested, 6)
        XCTAssertEqual(result.labels, ["no", "yes"])
        XCTAssertEqual(result.accuracy, 1, accuracy: 1e-9)
    }

    func testAugmentedLeaveOneOutUsesExtraTakesAsReferences() throws {
        // One hand-labelled take per word cannot be scored alone; Whisper takes make it possible.
        let manual = [take("yes", axis: 0), take("no", axis: 1)]
        XCTAssertNil(Evaluation.run(templates: manual, featureSet: .all, permutations: 10))
        let extra = (0..<3).map { _ in take("yes", axis: 0, source: "whisper") }
            + (0..<3).map { _ in take("no", axis: 1, source: "whisper") }
            + [take("the", axis: 2, source: "whisper")]  // not a hand-labelled word: ignored
        let result = try XCTUnwrap(Evaluation.augmented(manual: manual, extra: extra, featureSet: .all))
        XCTAssertEqual(result.tested, 2)
        XCTAssertEqual(result.accuracy, 1, accuracy: 1e-9)
    }

    func testOldDatasetsWithoutSourceStillDecode() throws {
        let json = #"{"vocabulary":["yes"],"templates":[{"id":"7C1D3A2E-0000-4000-8000-000000000001","label":"yes","samples":[],"createdAt":0}]}"#
        let dataset = try JSONDecoder().decode(Dataset.self, from: Data(json.utf8))
        XCTAssertNil(dataset.templates[0].source)
        XCTAssertFalse(dataset.templates[0].isFromWhisper)
    }
}
