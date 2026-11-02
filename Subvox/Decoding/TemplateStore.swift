import Foundation

struct Dataset: Codable {
    var vocabulary: [String]
    var templates: [Template]

    static let starter = Dataset(vocabulary: ["yes", "no", "next", "back", "stop"], templates: [])

    /// Drops every Whisper take, and the vocabulary words dictation brought in that have no takes
    /// left. Words the user added by hand stay, even before they have takes.
    func withoutWhisperTakes() -> Dataset {
        let whisperWords = Set(templates.filter(\.isFromWhisper).map(\.label))
        let kept = templates.filter { !$0.isFromWhisper }
        let used = Set(kept.map(\.label))
        let words = vocabulary.filter { word in
            !whisperWords.contains(word) || used.contains(word) || Dataset.starter.vocabulary.contains(word)
        }
        return Dataset(vocabulary: words, templates: kept)
    }
}

/// Persists the training set as JSON in Application Support.
enum TemplateStore {
    static var url: URL {
        let dir = URL.applicationSupportDirectory.appending(path: "Subvox", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "dataset.json")
    }

    static func load() -> Dataset {
        guard let data = try? Data(contentsOf: url),
              let dataset = try? JSONDecoder().decode(Dataset.self, from: data) else { return .starter }
        return dataset
    }

    static func save(_ dataset: Dataset) {
        do {
            let data = try JSONEncoder().encode(dataset)
            try data.write(to: url, options: .atomic)
        } catch {
            print("Subvox: failed to save dataset: \(error)")
        }
    }
}
