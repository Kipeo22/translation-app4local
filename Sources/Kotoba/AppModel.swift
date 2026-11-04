import AppKit
import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published var source = ""
    @Published var result = ""
    @Published var direction = TranslationDirection.automatic
    @Published var engineKind = EngineKind(rawValue: UserDefaults.standard.string(forKey: "engine") ?? "") ?? .apple
    @Published var ollamaModel = UserDefaults.standard.string(forKey: "ollamaModel") ?? "translategemma:12b"
    @Published var fontSize = UserDefaults.standard.double(forKey: "fontSize") == 0 ? 21 : UserDefaults.standard.double(forKey: "fontSize")
    @Published var isRunning = false
    @Published var isComplete = false
    @Published var status = "翻訳する文章を選ぶか、ここに入力してください"
    @Published var error: String?
    @Published var firstTextTime: TimeInterval?
    @Published var completeTime: TimeInterval?
    @Published var startedAt: Date?
    @Published var showHistory = false
    @Published var records: [TranslationRecord] = []
    @Published var saveHistory = UserDefaults.standard.bool(forKey: "saveHistory")
    @Published var copyFallback = UserDefaults.standard.bool(forKey: "copyFallback")
    @Published var showSettings = false
    @Published var shortcutKey = UserDefaults.standard.string(forKey: "shortcutKey") ?? "T"
    @Published var hotkeyError: String?
    @Published var captureInProgress = false
    @Published var copied = false
    var previewMode = false
    let engine = TranslationEngine()
    private var work: Task<Void, Never>?
    private var requestID: UUID?
    private var copyReset: Task<Void, Never>?

    init() { loadHistory() }

    func translate() {
        let text = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        stop()
        guard let target = direction.target(for: text) else {
            error = TranslationFailure.ambiguousLanguage.localizedDescription
            status = "翻訳先を選択してください"
            return
        }
        let id = UUID()
        requestID = id
        let selectedEngine = engineKind
        let selectedModel = ollamaModel
        let engineLabel = selectedEngine == .apple ? "Apple Intelligence・オンデバイス" : selectedModel
        result = ""
        error = nil
        copied = false
        isComplete = false
        firstTextTime = nil
        completeTime = nil
        let start = Date()
        startedAt = start
        isRunning = true
        status = "訳文を準備しています"
        persistSettings()
        work = Task { [weak self] in
            guard let self else { return }
            do {
                try await engine.translate(source: text, target: target, kind: selectedEngine, model: selectedModel) { [weak self] snapshot in
                    guard let self, requestID == id else { return }
                    result = snapshot
                    if !snapshot.isEmpty, firstTextTime == nil { firstTextTime = Date().timeIntervalSince(start) }
                    if !snapshot.isEmpty { status = "翻訳中" }
                }
                try Task.checkCancellation()
                guard requestID == id else { return }
                completeTime = Date().timeIntervalSince(start)
                isRunning = false
                isComplete = true
                status = "翻訳完了"
                if saveHistory {
                    records.insert(TranslationRecord(source: text, result: result, engine: engineLabel, target: target), at: 0)
                    records = Array(records.prefix(500))
                    writeHistory()
                }
            } catch is CancellationError {
                // stop() has already invalidated the request and updated the UI.
            } catch {
                guard requestID == id else { return }
                isRunning = false
                isComplete = false
                self.error = friendlyError(error)
                status = result.isEmpty ? "翻訳できませんでした" : "翻訳が途中で止まりました"
            }
        }
    }

    func stop() {
        requestID = nil
        work?.cancel()
        work = nil
        if isRunning {
            isComplete = false
            status = result.isEmpty ? "中断しました" : "中断しました・訳文は途中です"
        }
        isRunning = false
    }

    func editSource(_ value: String) {
        stop()
        source = value
        result = ""
        error = nil
        isComplete = false
        firstTextTime = nil
        completeTime = nil
        status = "翻訳する準備ができました"
    }

    func useSelection(_ text: String) {
        editSource(text)
        translate()
    }

    func copyResult() {
        guard isComplete, !result.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(result, forType: .string)
        copied = true
        copyReset?.cancel()
        copyReset = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            self?.copied = false
        }
    }

    func restore(_ record: TranslationRecord) {
        stop()
        source = record.source
        result = record.result
        isComplete = true
        error = nil
        firstTextTime = nil
        completeTime = nil
        status = "履歴から表示・\(record.engine)"
    }

    func clearHistory() {
        records = []
        writeHistory()
    }

    func deleteRecord(_ id: UUID) {
        records.removeAll { $0.id == id }
        writeHistory()
    }

    func persistSettings() {
        let defaults = UserDefaults.standard
        defaults.set(engineKind.rawValue, forKey: "engine")
        defaults.set(ollamaModel, forKey: "ollamaModel")
        defaults.set(fontSize, forKey: "fontSize")
        defaults.set(saveHistory, forKey: "saveHistory")
        defaults.set(copyFallback, forKey: "copyFallback")
        defaults.set(shortcutKey, forKey: "shortcutKey")
    }

    private var historyURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Kotoba/history.json")
    }

    private func loadHistory() {
        if let data = try? Data(contentsOf: historyURL),
           let decoded = try? JSONDecoder().decode([TranslationRecord].self, from: data) {
            records = Array(decoded.prefix(500))
        }
    }

    private func writeHistory() {
        guard !previewMode else { return }
        do {
            try FileManager.default.createDirectory(at: historyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(records).write(to: historyURL, options: .atomic)
        } catch { self.error = "履歴を保存できませんでした。訳文はこの画面からコピーできます。" }
    }

    private func friendlyError(_ error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            if nsError.code == NSURLErrorCannotConnectToHost {
                return "Ollamaに接続できません。Ollamaを起動して、モデル名を確認してください。"
            }
            if nsError.code == NSURLErrorTimedOut { return "応答がタイムアウトしました。原文を短くして再試行してください。" }
        }
        return error.localizedDescription
    }

    func loadPreview() {
        previewMode = true
        source = "Thanks for sharing the proposal. I like the overall direction, but I think we should clarify the scope before moving forward. Could we set aside some time this week to discuss the next steps?"
        result = "提案を共有してくれてありがとうございます。全体的な方向性には賛成ですが、先に進む前に範囲を明確にした方がよいと思います。今週、次のステップについて話し合う時間を取れますか？"
        status = "画面プレビュー・サンプルの訳文"
        isComplete = true
    }
}
