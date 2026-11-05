import Foundation

// Compile together with the app's TranslationEngine.swift and TranslationCore.swift.
// This deliberately calls the shipping engine, including its prompt and sampling options.
@main
struct AppleBenchmark {
    @MainActor
    static func main() async throws {
        let engine = TranslationEngine()
        if let reason = engine.availabilityMessage {
            FileHandle.standardError.write(Data((reason + "\n").utf8))
            exit(2)
        }
        let input = URL(fileURLWithPath: CommandLine.arguments[1])
        let output = URL(fileURLWithPath: CommandLine.arguments[2])
        if !FileManager.default.fileExists(atPath: output.path) {
            FileManager.default.createFile(atPath: output.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: output)
        try handle.seekToEnd()
        defer { try? handle.close() }
        let lines = try String(contentsOf: input, encoding: .utf8).split(separator: "\n")
        for (index, line) in lines.enumerated() {
            var row = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
            let start = Date()
            var first: Double?
            var text = ""
            do {
                try await engine.translate(source: row["source"] as! String,
                    target: row["target_lang"] as! String == "ja" ? "Japanese" : "English",
                    kind: .apple, model: "") { snapshot in
                        if first == nil && !snapshot.isEmpty { first = Date().timeIntervalSince(start) }
                        text = snapshot
                    }
                row["error"] = NSNull()
            } catch {
                row["error"] = String(describing: error)
            }
            row["prediction"] = text
            row["model"] = "apple-intelligence"
            row["first_text_seconds"] = first.map { $0 as Any } ?? NSNull()
            row["total_seconds"] = Date().timeIntervalSince(start)
            let data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
            try handle.write(contentsOf: data + Data([10]))
            try handle.synchronize()
            FileHandle.standardError.write(Data("\(index + 1)/\(lines.count) \(row["id"]!) \(row["total_seconds"]!)s\n".utf8))
        }
    }
}
