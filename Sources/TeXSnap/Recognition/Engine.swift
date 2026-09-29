import Foundation

struct EngineRequest {
    let system: String
    let image: PreparedImage
    let prompt: String
    let model: String
    let effort: String
}

struct EngineOutput {
    let text: String
    let model: String
    /// The reply hit the output limit before it finished.
    let truncated: Bool
}

/// Something that sends an image and a prompt to a model (Claude, or the local one) and streams back the reply.
protocol RecognitionEngine {
    var displayName: String { get }
    /// Runs on this Mac: transcription only, no repair or double-check prompts.
    var isLocal: Bool { get }
    func complete(_ request: EngineRequest, onText: @escaping @Sendable (String) -> Void) async throws -> EngineOutput
}

extension RecognitionEngine {
    var isLocal: Bool { false }
}

enum EngineChoice: String, CaseIterable, Identifiable {
    case automatic, api, claudeCode, local

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: return "Automatic"
        case .api: return "Anthropic API (API key)"
        case .claudeCode: return "Claude Code (your Claude login)"
        case .local: return "On this Mac (offline)"
        }
    }
}

struct ModelInfo: Identifiable, Hashable {
    let id: String
    let name: String
    let detail: String
    let supportsEffort: Bool
    /// Accepts `fallbacks: "default"` (server-side retry on another model after a policy decline).
    let supportsFallbacks: Bool
}

enum ModelCatalog {
    static let defaultID = "claude-opus-5-5"

    static let all: [ModelInfo] = [
        ModelInfo(id: "claude-opus-5-5", name: "Claude Opus 5.5", detail: "Most accurate",
                  supportsEffort: true, supportsFallbacks: true),
        ModelInfo(id: "claude-sonnet-5-5", name: "Claude Sonnet 5.5", detail: "Faster, lower cost",
                  supportsEffort: true, supportsFallbacks: true),
        ModelInfo(id: "claude-haiku-4-5", name: "Claude Haiku 4.5", detail: "Fastest, lowest cost",
                  supportsEffort: false, supportsFallbacks: false),
    ]

    static func info(_ id: String) -> ModelInfo {
        all.first { $0.id == id } ?? ModelInfo(id: id, name: id, detail: "", supportsEffort: false, supportsFallbacks: false)
    }

    /// Display name for a model id reported by the API (which may carry a suffix).
    static func name(for id: String) -> String {
        all.first { id == $0.id || id.hasPrefix($0.id + "-") }?.name ?? id
    }
}

enum EngineError: LocalizedError {
    case noEngine
    case missingAPIKey
    case claudeNotFound
    case http(status: Int, message: String, retryAfter: Double?)
    case api(type: String, message: String)
    case refusal(category: String?)
    case claudeCode(String)
    case emptyResponse
    case network(String)
    case localModelMissing
    case local(String)
    case verifyNeedsClaude

    var errorDescription: String? {
        switch self {
        case .noEngine:
            return "TeXSnap needs a way to recognize snips: add an Anthropic API key in Settings, install Claude Code and log in, or install the local model."
        case .localModelMissing:
            return "The local model is not installed. Run scripts/install-model.sh in the TeXSnap folder, or choose a Claude engine in Settings."
        case .local(let message):
            return "Local model: \(message)"
        case .verifyNeedsClaude:
            return "Double-check uses Claude: add an Anthropic API key in Settings, or install Claude Code and log in."
        case .missingAPIKey:
            return "No Anthropic API key is set. Add one in Settings, or switch the engine to Claude Code."
        case .claudeNotFound:
            return "Claude Code (the claude command) was not found. Install it, or choose the Anthropic API engine in Settings."
        case .http(let status, let message, _):
            switch status {
            case 401: return "The Anthropic API key was rejected. Check it in Settings. (\(message))"
            case 403: return "This API key may not use that model: \(message)"
            case 404: return "The model was not found: \(message)"
            case 413: return "The image is too large for the API."
            case 429: return "The Anthropic API rate limit was reached. Try again in a moment."
            case 529: return "Claude is overloaded right now. Try again in a moment."
            case 400: return "The API rejected the request: \(message)"
            default: return "Anthropic API error \(status): \(message)"
            }
        case .api(let type, let message):
            return type == "overloaded_error" ? "Claude is overloaded right now. Try again in a moment." : message
        case .refusal:
            return "Claude declined to transcribe this image."
        case .claudeCode(let message):
            return "Claude Code: \(message)"
        case .emptyResponse:
            return "The model returned an empty reply."
        case .network(let message):
            return "Network error: \(message)"
        }
    }

    var isRetryable: Bool {
        switch self {
        case .http(let status, _, _): return [408, 409, 429, 529].contains(status) || (500...599).contains(status)
        case .api(let type, _): return ["overloaded_error", "api_error", "rate_limit_error"].contains(type)
        case .network: return true
        default: return false
        }
    }

    var retryAfter: Double? {
        if case .http(_, _, let retryAfter) = self { return retryAfter }
        return nil
    }
}
