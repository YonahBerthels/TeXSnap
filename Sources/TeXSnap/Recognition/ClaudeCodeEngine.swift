import Foundation

/// Uses the Claude Code CLI in headless mode (`claude -p`), so TeXSnap works with the user's Claude login
/// and no API key. All tools, MCP servers and customizations are disabled; the system prompt is ours.
struct ClaudeCodeEngine: RecognitionEngine {
    let executable: URL

    var displayName: String { "Claude Code" }

    // MARK: Locating the CLI

    /// Finds `claude`: an explicit path, the usual install locations, or the user's login-shell PATH.
    static func locate(override: String?) -> URL? {
        let fm = FileManager.default
        if let override, !override.trimmingCharacters(in: .whitespaces).isEmpty {
            let path = (override as NSString).expandingTildeInPath
            return fm.isExecutableFile(atPath: path) ? URL(fileURLWithPath: path) : nil
        }
        let home = fm.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/claude", "\(home)/.claude/local/claude", "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude", "\(home)/.npm-global/bin/claude", "\(home)/.bun/bin/claude",
            "\(home)/.volta/bin/claude",
        ]
        for path in candidates where fm.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return locateWithLoginShell()
    }

    private static func locateWithLoginShell() -> URL? {
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-c", "command -v claude"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning && Date() < deadline { usleep(50_000) }
        if process.isRunning { process.terminate(); return nil }
        let path = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(separator: "\n").last.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        return path.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: path) ? URL(fileURLWithPath: path) : nil
    }

    static func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var path = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        for dir in ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        where !path.contains(dir) {
            path.append(dir)
        }
        env["PATH"] = path.joined(separator: ":")
        // A parent Claude Code session marks its children; this is a separate, top-level run.
        env.removeValue(forKey: "CLAUDECODE")
        return env
    }

    // MARK: Running

    func complete(_ request: EngineRequest, onText: @escaping @Sendable (String) -> Void) async throws -> EngineOutput {
        do {
            return try await run(request, minimalFlags: false, onText: onText)
        } catch EngineError.claudeCode(let message) where message.contains("unknown option") {
            // Older Claude Code versions lack some flags; the essential ones are enough.
            return try await run(request, minimalFlags: true, onText: onText)
        }
    }

    private func arguments(_ request: EngineRequest, minimalFlags: Bool) -> [String] {
        var args = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                    "--model", request.model, "--system-prompt", request.system, "--tools", ""]
        if ModelCatalog.info(request.model).supportsEffort { args += ["--effort", request.effort] }
        if !minimalFlags {
            args += ["--include-partial-messages", "--no-session-persistence", "--safe-mode", "--strict-mcp-config"]
        }
        return args
    }

    private func run(_ request: EngineRequest, minimalFlags: Bool,
                     onText: @escaping @Sendable (String) -> Void) async throws -> EngineOutput {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments(request, minimalFlags: minimalFlags)
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        process.environment = Self.environment()
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        let message: [String: Any] = [
            "type": "user",
            "message": [
                "role": "user",
                "content": [
                    ["type": "image", "source": [
                        "type": "base64",
                        "media_type": request.image.mediaType,
                        "data": request.image.data.base64EncodedString(),
                    ]],
                    ["type": "text", "text": request.prompt],
                ],
            ],
        ]
        var line = try JSONSerialization.data(withJSONObject: message)
        line.append(0x0A)

        let stderrText = LockedData()
        errors.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil } else { stderrText.append(chunk) }
        }
        let exit = ExitWaiter(process)
        do {
            try process.run()
        } catch {
            throw EngineError.claudeNotFound
        }
        ProcessRegistry.shared.add(process)
        defer { ProcessRegistry.shared.remove(process) }
        // Write on another thread: the image is larger than the pipe buffer.
        let writer = input.fileHandleForWriting
        DispatchQueue.global(qos: .userInitiated).async {
            try? writer.write(contentsOf: line)
            try? writer.close()
        }
        let watchdog = Task {
            try await Task.sleep(nanoseconds: 300 * 1_000_000_000)
            if process.isRunning { process.terminate() }
        }
        defer { watchdog.cancel() }

        return try await withTaskCancellationHandler {
            var text = ""
            var model = request.model
            var result: [String: Any]?
            for try await rawLine in output.fileHandleForReading.bytes.lines {
                guard let event = try? JSONSerialization.jsonObject(with: Data(rawLine.utf8)) as? [String: Any],
                      let type = event["type"] as? String else { continue }
                if type == "stream_event", let inner = event["event"] as? [String: Any],
                   inner["type"] as? String == "content_block_delta",
                   let delta = inner["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
                   let chunk = delta["text"] as? String {
                    text += chunk
                    onText(text)
                } else if type == "assistant", let served = (event["message"] as? [String: Any])?["model"] as? String {
                    model = served
                } else if type == "result" {
                    result = event
                    break
                }
            }
            try Task.checkCancellation()
            guard let result else {
                let status = await exit.wait()
                let details = stderrText.string.trimmingCharacters(in: .whitespacesAndNewlines)
                throw EngineError.claudeCode(details.isEmpty ? "exited (status \(status)) without a reply." : String(details.suffix(600)))
            }
            let reply = (result["result"] as? String) ?? ""
            let subtype = result["subtype"] as? String ?? ""
            if (result["is_error"] as? Bool ?? false) || subtype != "success" {
                throw EngineError.claudeCode(reply.isEmpty ? subtype : reply)
            }
            let stopReason = result["stop_reason"] as? String
            if stopReason == "refusal" { throw EngineError.refusal(category: nil) }
            let final = reply.isEmpty ? text : reply
            guard !final.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw EngineError.emptyResponse }
            return EngineOutput(text: final, model: model, truncated: stopReason == "max_tokens")
        } onCancel: {
            process.terminate()
        }
    }
}

/// Thread-safe byte accumulator.
final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    var string: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Awaits a Process's exit status without blocking a thread.
final class ExitWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var status: Int32?
    private var waiters: [CheckedContinuation<Int32, Never>] = []

    init(_ process: Process) {
        process.terminationHandler = { [self] process in finish(process.terminationStatus) }
    }

    private func finish(_ value: Int32) {
        lock.lock()
        status = value
        let pending = waiters
        waiters = []
        lock.unlock()
        pending.forEach { $0.resume(returning: value) }
    }

    func wait() async -> Int32 {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let status {
                lock.unlock()
                continuation.resume(returning: status)
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }
}
