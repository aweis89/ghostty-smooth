import AppKit
import SwiftUI
import WebKit

/// A drawer beside a terminal surface that shows pcode's /btw threads.
///
/// pcode asks for it with an APC (`ESC _ pcode;btw;<host>;<thread> ESC \`,
/// `ESC _ pcode;close ESC \`), which reaches us as `GHOSTTY_ACTION_PCODE_EVENT`.
/// The APC only names what to show: the drawer reads the thread itself from
/// the session host's Unix socket as a read-only observer, and the host sends
/// the page to show it in. Nothing here knows pcode's data model; host lines
/// are handed to the page as they arrive.
///
/// Any program can write an APC, so the host id and thread are checked, and
/// the socket must be one this user owns in pcode's host directory, with a
/// peer running as this user (`PCodeHostConnection`).
final class PCodeDrawer: NSObject, ObservableObject {
    @Published var visible = false

    weak var surfaceView: Ghostty.SurfaceView?
    private var host: String?
    private var thread: String?
    private var connection: PCodeHostConnection?
    /// The host answered our hello with the page.
    private var greeted = false
    /// The page has loaded and defines `window.pcode`.
    private var pageReady = false
    /// The load of the current host's page, so a late finish of an older one is ignored.
    private var pageLoad: WKNavigation?
    private var pendingScripts: [String] = []
    private var theme: [String: String] = [:]

    init(surfaceView: Ghostty.SurfaceView) {
        self.surfaceView = surfaceView
    }

    deinit {
        connection?.stop()
    }

    private(set) lazy var webView: PCodeWebView = {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(PCodeScriptHandler(drawer: self), name: "pcode")
        // The page needs no storage of its own.
        configuration.websiteDataStore = .nonPersistent()
        let view = PCodeWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        view.setValue(false, forKey: "drawsBackground")
        view.onDismiss = { [weak self] in self?.focusTerminal() }
        return view
    }()

    // MARK: Commands from pcode

    func handle(_ payload: String) {
        let parts = payload.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        switch parts.first {
        case "btw" where parts.count == 3:
            guard Self.valid(parts[1], length: 8...8), Self.valid(parts[2], length: 1...64) else {
                return
            }
            show(host: parts[1], thread: parts[2])
        case "close":
            close()
        default:
            break
        }
    }

    private static func valid(_ value: String, length: ClosedRange<Int>) -> Bool {
        length.contains(value.count) && value.allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_")
        }
    }

    private func show(host: String, thread: String) {
        if host != self.host || connection == nil {
            connect(to: host)
        }
        self.thread = thread
        run("window.pcode.show(\(Self.json(thread)))")
        // Shown beside the terminal without taking its keyboard: typing goes on
        // in pcode's editor, which replies to the thread.
        setVisible(true)
    }

    func close() {
        let hadFocus = drawerHasFocus
        setVisible(false)
        thread = nil
        // A hidden drawer needs no updates; showing it again reconnects.
        connection?.stop()
        connection = nil
        host = nil
        if hadFocus { focusTerminal() }
    }

    /// The drawer is an overlay (`PCodeDrawerSurface`): the surface stays put
    /// in the view tree, so whichever had the keyboard keeps it.
    private func setVisible(_ value: Bool) {
        if value != visible { visible = value }
    }

    func focusTerminal() {
        guard let surfaceView else { return }
        Ghostty.moveFocus(to: surfaceView)
    }

    private var drawerHasFocus: Bool {
        guard let responder = webView.window?.firstResponder as? NSView else { return false }
        return responder.isDescendant(of: webView)
    }

    /// The terminal's colors, so the drawer looks like part of it.
    func apply(background: Color, foreground: Color) {
        theme = ["bg": Self.hex(background), "fg": Self.hex(foreground)].compactMapValues { $0 }
        if pageReady { evaluate("window.pcode.theme(\(Self.json(theme)))") }
    }

    // MARK: The session host

    private func connect(to host: String) {
        connection?.stop()
        self.host = host
        greeted = false
        pageReady = false
        pageLoad = nil
        pendingScripts = []
        let socket = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/state/pcode/hosts/\(host).sock").path
        let connection = PCodeHostConnection(path: socket)
        connection.onLine = { [weak self, weak connection] line in
            guard let self, let connection, self.connection === connection else { return }
            self.received(line)
        }
        connection.onClose = { [weak self, weak connection] in
            guard let self, let connection, self.connection === connection else { return }
            // The session went, or could not be reached. The drawer stays as it
            // is, saying so, until pcode closes it: hiding it would leave the
            // thread shown nowhere, since pcode thinks the drawer has it.
            self.connection = nil
            self.host = nil
            if self.pageReady {
                self.evaluate("window.pcode.message({type: 'notify', method: 'host_closed', args: []})")
            } else if connection.connected {
                // A host from before drawers closes on a hello it does not know.
                self.showError("This session host's pcode predates the drawer. Run /restart in pcode, then open the thread again.")
            } else {
                self.showError("Could not reach the pcode session host.")
            }
        }
        self.connection = connection
        connection.start()
    }

    private func received(_ line: Data) {
        guard greeted else {
            // The first line answers our hello: the page, or a refusal.
            guard let reply = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  reply["type"] as? String == "ready",
                  let page = reply["page"] as? String else {
                Ghostty.logger.warning("pcode drawer: the session host refused the drawer")
                connection?.stop()
                return
            }
            greeted = true
            pageLoad = webView.loadHTMLString(page, baseURL: nil)
            return
        }
        // Only a whole JSON object reaches the page: as such it is a JavaScript expression.
        guard (try? JSONSerialization.jsonObject(with: line)) is [String: Any],
              let text = String(data: line, encoding: .utf8) else { return }
        run("window.pcode.message(\(text))")
    }

    private func showError(_ message: String) {
        pageReady = false
        pageLoad = nil
        let escaped = message
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
        webView.loadHTMLString("""
            <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'">
            <body style="font:13px -apple-system;color:#888;padding:40px 16px;text-align:center">\(escaped)</body>
            """, baseURL: nil)
    }

    // MARK: The page

    private func run(_ script: String) {
        if pageReady {
            evaluate(script)
        } else {
            pendingScripts.append(script)
        }
    }

    private func evaluate(_ script: String) {
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    fileprivate func pageLoaded(_ navigation: WKNavigation?) {
        guard greeted, !pageReady, let navigation, navigation === pageLoad else { return }
        pageReady = true
        evaluate("window.pcode.theme(\(Self.json(theme)))")
        let scripts = pendingScripts
        pendingScripts = []
        scripts.forEach(evaluate)
        if let thread { evaluate("window.pcode.show(\(Self.json(thread)))") }
    }

    private static func json(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]),
              let text = String(data: data, encoding: .utf8) else { return "null" }
        return text
    }

    private static func hex(_ color: Color) -> String? {
        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        let channel = { (value: CGFloat) in Int((max(0, min(1, value)) * 255).rounded()) }
        return String(format: "#%02x%02x%02x",
                      channel(rgb.redComponent), channel(rgb.greenComponent), channel(rgb.blueComponent))
    }
}

extension PCodeDrawer: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageLoaded(navigation)
    }

    /// The page's process died: start over with the same host, which sends the page again.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard let host else { return }
        connect(to: host)
    }

    /// The page itself loads; a web link opens in the browser; nothing else navigates.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        let url = navigationAction.request.url
        if navigationAction.navigationType == .other, url?.absoluteString == "about:blank" {
            decisionHandler(.allow)
            return
        }
        if navigationAction.navigationType == .linkActivated, let url,
           ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            NSWorkspace.shared.open(url)
        }
        decisionHandler(.cancel)
    }
}

/// Messages from the page: only asking to give the keyboard back to the terminal.
private final class PCodeScriptHandler: NSObject, WKScriptMessageHandler {
    // Weak: the content controller would otherwise keep the drawer alive.
    weak var drawer: PCodeDrawer?

    init(drawer: PCodeDrawer) {
        self.drawer = drawer
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.body as? String == "focus_terminal" else { return }
        drawer?.focusTerminal()
    }
}

/// The drawer's web view. Cmd+W would close the terminal beside it (the surface
/// is what has focus as far as the window knows), so it gives the keyboard back.
final class PCodeWebView: WKWebView {
    var onDismiss: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock)
        if flags == .command, event.charactersIgnoringModifiers == "w",
           let responder = window?.firstResponder as? NSView, responder.isDescendant(of: self) {
            onDismiss?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

private var pcodeDrawerKey: UInt8 = 0

extension Ghostty.SurfaceView {
    /// This surface's pcode drawer, made the first time it is asked for.
    var pcodeDrawer: PCodeDrawer {
        if let drawer = objc_getAssociatedObject(self, &pcodeDrawerKey) as? PCodeDrawer {
            return drawer
        }
        let drawer = PCodeDrawer(surfaceView: self)
        objc_setAssociatedObject(self, &pcodeDrawerKey, drawer, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return drawer
    }
}

/// The terminal surface, with its pcode drawer laid over its right side while one is shown.
///
/// An overlay rather than a split: the terminal keeps its size, so nothing
/// reflows and pcode's editor stays where it is, and the surface never leaves
/// the view tree, so it keeps the keyboard. The drawer covers what is under it.
struct PCodeDrawerSurface: View {
    @EnvironmentObject var ghostty: Ghostty.App
    @ObservedObject var surfaceView: Ghostty.SurfaceView
    @ObservedObject var drawer: PCodeDrawer
    var isSplit: Bool

    /// The drawer's share of the surface's width, set by dragging its left edge.
    @State private var fraction: CGFloat = 0.42
    /// `fraction` when the current drag began: drags report distance from their start.
    @State private var dragStart: CGFloat?
    private static let minWidth: CGFloat = 260

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .trailing) {
                Ghostty.SurfaceWrapper(surfaceView: surfaceView, isSplit: isSplit)
                if drawer.visible {
                    overlay(width: width(in: geometry.size.width), total: geometry.size.width)
                }
            }
        }
        .onChange(of: drawer.visible) { visible in
            guard visible else { return }
            let background = ghostty.config.backgroundColor
            let foreground: Color = NSColor(background).isLightColor ? .black : .white
            drawer.apply(background: background, foreground: foreground)
        }
    }

    private func width(in total: CGFloat) -> CGFloat {
        let upper = max(Self.minWidth, total * 0.85)
        return min(upper, max(Self.minWidth, total * fraction))
    }

    private func overlay(width: CGFloat, total: CGFloat) -> some View {
        HStack(spacing: 0) {
            // The left edge: a thin line to see, a wider strip to drag.
            Rectangle()
                .fill(ghostty.config.splitDividerColor)
                .frame(width: 1)
                .overlay(
                    Color.clear
                        .frame(width: 8)
                        .contentShape(Rectangle())
                        .onHover { inside in
                            if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                        }
                        .gesture(
                            DragGesture(coordinateSpace: .global)
                                .onChanged { gesture in
                                    guard total > 0 else { return }
                                    let start = dragStart ?? fraction
                                    dragStart = start
                                    let next = start - gesture.translation.width / total
                                    fraction = min(0.85, max(Self.minWidth / total, next))
                                }
                                .onEnded { _ in dragStart = nil }
                        )
                )
            PCodeWebViewRepresentable(webView: drawer.webView)
                .focusedValue(\.ghosttySurfaceView, surfaceView)
        }
        .frame(width: width)
        // Opaque even before the page has drawn, so the terminal never shows through.
        .background(ghostty.config.backgroundColor)
        .shadow(color: .black.opacity(0.35), radius: 8, x: -2, y: 0)
    }
}

private struct PCodeWebViewRepresentable: NSViewRepresentable {
    let webView: PCodeWebView

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        if webView.superview !== container { attach(to: container) }
    }

    /// One web view per drawer, kept warm and moved into whichever container shows it.
    private func attach(to container: NSView) {
        webView.removeFromSuperview()
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)
    }
}
