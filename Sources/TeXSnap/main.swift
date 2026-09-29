import AppKit

MainActor.assumeIsolated {
    if CLI.handles(CommandLine.arguments) {
        CLI.run(CommandLine.arguments)
    }
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) {
        app.run()
    }
}
