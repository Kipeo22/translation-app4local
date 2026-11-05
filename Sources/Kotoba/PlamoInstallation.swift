import Combine
import CryptoKit
import Foundation

struct PlamoInstallation: Sendable {
    static let version = "plamo3-2b-q4km-llama-b12125"
    static let modelBytes: Int64 = 1_807_192_480
    static let modelSHA256 = "2c288ecc7ebfe60c3561726580da3583767f3c41ca3ef5c6825bf6c4cc060787"
    static let runtimeSHA256 = "2585d0d097ba3277b8856d81b8bb1b3d1b1556f27ccf3d6717f6438bb27070a6"
    static let modelDownload = URL(string: "https://huggingface.co/pfnet/plamo-3-translate-2b-GGUF/resolve/f2b4599dff9b3e45c62567eac15e83186b4cb64e/plamo-3-translate-2b-Q4_K_M.gguf")!
    static let runtimeDownload = URL(string: "https://github.com/ggml-org/llama.cpp/releases/download/b12125/llama-b12125-bin-macos-arm64.tar.gz")!
    static let licenseURL = URL(string: "https://huggingface.co/pfnet/plamo-3-translate-2b-GGUF/blob/f2b4599dff9b3e45c62567eac15e83186b4cb64e/LICENSE/ja")!

    let directory: URL
    init(directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Kotoba/PLaMo/\(Self.version)", isDirectory: true)) {
        self.directory = directory
    }
    var model: URL { directory.appendingPathComponent("plamo-2b.gguf") }
    var executable: URL { directory.appendingPathComponent("runtime/llama-b12125/llama-server") }
    var isReady: Bool {
        FileManager.default.isExecutableFile(atPath: executable.path) &&
        (try? model.resourceValues(forKeys: [.fileSizeKey]).fileSize) == Int(Self.modelBytes) &&
        (try? String(contentsOf: directory.appendingPathComponent("installed.txt"), encoding: .utf8)) == Self.version
    }
}

enum PlamoError: LocalizedError, Equatable {
    case notInstalled, downloadFailed, checksumMismatch, installationConflict, extractionFailed
    case startupFailed, startupTimedOut, invalidTarget, server(String)
    var errorDescription: String? {
        switch self {
        case .notInstalled: return "PLaMoの準備が必要です。設定からモデルをダウンロードしてください。"
        case .downloadFailed: return "ダウンロードできませんでした。ネット接続と空き容量を確認して再試行してください。"
        case .checksumMismatch: return "ダウンロードしたファイルを検証できませんでした。もう一度ダウンロードしてください。"
        case .installationConflict: return "導入先に不完全なデータがあります。設定から保存先を開き、既存のフォルダを移動して再試行してください。"
        case .extractionFailed: return "実行環境を展開できませんでした。空き容量を確認して再試行してください。"
        case .startupFailed: return "PLaMoを起動できませんでした。モデル・実行環境と空きメモリを確認してください。"
        case .startupTimedOut: return "PLaMoの起動がタイムアウトしました。空きメモリを確認して再試行してください。"
        case .invalidTarget: return "PLaMoの翻訳先は日本語または英語を指定してください。"
        case .server(let message): return "PLaMoの応答エラーです。\(message)"
        }
    }
}

private final class DownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let update: @Sendable (Double?) -> Void
    init(update: @escaping @Sendable (Double?) -> Void) { self.update = update }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        update(totalBytesExpectedToWrite > 0 ? min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) : nil)
    }
}

@MainActor
final class PlamoInstaller: ObservableObject {
    let installation: PlamoInstallation
    @Published private(set) var isInstalling = false
    @Published private(set) var phase = ""
    @Published private(set) var progress: Double?
    @Published private(set) var error: String?
    private var work: Task<Void, Never>?
    private var operationID: UUID?
    private var activeStage: URL?

    init(installation: PlamoInstallation = .init()) { self.installation = installation }
    var isReady: Bool { installation.isReady }

    func start() {
        guard work == nil, !isInstalling else { return }
        work = Task {
            defer { work = nil }
            do { try await install() }
            catch is CancellationError { phase = "準備を中断しました" }
            catch {
                if Task.isCancelled { phase = "準備を中断しました" }
                else { self.error = error.localizedDescription }
            }
        }
    }
    func cancel() {
        work?.cancel()
        if let activeStage { try? FileManager.default.removeItem(at: activeStage) }
    }

    /// Cached files are used by opt-in integration checks; normal installation downloads pinned assets.
    func install(cachedArchive: URL? = nil, cachedModel: URL? = nil) async throws {
        guard !isInstalling else { return }
        guard !isReady else { return }
        let id = UUID()
        operationID = id
        isInstalling = true
        error = nil
        defer { operationID = nil; isInstalling = false; progress = nil }
        let manager = FileManager.default
        let parent = installation.directory.deletingLastPathComponent()
        try manager.createDirectory(at: parent, withIntermediateDirectories: true)
        guard !manager.fileExists(atPath: installation.directory.path) else { throw PlamoError.installationConflict }
        let stage = parent.appendingPathComponent(".setup-\(id)", isDirectory: true)
        try manager.createDirectory(at: stage, withIntermediateDirectories: true)
        activeStage = stage
        defer { activeStage = nil; try? manager.removeItem(at: stage) }
        let archive = stage.appendingPathComponent("runtime.tar.gz")
        phase = "実行環境をダウンロードしています"
        try await fetch(PlamoInstallation.runtimeDownload, cached: cachedArchive, to: archive, id: id)
        phase = "実行環境を検証しています"
        try await verify(archive, sha256: PlamoInstallation.runtimeSHA256)
        let runtime = stage.appendingPathComponent("runtime", isDirectory: true)
        try manager.createDirectory(at: runtime, withIntermediateDirectories: true)
        try await extract(archive, to: runtime)
        try manager.removeItem(at: archive)
        let model = stage.appendingPathComponent("plamo-2b.gguf")
        phase = "翻訳モデルをダウンロードしています"
        try await fetch(PlamoInstallation.modelDownload, cached: cachedModel, to: model, id: id)
        phase = "翻訳モデルを検証しています"
        try await verify(model, sha256: PlamoInstallation.modelSHA256)
        try Task.checkCancellation()
        try PlamoInstallation.version.write(to: stage.appendingPathComponent("installed.txt"), atomically: true, encoding: .utf8)
        guard PlamoInstallation(directory: stage).isReady else { throw PlamoError.extractionFailed }
        // Publish only a complete installation. Never replace an existing installation or user file.
        try manager.moveItem(at: stage, to: installation.directory)
        phase = "PLaMoの準備ができました"
    }

    private func fetch(_ url: URL, cached: URL?, to destination: URL, id: UUID) async throws {
        progress = nil
        try Task.checkCancellation()
        if let cached {
            // APFS hard links avoid copying a verified 1.8 GB model during local integration checks.
            do { try FileManager.default.linkItem(at: cached, to: destination) }
            catch { try FileManager.default.copyItem(at: cached, to: destination) }
            return
        }
        let delegate = DownloadProgress { [weak self] value in
            Task { @MainActor in
                guard let self, self.operationID == id else { return }
                self.progress = value
            }
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 120
        let (file, response) = try await URLSession.shared.download(for: request, delegate: delegate)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw PlamoError.downloadFailed }
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: file, to: destination)
    }

    private func verify(_ url: URL, sha256: String) async throws {
        progress = nil
        let worker = Task.detached(priority: .utility) {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hash = SHA256()
            while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
                try Task.checkCancellation()
                hash.update(data: data)
            }
            return hash.finalize().map { String(format: "%02x", $0) }.joined()
        }
        let actual = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        try Task.checkCancellation()
        guard actual == sha256 else { throw PlamoError.checksumMismatch }
    }

    private func extract(_ archive: URL, to destination: URL) async throws {
        // The archive's fixed SHA-256 is checked before any archive member is extracted or executed.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-xzf", archive.path, "-C", destination.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                process.terminationHandler = { task in
                    if task.terminationStatus == 0 { continuation.resume() }
                    else { continuation.resume(throwing: PlamoError.extractionFailed) }
                }
                do { try process.run() }
                catch { continuation.resume(throwing: error) }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
        try Task.checkCancellation()
    }
}
