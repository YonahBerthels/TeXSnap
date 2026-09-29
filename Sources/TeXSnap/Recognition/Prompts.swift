import Foundation

enum Prompts {
    /// The shared instructions, also used by Tests/eval_prompt.py.
    static func system() throws -> String {
        try AppResources.text("prompts/system.txt")
    }

    static let transcribe = "Transcribe this image into LaTeX."

    static func repair(kind: SnipKind, latex: String, problems: [String]) -> String {
        """
        Your transcription of this image has LaTeX problems:
        \(problems.map { "- " + $0 }.joined(separator: "\n"))

        Your transcription was:
        <kind>\(kind.rawValue)</kind>
        <latex>
        \(latex)
        </latex>

        Fix these problems while keeping the transcription faithful to the image. Reply in the required format.
        """
    }

    static func verify(kind: SnipKind, latex: String) -> String {
        """
        Here is a candidate transcription of this image:
        <kind>\(kind.rawValue)</kind>
        <latex>
        \(latex)
        </latex>

        Compare it with the image symbol by symbol: every character, digit, sign, subscript, superscript, \
        delimiter, accent, font style, table cell and rule. If it is exactly right, return it unchanged. \
        Otherwise return the corrected transcription. Reply in the required format.
        """
    }
}
