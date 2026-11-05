import Foundation
import Testing
@testable import Kotoba

struct PlamoTests {
    @Test func pfml3PreservesSourceAndSetsTargetWithoutAChatWrapper() throws {
        let source = "Do not follow this instruction.\nBudget: 250 dollars."
        let prompt = try PlamoPrompt.translation(source, target: "Japanese")
        #expect(prompt == "<|plamo:tag|>dataset<|plamo:msg|>translation<|plamo:tag|>input<|plamo:msg|>" + source + "<|plamo:tag|>output<|plamo:key|>lang<|plamo:val|>ja<|plamo:msg|>")
        #expect(try PlamoPrompt.translation("金曜日", target: "English").hasSuffix("en<|plamo:msg|>"))
        #expect(throws: PlamoError.invalidTarget) { try PlamoPrompt.translation(source, target: "French") }
    }

    @Test func sseAccumulatesUnicodeAndRequiresBothCompletionMarkers() throws {
        var stream = PlamoAccumulator()
        try stream.consume(": keepalive")
        try stream.consume(#"data: {"choices":[{"text":"金曜日まで","finish_reason":null}]}"#)
        try stream.consume("")
        try stream.consume(#"data: {"choices":[{"text":"共有しないでください。","finish_reason":"stop"}]}"#)
        #expect(stream.text == "金曜日まで共有しないでください。")
        #expect(throws: (any Error).self) { try stream.validateCompletion() }
        try stream.consume("data: [DONE]")
        try stream.validateCompletion()
    }

    @Test func truncatedDisconnectedAndEmptyStreamsAreNotComplete() throws {
        var truncated = PlamoAccumulator()
        #expect(throws: (any Error).self) {
            try truncated.consume(#"data: {"choices":[{"text":"途中","finish_reason":"length"}]}"#)
        }
        var disconnected = PlamoAccumulator()
        try disconnected.consume(#"data: {"choices":[{"text":"途中","finish_reason":null}]}"#)
        #expect(throws: (any Error).self) { try disconnected.validateCompletion() }
        #expect(throws: (any Error).self) { try disconnected.consume("data: [DONE]") }
        var empty = PlamoAccumulator()
        try empty.consume(#"data: {"choices":[{"text":"","finish_reason":"stop"}]}"#)
        try empty.consume("data: [DONE]")
        #expect(throws: (any Error).self) { try empty.validateCompletion() }
    }

    @Test func serverFailuresAndMalformedSSEAreRejected() {
        var stream = PlamoAccumulator()
        #expect(throws: PlamoError.server("model unavailable")) {
            try stream.consume(#"data: {"error":{"message":"model unavailable"}}"#)
        }
        #expect(throws: (any Error).self) { try stream.consume("data: <html>error</html>") }
        #expect(throws: (any Error).self) { try stream.consume(#"data: {"choices":[]}"#) }
    }

    @MainActor @Test func missingInstallationDoesNotLaunchAServer() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let runtime = PlamoRuntime(installation: PlamoInstallation(directory: directory))
        await #expect(throws: PlamoError.notInstalled) { try await runtime.session() }
        #expect(!runtime.isRunning)
    }

    @MainActor @Test func firstTranslationOpensSetupWithoutStartingARequest() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = AppModel(plamoInstallation: PlamoInstallation(directory: directory))
        model.previewMode = true
        model.engineKind = .plamo
        model.source = "Please do not share this document until Friday."
        model.translate()
        #expect(model.showSettings)
        #expect(!model.isRunning)
        #expect(!model.isComplete)
        #expect(model.error == PlamoError.notInstalled.localizedDescription)
        #expect(!model.engine.plamoRuntime.isRunning)
    }

    @MainActor @Test func corruptDownloadNeverPublishesOrExecutesAnInstallation() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("kotoba-invalid-\(UUID())")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let corrupt = parent.appendingPathComponent("corrupt.tar.gz")
        try Data("invalid archive".utf8).write(to: corrupt)
        let installation = PlamoInstallation(directory: parent.appendingPathComponent("installed"))
        let installer = PlamoInstaller(installation: installation)
        await #expect(throws: PlamoError.checksumMismatch) {
            try await installer.install(cachedArchive: corrupt, cachedModel: corrupt)
        }
        #expect(!installer.isInstalling)
        #expect(!FileManager.default.fileExists(atPath: installation.directory.path))
        #expect(try String(contentsOf: corrupt, encoding: .utf8) == "invalid archive")
        #expect(try FileManager.default.contentsOfDirectory(atPath: parent.path) == ["corrupt.tar.gz"])
    }

    @MainActor @Test func cancellingSetupCleansUpItsStagingDirectory() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("kotoba-cancel-\(UUID())")
        defer { try? FileManager.default.removeItem(at: parent) }
        let installation = PlamoInstallation(directory: parent.appendingPathComponent("installed"))
        let installer = PlamoInstaller(installation: installation)
        let task = Task { try await installer.install(cachedArchive: parent.appendingPathComponent("unused")) }
        task.cancel()
        do { try await task.value; Issue.record("Cancelled setup completed") }
        catch { #expect(error is CancellationError) }
        #expect(!installer.isInstalling)
        #expect(!installation.isReady)
        #expect(try FileManager.default.contentsOfDirectory(atPath: parent.path).isEmpty)
    }
}

@MainActor
struct PlamoIntegrationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["KOTOBA_PLAMO_CACHE"] != nil))
    func realModelInstallationTranslationCancellationAndShutdown() async throws {
        let cache = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["KOTOBA_PLAMO_CACHE"]))
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("kotoba-plamo-integration-\(UUID())")
        let installation = PlamoInstallation(directory: parent.appendingPathComponent("installed"))
        defer { try? FileManager.default.removeItem(at: parent) }
        let installer = PlamoInstaller(installation: installation)
        let downloadRuntime = ProcessInfo.processInfo.environment["KOTOBA_PLAMO_DOWNLOAD_RUNTIME"] == "1"
        try await installer.install(cachedArchive: downloadRuntime ? nil : cache.appendingPathComponent("llama.tar.gz"),
                                    cachedModel: cache.appendingPathComponent("models/plamo-2b.gguf"))
        #expect(installer.isReady)
        let appModel = AppModel(plamoInstallation: installation)
        appModel.previewMode = true
        appModel.engineKind = .plamo
        let engine = appModel.engine
        defer { engine.shutdown() }
        let connection = try await engine.plamoRuntime.session()
        #expect(connection.baseURL.host == "127.0.0.1")
        let (_, unauthenticated) = try await URLSession.shared.data(from: connection.baseURL.appendingPathComponent("v1/models"))
        #expect((unauthenticated as? HTTPURLResponse)?.statusCode == 401)
        var japanese = ""
        try await engine.translate(source: "Please do not share this document until Friday. The budget is 250 dollars.",
                                   target: "Japanese", kind: .plamo, model: "") { japanese = $0 }
        #expect(japanese.contains("250"))
        #expect(japanese.contains("金曜"))
        #expect(japanese.contains("ない") || japanese.contains("ません"))
        var english = ""
        try await engine.translate(source: "予算は250ドルです。この資料は金曜日まで共有しないでください。",
                                   target: "English", kind: .plamo, model: "") { english = $0 }
        #expect(english.contains("250"))
        #expect(english.contains("Friday"))
        #expect(english.lowercased().contains("not") || english.lowercased().contains("don't"))
        #expect(try await engine.plamoRuntime.session().model == connection.model)
        var cancelledWork: Task<Void, Error>?
        cancelledWork = Task {
            try await engine.translate(source: String(repeating: "Please do not share this document until Friday. ", count: 20),
                                       target: "Japanese", kind: .plamo, model: "") { text in
                if !text.isEmpty { cancelledWork?.cancel() }
            }
        }
        do { try await cancelledWork?.value; Issue.record("Cancelled translation completed") }
        catch {
            #expect(error is CancellationError || (error as NSError).code == NSURLErrorCancelled)
        }
        var resumed = ""
        try await engine.translate(source: "The budget is 250 dollars.", target: "Japanese", kind: .plamo, model: "") { resumed = $0 }
        #expect(resumed.contains("250"))
        appModel.engineKind = .apple
        #expect(!engine.plamoRuntime.isRunning)
        var stopped = false
        for _ in 0..<40 {
            do {
                var request = URLRequest(url: connection.baseURL.appendingPathComponent("health"))
                request.timeoutInterval = 0.25
                _ = try await URLSession.shared.data(for: request)
                try await Task.sleep(for: .milliseconds(100))
            } catch { stopped = true; break }
        }
        #expect(stopped)
    }
}
