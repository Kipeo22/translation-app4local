import Darwin
import Foundation

struct PlamoSession: Sendable {
    let baseURL: URL
    let apiKey: String
    let model: String
}

@MainActor
final class PlamoRuntime {
    let installation: PlamoInstallation
    private var process: Process?
    private var connection: PlamoSession?

    init(installation: PlamoInstallation = .init()) { self.installation = installation }
    var isRunning: Bool { process?.isRunning == true }

    func stop() {
        if let process, process.isRunning { process.terminate() }
        process = nil
        connection = nil
    }

    func session() async throws -> PlamoSession {
        try Task.checkCancellation()
        guard installation.isReady else { throw PlamoError.notInstalled }
        if !isRunning {
            stop()
            let port = try Self.availablePort()
            let session = PlamoSession(baseURL: URL(string: "http://127.0.0.1:\(port)")!,
                                       apiKey: UUID().uuidString, model: "kotoba-plamo-\(UUID().uuidString)")
            let task = Process()
            task.executableURL = installation.executable
            task.arguments = ["-m", installation.model.path, "-c", "8192", "-ngl", "99", "--parallel", "1",
                              "--host", "127.0.0.1", "--port", String(port), "--alias", session.model,
                              "--api-key", session.apiKey, "--no-webui", "--log-disable"]
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice
            try task.run()
            process = task
            connection = session
        }
        guard let connection, let ownedProcess = process else { throw PlamoError.startupFailed }
        let deadline = ContinuousClock.now.advanced(by: .seconds(90))
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            guard process === ownedProcess else { throw CancellationError() }
            guard ownedProcess.isRunning else { stop(); throw PlamoError.startupFailed }
            var request = URLRequest(url: connection.baseURL.appendingPathComponent("v1/models"))
            request.setValue("Bearer \(connection.apiKey)", forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 2
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                struct Models: Decodable {
                    struct Model: Decodable { let id: String }
                    let data: [Model]
                }
                if (response as? HTTPURLResponse)?.statusCode == 200,
                   let models = try? JSONDecoder().decode(Models.self, from: data),
                   models.data.contains(where: { $0.id == connection.model }) {
                    try Task.checkCancellation()
                    return connection
                }
            } catch {
                try Task.checkCancellation()
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        if process === ownedProcess { stop() }
        throw PlamoError.startupTimedOut
    }

    private static func availablePort() throws -> Int {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw PlamoError.startupFailed }
        defer { Darwin.close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { throw PlamoError.startupFailed }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &size) }
        }
        guard result == 0 else { throw PlamoError.startupFailed }
        return Int(UInt16(bigEndian: address.sin_port))
    }
}

enum PlamoPrompt {
    static func translation(_ source: String, target: String) throws -> String {
        let code: String
        switch target {
        case "Japanese": code = "ja"
        case "English": code = "en"
        default: throw PlamoError.invalidTarget
        }
        return "<|plamo:tag|>dataset<|plamo:msg|>translation" +
            "<|plamo:tag|>input<|plamo:msg|>" + source +
            "<|plamo:tag|>output<|plamo:key|>lang<|plamo:val|>" + code + "<|plamo:msg|>"
    }
}

struct PlamoAccumulator {
    private struct Event: Decodable {
        struct Choice: Decodable { let text: String?; let finish_reason: String? }
        struct Failure: Decodable { let message: String }
        let choices: [Choice]?
        let error: Failure?
    }
    private(set) var text = ""
    private(set) var finished = false
    private(set) var streamEnded = false

    mutating func consume(_ line: String) throws {
        guard line.hasPrefix("data:") else { return }
        let payload = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        guard !streamEnded else { throw TranslationFailure.invalidResponse }
        if payload == "[DONE]" {
            guard finished else { throw TranslationFailure.invalidResponse }
            streamEnded = true
            return
        }
        guard !finished, let data = payload.data(using: .utf8) else { throw TranslationFailure.invalidResponse }
        let event = try JSONDecoder().decode(Event.self, from: data)
        if let error = event.error { throw PlamoError.server(error.message) }
        guard let choices = event.choices, choices.count == 1 else { throw TranslationFailure.invalidResponse }
        text += choices[0].text ?? ""
        if let reason = choices[0].finish_reason {
            guard reason == "stop" else { throw TranslationFailure.truncated }
            finished = true
        }
    }
    func validateCompletion() throws {
        guard finished, streamEnded else { throw TranslationFailure.invalidResponse }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw TranslationFailure.empty }
    }
}
