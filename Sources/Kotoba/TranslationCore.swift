import Foundation
import NaturalLanguage

enum TranslationDirection: String, CaseIterable, Identifiable {
    case automatic = "自動判定"
    case toJapanese = "英語 → 日本語"
    case toEnglish = "日本語 → 英語"
    var id: String { rawValue }

    func target(for text: String) -> String? {
        switch self {
        case .toJapanese: return "Japanese"
        case .toEnglish: return "English"
        case .automatic:
            let recognizer = NLLanguageRecognizer()
            recognizer.processString(text)
            guard let language = recognizer.dominantLanguage else { return nil }
            if language == .japanese { return "English" }
            if language == .english { return "Japanese" }
            return nil
        }
    }
}

enum EngineKind: String, CaseIterable, Identifiable {
    case apple = "Apple Intelligence"
    case ollama = "Ollama"
    var id: String { rawValue }
}

enum TranslationFailure: LocalizedError {
    case ambiguousLanguage, unavailable(String), empty, truncated, invalidResponse
    var errorDescription: String? {
        switch self {
        case .ambiguousLanguage: return "言語を判定できませんでした。上のメニューで翻訳先を指定してください。"
        case .unavailable(let message): return message
        case .empty: return "訳文が返りませんでした。原文を確認して、もう一度お試しください。"
        case .truncated: return "出力の上限に達しました。訳文は途中です。原文を短くして再実行してください。"
        case .invalidResponse: return "翻訳エンジンからの応答を読み取れませんでした。"
        }
    }
}

struct OllamaChunk: Decodable {
    struct Message: Decodable { let content: String }
    let message: Message?
    let done: Bool?
    let done_reason: String?
    let error: String?
}

/// Handles incomplete streams explicitly: an interrupted connection is not a completed translation.
struct OllamaAccumulator {
    private(set) var text = ""
    private(set) var finished = false
    mutating func consume(_ line: String) throws {
        guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard !finished, let data = line.data(using: .utf8) else { throw TranslationFailure.invalidResponse }
        let chunk = try JSONDecoder().decode(OllamaChunk.self, from: data)
        if let error = chunk.error { throw TranslationFailure.unavailable(error) }
        text += chunk.message?.content ?? ""
        if chunk.done == true {
            if chunk.done_reason == "length" { throw TranslationFailure.truncated }
            finished = true
        }
    }
    func validateCompletion() throws {
        guard finished else { throw TranslationFailure.invalidResponse }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw TranslationFailure.empty }
    }
}

struct TranslationRecord: Codable, Identifiable {
    var id = UUID()
    var date = Date()
    let source: String
    let result: String
    let engine: String
    let target: String
}
