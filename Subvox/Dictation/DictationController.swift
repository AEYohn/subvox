import AppKit
import Observation

/// Wispr Flow-style dictation: hold Right Option anywhere, talk, let go. Whisper transcribes the
/// clip locally, the text is pasted into the app in front, and the head motion recorded during
/// the clip is cut per word and handed to the dataset with Whisper's words as labels.
@MainActor @Observable
final class DictationController {
    enum Phase: Equatable { case idle, listening, transcribing }

    struct Entry: Identifiable, Hashable {
        let id = UUID()
        var date = Date()
        var text = ""
        var labelled: [String] = []
        var seconds: Double = 0
        var pasted = false
        var error: String?
    }

    static let minHoldSeconds: TimeInterval = 0.25
    static let minAudioSeconds: TimeInterval = 0.3
    static let rightOptionKeyCode: UInt16 = 61
    /// NX_DEVICERALTKEYMASK: set while the right Option key is down.
    private static let rightOptionMask: UInt = 0x40
    private static let motionPrerollSeconds: TimeInterval = 0.4

    private(set) var isEnabled = false
    var pastesText = UserDefaults.standard.object(forKey: "dictationPastes") as? Bool ?? true {
        didSet { UserDefaults.standard.set(pastesText, forKey: "dictationPastes") }
    }
    var labelsMotion = UserDefaults.standard.object(forKey: "dictationLabels") as? Bool ?? true {
        didSet { UserDefaults.standard.set(labelsMotion, forKey: "dictationLabels") }
    }
    var onlyVocabularyWords = UserDefaults.standard.bool(forKey: "dictationVocabularyOnly") {
        didSet { UserDefaults.standard.set(onlyVocabularyWords, forKey: "dictationVocabularyOnly") }
    }
    private(set) var phase: Phase = .idle
    private(set) var history: [Entry] = []
    private(set) var error: String?
    private(set) var isTrusted = Paster.isTrusted

    /// Adds the aligned words to the dataset; returns the words actually kept.
    var onWords: (([AlignedWord]) -> [String])?

    @ObservationIgnored private let clip = AudioClipRecorder()
    @ObservationIgnored private weak var audio: AudioService?
    @ObservationIgnored private var hud: DictationHUD?
    @ObservationIgnored private var sinkID: UUID?
    @ObservationIgnored private var monitors: [Any] = []
    @ObservationIgnored private var recentMotion: [MotionSample] = []
    @ObservationIgnored private var clipMotion: [MotionSample] = []
    @ObservationIgnored private var pressedAt: TimeInterval?

    static var wasEnabled: Bool { UserDefaults.standard.bool(forKey: "dictationEnabled") }

    func configure(audio: AudioService) {
        self.audio = audio
        hud = DictationHUD(audio: audio)
    }

    func refreshTrust() {
        isTrusted = Paster.isTrusted
    }

    func setEnabled(_ on: Bool) async {
        guard on != isEnabled else { return }
        if on {
            refreshTrust()
            if !isTrusted { Paster.requestTrust() }
            guard let audio else { return }
            if !audio.isRunning { await audio.start() }
            guard audio.isRunning else {
                error = audio.error ?? "The microphone didn't start."
                return
            }
            sinkID = audio.sink.add { [clip] buffer, time in clip.append(buffer, time) }
            installMonitors()
            isEnabled = true
            error = nil
        } else {
            cancel()
            removeMonitors()
            if let sinkID { audio?.sink.remove(sinkID) }
            sinkID = nil
            isEnabled = false
        }
        UserDefaults.standard.set(isEnabled, forKey: "dictationEnabled")
    }

    func ingest(_ sample: MotionSample) {
        guard isEnabled else { return }
        if phase == .listening { clipMotion.append(sample) }
        recentMotion.append(sample)
        if let keepFrom = recentMotion.firstIndex(where: { $0.t >= sample.t - Self.motionPrerollSeconds }), keepFrom > 0 {
            recentMotion.removeFirst(keepFrom)
        }
    }

    func clearHistory() {
        history.removeAll()
    }

    // MARK: Hotkey

    private func installMonitors() {
        let handler: (NSEvent) -> Void = { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown], handler: handler) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown], handler: { event in
            handler(event)
            return event
        }) {
            monitors.append(local)
        }
    }

    private func removeMonitors() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .flagsChanged where event.keyCode == Self.rightOptionKeyCode:
            if event.modifierFlags.rawValue & Self.rightOptionMask != 0 { press() } else { release() }
        case .keyDown:
            // Right Option was part of a shortcut, not a dictation.
            if phase == .listening { cancel() }
        default:
            break
        }
    }

    private func press() {
        guard isEnabled, phase == .idle else { return }
        if let audio, !audio.isRunning { Task { await audio.start() } }
        pressedAt = ProcessInfo.processInfo.systemUptime
        clip.begin()
        clipMotion = recentMotion
        phase = .listening
        hud?.show(.listening)
    }

    private func cancel() {
        guard phase == .listening else { return }
        _ = clip.end()
        clipMotion = []
        phase = .idle
        hud?.hide()
    }

    private func release() {
        guard phase == .listening, let pressedAt else { return }
        let held = ProcessInfo.processInfo.systemUptime - pressedAt
        let (samples, start) = clip.end()
        let motion = clipMotion
        clipMotion = []
        guard held >= Self.minHoldSeconds,
              Double(samples.count) >= Self.minAudioSeconds * AudioClipRecorder.sampleRate else {
            phase = .idle
            hud?.hide()
            return
        }
        phase = .transcribing
        hud?.show(.transcribing)
        Task { await finish(samples: samples, start: start, motion: motion) }
    }

    private func finish(samples: [Float], start: TimeInterval?, motion: [MotionSample]) async {
        let began = ProcessInfo.processInfo.systemUptime
        let wav = FileManager.default.temporaryDirectory.appending(path: "subvox-\(UUID().uuidString).wav")
        var entry = Entry()
        do {
            try WAVFile.data(samples: samples, sampleRate: Int(AudioClipRecorder.sampleRate)).write(to: wav)
            let result = try await WhisperEngine.transcribe(wav)
            entry.text = result.text
            if pastesText, !result.text.isEmpty {
                entry.pasted = Paster.paste(result.text)
                if !entry.pasted { error = "Copied, not pasted: allow Subvox under Accessibility to paste." }
            }
            if labelsMotion, let start {
                let aligned = WordAligner.align(words: result.words, clipStart: start, motion: motion)
                entry.labelled = onWords?(aligned) ?? []
            }
            if entry.pasted || !pastesText { error = nil }
        } catch {
            entry.error = error.localizedDescription
            self.error = error.localizedDescription
        }
        try? FileManager.default.removeItem(at: wav)
        entry.seconds = ProcessInfo.processInfo.systemUptime - began
        history.insert(entry, at: 0)
        if history.count > 50 { history.removeLast(history.count - 50) }
        phase = .idle
        hud?.hide()
    }
}
