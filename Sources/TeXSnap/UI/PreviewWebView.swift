import SwiftUI
import WebKit

/// Shows a transcription rendered by Resources/web/preview.html (KaTeX + LatexKit).
struct PreviewWebView: NSViewRepresentable {
    let kind: SnipKind
    let latex: String
    @Binding var contentHeight: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "size")
        let web = WKWebView(frame: .zero, configuration: config)
        web.setValue(false, forKey: "drawsBackground")
        web.navigationDelegate = context.coordinator
        context.coordinator.web = web
        web.loadFileURL(AppResources.url("web/preview.html"), allowingReadAccessTo: AppResources.url("web"))
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.render(kind: kind, latex: latex)
    }

    static func dismantleNSView(_ web: WKWebView, coordinator: Coordinator) {
        web.configuration.userContentController.removeScriptMessageHandler(forName: "size")
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: PreviewWebView
        weak var web: WKWebView?
        private var loaded = false
        private var wanted: (SnipKind, String)?
        private var shown: (SnipKind, String)?

        init(_ parent: PreviewWebView) {
            self.parent = parent
        }

        func render(kind: SnipKind, latex: String) {
            wanted = (kind, latex)
            guard loaded, let web else { return }
            if let shown, shown == (kind, latex) { return }
            shown = (kind, latex)
            guard let data = try? JSONSerialization.data(withJSONObject: ["kind": kind.rawValue, "latex": latex]) else { return }
            web.evaluateJavaScript("texsnapRender(\(String(decoding: data, as: UTF8.self)))")
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loaded = true
            if let wanted { render(kind: wanted.0, latex: wanted.1) }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            // Only the preview page itself may load; ignore clicks on anything else.
            navigationAction.navigationType == .other || navigationAction.navigationType == .reload ? .allow : .cancel
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            loaded = false
            shown = nil
            webView.reload()
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "size", let height = (message.body as? NSNumber)?.doubleValue else { return }
            if abs(parent.contentHeight - height) > 0.5 { parent.contentHeight = height }
        }
    }
}
