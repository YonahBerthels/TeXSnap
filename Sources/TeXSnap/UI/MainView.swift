import SwiftUI
import UniformTypeIdentifiers

/// What the window's buttons do; provided by the app delegate.
struct AppActions {
    var snip: () -> Void
    var paste: () -> Void
    var open: () -> Void
    var settings: () -> Void
    var addImageData: (Data) -> Void
}

struct MainView: View {
    @ObservedObject var store: SnipStore
    @ObservedObject var settings: Settings
    let actions: AppActions

    @State private var dropTargeted = false

    var body: some View {
        NavigationSplitView {
            HistoryList(store: store, settings: settings)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
        } detail: {
            Group {
                if let id = store.selection, store.snip(id) != nil {
                    SnipDetailView(store: store, settings: settings, snipID: id, openSettings: actions.settings)
                } else {
                    EmptyStateView(settings: settings, actions: actions)
                }
            }
            .frame(minWidth: 560, minHeight: 440)
        }
        .toolbar {
            ToolbarItemGroup {
                Button(action: actions.snip) {
                    Label("Snip", systemImage: "viewfinder")
                }
                .help("Snip a region of the screen (\(settings.hotKey.display))")
                Button(action: actions.paste) {
                    Label("Paste Image", systemImage: "doc.on.clipboard")
                }
                .help("Convert the image on the clipboard (⇧⌘V)")
                Button(action: actions.open) {
                    Label("Open Image", systemImage: "photo.on.rectangle")
                }
                .help("Convert an image file (⌘O)")
            }
        }
        .onDrop(of: [.fileURL, .image], isTargeted: $dropTargeted, perform: handleDrop)
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let add = actions.addImageData
        var accepted = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                accepted = true
                _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                    guard let data, let url = URL(dataRepresentation: data, relativeTo: nil),
                          let contents = try? Data(contentsOf: url) else { return }
                    DispatchQueue.main.async { add(contents) }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                accepted = true
                _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    guard let data else { return }
                    DispatchQueue.main.async { add(data) }
                }
            }
        }
        return accepted
    }
}

struct HistoryList: View {
    @ObservedObject var store: SnipStore
    @ObservedObject var settings: Settings

    @State private var query = ""

    var body: some View {
        let visible = store.snips.filter { $0.matches(query) }
        let pinned = visible.filter(\.pinned)
        let recent = visible.filter { !$0.pinned }
        List(selection: $store.selection) {
            if !pinned.isEmpty {
                Section("Pinned") { rows(pinned) }
            }
            Section {
                rows(recent)
            } header: {
                if !pinned.isEmpty && !recent.isEmpty { Text("Recent") }
            }
        }
        .searchable(text: $query, placement: .sidebar, prompt: "Search LaTeX")
        .onDeleteCommand {
            if let id = store.selection { store.delete([id]) }
        }
        .overlay {
            if store.snips.isEmpty {
                Text("No snips yet").foregroundStyle(.secondary)
            } else if visible.isEmpty {
                Text("No snips match “\(query)”").foregroundStyle(.secondary).padding()
            }
        }
    }

    private func rows(_ snips: [Snip]) -> some View {
        ForEach(snips) { snip in
            HistoryRow(snip: snip, image: store.image(for: snip), live: store.live[snip.id])
                .tag(snip.id)
                .contextMenu {
                    Button("Copy") {
                        if let value = store.defaultFormatValue(snip) {
                            store.copy(value, snip: snip.id, format: settings.defaultFormat(for: snip.kind))
                        }
                    }
                    .disabled(snip.status != .done || snip.kind == .none)
                    Button(snip.pinned ? "Unpin" : "Pin") { store.togglePin(snip.id) }
                    Button("Retry") { store.recognize(snip.id, mode: .transcribe) }
                    Button("Show Image in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([store.imageURL(snip)])
                    }
                    Divider()
                    Button("Delete", role: .destructive) { store.delete([snip.id]) }
                }
        }
    }
}

private struct HistoryRow: View {
    let snip: Snip
    let image: NSImage?
    let live: SnipStore.Live?

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .textBackgroundColor))
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .padding(3)
                }
            }
            .frame(width: 64, height: 40)
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color(nsColor: .separatorColor)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 11.5, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.tail)
                HStack(spacing: 4) {
                    statusIcon
                    Text(timestamp)
                    if snip.pinned {
                        Image(systemName: "pin.fill").help("Pinned: kept when the history is trimmed or cleared")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var title: String {
        switch snip.status {
        case .running: return live?.phase.title ?? "Working…"
        case .failed: return "Failed"
        case .done:
            let flat = snip.latex.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .joined(separator: " ")
            return flat.isEmpty ? "Nothing found" : flat
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch snip.status {
        case .running: ProgressView().controlSize(.mini)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .done: Image(systemName: snip.kind.symbol)
        }
    }

    private var timestamp: String {
        Calendar.current.isDateInToday(snip.created)
            ? snip.created.formatted(date: .omitted, time: .shortened)
            : snip.created.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }
}

struct EmptyStateView: View {
    @ObservedObject var settings: Settings
    let actions: AppActions

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "x.squareroot")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(.tint)
            Text("Turn screenshots into LaTeX")
                .font(.title2.weight(.semibold))
            Text("Press \(settings.hotKey.display) anywhere and drag over an equation, table or passage. TeXSnap transcribes it and copies the LaTeX to your clipboard.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 440)
            HStack(spacing: 10) {
                Button(action: actions.snip) {
                    Label("Snip Screen Region", systemImage: "viewfinder")
                }
                .buttonStyle(.borderedProminent)
                Button(action: actions.paste) {
                    Label("Paste Image", systemImage: "doc.on.clipboard")
                }
                Button(action: actions.open) {
                    Label("Open Image…", systemImage: "photo.on.rectangle")
                }
            }
            .controlSize(.large)
            engineStatus
            Text("You can also drop image files here.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var engineStatus: some View {
        switch settings.engineSummary {
        case "Anthropic API", "Claude Code":
            Text("Using \(settings.engineSummary == "Claude Code" ? "Claude Code and your Claude login" : "the Anthropic API") · \(ModelCatalog.info(settings.model).name)")
                .font(.callout)
                .foregroundStyle(.secondary)
        case "Local model":
            Text("Using the offline model on this Mac")
                .font(.callout)
                .foregroundStyle(.secondary)
        default:
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("Add an Anthropic API key, install Claude Code or install the offline model to start.")
                Button("Open Settings", action: actions.settings)
            }
            .font(.callout)
        }
    }
}
