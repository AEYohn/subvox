import AppKit
import Observation

struct DecodedWord: Identifiable, Hashable {
    let id = UUID()
    var prediction: Prediction
    var text: String { prediction.best?.label ?? "?" }
}

@MainActor @Observable
final class AppModel {
    enum Screen: String, CaseIterable, Identifiable {
        case sensors = "Sensors"
        case train = "Train"
        case decode = "Decode"
        case dictate = "Dictate"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .sensors: "waveform.path.ecg"
            case .train: "square.stack.3d.up"
            case .decode: "text.bubble"
            case .dictate: "mic"
            }
        }
    }

    let motion = HeadphoneMotionService()
    let audio = AudioService()
    let transcriber = MicTranscriber()
    let capture = CaptureController()
    let recorder = SessionRecorder()
    let dictation = DictationController()

    var screen: Screen = .train {
        didSet { syncCaptureMode() }
    }

    // MARK: Training

    private(set) var dataset = TemplateStore.load()
    var selectedWord: String?
    var featureSet: FeatureSet = .all {
        didSet { rebuildClassifier() }
    }
    private(set) var classifier: TemplateClassifier?
    private(set) var evaluation: Evaluation?
    private(set) var isEvaluating = false
    private(set) var lastTemplateID: Template.ID?

    // Which takes Evaluate uses. Dictation adds many one-off words, so only words with
    // enough takes are scored, and only the most-recorded `maxWords` of them.
    var evalSource: TemplateSource = .all {
        didSet { evaluation = nil }
    }
    var minTakes = 3 {
        didSet { evaluation = nil }
    }
    var maxWords = 20 {
        didSet { evaluation = nil }
    }
    private(set) var comparison: SourceComparisonResult?
    private(set) var isComparing = false
    private(set) var accuracyLog: [AccuracyLogEntry] = AccuracyLog.load()

    var whisperTakeCount: Int { dataset.templates.filter(\.isFromWhisper).count }
    var manualTakeCount: Int { dataset.templates.count - whisperTakeCount }

    // MARK: Decoding

    var decodeMode: CaptureController.Mode = .hold {
        didSet { syncCaptureMode() }
    }
    var maxDistance: Double = 1.5
    var minConfidence: Double = 0.05
    private(set) var decoded: [DecodedWord] = []
    private(set) var lastSegment: [MotionSample] = []

    @ObservationIgnored private var keyMonitor: Any?
    @ObservationIgnored private var started = false

    init() {
        selectedWord = dataset.vocabulary.first
        rebuildClassifier()
    }

    func start() {
        guard !started else { return }
        started = true
        motion.onSample = { [weak self] sample in self?.ingest(sample) }
        capture.onSegment = { [weak self] segment in self?.handleSegment(segment) }
        motion.start()
        audio.refreshDevices()
        installKeyMonitor()
        dictation.configure(audio: audio)
        dictation.onWords = { [weak self] words in self?.addWhisperWords(words) ?? [] }
        if DictationController.wasEnabled {
            Task { await dictation.setEnabled(true) }
        }
    }

    private func ingest(_ sample: MotionSample) {
        capture.ingest(sample)
        recorder.record(sample)
        dictation.ingest(sample)
    }

    private func syncCaptureMode() {
        capture.autoEnabled = screen == .decode && decodeMode == .auto
    }

    private func handleSegment(_ segment: [MotionSample]) {
        lastSegment = segment
        switch screen {
        case .train:
            guard let word = selectedWord else { return }
            addTemplate(Template(label: word, samples: segment))
            recorder.logEvent(segment, kind: "train", label: word, confidence: nil)
        case .decode:
            guard let classifier else { return }
            let prediction = classifier.predict(segment, maxDistance: maxDistance, minConfidence: minConfidence)
            decoded.append(DecodedWord(prediction: prediction))
            recorder.logEvent(segment, kind: prediction.accepted ? "decode" : "reject",
                              label: prediction.best?.label ?? "", confidence: prediction.confidence)
        case .sensors, .dictate:
            recorder.logEvent(segment, kind: "segment", label: recorder.prompt, confidence: nil)
        }
    }

    // MARK: Space bar = hold to capture

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard event.keyCode == 49 else { return event }
            let isDown = event.type == .keyDown
            let isRepeat = isDown && event.isARepeat
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard let self, self.spaceCapturesMotion else { return false }
                if !isDown {
                    self.capture.end()
                } else if !isRepeat {
                    self.capture.begin()
                }
                return true
            }
            return consumed ? nil : event
        }
    }

    private var spaceCapturesMotion: Bool {
        // Let text fields keep the space bar.
        if NSApp.keyWindow?.firstResponder is NSText { return false }
        switch screen {
        case .train: return selectedWord != nil
        case .decode: return decodeMode == .hold && classifier != nil
        case .sensors: return recorder.isRecording
        case .dictate: return false
        }
    }

    // MARK: Dataset editing

    func templates(for word: String) -> [Template] {
        dataset.templates.filter { $0.label == word }
    }

    func addWord(_ raw: String) {
        let word = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !word.isEmpty, !dataset.vocabulary.contains(word) else { return }
        dataset.vocabulary.append(word)
        selectedWord = word
        persist()
    }

    func removeWord(_ word: String) {
        dataset.vocabulary.removeAll { $0 == word }
        dataset.templates.removeAll { $0.label == word }
        if selectedWord == word { selectedWord = dataset.vocabulary.first }
        persist()
    }

    func addTemplate(_ template: Template) {
        dataset.templates.append(template)
        lastTemplateID = template.id
        persist()
    }

    /// Dictation's per-word motion, labelled by Whisper. Returns the words kept.
    func addWhisperWords(_ words: [AlignedWord]) -> [String] {
        var kept: [String] = []
        for word in words {
            let known = dataset.vocabulary.contains(word.word)
            if dictation.onlyVocabularyWords && !known { continue }
            if !known { dataset.vocabulary.append(word.word) }
            let template = Template(label: word.word, samples: word.samples, source: Template.whisperSource)
            dataset.templates.append(template)
            lastTemplateID = template.id
            kept.append(word.word)
        }
        if !kept.isEmpty { persist() }
        return kept
    }

    func deleteWhisperTakes() {
        dataset.templates.removeAll(where: \.isFromWhisper)
        let used = Set(dataset.templates.map(\.label))
        dataset.vocabulary.removeAll { !used.contains($0) && !Dataset.starter.vocabulary.contains($0) }
        persist()
    }

    func deleteTemplate(_ id: Template.ID) {
        dataset.templates.removeAll { $0.id == id }
        persist()
    }

    private func persist() {
        TemplateStore.save(dataset)
        rebuildClassifier()
    }

    private func rebuildClassifier() {
        classifier = TemplateClassifier(templates: dataset.templates, featureSet: featureSet)
        evaluation = nil
    }

    var evaluationSubset: [Template] {
        DatasetSubset.select(dataset.templates, source: evalSource, minTakes: minTakes, maxWords: maxWords)
    }

    func evaluate() {
        guard !isEvaluating else { return }
        isEvaluating = true
        let templates = evaluationSubset
        let featureSet = featureSet
        let source = evalSource
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Evaluation.run(templates: templates, featureSet: featureSet)
            }.value
            self.evaluation = result
            self.isEvaluating = false
            if let result {
                self.log(test: "Leave-one-out · \(source.rawValue)", takes: result.templateCount,
                         references: result.templateCount - 1, words: result.labels.count,
                         accuracy: result.accuracy, chance: result.chance, pValue: result.pValue)
            }
        }
    }

    /// The question behind Whisper labelling: does speech-labelled data help on hand-labelled takes?
    func compareSources() {
        guard !isComparing else { return }
        isComparing = true
        let templates = dataset.templates
        let featureSet = featureSet
        let minTakes = minTakes
        let maxWords = maxWords
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                SourceComparisonResult.run(templates: templates, featureSet: featureSet,
                                           minTakes: minTakes, maxWords: maxWords)
            }.value
            self.comparison = result
            self.isComparing = false
            for row in result.rows {
                guard let score = row.score else { continue }
                self.log(test: row.title, takes: score.tested, references: score.references,
                         words: score.labels.count, accuracy: score.accuracy, chance: score.chance, pValue: row.pValue)
            }
        }
    }

    private func log(test: String, takes: Int, references: Int, words: Int, accuracy: Double, chance: Double, pValue: Double?) {
        let entry = AccuracyLogEntry(date: Date(), test: test, takes: takes, references: references, words: words,
                                     accuracy: accuracy, chance: chance, pValue: pValue, features: featureSet.summary)
        AccuracyLog.append(entry)
        accuracyLog.insert(entry, at: 0)
    }

    // MARK: Decode transcript

    var transcript: String {
        decoded.filter(\.prediction.accepted).map(\.text).joined(separator: " ")
    }

    func clearDecoded() {
        decoded.removeAll()
        lastSegment = []
    }

    // MARK: Mic

    func toggleMic() async {
        if audio.isRunning {
            transcriber.stop()
            audio.stop()
        } else {
            await audio.start()
            if audio.isRunning { await transcriber.start(sink: audio.sink) }
        }
    }
}
