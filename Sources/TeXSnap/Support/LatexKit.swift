import Foundation
import JavaScriptCore

enum LatexKitError: LocalizedError {
    case unavailable
    case script(String)

    var errorDescription: String? {
        switch self {
        case .unavailable: return "JavaScriptCore is unavailable."
        case .script(let message): return "Could not load the LaTeX tools: \(message)"
        }
    }
}

/// Runs Resources/web/latexkit.js (with KaTeX) in JavaScriptCore: normalizing, validating and
/// converting transcriptions exactly as the preview page does.
@MainActor
final class LatexKit {
    static let shared: Result<LatexKit, Error> = Result { try LatexKit() }

    private let context: JSContext
    private let kit: JSValue

    private final class ExceptionBox { var message: String? }

    init() throws {
        guard let context = JSContext() else { throw LatexKitError.unavailable }
        let box = ExceptionBox()
        context.exceptionHandler = { _, exception in
            box.message = exception?.toString() ?? "unknown JavaScript error"
        }
        for file in ["web/katex/katex.min.js", "web/latexkit.js"] {
            let source = try AppResources.text(file)
            context.evaluateScript(source, withSourceURL: AppResources.url(file))
            if let message = box.message { throw LatexKitError.script("\(file): \(message)") }
        }
        guard let kit = context.objectForKeyedSubscript("LatexKit"), kit.isObject else {
            throw LatexKitError.script("LatexKit is not defined")
        }
        self.context = context
        self.kit = kit
    }

    func normalize(kind: String?, latex: String) -> (kind: SnipKind, latex: String) {
        let result = kit.invokeMethod("normalize", withArguments: [kind ?? "", latex])
        let k = result?.forProperty("kind")?.toString() ?? "text"
        let l = result?.forProperty("latex")?.toString() ?? latex
        return (SnipKind(rawValue: k) ?? .text, l)
    }

    /// LaTeX problems (syntax errors, malformed tables); empty when the transcription is valid.
    func validate(kind: SnipKind, latex: String) -> [String] {
        let result = kit.invokeMethod("validate", withArguments: [kind.rawValue, latex])
        guard let items = result?.toArray() as? [[String: Any]] else { return [] }
        return items.compactMap { $0["message"] as? String }
    }

    func formats(kind: SnipKind, latex: String) -> [OutputFormat] {
        let result = kit.invokeMethod("formats", withArguments: [kind.rawValue, latex])
        guard let items = result?.toArray() as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let id = item["id"] as? String, let label = item["label"] as? String,
                  let value = item["value"] as? String else { return nil }
            return OutputFormat(id: id, label: label, value: value)
        }
    }

    func packages(latex: String) -> [String] {
        kit.invokeMethod("packages", withArguments: [latex])?.toArray() as? [String] ?? []
    }
}
