import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: Settings
    let clearHistory: () -> Void
    let pauseHotKey: (Bool) -> Void

    @State private var keyDraft = ""
    @State private var keyStatus: String?
    @State private var testing = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    @State private var confirmClear = false
    @State private var claudeLocation: String = ""

    private static let formatChoices: [SnipKind: [(id: String, title: String)]] = [
        .math: [("latex", "LaTeX"), ("inline_dollar", "$…$"), ("display_dollar", "$$…$$"), ("display_bracket", "\\[…\\]"),
                ("inline_paren", "\\(…\\)"), ("equation", "equation environment"), ("mathml", "MathML (Word)")],
        .table: [("latex", "LaTeX"), ("markdown", "Markdown"), ("tsv", "TSV (Excel, Sheets)"), ("csv", "CSV"), ("html", "HTML")],
        .text: [("latex", "LaTeX"), ("markdown", "Markdown")],
    ]

    var body: some View {
        Form {
            Section("Recognition") {
                Picker("Engine", selection: $settings.engine) {
                    ForEach(EngineChoice.allCases) { Text($0.title).tag($0) }
                }
                LabeledContent("In use") {
                    Text(settings.engineSummary)
                        .foregroundStyle(["Anthropic API", "Claude Code", "Local model"].contains(settings.engineSummary)
                                         ? Color.secondary : Color.orange)
                }
                if settings.engine == .local {
                    LabeledContent("Local model") {
                        Text(LocalModel.isInstalled ? LocalModel.directory.path : "Not installed: run scripts/install-model.sh")
                            .textSelection(.enabled)
                            .foregroundStyle(LocalModel.isInstalled ? Color.secondary : Color.orange)
                    }
                    Text("Runs offline on this Mac. It loads on the first snip and unloads after two idle minutes. Double-check still uses Claude when available.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Model", selection: $settings.model) {
                        ForEach(ModelCatalog.all) { model in
                            Text("\(model.name) (\(model.detail.lowercased()))").tag(model.id)
                        }
                    }
                    Picker("Effort", selection: $settings.effort) {
                        ForEach(Settings.efforts, id: \.id) { Text($0.title).tag($0.id) }
                    }
                    .disabled(!ModelCatalog.info(settings.model).supportsEffort)
                    Toggle(isOn: $settings.autoRepair) {
                        Text("Fix LaTeX errors automatically")
                        Text("If the LaTeX does not parse, Claude gets one more try with the exact error.")
                    }
                }
            }

            Section {
                SecureField("API key", text: $keyDraft, prompt: Text(settings.hasAPIKey ? "Saved in the keychain" : "sk-ant-…"))
                HStack {
                    Button("Save") { saveKey() }
                        .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Remove") { removeKey() }
                        .disabled(!settings.hasAPIKey)
                    Button("Test") { testKey() }
                        .disabled(testing || (!settings.hasAPIKey && keyDraft.isEmpty))
                    if testing { ProgressView().controlSize(.small) }
                    Spacer()
                    if let keyStatus {
                        Text(keyStatus).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            } header: {
                Text("Anthropic API key")
            } footer: {
                Text("Optional. Stored in your login keychain. Without a key, TeXSnap uses Claude Code and your Claude login.")
                    .foregroundStyle(.secondary)
            }

            Section("Claude Code") {
                LabeledContent("Found at") {
                    Text(claudeLocation.isEmpty ? "Not found" : claudeLocation)
                        .textSelection(.enabled)
                        .foregroundStyle(claudeLocation.isEmpty ? Color.orange : Color.secondary)
                }
                TextField("Custom path", text: $settings.claudePath, prompt: Text("Detected automatically"))
                    .onSubmit(refreshClaudeLocation)
            }

            Section("Snipping") {
                LabeledContent("Shortcut") {
                    ShortcutRecorder(combo: $settings.hotKey, pause: pauseHotKey)
                }
                Toggle("Copy the result to the clipboard automatically", isOn: $settings.autoCopy)
                Picker("Math copies as", selection: formatBinding(.math)) { options(.math) }
                    .disabled(!settings.autoCopy)
                Picker("Tables copy as", selection: formatBinding(.table)) { options(.table) }
                    .disabled(!settings.autoCopy)
                Picker("Text copies as", selection: formatBinding(.text)) { options(.text) }
                    .disabled(!settings.autoCopy)
                Toggle("Play a sound when a snip is done", isOn: $settings.playSound)
            }

            Section("General") {
                Toggle("Open TeXSnap at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.orange)
                }
                Toggle("Show the window when TeXSnap opens", isOn: $settings.showWindowAtLaunch)
                Stepper("Keep the last \(settings.historyLimit) snips", value: $settings.historyLimit, in: 20...2000, step: 20)
                Button("Clear History…", role: .destructive) { confirmClear = true }
                    .confirmationDialog("Delete all snips and their images?", isPresented: $confirmClear) {
                        Button("Delete All", role: .destructive, action: clearHistory)
                    }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .frame(minHeight: 560, idealHeight: 700)
        .onAppear(perform: refreshClaudeLocation)
        .onChange(of: settings.claudePath) { _, _ in refreshClaudeLocation() }
    }

    private func options(_ kind: SnipKind) -> some View {
        ForEach(Self.formatChoices[kind] ?? [], id: \.id) { Text($0.title).tag($0.id) }
    }

    private func formatBinding(_ kind: SnipKind) -> Binding<String> {
        Binding(get: {
            let current = settings.defaultFormat(for: kind)
            return (Self.formatChoices[kind] ?? []).contains { $0.id == current } ? current : "latex"
        }, set: { settings.setDefaultFormat($0, for: kind) })
    }

    private func refreshClaudeLocation() {
        ClaudeLocator.shared.invalidate()
        claudeLocation = ClaudeLocator.shared.locate(override: settings.claudePath)?.path ?? ""
    }

    private func saveKey() {
        do {
            try settings.setAPIKey(keyDraft)
            keyDraft = ""
            keyStatus = "Saved."
        } catch {
            keyStatus = error.localizedDescription
        }
    }

    private func removeKey() {
        try? settings.setAPIKey(nil)
        keyStatus = "Removed."
    }

    private func testKey() {
        let key = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? settings.apiKey : keyDraft
        guard let key else { return }
        testing = true
        keyStatus = nil
        Task {
            let problem = await AnthropicEngine.checkKey(key)
            testing = false
            keyStatus = problem ?? "The key works."
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = "Could not change the login item: \(error.localizedDescription)"
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

/// Click, then press the new shortcut. Esc cancels.
struct ShortcutRecorder: View {
    @Binding var combo: HotKeyCombo
    let pause: (Bool) -> Void

    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 8) {
            Button(recording ? "Type a shortcut…" : combo.display) {
                recording ? stop() : start()
            }
            .frame(minWidth: 120)
            if combo != .standard && !recording {
                Button("Reset") { combo = .standard }
                    .controlSize(.small)
            }
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        recording = true
        pause(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {  // Esc
                stop()
                return nil
            }
            let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
            guard !modifiers.intersection([.command, .control, .option]).isEmpty else {
                NSSound.beep()
                return nil
            }
            combo = HotKeyCombo(keyCode: UInt32(event.keyCode),
                                modifiers: HotKeyCombo.carbonModifiers(modifiers),
                                display: HotKeyCombo.displayString(modifiers: modifiers, keyCode: event.keyCode,
                                                                   characters: event.charactersIgnoringModifiers))
            stop()
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording {
            recording = false
            pause(false)
        }
    }
}
