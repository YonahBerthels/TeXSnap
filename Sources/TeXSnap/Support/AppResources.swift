import Foundation

/// Locates the files in `Resources/` (prompts, KaTeX, preview page).
/// Inside the app bundle they live in Contents/Resources; `TEXSNAP_RESOURCES` points elsewhere for development.
enum AppResources {
    static let root: URL = {
        if let override = ProcessInfo.processInfo.environment["TEXSNAP_RESOURCES"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return Bundle.main.resourceURL ?? Bundle.main.bundleURL
    }()

    static func url(_ relativePath: String) -> URL {
        root.appendingPathComponent(relativePath)
    }

    static func text(_ relativePath: String) throws -> String {
        try String(contentsOf: url(relativePath), encoding: .utf8)
    }
}
