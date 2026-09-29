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
}

/// One copyable representation of a result, produced by LatexKit.formats.
struct OutputFormat: Identifiable, Equatable {
    let id: String
    let label: String
    let value: String
}
