import Carbon.HIToolbox
import Foundation

/// A global keyboard shortcut: Carbon key code and modifier flags, plus how to display it.
struct HotKeyCombo: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    var display: String

    /// ⌃⌘M, the same default as Mathpix Snip.
    static let standard = HotKeyCombo(keyCode: UInt32(kVK_ANSI_M), modifiers: UInt32(controlKey | cmdKey), display: "⌃⌘M")
}

/// User preferences, persisted in UserDefaults (the API key lives in the keychain).
@MainActor
final class Settings: ObservableObject {
    static let shared = Settings()

    private let defaults = UserDefaults.standard

    @Published var engine: EngineChoice { didSet { defaults.set(engine.rawValue, forKey: "engine") } }
    @Published var model: String { didSet { defaults.set(model, forKey: "model") } }
    @Published var effort: String { didSet { defaults.set(effort, forKey: "effort") } }
    @Published var autoRepair: Bool { didSet { defaults.set(autoRepair, forKey: "autoRepair") } }
    @Published var autoCopy: Bool { didSet { defaults.set(autoCopy, forKey: "autoCopy") } }
    @Published var playSound: Bool { didSet { defaults.set(playSound, forKey: "playSound") } }
    @Published var showWindowAtLaunch: Bool { didSet { defaults.set(showWindowAtLaunch, forKey: "showWindowAtLaunch") } }
    @Published var historyLimit: Int { didSet { defaults.set(historyLimit, forKey: "historyLimit") } }
    @Published var claudePath: String { didSet { defaults.set(claudePath, forKey: "claudePath") } }
    @Published var hotKey: HotKeyCombo {
        didSet { defaults.set(try? JSONEncoder().encode(hotKey), forKey: "hotKey") }
    }
    @Published private(set) var defaultFormats: [String: String] {
        didSet { defaults.set(defaultFormats, forKey: "defaultFormats") }
    }
    @Published private(set) var hasAPIKey = false

    private var cachedAPIKey: String??

    static let efforts: [(id: String, title: String)] = [
        ("low", "Fast"), ("medium", "Balanced"), ("high", "Thorough"),
    ]

    private init() {
        defaults.register(defaults: [
            "engine": EngineChoice.automatic.rawValue,
            "model": ModelCatalog.defaultID,
            "effort": "medium",
            "autoRepair": true,
            "autoCopy": true,
            "playSound": true,
            "showWindowAtLaunch": true,
            "historyLimit": 300,
            "claudePath": "",
        ])
        engine = EngineChoice(rawValue: defaults.string(forKey: "engine") ?? "") ?? .automatic
        model = defaults.string(forKey: "model") ?? ModelCatalog.defaultID
        effort = defaults.string(forKey: "effort") ?? "medium"
        autoRepair = defaults.bool(forKey: "autoRepair")
        autoCopy = defaults.bool(forKey: "autoCopy")
        playSound = defaults.bool(forKey: "playSound")
        showWindowAtLaunch = defaults.bool(forKey: "showWindowAtLaunch")
        historyLimit = max(10, defaults.integer(forKey: "historyLimit"))
        claudePath = defaults.string(forKey: "claudePath") ?? ""
        hotKey = (defaults.data(forKey: "hotKey")).flatMap { try? JSONDecoder().decode(HotKeyCombo.self, from: $0) } ?? .standard
        defaultFormats = defaults.dictionary(forKey: "defaultFormats") as? [String: String] ?? [:]
        hasAPIKey = apiKey != nil
    }

    // MARK: API key

    /// The saved key, or ANTHROPIC_API_KEY when TeXSnap was started from a shell that sets it.
    var apiKey: String? {
        if let cached = cachedAPIKey { return cached }
        var key = Keychain.readAPIKey()
        if key == nil, let env = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"],
           !env.trimmingCharacters(in: .whitespaces).isEmpty {
            key = env.trimmingCharacters(in: .whitespaces)
        }
        cachedAPIKey = .some(key)
        return key
    }

    func setAPIKey(_ key: String?) throws {
        let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            Keychain.deleteAPIKey()
        } else {
            try Keychain.saveAPIKey(trimmed)
        }
        cachedAPIKey = nil
        hasAPIKey = apiKey != nil
    }

    // MARK: Default copy format per kind

    func defaultFormat(for kind: SnipKind) -> String {
        defaultFormats[kind.rawValue] ?? "latex"
    }

    func setDefaultFormat(_ id: String, for kind: SnipKind) {
        defaultFormats[kind.rawValue] = id
    }

    // MARK: Engine

    /// The engine for a recognition. Double-checking always uses Claude, since the local model only transcribes.
    func resolveEngine(verifying: Bool = false) throws -> RecognitionEngine {
        func claude() -> URL? { ClaudeLocator.shared.locate(override: claudePath) }
        switch engine {
        case .api:
            guard let key = apiKey else { throw EngineError.missingAPIKey }
            return AnthropicEngine(apiKey: key)
        case .claudeCode:
            guard let url = claude() else { throw EngineError.claudeNotFound }
            return ClaudeCodeEngine(executable: url)
        case .local where !verifying:
            guard LocalModel.isInstalled else { throw EngineError.localModelMissing }
            return LocalEngine()
        case .local:
            if let key = apiKey { return AnthropicEngine(apiKey: key) }
            if let url = claude() { return ClaudeCodeEngine(executable: url) }
            throw EngineError.verifyNeedsClaude
        case .automatic:
            if let key = apiKey { return AnthropicEngine(apiKey: key) }
            if let url = claude() { return ClaudeCodeEngine(executable: url) }
            if verifying { throw EngineError.verifyNeedsClaude }
            if LocalModel.isInstalled { return LocalEngine() }
            throw EngineError.noEngine
        }
    }

    /// A one-line description of what "Automatic" (or the chosen engine) will use.
    var engineSummary: String {
        switch engine {
        case .api:
            return apiKey == nil ? "No API key set" : "Anthropic API"
        case .claudeCode:
            return ClaudeLocator.shared.locate(override: claudePath) == nil ? "Claude Code not found" : "Claude Code"
        case .local:
            return LocalModel.isInstalled ? "Local model" : "Local model not installed"
        case .automatic:
            if apiKey != nil { return "Anthropic API" }
            if ClaudeLocator.shared.locate(override: claudePath) != nil { return "Claude Code" }
            if LocalModel.isInstalled { return "Local model" }
            return "Not set up"
        }
    }
}

/// Caches where the `claude` command lives; the lookup can involve a login shell.
@MainActor
final class ClaudeLocator {
    static let shared = ClaudeLocator()

    private var cache: [String: URL?] = [:]

    func locate(override: String) -> URL? {
        if let cached = cache[override] { return cached }
        let url = ClaudeCodeEngine.locate(override: override)
        cache[override] = url
        return url
    }

    func invalidate() {
        cache.removeAll()
    }

    /// Looks the command up in the background so the first snip does not wait for a login shell.
    func prefetch(override: String) {
        guard cache[override] == nil else { return }
        Task.detached(priority: .utility) {
            let url = ClaudeCodeEngine.locate(override: override)
            await MainActor.run { ClaudeLocator.shared.cache[override] = url }
        }
    }
}
