import AppKit

import GhosttyKit


/// A Unix socket for inspecting and driving the app from a script: what each
/// terminal shows and where it sits, which view a click would reach, synthetic
/// keys and mouse input, and window snapshots. It exists so a coding agent can
/// see and test UI changes without Screen Recording or Accessibility access.
///
/// Off unless `GHOSTTY_DEBUG_SOCKET` names a socket path. The protocol is one
/// JSON object per line each way: `{"cmd": "dump"}` → `{"ok": true, ...}`.
/// Coordinates are points from the top-left of a window's content view.
final class DebugSocket {
    static private(set) var shared: DebugSocket?

    static func startIfRequested() {
        guard let path = ProcessInfo.processInfo.environment["GHOSTTY_DEBUG_SOCKET"],
              !path.isEmpty, shared == nil else { return }
        let server = DebugSocket(path: path)
        if server.start() {
            shared = server
        } else {
            Ghostty.logger.warning("debug socket: could not listen on \(path, privacy: .public)")
        }
    }

    private let path: String
    private var listenFD: Int32 = -1

    private init(path: String) {
        self.path = path
    }

    private func start() -> Bool {
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd)
            return false
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes) }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(fd, 8) == 0 else {
            close(fd)
            return false
        }
        chmod(path, 0o600)
        listenFD = fd
        let thread = Thread { [weak self] in self?.acceptLoop() }
        thread.name = "ghostty.debug-socket"
        thread.start()
        return true
    }

    private func acceptLoop() {
        while true {
            let client = accept(listenFD, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return
            }
            DispatchQueue.global(qos: .userInitiated).async { Self.serve(client) }
        }
    }

    /// Answers each request line on `fd` in turn, running it on the main thread.
    private static func serve(_ fd: Int32) {
        defer { close(fd) }
        var pending = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = read(fd, &chunk, chunk.count)
            if count <= 0 { return }
            pending.append(chunk, count: count)
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = pending[pending.startIndex..<newline]
                pending = Data(pending[pending.index(after: newline)...])
                guard !line.isEmpty else { continue }
                var reply = respond(to: Data(line))
                reply.append(0x0A)
                let sent = reply.withUnsafeBytes { raw -> Bool in
                    var offset = 0
                    while offset < raw.count {
                        let written = write(fd, raw.baseAddress! + offset, raw.count - offset)
                        if written <= 0 { return false }
                        offset += written
                    }
                    return true
                }
                if !sent { return }
            }
        }
    }

    private static func respond(to line: Data) -> Data {
        var result: [String: Any]
        if let request = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
           let cmd = request["cmd"] as? String {
            let done = DispatchSemaphore(value: 0)
            var answer: [String: Any] = [:]
            DispatchQueue.main.async {
                DebugCommands.run(cmd, request) { reply in
                    answer = reply
                    done.signal()
                }
            }
            done.wait()
            result = answer
        } else {
            result = ["ok": false, "error": "expected a JSON object with a \"cmd\" string"]
        }
        let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        return data ?? Data(#"{"ok":false,"error":"reply was not JSON-serializable"}"#.utf8)
    }
}

/// The socket's commands. Each runs on the main thread and calls `reply`
/// exactly once, possibly later (input with pauses, recordings, waits).
enum DebugCommands {
    typealias Reply = ([String: Any]) -> Void

    struct Failure: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    static func run(_ cmd: String, _ args: [String: Any], reply: @escaping Reply) {
        let finish: Reply = { body in
            var body = body
            body["ok"] = body["ok"] ?? true
            reply(body)
        }
        do {
            switch cmd {
            case "ping":
                finish(["pid": ProcessInfo.processInfo.processIdentifier,
                        "bundle": Bundle.main.bundleIdentifier ?? "",
                        "active": NSApp.isActive])
            case "dump": finish(["windows": terminalWindows().enumerated().map { windowInfo($1, index: $0) }])
            case "text": try text(args, finish)
            case "wait": try waitForText(args, finish)
            case "views": finish(try viewTree(args))
            case "layers": finish(try layerTree(args))
            case "hit": finish(try hit(args))
            case "activate": try activate(args, finish)
            case "focus": try focus(args, finish)
            case "key": try DebugInput.keys(args, finish)
            case "type": try DebugInput.typeText(args, finish)
            case "click": try DebugInput.click(args, finish)
            case "drag": try DebugInput.drag(args, finish)
            case "move": try DebugInput.move(args, finish)
            case "scroll": try DebugInput.scroll(args, finish)
            case "snap": try DebugSnapshot.snapFresh(args, finish)
            case "record": try DebugSnapshot.record(args, finish)
            default: throw Failure("unknown command \(cmd)")
            }
        } catch let failure as Failure {
            reply(["ok": false, "error": failure.message])
        } catch {
            reply(["ok": false, "error": "\(error)"])
        }
    }

    // MARK: Windows, surfaces, coordinates

    /// Visible windows front to back, those with a terminal first.
    static func terminalWindows() -> [NSWindow] {
        let visible = NSApp.orderedWindows.filter { $0.isVisible }
        return visible.filter { !surfaces(in: $0).isEmpty } + visible.filter { surfaces(in: $0).isEmpty }
    }

    static func window(_ args: [String: Any]) throws -> NSWindow {
        let windows = terminalWindows()
        if let index = args["window"] as? Int {
            guard windows.indices.contains(index) else { throw Failure("no window \(index)") }
            return windows[index]
        }
        if let id = args["surface"] as? String, let view = try? surface(id), let window = view.window {
            return window
        }
        if let key = NSApp.keyWindow, !surfaces(in: key).isEmpty { return key }
        guard let first = windows.first else { throw Failure("no visible window") }
        return first
    }

    static func surfaces(in window: NSWindow) -> [Ghostty.SurfaceView] {
        var found: [Ghostty.SurfaceView] = []
        func walk(_ view: NSView) {
            if let surface = view as? Ghostty.SurfaceView { found.append(surface) }
            view.subviews.forEach(walk)
        }
        if let root = window.contentView { walk(root) }
        return found
    }

    static func allSurfaces() -> [Ghostty.SurfaceView] {
        NSApp.windows.flatMap(surfaces(in:))
    }

    static func shortID(_ view: Ghostty.SurfaceView) -> String {
        String(view.id.uuidString.prefix(8)).lowercased()
    }

    /// A surface by ID prefix, or the focused one when `id` is nil.
    static func surface(_ id: String?) throws -> Ghostty.SurfaceView {
        let all = allSurfaces()
        if let id, !id.isEmpty {
            let matches = all.filter { $0.id.uuidString.lowercased().hasPrefix(id.lowercased()) }
            guard matches.count == 1 else {
                throw Failure(matches.isEmpty ? "no surface \(id)" : "surface \(id) is ambiguous")
            }
            return matches[0]
        }
        let key = NSApp.keyWindow ?? terminalWindows().first
        if let responder = key?.firstResponder as? Ghostty.SurfaceView { return responder }
        guard let first = key.map(surfaces(in:))?.first ?? all.first else { throw Failure("no surface") }
        return first
    }

    /// `rect` (in `view`'s coordinates) in top-left points of the window's content view.
    static func topLeftRect(_ rect: NSRect, of view: NSView) -> CGRect? {
        guard let content = view.window?.contentView else { return nil }
        let local = content.convert(rect, from: view)
        let y = content.isFlipped ? local.minY : content.bounds.height - local.maxY
        return CGRect(x: local.minX, y: y, width: local.width, height: local.height)
    }

    /// A top-left content point as a point in the window's base coordinates.
    static func windowPoint(_ x: Double, _ y: Double, in window: NSWindow) throws -> NSPoint {
        guard let content = window.contentView else { throw Failure("window has no content view") }
        let local = NSPoint(x: x, y: content.isFlipped ? y : content.bounds.height - y)
        return content.convert(local, to: nil)
    }

    static func point(_ value: Any?) throws -> (Double, Double) {
        guard let pair = value as? [Any], pair.count == 2,
              let x = (pair[0] as? NSNumber)?.doubleValue,
              let y = (pair[1] as? NSNumber)?.doubleValue else { throw Failure("expected a point [x, y]") }
        return (x, y)
    }

    /// The point named by `at` (`[x, y]`), or `cell` (`[col, row]`) of
    /// `surface` (the middle of that cell), or else a surface's centre.
    static func target(_ args: [String: Any], key: String = "at") throws -> (NSWindow, Double, Double) {
        if let cell = args[key == "at" ? "cell" : "\(key)_cell"] {
            let view = try surface(args["surface"] as? String)
            let (col, row) = try point(cell)
            guard let window = view.window, let frame = topLeftRect(view.bounds, of: view),
                  view.cellSize.width > 0 else { throw Failure("surface is not on screen") }
            // Cells start after the terminal's padding, which is centred.
            let size = view.surfaceSize
            let cols = Double(size?.columns ?? 0), rows = Double(size?.rows ?? 0)
            let cellW = Double(view.cellSize.width), cellH = Double(view.cellSize.height)
            let padX = (Double(frame.width) - cols * cellW) / 2
            let padY = (Double(frame.height) - rows * cellH) / 2
            let x: Double = Double(frame.minX) + padX + (col + 0.5) * cellW
            let y: Double = Double(frame.minY) + padY + (row + 0.5) * cellH
            return (window, x, y)
        }
        if let at = args[key] {
            let (x, y) = try point(at)
            return (try window(args), x, y)
        }
        let view = try surface(args["surface"] as? String)
        guard let window = view.window, let frame = topLeftRect(view.bounds, of: view) else {
            throw Failure("surface is not on screen")
        }
        return (window, frame.midX, frame.midY)
    }

    static func rectJSON(_ rect: CGRect?) -> [Double]? {
        guard let rect else { return nil }
        return [rect.minX, rect.minY, rect.width, rect.height].map { (Double($0) * 10).rounded() / 10 }
    }

    static func windowInfo(_ window: NSWindow, index: Int) -> [String: Any] {
        var info: [String: Any] = [
            "index": index,
            "number": window.windowNumber,
            "class": String(describing: type(of: window)),
            "title": window.title,
            "key": window.isKeyWindow,
            "main": window.isMainWindow,
            // False when covered: terminals then stop drawing until snap/record wakes them.
            "on_screen": window.occlusionState.contains(.visible),
            "content_size": [window.contentView?.bounds.width ?? 0, window.contentView?.bounds.height ?? 0],
            "scale": window.backingScaleFactor,
            "surfaces": surfaces(in: window).map(surfaceInfo),
        ]
        if let responder = window.firstResponder {
            info["first_responder"] = String(describing: type(of: responder))
        }
        return info
    }

    static func surfaceInfo(_ view: Ghostty.SurfaceView) -> [String: Any] {
        var info: [String: Any] = [
            "id": shortID(view),
            "first_responder": view.window?.firstResponder === view,
            "focused": view.focused,
            "hidden": view.isHiddenOrHasHiddenAncestor,
            "title": view.title,
            "cell": [view.cellSize.width, view.cellSize.height],
            "has_selection": view.surface.map(ghostty_surface_has_selection) ?? false,
        ]
        if let size = view.surfaceSize {
            info["grid"] = [Int(size.columns), Int(size.rows)]
        }
        info["frame"] = rectJSON(topLeftRect(view.bounds, of: view))
        // The part not clipped away by any ancestor view. SwiftUI clips with
        // layers, not views, so `layers` is the truth for SwiftUI clip shapes.
        info["visible"] = rectJSON(topLeftRect(view.visibleRect, of: view))
        if let pwd = view.pwd { info["pwd"] = pwd }
        if view.isPCodeOverlay {
            info["overlay"] = view.pcodeOwner.map { String(describing: type(of: $0)) } ?? "orphaned"
            if let pane = view.pcodeOwner?.surfaceView { info["overlay_of"] = shortID(pane) }
        }
        return info
    }

    // MARK: Text

    static func readText(_ view: Ghostty.SurfaceView, scope: String) throws -> String {
        guard let surface = view.surface else { throw Failure("surface has no terminal") }
        var text = ghostty_text_s()
        if scope == "selection" {
            guard ghostty_surface_read_selection(surface, &text) else { return "" }
        } else {
            let tag = scope == "screen" ? GHOSTTY_POINT_SCREEN : GHOSTTY_POINT_VIEWPORT
            let sel = ghostty_selection_s(
                top_left: ghostty_point_s(tag: tag, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
                bottom_right: ghostty_point_s(tag: tag, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0),
                rectangle: false)
            guard ghostty_surface_read_text(surface, sel, &text) else { return "" }
        }
        defer { ghostty_surface_free_text(surface, &text) }
        guard let ptr = text.text else { return "" }
        return String(cString: ptr)
    }

    static func text(_ args: [String: Any], _ reply: Reply) throws {
        let view = try surface(args["surface"] as? String)
        let scope = args["scope"] as? String ?? "viewport"
        reply(["surface": shortID(view), "scope": scope, "text": try readText(view, scope: scope)])
    }

    /// Polls a surface's text until `pattern` (a regex) matches, or stops
    /// matching with `absent`, or `timeout` seconds pass.
    static func waitForText(_ args: [String: Any], _ reply: @escaping Reply) throws {
        let view = try surface(args["surface"] as? String)
        guard let pattern = args["pattern"] as? String else { throw Failure("wait needs a pattern") }
        let regex = try NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
        let scope = args["scope"] as? String ?? "viewport"
        let timeout = (args["timeout"] as? NSNumber)?.doubleValue ?? 10
        let absent = args["absent"] as? Bool ?? false
        let deadline = Date().addingTimeInterval(timeout)
        func poll() {
            let text = (try? readText(view, scope: scope)) ?? ""
            let found = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
            if found != absent {
                reply(["surface": shortID(view), "text": text])
            } else if Date() >= deadline {
                reply(["ok": false, "error": "timed out", "text": text])
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: poll)
            }
        }
        poll()
    }

    // MARK: Views, layers, hit-testing

    static func viewTree(_ args: [String: Any]) throws -> [String: Any] {
        let window = try self.window(args)
        let maxDepth = args["depth"] as? Int ?? 40
        func node(_ view: NSView, _ depth: Int) -> [String: Any] {
            var info: [String: Any] = ["class": String(describing: type(of: view))]
            info["frame"] = rectJSON(topLeftRect(view.bounds, of: view))
            if view.isHidden { info["hidden"] = true }
            if view.alphaValue < 1 { info["alpha"] = view.alphaValue }
            if let surface = view as? Ghostty.SurfaceView { info["surface"] = shortID(surface) }
            if depth < maxDepth, !view.subviews.isEmpty {
                info["children"] = view.subviews.map { node($0, depth + 1) }
            }
            return info
        }
        guard let root = window.contentView else { throw Failure("window has no content view") }
        return ["tree": node(root, 0)]
    }

    static func layerTree(_ args: [String: Any]) throws -> [String: Any] {
        let window = try self.window(args)
        let maxDepth = args["depth"] as? Int ?? 40
        guard let content = window.contentView, let rootLayer = content.layer else {
            throw Failure("window content is not layer-backed")
        }
        func frame(_ layer: CALayer) -> CGRect {
            let local = rootLayer.convert(layer.bounds, from: layer)
            let flipped = content.isFlipped != rootLayer.isGeometryFlipped
            let y = flipped ? local.minY : rootLayer.bounds.height - local.maxY
            return CGRect(x: local.minX, y: y, width: local.width, height: local.height)
        }
        func node(_ layer: CALayer, _ depth: Int) -> [String: Any] {
            var info: [String: Any] = ["class": String(describing: type(of: layer))]
            info["frame"] = rectJSON(frame(layer))
            if layer.isHidden { info["hidden"] = true }
            if layer.opacity < 1 { info["opacity"] = layer.opacity }
            if layer.masksToBounds { info["clips"] = true }
            if layer.cornerRadius > 0 { info["corner_radius"] = layer.cornerRadius }
            if layer.shadowOpacity > 0 { info["shadow"] = [Double(layer.shadowOpacity), layer.shadowRadius] }
            if layer.mask != nil { info["mask"] = true }
            if let color = layer.backgroundColor, let hex = hexColor(color) { info["background"] = hex }
            if let contents = layer.contents {
                info["contents"] = CFGetTypeID(contents as CFTypeRef) == IOSurfaceGetTypeID()
                    ? "IOSurface" : String(describing: type(of: contents))
            }
            if let view = layer.delegate as? Ghostty.SurfaceView { info["surface"] = shortID(view) }
            if depth < maxDepth, let sublayers = layer.sublayers, !sublayers.isEmpty {
                info["children"] = sublayers.map { node($0, depth + 1) }
            }
            return info
        }
        return ["tree": node(rootLayer, 0)]
    }

    static func hexColor(_ color: CGColor) -> String? {
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let converted = color.converted(to: srgb, intent: .defaultIntent, options: nil),
              let parts = converted.components, parts.count >= 3 else { return nil }
        let bytes = parts.prefix(4).map { Int(($0 * 255).rounded()) }
        return "#" + bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Which view a click at a point would reach, and the terminal it belongs to.
    static func hit(_ args: [String: Any]) throws -> [String: Any] {
        let (window, x, y) = try target(args)
        let base = try windowPoint(x, y, in: window)
        guard let content = window.contentView else { throw Failure("window has no content view") }
        let root = content.superview ?? content
        guard let view = root.hitTest(root.convert(base, from: nil)) else {
            return ["point": [x, y], "view": NSNull()]
        }
        var chain: [String] = []
        var surface: Ghostty.SurfaceView?
        var cursor: NSView? = view
        while let current = cursor, chain.count < 12 {
            chain.append(String(describing: type(of: current)))
            if surface == nil { surface = current as? Ghostty.SurfaceView }
            cursor = current.superview
        }
        // A wrapper around a terminal (its scroll view) hit outside the terminal's own view.
        if surface == nil {
            surface = surfaces(in: window).first { view !== content && $0.isDescendant(of: view) }
        }
        var result: [String: Any] = ["point": [x, y], "view": chain.first ?? "", "chain": chain]
        if let surface { result["surface"] = surfaceInfo(surface) }
        return result
    }

    // MARK: Focus

    static func activate(_ args: [String: Any], _ reply: Reply) throws {
        let window = try self.window(args)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        reply(["window": window.windowNumber])
    }

    static func focus(_ args: [String: Any], _ reply: Reply) throws {
        let view = try surface(args["surface"] as? String)
        guard let window = view.window else { throw Failure("surface is not in a window") }
        reply(["surface": shortID(view), "focused": window.makeFirstResponder(view)])
    }
}
