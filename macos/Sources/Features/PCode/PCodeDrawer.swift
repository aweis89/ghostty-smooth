import AppKit
import GhosttyKit
import SwiftUI

/// A drawer over the right of a terminal surface that shows a pcode /btw thread.
///
/// pcode asks for it with an APC (`ESC _ pcode;btw;<host>;<thread> ESC \`,
/// `ESC _ pcode;close ESC \`), which reaches us as `GHOSTTY_ACTION_PCODE_EVENT`.
/// The drawer is a second terminal surface, so it has this terminal's font,
/// size and colors. It runs `python -m pcode.btw_tail <host> <thread>` with
/// the session host's own interpreter, read from the host's entry file; that
/// viewer reads the thread from the host and draws it. Nothing in the APC
/// becomes part of the command but the checked host id and thread.
final class PCodeDrawer: NSObject, ObservableObject {
    @Published var visible = false
    /// The drawer's terminal while it is open; dropping it ends the viewer.
    @Published private(set) var viewer: Ghostty.SurfaceView?

    weak var surfaceView: Ghostty.SurfaceView?
    private var shown: (host: String, thread: String)?
    private var closeObserver: NSObjectProtocol?

    init(surfaceView: Ghostty.SurfaceView) {
        self.surfaceView = surfaceView
    }

    deinit {
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
    }

    // MARK: Commands

    /// From pcode in the terminal this drawer belongs to.
    func handle(_ payload: String) {
        let parts = payload.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        switch parts.first {
        case "btw" where parts.count == 3:
            guard Self.valid(parts[1], length: 8...8, hex: true), Self.valid(parts[2], length: 1...64) else {
                return
            }
            show(host: parts[1], thread: parts[2])
        case "close":
            close()
        default:
            break
        }
    }

    /// From the viewer in the drawer's own terminal: only asking for the keyboard to go back.
    func handleFromViewer(_ payload: String) {
        // Only while the drawer has the keyboard: anything else that prints
        // the sequence there must not pull focus from another split.
        if payload == "focus" && viewerHasFocus { focusTerminal() }
    }

    private static func valid(_ value: String, length: ClosedRange<Int>, hex: Bool = false) -> Bool {
        length.contains(value.count) && value.allSatisfy {
            guard $0.isASCII else { return false }
            if hex { return $0.isHexDigit && !$0.isUppercase }
            return $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_"
        }
    }

    private func show(host: String, thread: String) {
        if viewer == nil || shown?.host != host || shown?.thread != thread {
            replaceViewer(with: makeViewer(host: host, thread: thread))
            shown = (host, thread)
        }
        // Shown beside the terminal without taking its keyboard: typing goes on
        // in pcode's editor, which replies to the thread.
        visible = true
    }

    func close() {
        let hadFocus = viewerHasFocus
        visible = false
        shown = nil
        replaceViewer(with: nil)
        if hadFocus { focusTerminal() }
    }

    func focusTerminal() {
        guard let surfaceView else { return }
        Ghostty.moveFocus(to: surfaceView)
    }

    private var viewerHasFocus: Bool {
        guard let viewer, let responder = viewer.window?.firstResponder as? NSView else { return false }
        return responder === viewer || responder.isDescendant(of: viewer)
    }

    // MARK: The viewer's terminal

    private func replaceViewer(with next: Ghostty.SurfaceView?) {
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
        viewer = next
        guard let next else { return }
        // Cmd+W in the drawer, or the viewer exiting, asks to close its surface.
        // No window controller owns this one, so the drawer closes instead.
        closeObserver = NotificationCenter.default.addObserver(
            forName: Ghostty.Notification.ghosttyCloseSurface, object: next, queue: .main
        ) { [weak self] _ in
            // After the notification, not inside the callback that posted it,
            // which is still using the surface this frees.
            DispatchQueue.main.async { self?.close() }
        }
    }

    private func makeViewer(host: String, thread: String) -> Ghostty.SurfaceView? {
        guard let surfaceView, let surface = surfaceView.surface else { return nil }
        let app = ghostty_surface_app(surface)
        // As a new split would be: this terminal's font size, directory and environment.
        var config = Ghostty.SurfaceConfiguration(
            from: ghostty_surface_inherited_config(surface, GHOSTTY_SURFACE_CONTEXT_SPLIT))
        config.command = Self.viewerCommand(host: host, thread: thread)
        // Not the pane's directory: nothing from a checkout is near the viewer.
        config.workingDirectory = NSHomeDirectory()
        config.initialInput = nil
        config.waitAfterCommand = false
        let view = Ghostty.SurfaceView(app, baseConfig: config)
        view.pcodeOwner = self
        return view
    }

    /// The viewer, run with the interpreter the session host runs on, so it
    /// is the same pcode; or a message, if the host cannot say which that is.
    private static func viewerCommand(host: String, thread: String) -> String {
        let entry = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/state/pcode/hosts/\(host).json").path
        guard let python = hostPython(entry) else {
            return message("This session host's pcode predates the drawer: run /restart in pcode.")
        }
        // The embedded API always runs a surface's command in a shell, as
        // `bash -c "exec -l <command>"` (`embedded.zig`, `Exec.zig`). `-l`
        // puts a dash before argv[0], and a venv's Python finds its venv from
        // argv[0], so `env` starts it with a plain one. `-I` keeps the
        // directory, user site and PYTHON* variables out of its imports.
        // The ids are plain by now.
        return "/usr/bin/env \(shellQuoted(python)) -I -m pcode.btw_tail \(host) \(thread)"
    }

    private static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// `python` from a host entry this user owns, if it names an executable at a plain path.
    private static func hostPython(_ path: String) -> String? {
        // Opened without following a link, then checked: what is checked is what is read.
        let fd = open(path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              info.st_size < 1 << 20,
              let data = try? handle.readToEnd(),
              let entry = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let python = entry["python"] as? String,
              python.hasPrefix("/"),
              // `env` would take a word with `=` for a variable to set.
              !python.contains("="),
              !python.contains(where: { $0.asciiValue.map { $0 < 0x20 } ?? false }),
              FileManager.default.isExecutableFile(atPath: python) else { return nil }
        return python
    }

    /// A command that only shows `text`; the embedded API waits after every
    /// command, so it stays until a key or the drawer closes it.
    private static func message(_ text: String) -> String {
        "printf '%s\\n' \(shellQuoted(text))"
    }
}

private var pcodeDrawerKey: UInt8 = 0
private var pcodeOwnerKey: UInt8 = 0

/// Holds the drawer weakly: the drawer owns the viewer's surface, not the other way round.
private final class WeakDrawer: NSObject {
    weak var drawer: PCodeDrawer?
    init(_ drawer: PCodeDrawer) { self.drawer = drawer }
}

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

    /// The drawer this surface is the viewer of, if it is one.
    var pcodeOwner: PCodeDrawer? {
        get { (objc_getAssociatedObject(self, &pcodeOwnerKey) as? WeakDrawer)?.drawer }
        set {
            objc_setAssociatedObject(
                self, &pcodeOwnerKey, newValue.map(WeakDrawer.init), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }
}

/// The terminal surface, with its pcode drawer laid over its right side while one is shown.
///
/// An overlay rather than a split: the terminal keeps its size, so nothing
/// reflows and pcode's editor stays where it is, and the surface never leaves
/// the view tree, so it keeps the keyboard. The drawer slides in from the right
/// and stops several rows above the bottom so the editor and status bar stay
/// uncovered.
struct PCodeDrawerSurface: View {
    @EnvironmentObject var ghostty: Ghostty.App
    @ObservedObject var surfaceView: Ghostty.SurfaceView
    @ObservedObject var drawer: PCodeDrawer
    var isSplit: Bool

    /// The drawer's share of the surface's width, set by dragging its left edge.
    @State private var fraction: CGFloat = 0.70
    /// `fraction` when the current drag began: drags report distance from their start.
    @State private var dragStart: CGFloat?
    private static let minWidth: CGFloat = 260
    private static let minHeight: CGFloat = 120
    /// Terminal rows left uncovered at the bottom so pcode's editor and status bar stay visible.
    private static let bottomLines: CGFloat = 6
    private static let fallbackLineHeight: CGFloat = 18

    var body: some View {
        GeometryReader { geometry in
            Ghostty.SurfaceWrapper(surfaceView: surfaceView, isSplit: isSplit)
                .overlay(alignment: .topTrailing) {
                    ZStack(alignment: .topTrailing) {
                        Color.clear
                        if drawer.visible, let viewer = drawer.viewer {
                            overlay(
                                viewer,
                                width: width(in: geometry.size.width),
                                height: height(in: geometry.size.height),
                                total: geometry.size.width
                            )
                            .allowsHitTesting(drawer.visible)
                            .transition(.move(edge: .trailing))
                            .zIndex(1)
                        }
                    }
                    .clipped()
                    .animation(.easeOut(duration: 0.18), value: drawer.visible)
                }
        }
    }

    private func width(in total: CGFloat) -> CGFloat {
        let floor = min(total, Self.minWidth)
        let upper = max(floor, total * 0.85)
        return min(upper, max(floor, total * fraction))
    }

    private func height(in total: CGFloat) -> CGFloat {
        let lineHeight = surfaceView.cellSize.height > 0 ? surfaceView.cellSize.height : Self.fallbackLineHeight
        let extraPadding: CGFloat
        if let rows = surfaceView.surfaceSize?.rows, rows > 0, surfaceView.cellSize.height > 0 {
            extraPadding = max(0, total - CGFloat(rows) * lineHeight) / 2
        } else {
            extraPadding = 0
        }
        let inset = min(lineHeight * Self.bottomLines + extraPadding, max(0, total - Self.minHeight))
        return max(0, total - inset)
    }

    private func overlay(
        _ viewer: Ghostty.SurfaceView,
        width: CGFloat,
        height: CGFloat,
        total: CGFloat
    ) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                // The left edge: a thin line to see, a wider strip to drag.
                Rectangle()
                    .fill(ghostty.config.splitDividerColor)
                    .frame(width: 1)
                    .overlay(
                        Color.clear
                            .frame(width: 8)
                            .contentShape(Rectangle())
                            .backport.pointerStyle(.resizeLeftRight)
                            .onHover { inside in
                                if #available(macOS 15, *) { return }
                                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                            }
                            .gesture(
                                DragGesture(coordinateSpace: .global)
                                    .onChanged { gesture in
                                        guard total > 0 else { return }
                                        let start = dragStart ?? fraction
                                        dragStart = start
                                        let next = start - gesture.translation.width / total
                                        let minFraction = min(1, Self.minWidth / total)
                                        let maxFraction = max(minFraction, 0.85)
                                        fraction = min(maxFraction, max(minFraction, next))
                                    }
                                    .onEnded { _ in dragStart = nil }
                            )
                    )
                    .zIndex(1)
                Ghostty.SurfaceWrapper(surfaceView: viewer, isSplit: false)
                    .id(ObjectIdentifier(viewer))
            }
            // Bottom edge above the uncovered editor rows.
            Rectangle()
                .fill(ghostty.config.splitDividerColor)
                .frame(height: 1)
        }
        .frame(width: width, height: height)
        .background(ghostty.config.backgroundColor)
        .shadow(color: .black.opacity(0.35), radius: 8, x: -2, y: 2)
    }
}

