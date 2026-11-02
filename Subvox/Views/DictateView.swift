import SwiftUI

struct DictateView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                setup
                recent
                ComparisonPanel()
                AccuracyHistory()
            }
            .padding(20)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .task {
            while !Task.isCancelled {
                model.dictation.refreshTrust()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private var header: some View {
        let dictation = model.dictation
        return GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(isOn: Binding(get: { dictation.isEnabled },
                                     set: { on in Task { await dictation.setEnabled(on) } })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Dictation").font(.headline)
                        Text("Hold Right Option in any app, talk, let go. Whisper runs on this Mac and the text is pasted where you're typing.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                HStack(spacing: 18) {
                    Toggle("Paste into the app in front", isOn: Bindable(dictation).pastesText)
                    Toggle("Label head motion with Whisper's words", isOn: Bindable(dictation).labelsMotion)
                }
                .toggleStyle(.checkbox)
                Toggle("Only label words already in my vocabulary", isOn: Bindable(dictation).onlyVocabularyWords)
                    .toggleStyle(.checkbox)
                    .disabled(!dictation.labelsMotion)
                if let error = dictation.error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    private var setup: some View {
        let dictation = model.dictation
        return GroupBox("Setup") {
            VStack(alignment: .leading, spacing: 8) {
                check(WhisperEngine.binary != nil,
                      ok: "whisper.cpp installed",
                      missing: "whisper.cpp missing: brew install whisper-cpp")
                check(WhisperEngine.model != nil,
                      ok: "Model: \(WhisperEngine.model?.lastPathComponent ?? "")",
                      missing: "No model in \(WhisperEngine.modelsDirectory.path)")
                HStack {
                    check(dictation.isTrusted,
                          ok: "Accessibility allowed (needed for the hotkey and pasting)",
                          missing: "Accessibility not allowed: the hotkey and pasting won't work")
                    if !dictation.isTrusted {
                        Button("Open Settings") { Paster.openAccessibilitySettings() }
                            .controlSize(.small)
                    }
                }
                check(model.audio.isRunning,
                      ok: "Microphone: \(model.audio.activeDeviceName ?? "default input")",
                      missing: model.audio.error ?? "Microphone off (turns on with dictation)")
                check(model.motion.status == .streaming,
                      ok: "AirPods motion streaming",
                      missing: "\(model.motion.status.label): dictation still works, but no motion is labelled")
                Text("Use the Mac's own microphone if you can. Picking the AirPods mic drops them into headset mode.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    private func check(_ ok: Bool, ok okText: String, missing: String) -> some View {
        Label(ok ? okText : missing, systemImage: ok ? "checkmark.circle.fill" : "xmark.circle")
            .foregroundStyle(ok ? Color.green : Color.orange)
            .font(.callout)
    }

    private var recent: some View {
        let history = model.dictation.history
        return GroupBox("Recent dictations") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("\(model.whisperTakeCount) Whisper-labelled takes · \(model.manualTakeCount) hand-labelled")
                        .font(.callout.monospacedDigit())
                    Spacer()
                    if model.whisperTakeCount > 0 {
                        Button("Delete Whisper takes", role: .destructive) { model.deleteWhisperTakes() }
                            .controlSize(.small)
                    }
                }
                if history.isEmpty {
                    Text("Nothing yet. Turn dictation on, hold Right Option and talk.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(history) { entry in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.error ?? (entry.text.isEmpty ? "(no speech)" : entry.text))
                                .foregroundStyle(entry.error == nil ? .primary : Color.orange)
                                .textSelection(.enabled)
                            Text(detail(entry))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Divider()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    private func detail(_ entry: DictationController.Entry) -> String {
        var parts = [String(format: "%.2f s", entry.seconds)]
        if entry.pasted { parts.append("pasted") }
        parts.append(entry.labelled.isEmpty ? "no takes added" : "+\(entry.labelled.count) takes: \(entry.labelled.joined(separator: " "))")
        return parts.joined(separator: " · ")
    }
}

private struct ComparisonPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        GroupBox("Does Whisper data help?") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Scored on your hand-labelled (mouthed) takes, with features \(model.featureSet.summary).")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(model.isComparing ? "Comparing…" : "Compare") { model.compareSources() }
                        .disabled(model.isComparing)
                }
                if let comparison = model.comparison {
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                        GridRow {
                            Text("").gridColumnAlignment(.leading)
                            Text("Accuracy").font(.caption).foregroundStyle(.secondary)
                            Text("Chance").font(.caption).foregroundStyle(.secondary)
                            Text("Takes").font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(comparison.rows) { row in
                            GridRow {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(row.title).font(.callout.weight(.medium))
                                    Text(row.detail).font(.caption).foregroundStyle(.secondary)
                                }
                                if let score = row.score {
                                    Text(percent(score.accuracy)).font(.title3.monospacedDigit().bold())
                                    Text(percent(score.chance)).monospacedDigit()
                                    Text("\(score.tested) · \(score.labels.count) words").monospacedDigit()
                                } else {
                                    Text("not enough takes").foregroundStyle(.secondary)
                                    Text("")
                                    Text("")
                                }
                            }
                        }
                    }
                } else {
                    Text("Needs at least 2 hand-labelled words with 2 takes each (Train screen) and Whisper takes of the same words (dictate sentences that use them).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    private func percent(_ value: Double) -> String { String(format: "%.0f%%", value * 100) }
}

private struct AccuracyHistory: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        GroupBox("Accuracy log") {
            VStack(alignment: .leading, spacing: 6) {
                Text("Every Evaluate and Compare run is appended to \(AccuracyLog.url.path).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if model.accuracyLog.isEmpty {
                    Text("No runs yet.").foregroundStyle(.secondary)
                } else {
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                        ForEach(model.accuracyLog.prefix(15)) { entry in
                            GridRow {
                                Text(entry.date, format: .dateTime.month().day().hour().minute())
                                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                Text(entry.test).font(.caption)
                                Text(String(format: "%.0f%%", entry.accuracy * 100)).font(.caption.monospacedDigit().bold())
                                Text("chance \(String(format: "%.0f%%", entry.chance * 100))")
                                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                Text("\(entry.takes) takes · \(entry.words) words")
                                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }
}
