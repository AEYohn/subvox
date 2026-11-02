import Foundation

/// One word from whisper-cli, with times in seconds from the start of the clip.
struct WhisperWord: Hashable, Sendable {
    var text: String
    var start: TimeInterval
    var end: TimeInterval

    /// The training label: lowercase letters, digits and inner apostrophes; nil for punctuation.
    var normalized: String? { Self.normalize(text) }

    static func normalize(_ raw: String) -> String? {
        let kept = raw.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "'" }
        let word = String(String.UnicodeScalarView(kept)).trimmingCharacters(in: CharacterSet(charactersIn: "'"))
        return word.isEmpty ? nil : word
    }
}

struct WhisperResult: Sendable {
    var text: String
    var words: [WhisperWord]

    /// Parses whisper-cli `-oj` output made with `-ml 1 -sow`, which gives one segment per word.
    static func parse(_ data: Data) throws -> WhisperResult {
        struct File: Decodable { var transcription: [Segment] }
        struct Segment: Decodable { var text: String; var offsets: Offsets }
        struct Offsets: Decodable { var from: Int; var to: Int }

        let segments = try JSONDecoder().decode(File.self, from: data).transcription
            .filter { segment in
                let t = segment.text.trimmingCharacters(in: .whitespaces)
                return !t.isEmpty && !(t.hasPrefix("[") && t.hasSuffix("]")) && !(t.hasPrefix("(") && t.hasSuffix(")"))
            }
        let words = segments.map {
            WhisperWord(text: $0.text.trimmingCharacters(in: .whitespaces),
                        start: Double($0.offsets.from) / 1000,
                        end: Double($0.offsets.to) / 1000)
        }
        let text = segments.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        return WhisperResult(text: text, words: words)
    }
}

/// Runs the local whisper.cpp command-line tool (`brew install whisper-cpp`) on a WAV file.
enum WhisperEngine {
    enum Failure: LocalizedError {
        case missingBinary, missingModel, failed(String)
        var errorDescription: String? {
            switch self {
            case .missingBinary: "whisper-cli not found. Run: brew install whisper-cpp"
            case .missingModel: "No Whisper model in \(WhisperEngine.modelsDirectory.path)."
            case .failed(let message): "Whisper failed: \(message)"
            }
        }
    }

    static let binaryCandidates = ["/opt/homebrew/bin/whisper-cli", "/usr/local/bin/whisper-cli"]
    /// Best first: English-only small is accurate and still ~0.4 s warm on Apple silicon.
    static let modelNames = ["ggml-small.en.bin", "ggml-base.en.bin", "ggml-small.bin", "ggml-base.bin", "ggml-tiny.en.bin"]

    static var modelsDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "Subvox/models", directoryHint: .isDirectory)
    }

    static var binary: URL? {
        binaryCandidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    static var model: URL? {
        modelNames.lazy.map { modelsDirectory.appending(path: $0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func transcribe(_ wav: URL) async throws -> WhisperResult {
        guard let binary else { throw Failure.missingBinary }
        guard let model else { throw Failure.missingModel }
        let outBase = wav.deletingPathExtension()
        let threads = max(2, min(8, ProcessInfo.processInfo.activeProcessorCount - 2))
        let args = ["-m", model.path, "-f", wav.path, "-ml", "1", "-sow", "-oj", "-of", outBase.path,
                    "-np", "-t", String(threads)]
        try await run(binary, args)
        let json = outBase.appendingPathExtension("json")
        defer { try? FileManager.default.removeItem(at: json) }
        return try WhisperResult.parse(Data(contentsOf: json))
    }

    private static func run(_ binary: URL, _ args: [String]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = binary
            process.arguments = args
            let stderr = Pipe()
            process.standardError = stderr
            process.standardOutput = FileHandle.nullDevice
            process.terminationHandler = { finished in
                if finished.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    let message = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    let lastLine = message.split(separator: "\n").last.map(String.init) ?? "exit \(finished.terminationStatus)"
                    continuation.resume(throwing: Failure.failed(lastLine))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: Failure.failed(error.localizedDescription))
            }
        }
    }
}
