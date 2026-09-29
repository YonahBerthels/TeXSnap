import Foundation

/// The model's reply, split into its <kind>, <latex> and <note> parts.
struct ModelOutput: Equatable {
    var kind: String?
    var latex: String
    var note: String?

    static func parse(_ text: String) -> ModelOutput {
        var kind: String?
        if let range = text.range(of: #"<kind>\s*[A-Za-z]+\s*</kind>"#, options: .regularExpression) {
            kind = text[range]
                .replacingOccurrences(of: #"</?kind>|\s"#, with: "", options: .regularExpression)
                .lowercased()
        }

        var note: String?
        if let range = text.range(of: #"<note>[\s\S]*?</note>"#, options: .regularExpression) {
            let body = text[range].dropFirst("<note>".count).dropLast("</note>".count)
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            note = trimmed.isEmpty ? nil : trimmed
        }

        var latex: String
        if let start = text.range(of: "<latex>") {
            let rest = text[start.upperBound...]
            if let end = rest.range(of: "</latex>", options: .backwards) {
                latex = String(rest[..<end.lowerBound])
            } else {
                latex = String(rest)
            }
        } else {
            latex = text
        }
        latex = latex
            .replacingOccurrences(of: #"<kind>[\s\S]*?</kind>|<note>[\s\S]*?</note>"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return ModelOutput(kind: kind, latex: latex, note: note)
    }

    /// The LaTeX received so far while the reply is still streaming.
    static func partialLatex(_ text: String) -> String {
        guard let start = text.range(of: "<latex>") else { return "" }
        var body = String(text[start.upperBound...])
        if let end = body.range(of: "</latex>") {
            body = String(body[..<end.lowerBound])
        } else if let lastOpen = body.lastIndex(of: "<"), "</latex>".hasPrefix(body[lastOpen...]) {
            body = String(body[..<lastOpen])
        }
        return body.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
