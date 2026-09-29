import Foundation

/// Image in, checked LaTeX out: prepares the image, asks Claude, normalizes and validates the reply,
/// and asks once more with the specific errors if the LaTeX does not parse.
@MainActor
final class Recognizer {
    struct Options {
        var engine: RecognitionEngine
        var model: String
        var effort: String
        var autoRepair: Bool
        var imageOptions = ImagePreparer.Options()
    }

    enum Mode {
        case transcribe
        /// Double-check an existing transcription against the image.
        case verify(kind: SnipKind, latex: String)
    }

    enum Phase: Equatable {
        case preparing, reading, writing, fixing

        var title: String {
            switch self {
            case .preparing: return "Preparing image…"
            case .reading: return "Reading image…"
            case .writing: return "Writing LaTeX…"
            case .fixing: return "Fixing LaTeX errors…"
            }
        }
    }

    struct Result {
        var kind: SnipKind
        var latex: String
        var note: String?
        var problems: [String]
        var model: String
        var engine: String
        var seconds: Double
        var raw: String
        var repaired: Bool
    }

    private struct Candidate {
        var kind: SnipKind
        var latex: String
        var note: String?
        var problems: [String]
        var model: String
        var raw: String
    }

    let kit: LatexKit

    init(kit: LatexKit) {
        self.kit = kit
    }

    func run(imageData: Data, mode: Mode, options: Options,
             progress: @escaping @MainActor (Phase, String) -> Void) async throws -> Result {
        let started = Date()
        progress(.preparing, "")
        let imageOptions = options.imageOptions
        let image = try await Task.detached(priority: .userInitiated) {
            try ImagePreparer.prepare(imageData, options: imageOptions)
        }.value
        let system = try Prompts.system()
        let prompt: String
        switch mode {
        case .transcribe: prompt = Prompts.transcribe
        case .verify(let kind, let latex): prompt = Prompts.verify(kind: kind, latex: latex)
        }

        progress(.reading, "")
        let throttle = ProgressThrottle { text in progress(.writing, ModelOutput.partialLatex(text)) }
        let first = try await options.engine.complete(
            EngineRequest(system: system, image: image, prompt: prompt, model: options.model, effort: options.effort),
            onText: { throttle.push($0) })
        throttle.cancel()
        var best = evaluate(first)
        var repaired = false

        // The local model only knows how to transcribe; asking it to repair would just repeat the reply.
        if options.autoRepair, !options.engine.isLocal, !best.problems.isEmpty, best.kind != .none {
            progress(.fixing, best.latex)
            let request = EngineRequest(system: system, image: image,
                                        prompt: Prompts.repair(kind: best.kind, latex: best.latex, problems: best.problems),
                                        model: options.model, effort: options.effort)
            if let second = try? await options.engine.complete(request, onText: { _ in }) {
                let candidate = evaluate(second)
                if candidate.problems.count < best.problems.count {
                    best = Candidate(kind: candidate.kind, latex: candidate.latex, note: candidate.note ?? best.note,
                                     problems: candidate.problems, model: candidate.model, raw: candidate.raw)
                    repaired = true
                }
            }
        }
        try Task.checkCancellation()
        return Result(kind: best.kind, latex: best.latex, note: best.note, problems: best.problems, model: best.model,
                      engine: options.engine.displayName, seconds: Date().timeIntervalSince(started), raw: best.raw,
                      repaired: repaired)
    }

    private func evaluate(_ output: EngineOutput) -> Candidate {
        let parsed = ModelOutput.parse(output.text)
        let normalized = kit.normalize(kind: parsed.kind, latex: parsed.latex)
        var problems = kit.validate(kind: normalized.kind, latex: normalized.latex)
        if output.truncated { problems.append("The reply was cut off before it finished.") }
        return Candidate(kind: normalized.kind, latex: normalized.latex, note: parsed.note, problems: problems,
                         model: output.model, raw: output.text)
    }
}

/// Coalesces streamed text into at most ~12 main-thread updates per second.
final class ProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: String?
    private var scheduled = false
    private var cancelled = false
    private let deliver: @MainActor (String) -> Void

    init(_ deliver: @escaping @MainActor (String) -> Void) {
        self.deliver = deliver
    }

    func push(_ text: String) {
        lock.lock()
        latest = text
        let schedule = !scheduled && !cancelled
        scheduled = true
        lock.unlock()
        guard schedule else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [self] in
            lock.lock()
            let text = cancelled ? nil : latest
            scheduled = false
            lock.unlock()
            if let text { MainActor.assumeIsolated { deliver(text) } }
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}
