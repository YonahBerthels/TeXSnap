import Foundation

enum SnipKind: String, Codable, CaseIterable {
    case math, table, text, none

    var title: String {
        switch self {
        case .math: return "Math"
        case .table: return "Table"
        case .text: return "Text"
        case .none: return "Nothing found"
        }
    }

    var symbol: String {
        switch self {
        case .math: return "function"
        case .table: return "tablecells"
        case .text: return "text.alignleft"
        case .none: return "questionmark.circle"
        }
    }
}

/// One capture and its transcription. Persisted in the history.
struct Snip: Identifiable, Codable, Equatable {
    enum Status: Codable, Equatable {
        case running
        case done
        case failed(String)
    }

    let id: UUID
    let created: Date
    var imageFile: String
    var status: Status
    var kind: SnipKind
    /// The LaTeX shown and copied; the user may edit it.
    var latex: String
    /// The transcription as recognized, so edits can be reverted.
    var recognizedLatex: String
    var note: String?
    var problems: [String]
    var model: String
    var engine: String
    var seconds: Double
    // Optional so histories saved before these fields existed still decode.
    private var pinnedFlag: Bool?
    /// What the offline model first recognized, kept when the text is later edited or double-checked,
    /// so the difference can become a training example (see CorrectionLog).
    var localLatex: String?
    var localKind: SnipKind?

    private enum CodingKeys: String, CodingKey {
        case id, created, imageFile, status, kind, latex, recognizedLatex, note, problems, model, engine, seconds
        case pinnedFlag = "pinned", localLatex, localKind
    }

    var pinned: Bool {
        get { pinnedFlag ?? false }
        set { pinnedFlag = newValue ? true : nil }
    }

    init(id: UUID = UUID(), imageFile: String) {
        self.id = id
        self.created = Date()
        self.imageFile = imageFile
        self.status = .running
        self.kind = .none
        self.latex = ""
        self.recognizedLatex = ""
        self.note = nil
        self.problems = []
        self.model = ""
        self.engine = ""
        self.seconds = 0
    }

    var isEdited: Bool { status == .done && latex != recognizedLatex }

    /// The final transcription differs from the offline model's: a correction worth learning from.
    var correctsLocalModel: Bool {
        guard status == .done, let localLatex else { return false }
        return latex != localLatex || kind != localKind
    }

    /// Whether a search matches the LaTeX, what it recognized, or the kind.
    func matches(_ query: String) -> Bool {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return true }
        let haystack = (latex + "\n" + recognizedLatex + "\n" + kind.title).lowercased()
        let compact = haystack.filter { !$0.isWhitespace }
        return words.allSatisfy { haystack.contains($0) || compact.contains($0) }
    }
}

/// One copyable representation of a result, produced by LatexKit.formats.
struct OutputFormat: Identifiable, Equatable {
    let id: String
    let label: String
    let value: String
}
