import AppKit
import WebKit

/// Renders a result with the preview page in an offscreen web view and returns a PNG.
@MainActor
final class PreviewSnapshotter: NSObject, WKNavigationDelegate {
    private var loaded: CheckedContinuation<Void, Error>?

    static func snapshot(kind: SnipKind, latex: String, width: CGFloat, dark: Bool) async throws -> Data {
        try await PreviewSnapshotter().render(kind: kind, latex: latex, width: width, dark: dark)
    }

    private func render(kind: SnipKind, latex: String, width: CGFloat, dark: Bool) async throws -> Data {
        // WebKit only lays out and paints for a window that is on screen, so park one far off the visible area.
        let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: width, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.isReleasedWhenClosed = false
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: 300))
        web.navigationDelegate = self
        window.contentView = web
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            loaded = continuation
            web.loadFileURL(AppResources.url("web/preview.html"), allowingReadAccessTo: AppResources.url("web"))
        }
        let payload: [String: Any] = ["kind": kind.rawValue, "latex": latex, "background": dark ? "#1e1e1e" : "#ffffff"]
        let measured = try await web.callAsyncJavaScript("return await texsnapRenderAndMeasure(payload);",
                                                         arguments: ["payload": payload], contentWorld: .page)
        let height = max(40, ceil((measured as? NSNumber)?.doubleValue ?? 300))
        window.setContentSize(NSSize(width: width, height: height))
        web.frame = NSRect(x: 0, y: 0, width: width, height: height)
        try await Task.sleep(nanoseconds: 150_000_000)

        let config = WKSnapshotConfiguration()
        config.rect = NSRect(x: 0, y: 0, width: width, height: height)
        let image: NSImage = try await withCheckedThrowingContinuation { continuation in
            web.takeSnapshot(with: config) { image, error in
                if let image { continuation.resume(returning: image) }
                else { continuation.resume(throwing: error ?? CocoaError(.fileWriteUnknown)) }
            }
        }
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else { throw CocoaError(.fileWriteUnknown) }
        return png
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded?.resume()
        loaded = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loaded?.resume(throwing: error)
        loaded = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loaded?.resume(throwing: error)
        loaded = nil
    }
}
