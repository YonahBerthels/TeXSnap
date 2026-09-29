import AppKit
import UniformTypeIdentifiers

/// The snip history (persisted in ~/Library/Application Support/TeXSnap) and the recognitions in flight.
@MainActor
final class SnipStore: ObservableObject {
    struct Live: Equatable {
        var phase: Recognizer.Phase
        var partial: String
        var started: Date
    }

    @Published private(set) var snips: [Snip] = []
    @Published var selection: Snip.ID?
    @Published private(set) var live: [Snip.ID: Live] = [:]
    /// The format most recently copied, for the "Copied" confirmation.
    @Published private(set) var lastCopy: (snip: Snip.ID, format: String, date: Date)?

    let settings: Settings
    let directory: URL
    private var imagesDirectory: URL { directory.appendingPathComponent("images", isDirectory: true) }
    private var indexURL: URL { directory.appendingPathComponent("history.json") }
    private var tasks: [Snip.ID: Task<Void, Never>] = [:]
    private var pendingSave: DispatchWorkItem?
    private let images = NSCache<NSString, NSImage>()
    private var formatCache: [String: [OutputFormat]] = [:]

    init(settings: Settings, directory: URL? = nil) {
        self.settings = settings
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.directory = directory ?? support.appendingPathComponent("TeXSnap", isDirectory: true)
        try? FileManager.default.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
        load()
    }

    func snip(_ id: Snip.ID?) -> Snip? {
        guard let id else { return nil }
        return snips.first { $0.id == id }
    }

    private func index(_ id: Snip.ID) -> Int? {
        snips.firstIndex { $0.id == id }
    }

    // MARK: Persistence

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              var loaded = try? Self.decoder.decode([Snip].self, from: data) else { return }
        for i in loaded.indices where loaded[i].status == .running {
            loaded[i].status = .failed("Interrupted before it finished.")
        }
        snips = loaded
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.save() }
        }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    func save() {
        pendingSave?.cancel()
        pendingSave = nil
        guard let data = try? Self.encoder.encode(snips) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    // MARK: Images

    func imageURL(_ snip: Snip) -> URL {
        imagesDirectory.appendingPathComponent(snip.imageFile)
    }

    func image(for snip: Snip) -> NSImage? {
        let key = snip.imageFile as NSString
        if let cached = images.object(forKey: key) { return cached }
        guard let image = NSImage(contentsOf: imageURL(snip)) else { return nil }
        images.setObject(image, forKey: key)
        return image
    }

    /// Image data from the pasteboard or a drag: image files first, then image data.
    static func imageData(from pasteboard: NSPasteboard) -> Data? {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] {
            for url in urls {
                if let data = try? Data(contentsOf: url), ImagePreparer.decode(data) != nil { return data }
            }
        }
        let types: [NSPasteboard.PasteboardType] = [.png, .tiff, NSPasteboard.PasteboardType(UTType.jpeg.identifier),
                                                    NSPasteboard.PasteboardType(UTType.heic.identifier), .pdf]
        for type in types {
            if let data = pasteboard.data(forType: type), ImagePreparer.decode(data) != nil { return data }
        }
        return nil
    }

    // MARK: Snipping

    /// Stores the image and starts recognizing it. Returns nil if the data is not a readable image.
    @discardableResult
    func add(imageData: Data) -> Snip.ID? {
        guard let image = ImagePreparer.decode(imageData), let png = ImagePreparer.encode(image, type: .png) else { return nil }
        let id = UUID()
        let file = "\(id.uuidString).png"
        do {
            try png.write(to: imagesDirectory.appendingPathComponent(file))
        } catch {
            return nil
        }
        snips.insert(Snip(id: id, imageFile: file), at: 0)
        selection = id
        trimHistory()
        scheduleSave()
        recognize(id, mode: .transcribe)
        return id
    }

    func recognize(_ id: Snip.ID, mode: Recognizer.Mode) {
        guard let i = index(id) else { return }
        tasks[id]?.cancel()
        snips[i].status = .running
        live[id] = Live(phase: .preparing, partial: "", started: Date())
        let imageURL = imageURL(snips[i])
        let settings = settings
        tasks[id] = Task { [weak self] in
            do {
                let kit = try LatexKit.shared.get()
                let verifying: Bool
                if case .verify = mode { verifying = true } else { verifying = false }
                let engine = try settings.resolveEngine(verifying: verifying)
                let data = try Data(contentsOf: imageURL)
                let options = Recognizer.Options(engine: engine, model: settings.model, effort: settings.effort,
                                                 autoRepair: settings.autoRepair)
                let result = try await Recognizer(kit: kit).run(imageData: data, mode: mode, options: options) { phase, partial in
                    guard let self, self.live[id] != nil else { return }
                    self.live[id]?.phase = phase
                    if phase != .reading { self.live[id]?.partial = partial }
                }
                self?.finish(id, result: result, mode: mode)
            } catch is CancellationError {
                self?.fail(id, message: "Cancelled.")
            } catch {
                self?.fail(id, message: error.localizedDescription)
            }
        }
    }

    func cancel(_ id: Snip.ID) {
        tasks[id]?.cancel()
    }

    private func finish(_ id: Snip.ID, result: Recognizer.Result, mode: Recognizer.Mode) {
        live[id] = nil
        tasks[id] = nil
        guard let i = index(id) else { return }
        let previous = snips[i].latex
        snips[i].status = .done
        snips[i].kind = result.kind
        snips[i].latex = result.latex
        snips[i].recognizedLatex = result.latex
        snips[i].problems = result.problems
        snips[i].model = result.model
        snips[i].engine = result.engine
        snips[i].seconds = result.seconds
        snips[i].note = result.note
        if case .verify = mode {
            let verdict = previous == result.latex ? "Double-checked: no changes needed." : "Double-check corrected the transcription."
            snips[i].note = [verdict, result.note].compactMap { $0 }.joined(separator: " ")
        }
        scheduleSave()
        if settings.autoCopy, i == 0, result.kind != .none, let value = defaultFormatValue(snips[i]) {
            copy(value, snip: id, format: settings.defaultFormat(for: result.kind))
        }
        if settings.playSound { NSSound(named: result.kind == .none ? "Basso" : "Glass")?.play() }
    }

    private func fail(_ id: Snip.ID, message: String) {
        live[id] = nil
        tasks[id] = nil
        guard let i = index(id) else { return }
        snips[i].status = .failed(message)
        scheduleSave()
        if settings.playSound, message != "Cancelled." { NSSound(named: "Basso")?.play() }
    }

    // MARK: Editing

    func updateLatex(_ id: Snip.ID, to latex: String) {
        guard let i = index(id), snips[i].status == .done, snips[i].latex != latex else { return }
        snips[i].latex = latex
        snips[i].problems = (try? LatexKit.shared.get())?.validate(kind: snips[i].kind, latex: latex) ?? []
        scheduleSave()
    }

    func setKind(_ id: Snip.ID, to kind: SnipKind) {
        guard let i = index(id), snips[i].status == .done, snips[i].kind != kind else { return }
        snips[i].kind = kind
        snips[i].problems = (try? LatexKit.shared.get())?.validate(kind: kind, latex: snips[i].latex) ?? []
        scheduleSave()
    }

    func revert(_ id: Snip.ID) {
        guard let i = index(id) else { return }
        updateLatex(id, to: snips[i].recognizedLatex)
    }

    // MARK: Formats and copying

    func formats(for snip: Snip) -> [OutputFormat] {
        guard snip.status == .done, snip.kind != .none, let kit = try? LatexKit.shared.get() else { return [] }
        let key = snip.kind.rawValue + "\u{1}" + snip.latex
        if let cached = formatCache[key] { return cached }
        let formats = kit.formats(kind: snip.kind, latex: snip.latex)
        if formatCache.count > 40 { formatCache.removeAll() }
        formatCache[key] = formats
        return formats
    }

    func packages(for snip: Snip) -> [String] {
        (try? LatexKit.shared.get())?.packages(latex: snip.latex) ?? []
    }

    func defaultFormatValue(_ snip: Snip) -> String? {
        let formats = formats(for: snip)
        let preferred = settings.defaultFormat(for: snip.kind)
        return (formats.first { $0.id == preferred } ?? formats.first)?.value
    }

    func copy(_ value: String, snip: Snip.ID, format: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
        lastCopy = (snip, format, Date())
    }

    // MARK: Deleting

    func delete(_ ids: Set<Snip.ID>) {
        for id in ids {
            tasks[id]?.cancel()
            tasks[id] = nil
            live[id] = nil
            if let snip = snip(id) {
                try? FileManager.default.removeItem(at: imageURL(snip))
                images.removeObject(forKey: snip.imageFile as NSString)
            }
        }
        let oldIndex = selection.flatMap { index($0) }
        snips.removeAll { ids.contains($0.id) }
        if let selection, ids.contains(selection) {
            self.selection = snips.isEmpty ? nil : snips[min(oldIndex ?? 0, snips.count - 1)].id
        }
        scheduleSave()
    }

    func clearAll() {
        delete(Set(snips.map(\.id)))
    }

    private func trimHistory() {
        let limit = max(10, settings.historyLimit)
        guard snips.count > limit else { return }
        let excess = snips[limit...].filter { $0.status != .running }.map(\.id)
        delete(Set(excess))
    }
}
