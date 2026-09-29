import Foundation

/// Snips where the offline model got something wrong, with the corrected LaTeX: training examples for the next
/// fine-tune. Kept in ~/Library/Application Support/TeXSnap/Corrections as a dataset mlx_vlm.lora can load
/// directly (images/ + metadata.jsonl with file_name, question, answer), and they outlive the snip history:
/// deleting a snip keeps its correction.
@MainActor
final class CorrectionLog: ObservableObject {
    private struct Entry: Codable {
        var file: String
        var kind: SnipKind
        var latex: String
        var updated: Date
    }

    /// The prompt the model was trained with (Prompts.transcribe), so examples match inference.
    private static let question = "Transcribe this image into LaTeX."

    let directory: URL
    @Published private(set) var count = 0
    private var entries: [UUID: Entry] = [:]

    private var imagesDirectory: URL { directory.appendingPathComponent("images", isDirectory: true) }
    private var entriesURL: URL { directory.appendingPathComponent("corrections.json") }
    private var metadataURL: URL { directory.appendingPathComponent("metadata.jsonl") }

    init(directory: URL) {
        self.directory = directory
        if let data = try? Data(contentsOf: entriesURL),
           let loaded = try? JSONDecoder.iso8601.decode([UUID: Entry].self, from: data) {
            entries = loaded
        }
        count = entries.count
    }

    /// Records the corrections among `snips` and drops entries whose snip no longer differs (an edit that was
    /// reverted). Entries of snips that were deleted from the history are kept.
    func sync(_ snips: [Snip], imageURL: (Snip) -> URL) {
        var changed = false
        for snip in snips {
            let existing = entries[snip.id]
            if snip.correctsLocalModel {
                if existing?.latex == snip.latex && existing?.kind == snip.kind { continue }
                let file = "images/\(snip.id.uuidString).png"
                let destination = directory.appendingPathComponent(file)
                if !FileManager.default.fileExists(atPath: destination.path) {
                    try? FileManager.default.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
                    guard (try? FileManager.default.copyItem(at: imageURL(snip), to: destination)) != nil else { continue }
                }
                entries[snip.id] = Entry(file: file, kind: snip.kind, latex: snip.latex, updated: Date())
                changed = true
            } else if let existing, snip.status == .done {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(existing.file))
                entries[snip.id] = nil
                changed = true
            }
        }
        if changed { write() }
    }

    func removeAll() {
        entries.removeAll()
        try? FileManager.default.removeItem(at: directory)
        count = 0
    }

    private func write() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder.iso8601.encode(entries) {
            try? data.write(to: entriesURL, options: .atomic)
        }
        var lines = ""
        for entry in entries.values.sorted(by: { $0.updated < $1.updated }) {
            let answer = "<kind>\(entry.kind.rawValue)</kind>\n<latex>\n\(entry.latex)\n</latex>"
            let row: [String: String] = ["file_name": entry.file, "question": Self.question, "answer": answer,
                                         "kind": entry.kind.rawValue]
            if let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys, .withoutEscapingSlashes]) {
                lines += String(decoding: data, as: UTF8.self) + "\n"
            }
        }
        try? lines.write(to: metadataURL, atomically: true, encoding: .utf8)
        count = entries.count
    }
}

extension JSONEncoder {
    static let iso8601: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}

extension JSONDecoder {
    static let iso8601: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
