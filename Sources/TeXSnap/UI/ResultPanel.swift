import AppKit
import Combine
import SwiftUI

/// The small floating result shown after a snip: progress, then the rendering with one-click copy buttons.
/// It never takes focus from the app the user is working in, and closes itself shortly after the result is in
/// (not while the pointer is over it).
@MainActor
final class ResultPanelController {
    private let store: SnipStore
    private let settings: Settings
    private let openInWindow: (Snip.ID) -> Void
    private var panel: NSPanel?
    private var snipID: Snip.ID?
    private var hovering = false
    private var dismissal: DispatchWorkItem?
    private var watch: AnyCancellable?

    private static let width: CGFloat = 440
    private static let doneDelay: TimeInterval = 6
    private static let failedDelay: TimeInterval = 12

    init(store: SnipStore, settings: Settings, openInWindow: @escaping (Snip.ID) -> Void) {
        self.store = store
        self.settings = settings
        self.openInWindow = openInWindow
    }

    var isVisible: Bool { panel?.isVisible == true }

    /// Shows the result of `id` next to the pointer, replacing whatever the panel showed before.
    func show(_ id: Snip.ID) {
        snipID = id
        hovering = false
        dismissal?.cancel()
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let view = ResultPopupView(store: store, settings: settings, snipID: id,
                                   onSize: { [weak self] size in self?.resize(to: size) },
                                   onHover: { [weak self] inside in self?.hover(inside) },
                                   onCopy: { [weak self] in self?.scheduleClose(after: 1.2) },
                                   onOpen: { [weak self] in self?.open() },
                                   onClose: { [weak self] in self?.close() })
        panel.contentView = NSHostingView(rootView: view)
        place(panel, size: NSSize(width: Self.width, height: 120))
        panel.orderFrontRegardless()

        // Close on its own once the result is in.
        watch = store.$snips
            .map { snips in snips.first { $0.id == id }?.status }
            .removeDuplicates()
            .sink { [weak self] status in
                guard let self else { return }
                guard let status else { return self.close() }  // the snip was deleted
                switch status {
                case .running: self.dismissal?.cancel()
                case .done: self.scheduleClose(after: Self.doneDelay)
                case .failed: self.scheduleClose(after: Self.failedDelay)
                }
            }
    }

    func close() {
        dismissal?.cancel()
        watch = nil
        panel?.orderOut(nil)
        panel?.contentView = nil
        snipID = nil
    }

    private func open() {
        guard let id = snipID else { return }
        close()
        openInWindow(id)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 120),
                            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                            backing: .buffered, defer: true)
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        return panel
    }

    /// Below and to the right of the pointer, kept on the pointer's screen.
    private func place(_ panel: NSPanel, size: NSSize) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var origin = NSPoint(x: mouse.x + 16, y: mouse.y - 16 - size.height)
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    /// Follows the content's height, keeping the top edge where it is (and the panel on screen).
    private func resize(to size: CGSize) {
        guard let panel, size.height > 0 else { return }
        let top = panel.frame.maxY
        var frame = NSRect(x: panel.frame.minX, y: top - size.height, width: Self.width, height: size.height)
        if let visible = panel.screen?.visibleFrame, frame.minY < visible.minY + 8 {
            frame.origin.y = visible.minY + 8
        }
        if frame != panel.frame { panel.setFrame(frame, display: true) }
    }

    private func hover(_ inside: Bool) {
        hovering = inside
        if inside {
            dismissal?.cancel()
        } else if let id = snipID, let snip = store.snip(id), snip.status != .running {
            scheduleClose(after: 2.5)
        }
    }

    private func scheduleClose(after seconds: TimeInterval) {
        dismissal?.cancel()
        guard !hovering || seconds < 2 else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.hovering || seconds < 2 else { return }
                self.close()
            }
        }
        dismissal = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }
}

private struct ResultPopupView: View {
    @ObservedObject var store: SnipStore
    @ObservedObject var settings: Settings
    let snipID: Snip.ID
    let onSize: (CGSize) -> Void
    let onHover: (Bool) -> Void
    let onCopy: () -> Void
    let onOpen: () -> Void
    let onClose: () -> Void

    @State private var previewHeight: CGFloat = 60

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let snip = store.snip(snipID) {
                header(snip)
                content(snip)
                if snip.status == .done, snip.kind != .none {
                    copyButtons(snip)
                }
            }
        }
        .padding(14)
        .frame(width: 440, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(nsColor: .separatorColor)))
        .onGeometryChange(for: CGSize.self) { $0.size } action: { onSize($0) }
        .onHover(perform: onHover)
    }

    private func header(_ snip: Snip) -> some View {
        HStack(spacing: 8) {
            switch snip.status {
            case .running:
                ProgressView().controlSize(.small)
                Text(store.live[snip.id]?.phase.title ?? "Working…").font(.headline)
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("Could not transcribe").font(.headline)
            case .done:
                Image(systemName: snip.kind.symbol).foregroundStyle(.secondary)
                Text(snip.kind.title).font(.headline)
                if let copied = copiedLabel(snip) {
                    Text("· Copied \(copied)").foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(action: onOpen) {
                Image(systemName: "macwindow")
            }
            .buttonStyle(.borderless)
            .help("Open in the TeXSnap window to edit")
            Button(action: onClose) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Close")
        }
    }

    @ViewBuilder
    private func content(_ snip: Snip) -> some View {
        switch snip.status {
        case .running:
            let partial = store.live[snip.id]?.partial ?? ""
            Text(partial.isEmpty ? " " : partial)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .failed(let message):
            Text(message)
                .font(.callout)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
        case .done:
            if snip.kind == .none {
                Text(snip.note ?? "No math, text or table found in this snip.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                PreviewWebView(kind: snip.kind, latex: snip.latex, contentHeight: $previewHeight, fitWidth: true)
                    .frame(height: min(max(previewHeight, 40), 240))
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                if !snip.problems.isEmpty {
                    Label("The LaTeX has problems; open it to check.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    /// The default format first, then the next few, as one-click buttons.
    private func copyButtons(_ snip: Snip) -> some View {
        let formats = store.formats(for: snip)
        let preferred = settings.defaultFormat(for: snip.kind)
        let ordered = formats.filter { $0.id == preferred } + formats.filter { $0.id != preferred }
        return HStack(spacing: 6) {
            ForEach(ordered.prefix(4)) { format in
                let copied = store.lastCopy.map { $0.snip == snip.id && $0.format == format.id } ?? false
                Button {
                    store.copy(format.value, snip: snip.id, format: format.id)
                    onCopy()
                } label: {
                    Label(shortLabel(format), systemImage: copied ? "checkmark" : "doc.on.doc")
                        .lineLimit(1)
                }
                .controlSize(.small)
                .help(format.label)
            }
        }
    }

    private func copiedLabel(_ snip: Snip) -> String? {
        guard let copy = store.lastCopy, copy.snip == snip.id,
              let format = store.formats(for: snip).first(where: { $0.id == copy.format }) else { return nil }
        return "as " + shortLabel(format)
    }

    /// "LaTeX (\\hline rules, no booktabs)" -> "LaTeX (\\hline rules)": short enough for a button.
    private func shortLabel(_ format: OutputFormat) -> String {
        var label = format.label.replacingOccurrences(of: "  ", with: " ")
            .replacingOccurrences(of: " environment", with: "")
            .replacingOccurrences(of: " (Word)", with: "")
            .replacingOccurrences(of: " (Excel, Sheets)", with: "")
        if let open = label.firstIndex(of: "("), let comma = label[open...].firstIndex(of: ",") {
            label = String(label[..<comma]) + ")"
        }
        return label
    }
}
