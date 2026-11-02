import Foundation

/// Every evaluation is appended to a CSV so you can watch accuracy change as the dataset grows.
struct AccuracyLogEntry: Identifiable, Hashable, Sendable {
    var id = UUID()
    var date: Date
    var test: String
    var takes: Int
    var references: Int
    var words: Int
    var accuracy: Double
    var chance: Double
    var pValue: Double?
    var features: String
}

enum AccuracyLog {
    static let header = "date,test,takes,references,words,accuracy,chance,p_value,features"

    static var url: URL {
        let dir = URL.applicationSupportDirectory.appending(path: "Subvox", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "accuracy-log.csv")
    }

    private static let formatter = ISO8601DateFormatter()

    static func append(_ entry: AccuracyLogEntry) {
        let row = [formatter.string(from: entry.date), entry.test, "\(entry.takes)", "\(entry.references)",
                   "\(entry.words)", String(format: "%.4f", entry.accuracy), String(format: "%.4f", entry.chance),
                   entry.pValue.map { String(format: "%.4f", $0) } ?? "", entry.features]
            .map { $0.replacingOccurrences(of: ",", with: ";") }
            .joined(separator: ",") + "\n"
        let url = url
        if !FileManager.default.fileExists(atPath: url.path) {
            try? (header + "\n").write(to: url, atomically: true, encoding: .utf8)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(row.utf8))
    }

    static func load(limit: Int = 50) -> [AccuracyLogEntry] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").dropFirst().suffix(limit).compactMap { line in
            let f = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 9, let date = formatter.date(from: f[0]),
                  let takes = Int(f[2]), let refs = Int(f[3]), let words = Int(f[4]),
                  let accuracy = Double(f[5]), let chance = Double(f[6]) else { return nil }
            return AccuracyLogEntry(date: date, test: f[1], takes: takes, references: refs, words: words,
                                    accuracy: accuracy, chance: chance, pValue: Double(f[7]), features: f[8])
        }.reversed()
    }
}

extension FeatureSet {
    var summary: String {
        var parts: [String] = []
        if contains(.acceleration) { parts.append("accel") }
        if contains(.rotation) { parts.append("rot") }
        if contains(.attitude) { parts.append("att") }
        return parts.joined(separator: "+")
    }
}
