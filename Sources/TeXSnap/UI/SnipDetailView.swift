import SwiftUI

/// The selected snip: the image next to its rendering, status, the editable LaTeX, and copy formats.
struct SnipDetailView: View {
    @ObservedObject var store: SnipStore
    @ObservedObject var settings: Settings
    let snipID: Snip.ID
    let openSettings: () -> Void

    @State private var previewHeight: CGFloat = 140

    var body: some View {
        if let snip = store.snip(snipID) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    comparison(snip)
                    status(snip)
                    editor(snip)
                    if snip.status == .done, snip.kind != .none {
                        formats(snip)
                    }
                }
                .padding(20)
            }
        }
    }

    // MARK: Image and rendering

    private func comparison(_ snip: Snip) -> some View {
        let height = min(max(previewHeight, 120), 440)
        let running = snip.status == .running
        return HStack(alignment: .top, spacing: 12) {
            Panel(title: "Snip") {
                if let image = store.image(for: snip) {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: image.size.width, maxHeight: image.size.height)
                        .padding(12)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            Panel(title: "Rendered") {
                ZStack {
                    PreviewWebView(kind: snip.kind, latex: running ? "" : snip.latex, contentHeight: $previewHeight)
                        .opacity(running ? 0 : 1)
                    if running {
                        ProgressView().controlSize(.small)
                    } else if case .failed = snip.status {
                        Image(systemName: "exclamationmark.triangle").font(.title2).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(height: height + 26)
    }

    // MARK: Status

    @ViewBuilder
    private func status(_ snip: Snip) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                switch snip.status {
                case .running:
                    ProgressView().controlSize(.small)
                    Text(store.live[snip.id]?.phase.title ?? "Working…")
                    if let started = store.live[snip.id]?.started {
                        Text(started, style: .timer).monospacedDigit().foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Cancel") { store.cancel(snip.id) }
                case .failed(let message):
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(message).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Settings…", action: openSettings)
                    Button("Try Again") { store.recognize(snip.id, mode: .transcribe) }
                case .done:
                    Picker("", selection: Binding(get: { snip.kind }, set: { store.setKind(snip.id, to: $0) })) {
                        ForEach([SnipKind.math, .table, .text], id: \.self) { kind in
                            Label(kind.title, systemImage: kind.symbol).tag(kind)
                        }
                        if snip.kind == .none { Text(SnipKind.none.title).tag(SnipKind.none) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .help("What the snip contains. Change it if Claude guessed wrong.")
                    Text(details(snip)).foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        store.recognize(snip.id, mode: .verify(kind: snip.kind, latex: snip.latex))
                    } label: {
                        Label("Double-check", systemImage: "checkmark.seal")
                    }
                    .help("Ask Claude to compare this LaTeX with the image once more and fix any difference")
                    .disabled(snip.kind == .none)
                    Button {
                        store.recognize(snip.id, mode: .transcribe)
                    } label: {
                        Label("Retry", systemImage: "arrow.clockwise")
                    }
                    .help("Transcribe the image again from scratch")
                }
            }
            if snip.status == .done, let note = snip.note {
                Label(note, systemImage: "info.circle")
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if snip.status == .done, !snip.problems.isEmpty {
                Label {
                    Text(snip.problems.joined(separator: "\n")).textSelection(.enabled)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.callout)
    }

    private func details(_ snip: Snip) -> String {
        var parts = [ModelCatalog.name(for: snip.model), String(format: "%.1f s", snip.seconds)]
        if snip.engine == "Claude Code" { parts.insert("via Claude Code", at: 1) }
        if snip.isEdited { parts.append("edited") }
        return parts.joined(separator: " · ")
    }

    // MARK: LaTeX

    private func editor(_ snip: Snip) -> some View {
        let running = snip.status == .running
        let text = running ? (store.live[snip.id]?.partial ?? "") : snip.latex
        let lines = max(3, min(14, text.split(separator: "\n", omittingEmptySubsequences: false).count + 1))
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("LaTeX").font(.headline)
                Spacer()
                if snip.isEdited {
                    Button("Revert to Recognized") { store.revert(snip.id) }
                        .controlSize(.small)
                }
            }
            LatexEditor(text: Binding(get: { text }, set: { store.updateLatex(snip.id, to: $0) }),
                        isEditable: snip.status == .done, identity: snip.id)
                .frame(height: CGFloat(lines) * 17 + 20)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    // MARK: Formats

    private func formats(_ snip: Snip) -> some View {
        let formats = store.formats(for: snip)
        let packages = store.packages(for: snip)
        let preferred = settings.defaultFormat(for: snip.kind)
        let effectiveDefault = formats.contains { $0.id == preferred } ? preferred : formats.first?.id
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Copy as").font(.headline)
                Spacer()
                if !packages.isEmpty {
                    Text("Needs \\usepackage{\(packages.joined(separator: ","))}")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            VStack(spacing: 0) {
                ForEach(Array(formats.enumerated()), id: \.element.id) { index, format in
                    if index > 0 { Divider() }
                    FormatRow(format: format,
                              isDefault: format.id == effectiveDefault,
                              copied: store.lastCopy.map { $0.snip == snip.id && $0.format == format.id } ?? false,
                              copy: { store.copy(format.value, snip: snip.id, format: format.id) },
                              makeDefault: { settings.setDefaultFormat(format.id, for: snip.kind) })
                }
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
        }
    }
}

private struct FormatRow: View {
    let format: OutputFormat
    let isDefault: Bool
    let copied: Bool
    let copy: () -> Void
    let makeDefault: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Button(action: makeDefault) {
                Image(systemName: isDefault ? "star.fill" : "star")
                    .foregroundStyle(isDefault ? Color.yellow : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(isDefault ? "Copied automatically after each snip" : "Copy this format automatically after each snip")
            Text(format.label)
                .foregroundStyle(.secondary)
                .frame(width: 170, alignment: .leading)
            Text(format.value)
                .font(.system(size: 11.5, design: .monospaced))
                .lineLimit(3)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            Button(action: copy) {
                Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                    .frame(width: 70)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// A titled, rounded container.
private struct Panel<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}
