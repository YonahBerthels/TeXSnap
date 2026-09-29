import SwiftUI

/// A plain-text code editor for LaTeX. Unlike SwiftUI's TextEditor it never "smartens" quotes or
/// dashes and never autocorrects, either of which would silently corrupt LaTeX.
struct LatexEditor: NSViewRepresentable {
    @Binding var text: String
    var isEditable: Bool
    /// Changes when a different snip is shown, so undo history does not carry over.
    var identity: UUID

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        let textView = scroll.documentView as! NSTextView
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = .monospacedSystemFont(ofSize: 12.5, weight: .regular)
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.string = text
        textView.isEditable = isEditable
        textView.delegate = context.coordinator
        context.coordinator.identity = identity
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scroll.documentView as? NSTextView else { return }
        if context.coordinator.identity != identity {
            context.coordinator.identity = identity
            textView.undoManager?.removeAllActions()
        }
        if textView.string != text {
            textView.string = text
        }
        textView.isEditable = isEditable
        textView.textColor = isEditable ? .textColor : .secondaryLabelColor
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: LatexEditor
        var identity: UUID?

        init(_ parent: LatexEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }
    }
}
