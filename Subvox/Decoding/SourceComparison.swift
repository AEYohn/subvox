import Foundation

/// Which takes an evaluation looks at.
enum TemplateSource: String, CaseIterable, Identifiable, Sendable {
    case all = "All takes"
    case manual = "Hand-labelled"
    case whisper = "Whisper-labelled"
    var id: String { rawValue }

    func includes(_ template: Template) -> Bool {
        switch self {
        case .all: true
        case .manual: !template.isFromWhisper
        case .whisper: template.isFromWhisper
        }
    }
}

/// Picks the takes an evaluation can use: one source, words with enough takes, and at most
/// `maxWords` words (the most-recorded ones), so dictation's long tail of one-off words and the
/// O(n²) DTW cost stay out of the way.
enum DatasetSubset {
    static func select(_ templates: [Template], source: TemplateSource, minTakes: Int, maxWords: Int) -> [Template] {
        let pool = templates.filter(source.includes)
        let counts = Dictionary(grouping: pool, by: \.label).mapValues(\.count)
        let keep = Set(counts.filter { $0.value >= minTakes }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(maxWords)
            .map(\.key))
        return pool.filter { keep.contains($0.label) }
    }
}

/// Accuracy of nearest-neighbour DTW on one set of test takes, with references from elsewhere.
struct SourceScore: Sendable, Hashable {
    var accuracy: Double
    /// Accuracy of always guessing the test set's most common word, as `Evaluation.chance`,
    /// so every row of a comparison has the same baseline for the same test takes.
    var chance: Double
    var tested: Int
    var references: Int
    var labels: [String]
}

extension Evaluation {
    /// Train on one set (e.g. Whisper-labelled speech), test on another (e.g. hand-labelled
    /// mouthing). Only words present in both are scored.
    static func transfer(train: [Template], test: [Template], featureSet: FeatureSet) -> SourceScore? {
        let shared = Set(train.map(\.label)).intersection(test.map(\.label))
        let trainSet = train.filter { shared.contains($0.label) }
        let testSet = test.filter { shared.contains($0.label) }
        guard shared.count >= 2, !testSet.isEmpty,
              let classifier = TemplateClassifier(templates: trainSet, featureSet: featureSet) else { return nil }
        let correct = testSet.filter { classifier.rank($0.samples).first?.label == $0.label }.count
        return SourceScore(accuracy: Double(correct) / Double(testSet.count),
                           chance: majorityShare(testSet),
                           tested: testSet.count,
                           references: trainSet.count,
                           labels: shared.sorted())
    }

    /// Leave-one-out over the hand-labelled takes, where the references are the other
    /// hand-labelled takes plus every extra (Whisper) take of the same words. Compare with
    /// plain leave-one-out to see whether the extra data helps.
    static func augmented(manual: [Template], extra: [Template], featureSet: FeatureSet) -> SourceScore? {
        let words = Set(manual.map(\.label))
        let extraSet = extra.filter { words.contains($0.label) }
        let all = manual + extraSet
        guard words.count >= 2, !featureSet.isEmpty else { return nil }

        let raw = all.map { MotionFeatures.frames(MotionFeatures.trim($0.samples), set: featureSet) }
        let scales = MotionFeatures.channelScales(raw)
        let seqs = raw.map { MotionFeatures.scaled($0, by: scales) }

        var tested = 0
        var correct = 0
        for i in manual.indices {
            var best: (label: String, distance: Double)?
            for j in all.indices where j != i {
                let d = DTW.distance(seqs[i], seqs[j])
                if best == nil || d < best!.distance { best = (all[j].label, d) }
            }
            guard let best else { continue }
            tested += 1
            if best.label == manual[i].label { correct += 1 }
        }
        guard tested > 0 else { return nil }
        return SourceScore(accuracy: Double(correct) / Double(tested),
                           chance: majorityShare(manual),
                           tested: tested,
                           references: all.count - 1,
                           labels: words.sorted())
    }

    /// Share of the most common label: the accuracy of always guessing it.
    static func majorityShare(_ takes: [Template]) -> Double {
        let counts = Dictionary(grouping: takes, by: \.label).mapValues(\.count)
        guard let most = counts.values.max(), !takes.isEmpty else { return 0 }
        return Double(most) / Double(takes.count)
    }
}

/// "Does Whisper-labelled data help?" in four numbers, all on the same hand-labelled words.
struct SourceComparisonResult: Sendable {
    struct Row: Identifiable, Sendable {
        var title: String
        var detail: String
        var score: SourceScore?
        var pValue: Double?
        var id: String { title }
    }

    var rows: [Row]

    static func run(templates: [Template], featureSet: FeatureSet, minTakes: Int, maxWords: Int,
                    permutations: Int = 200) -> SourceComparisonResult {
        // Hand-labelled words with at least two takes, so leave-one-out on them alone is defined.
        let manual = DatasetSubset.select(templates, source: .manual, minTakes: 2, maxWords: maxWords)
        let whisper = templates.filter(\.isFromWhisper)
        let whisperOnly = DatasetSubset.select(templates, source: .whisper, minTakes: minTakes, maxWords: maxWords)

        let alone = Evaluation.run(templates: manual, featureSet: featureSet, permutations: permutations)
        let aloneScore = alone.map {
            SourceScore(accuracy: $0.accuracy, chance: $0.chance, tested: $0.templateCount,
                        references: $0.templateCount - 1, labels: $0.labels)
        }
        let whisperAlone = Evaluation.run(templates: whisperOnly, featureSet: featureSet, permutations: permutations)
        let whisperAloneScore = whisperAlone.map {
            SourceScore(accuracy: $0.accuracy, chance: $0.chance, tested: $0.templateCount,
                        references: $0.templateCount - 1, labels: $0.labels)
        }

        return SourceComparisonResult(rows: [
            Row(title: "Hand-labelled alone",
                detail: "Each mouthed take matched against your other mouthed takes.",
                score: aloneScore, pValue: alone?.pValue),
            Row(title: "Hand-labelled + Whisper takes",
                detail: "Same takes, with every Whisper take of those words added as references.",
                score: Evaluation.augmented(manual: manual, extra: whisper, featureSet: featureSet)),
            Row(title: "Whisper only → hand-labelled",
                detail: "Trained only on dictation, tested on your mouthed takes.",
                score: Evaluation.transfer(train: whisper, test: manual, featureSet: featureSet)),
            Row(title: "Whisper-labelled alone",
                detail: "Dictation takes matched against each other (words with ≥ \(minTakes) takes).",
                score: whisperAloneScore, pValue: whisperAlone?.pValue),
        ])
    }
}
