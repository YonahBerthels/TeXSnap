import Foundation

/// The offline model installed by scripts/install-model.sh (or ml/install_local.py after training): a fine-tuned PaddleOCR-VL in
/// ~/Library/Application Support/TeXSnap/LocalModel, with runtime.json naming the Python that runs it.
enum LocalModel {
    struct Runtime: Decodable {
        let python: String
        let server: String
        let model: String
        let name: String?
    }

    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TeXSnap/LocalModel", isDirectory: true)
    }

    static func runtime() -> Runtime? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("runtime.json")),
              let runtime = try? JSONDecoder().decode(Runtime.self, from: data) else { return nil }
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: runtime.python), fm.fileExists(atPath: runtime.server),
              fm.fileExists(atPath: runtime.model) else { return nil }
        return runtime
    }

    static var isInstalled: Bool { runtime() != nil }
}

/// Recognizes on this Mac with the local model. Only transcription: the model was not trained to repair or
/// double-check, so those stay with Claude.
struct LocalEngine: RecognitionEngine {
    var displayName: String { "On this Mac" }
    var isLocal: Bool { true }

    func complete(_ request: EngineRequest, onText: @escaping @Sendable (String) -> Void) async throws -> EngineOutput {
        guard let runtime = LocalModel.runtime() else { throw EngineError.localModelMissing }
        let ext = request.image.mediaType == "image/jpeg" ? "jpg" : "png"
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("texsnap-local-\(UUID().uuidString).\(ext)")
        try request.image.data.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let reply = try await LocalModelServer.shared.transcribe(runtime: runtime, image: file, prompt: request.prompt,
                                                                 onText: onText)
        guard !reply.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw EngineError.emptyResponse }
        return EngineOutput(text: reply.text, model: runtime.name ?? "TeXSnap local model", truncated: reply.truncated)
    }
}

/// The Python model server (ml/serve.py). Started on first use, it keeps the model in memory for a
/// while and quits after `idleSeconds` without requests, so it only uses memory while snips come in.
actor LocalModelServer {
    static let shared = LocalModelServer()

    static let idleSeconds: UInt64 = 120
    private static let startTimeout: UInt64 = 90
    private static let requestTimeout: UInt64 = 120

    private var process: Process?
    private var input: FileHandle?
    private var lines: LineReader?
    private var stderrText = LockedData()
    private var nextID = 1
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var idleTimer: Task<Void, Never>?

    struct Reply {
        let text: String
        let truncated: Bool
    }

    func transcribe(runtime: LocalModel.Runtime, image: URL, prompt: String,
                    onText: @escaping @Sendable (String) -> Void) async throws -> Reply {
        await acquire()
        defer { release() }
        idleTimer?.cancel()
        defer { scheduleIdleStop() }
        try Task.checkCancellation()
        try await startIfNeeded(runtime)
        guard let input, let lines else { throw EngineError.local("the model server is not running.") }

        let id = nextID
        nextID += 1
        let request: [String: Any] = ["id": id, "image": image.path, "prompt": prompt, "max_tokens": 2048]
        var line = try JSONSerialization.data(withJSONObject: request)
        line.append(0x0A)
        do {
            try input.write(contentsOf: line)
        } catch {
            stop()
            throw EngineError.local("the model server stopped unexpectedly.")
        }

        let process = self.process
        let watchdog = Task {
            try await Task.sleep(nanoseconds: Self.requestTimeout * 1_000_000_000)
            process?.terminate()
        }
        defer { watchdog.cancel() }
        return try await withTaskCancellationHandler {
            while let raw = try await lines.next() {
                guard let event = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
                      (event["id"] as? Int) == id else { continue }
                if let error = event["error"] as? String { throw EngineError.local(error) }
                let text = event["text"] as? String ?? ""
                if event["done"] as? Bool == true {
                    return Reply(text: text, truncated: event["truncated"] as? Bool ?? false)
                }
                onText(text)
            }
            // stdout closed: the server exited (crash, watchdog or cancellation).
            let details = stderrText.string.trimmingCharacters(in: .whitespacesAndNewlines)
            stop()
            try Task.checkCancellation()
            throw EngineError.local(details.isEmpty ? "the model server exited." : String(details.suffix(400)))
        } onCancel: {
            // The server cannot abort a generation, so a cancelled snip restarts it.
            process?.terminate()
        }
    }

    // MARK: Lifecycle

    private func startIfNeeded(_ runtime: LocalModel.Runtime) async throws {
        if let process, process.isRunning { return }
        stop()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: runtime.python)
        process.arguments = [runtime.server, runtime.model]
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        env["HF_HUB_OFFLINE"] = "1"  // everything it needs is on disk; never reach out to the network
        process.environment = env
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        let log = LockedData()
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil } else { log.append(chunk) }
        }
        do {
            try process.run()
        } catch {
            throw EngineError.local("could not start \(runtime.python): \(error.localizedDescription)")
        }
        ProcessRegistry.shared.add(process)
        self.process = process
        self.input = stdin.fileHandleForWriting
        self.lines = LineReader(stdout.fileHandleForReading)
        self.stderrText = log

        let starting = Task {
            try await Task.sleep(nanoseconds: Self.startTimeout * 1_000_000_000)
            process.terminate()
        }
        defer { starting.cancel() }
        while let raw = try await lines?.next() {
            if let event = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
               event["ready"] as? Bool == true {
                return
            }
        }
        let details = log.string.trimmingCharacters(in: .whitespacesAndNewlines)
        stop()
        throw EngineError.local(details.isEmpty ? "the model server did not start." : String(details.suffix(400)))
    }

    private func stop() {
        if let process {
            if process.isRunning { process.terminate() }
            ProcessRegistry.shared.remove(process)
        }
        try? input?.close()
        process = nil
        input = nil
        lines = nil
    }

    private func scheduleIdleStop() {
        idleTimer?.cancel()
        idleTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.idleSeconds * 1_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.stopIfIdle()
        }
    }

    private func stopIfIdle() {
        if !busy && waiting.isEmpty { stop() }
    }

    // MARK: One request at a time

    private func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    private func release() {
        if waiting.isEmpty {
            busy = false
        } else {
            waiting.removeFirst().resume()
        }
    }
}

/// Reads lines from a pipe; a class so the actor can keep the iterator across suspension points.
final class LineReader: @unchecked Sendable {
    private var iterator: AsyncLineSequence<FileHandle.AsyncBytes>.AsyncIterator

    init(_ handle: FileHandle) {
        iterator = handle.bytes.lines.makeAsyncIterator()
    }

    func next() async throws -> String? {
        try await iterator.next()
    }
}
