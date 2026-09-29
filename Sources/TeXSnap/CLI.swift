import AppKit

/// Command-line modes of the app binary, used by the tests and handy for scripting:
///
///     TeXSnap --recognize <image> [--engine auto|api|claude-code|local] [--model ID] [--effort low|medium|high]
///             [--no-repair] [--upscale] [--no-pad] [--verify-latex FILE --verify-kind KIND] [--json]
///     TeXSnap --prepare <image> <out>                  write the image exactly as it is sent to Claude
///     TeXSnap --formats <kind> <latex-file>            normalize, validate and convert a transcription
///     TeXSnap --render-preview <kind> <latex-file> <out.png> [--width N] [--dark]
///     TeXSnap --self-test                              check that the bundled resources load
@MainActor
enum CLI {
    private static let commands: Set<String> = ["--recognize", "--prepare", "--formats", "--render-preview", "--self-test", "--help"]
    private nonisolated static let valued: Set<String> = ["--engine", "--model", "--effort", "--width", "--verify-latex", "--verify-kind"]

    struct UsageError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func handles(_ arguments: [String]) -> Bool {
        arguments.count > 1 && commands.contains(arguments[1])
    }

    static func run(_ arguments: [String]) -> Never {
        let app = NSApplication.shared
        // Rendering previews needs an (off-screen) window, which a .prohibited app may not show.
        app.setActivationPolicy(arguments[1] == "--render-preview" ? .accessory : .prohibited)
        Task { @MainActor in
            var status: Int32 = 0
            do {
                try await execute(Array(arguments.dropFirst()))
            } catch {
                FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
                status = 1
            }
            exit(status)
        }
        app.run()
        exit(0)
    }

    private struct Arguments {
        var positional: [String] = []
        var options: [String: String] = [:]
        var flags: Set<String> = []

        init(_ raw: [String]) {
            var i = 0
            while i < raw.count {
                let arg = raw[i]
                if CLI.valued.contains(arg), i + 1 < raw.count {
                    options[arg] = raw[i + 1]
                    i += 2
                    continue
                }
                if arg.hasPrefix("--") { flags.insert(arg) } else { positional.append(arg) }
                i += 1
            }
        }
    }

    private static func execute(_ raw: [String]) async throws {
        let args = Arguments(Array(raw.dropFirst()))
        switch raw[0] {
        case "--recognize": try await recognize(args)
        case "--prepare": try prepare(args)
        case "--formats": try formats(args)
        case "--render-preview": try await renderPreview(args)
        case "--self-test": try selfTest()
        default: print(usage)
        }
    }

    private static let usage = """
    TeXSnap --recognize <image> [--engine auto|api|claude-code|local] [--model ID] [--effort low|medium|high] [--json]
    TeXSnap --prepare <image> <out>
    TeXSnap --formats <kind> <latex-file>
    TeXSnap --render-preview <kind> <latex-file> <out.png> [--width N] [--dark]
    TeXSnap --self-test
    """

    private static func makeEngine(_ name: String) throws -> RecognitionEngine {
        let env = ProcessInfo.processInfo.environment
        let key = env["ANTHROPIC_API_KEY"].flatMap { $0.isEmpty ? nil : $0 } ?? Keychain.readAPIKey()
        let claude = { ClaudeCodeEngine.locate(override: env["TEXSNAP_CLAUDE"]) }
        switch name {
        case "api":
            guard let key else { throw EngineError.missingAPIKey }
            return AnthropicEngine(apiKey: key)
        case "claude-code":
            guard let url = claude() else { throw EngineError.claudeNotFound }
            return ClaudeCodeEngine(executable: url)
        case "local":
            guard LocalModel.isInstalled else { throw EngineError.localModelMissing }
            return LocalEngine()
        case "auto":
            if let key { return AnthropicEngine(apiKey: key) }
            if let url = claude() { return ClaudeCodeEngine(executable: url) }
            throw EngineError.noEngine
        default:
            throw UsageError(message: "unknown engine \(name)")
        }
    }

    private static func printJSON(_ object: Any) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        print(String(decoding: data, as: UTF8.self))
    }

    private static func recognize(_ args: Arguments) async throws {
        guard let path = args.positional.first else { throw UsageError(message: usage) }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let kit = try LatexKit.shared.get()
        var options = Recognizer.Options(engine: try makeEngine(args.options["--engine"] ?? "auto"),
                                         model: args.options["--model"] ?? ModelCatalog.defaultID,
                                         effort: args.options["--effort"] ?? "medium",
                                         autoRepair: !args.flags.contains("--no-repair"))
        options.imageOptions.upscale = args.flags.contains("--upscale")
        options.imageOptions.pad = !args.flags.contains("--no-pad")
        var mode = Recognizer.Mode.transcribe
        if let file = args.options["--verify-latex"] {
            let kind = SnipKind(rawValue: args.options["--verify-kind"] ?? "math") ?? .math
            mode = .verify(kind: kind, latex: try String(contentsOfFile: file, encoding: .utf8))
        }
        let verbose = args.flags.contains("--verbose")
        let result = try await Recognizer(kit: kit).run(imageData: data, mode: mode, options: options) { phase, partial in
            if verbose { FileHandle.standardError.write(Data("[\(phase.title)] \(partial.count) chars\n".utf8)) }
        }
        guard args.flags.contains("--json") else {
            print(result.latex)
            return
        }
        let formats = kit.formats(kind: result.kind, latex: result.latex)
        try printJSON([
            "kind": result.kind.rawValue,
            "latex": result.latex,
            "note": result.note ?? NSNull(),
            "problems": result.problems,
            "model": result.model,
            "engine": result.engine,
            "seconds": (result.seconds * 100).rounded() / 100,
            "raw": result.raw,
            "repaired": result.repaired,
            "packages": kit.packages(latex: result.latex),
            "formats": Dictionary(uniqueKeysWithValues: formats.map { ($0.id, $0.value) }),
        ])
    }

    private static func prepare(_ args: Arguments) throws {
        guard args.positional.count >= 2 else { throw UsageError(message: usage) }
        let data = try Data(contentsOf: URL(fileURLWithPath: args.positional[0]))
        var options = ImagePreparer.Options()
        options.upscale = args.flags.contains("--upscale")
        options.pad = !args.flags.contains("--no-pad")
        let image = try ImagePreparer.prepare(data, options: options)
        try image.data.write(to: URL(fileURLWithPath: args.positional[1]))
        print("\(image.width)x\(image.height) \(image.mediaType) \(image.data.count) bytes")
    }

    private static func formats(_ args: Arguments) throws {
        guard args.positional.count >= 2 else { throw UsageError(message: usage) }
        let kit = try LatexKit.shared.get()
        let latex = try String(contentsOfFile: args.positional[1], encoding: .utf8)
        let normalized = kit.normalize(kind: args.positional[0], latex: latex)
        try printJSON([
            "kind": normalized.kind.rawValue,
            "latex": normalized.latex,
            "problems": kit.validate(kind: normalized.kind, latex: normalized.latex),
            "packages": kit.packages(latex: normalized.latex),
            "formats": kit.formats(kind: normalized.kind, latex: normalized.latex).map { ["id": $0.id, "label": $0.label, "value": $0.value] },
        ])
    }

    private static func renderPreview(_ args: Arguments) async throws {
        guard args.positional.count >= 3, let kind = SnipKind(rawValue: args.positional[0]) else {
            throw UsageError(message: usage)
        }
        let latex = try String(contentsOfFile: args.positional[1], encoding: .utf8)
        let width = CGFloat(Double(args.options["--width"] ?? "") ?? 720)
        let png = try await PreviewSnapshotter.snapshot(kind: kind, latex: latex, width: width, dark: args.flags.contains("--dark"))
        try png.write(to: URL(fileURLWithPath: args.positional[2]))
        print("wrote \(args.positional[2])")
    }

    private static func selfTest() throws {
        let kit = try LatexKit.shared.get()
        _ = try Prompts.system()
        let problems = kit.validate(kind: .math, latex: #"x = \frac{-b \pm \sqrt{b^2 - 4ac}}{2a}"#)
        guard problems.isEmpty else { throw UsageError(message: "unexpected problems: \(problems)") }
        let broken = kit.validate(kind: .math, latex: #"\frac{1}{2"#)
        guard !broken.isEmpty else { throw UsageError(message: "validation did not catch a missing brace") }
        let mathml = kit.formats(kind: .math, latex: "x^2").first { $0.id == "mathml" }?.value ?? ""
        guard mathml.hasPrefix("<math") else { throw UsageError(message: "MathML conversion failed") }
        print("self-test passed")
    }
}
