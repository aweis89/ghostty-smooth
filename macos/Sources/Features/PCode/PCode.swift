import AppKit
import GhosttyKit

/// What the pcode drawer and popup share: checks on what pcode sends, the
/// overlay terminals they run, and how those terminals' APCs are routed.
///
/// pcode talks to us with APCs (`ESC _ pcode;<payload> ESC \`), which reach us
/// as `GHOSTTY_ACTION_PCODE_EVENT`. A terminal of the window speaks to its own
/// drawer and popup (`PCodeDrawer`, `PCodePopup`); an overlay terminal one of
/// those runs speaks only to the drawer or popup it is in. Neither can use the
/// other's verbs.
enum PCode {
    /// True if `value` is plain: ASCII letters, digits, `-` and `_`, or
    /// lowercase hex digits only if `hex`, with a length in `length`.
    static func valid(_ value: String, length: ClosedRange<Int>, hex: Bool = false) -> Bool {
        length.contains(value.count) && value.allSatisfy {
            guard $0.isASCII else { return false }
            if hex { return $0.isHexDigit && !$0.isUppercase }
            return $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_"
        }
    }

    /// `~/.local/state/pcode/<relative>`.
    static func statePath(_ relative: String) -> String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/state/pcode/\(relative)").path
    }

    /// `python` from a pcode state file this user owns, if it names an executable at a plain path.
    static func entryPython(_ path: String) -> String? {
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

    /// `python -I -m <module> <args>`, as a surface command.
    ///
    /// The embedded API always runs a surface's command in a shell, as
    /// `bash -c "exec -l <command>"` (`embedded.zig`, `Exec.zig`). `-l` puts a
    /// dash before argv[0], and a venv's Python finds its venv from argv[0], so
    /// `env` starts it with a plain one. `-I` keeps the directory, user site
    /// and PYTHON* variables out of its imports. `args` must be plain already.
    static func pythonCommand(_ python: String, module: String, args: [String]) -> String {
        (["/usr/bin/env", shellQuoted(python), "-I", "-m", module] + args).joined(separator: " ")
    }

    static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// A terminal laid over `surfaceView` that runs `command`, owned by `owner`.
    static func makeOverlaySurface(
        over surfaceView: Ghostty.SurfaceView?,
        command: String,
        owner: PCodeOverlayOwner
    ) -> Ghostty.SurfaceView? {
        guard let surfaceView, let surface = surfaceView.surface else { return nil }
        let app = ghostty_surface_app(surface)
        // As a new split would be: this terminal's font size, directory and environment.
        var config = Ghostty.SurfaceConfiguration(
            from: ghostty_surface_inherited_config(surface, GHOSTTY_SURFACE_CONTEXT_SPLIT))
        config.command = command
        // Not the pane's directory: nothing from a checkout is near the overlay's command.
        config.workingDirectory = NSHomeDirectory()
        config.initialInput = nil
        config.waitAfterCommand = false
        let view = Ghostty.SurfaceView(app, baseConfig: config)
        view.pcodeOwner = owner
        return view
    }
}

/// A drawer or popup that runs overlay terminals over a terminal of the window.
protocol PCodeOverlayOwner: AnyObject {
    /// The terminal of the window the overlay is laid over.
    var surfaceView: Ghostty.SurfaceView? { get }

    /// An APC from `overlay`, a terminal this owner made. It may be one the
    /// owner has since dropped, so the owner checks it is still its own.
    func handleFromOverlay(_ payload: String, from overlay: Ghostty.SurfaceView)
}

private var pcodeDrawerKey: UInt8 = 0
private var pcodePopupKey: UInt8 = 0
private var pcodeOwnerKey: UInt8 = 0

/// Holds the owner weakly: the owner holds its overlay's surface, not the other way round.
private final class WeakOwner: NSObject {
    weak var owner: PCodeOverlayOwner?
    init(_ owner: PCodeOverlayOwner) { self.owner = owner }
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

    /// This surface's pcode popup slot, made the first time it is asked for.
    var pcodePopup: PCodePopup {
        if let popup = existingPCodePopup { return popup }
        let popup = PCodePopup(surfaceView: self)
        objc_setAssociatedObject(self, &pcodePopupKey, popup, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return popup
    }

    private var existingPCodePopup: PCodePopup? {
        objc_getAssociatedObject(self, &pcodePopupKey) as? PCodePopup
    }

    /// The drawer or popup this surface is the overlay terminal of, if it is one.
    var pcodeOwner: PCodeOverlayOwner? {
        get { (objc_getAssociatedObject(self, &pcodeOwnerKey) as? WeakOwner)?.owner }
        set {
            objc_setAssociatedObject(
                self, &pcodeOwnerKey, newValue.map(WeakOwner.init), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }

    /// The surface this one stands for in its window: for a pcode overlay, the
    /// terminal it is laid over, which is in the window's split tree where the
    /// overlay is not. Focusing an overlay then leaves the window's title,
    /// directory and split actions on that terminal.
    var pcodeWindowSurface: Ghostty.SurfaceView {
        pcodeOwner?.surfaceView ?? self
    }

    /// An APC from pcode in this surface.
    func pcodeEvent(_ payload: String) {
        if let owner = pcodeOwner {
            owner.handleFromOverlay(payload, from: self)
            return
        }
        switch payload.prefix(while: { $0 != ";" }) {
        case "popup", "popup-close":
            pcodePopup.handle(payload)
        default:
            pcodeDrawer.handle(payload)
        }
    }

    /// This surface took the keyboard. While its popup is shown, the popup gets it back.
    func pcodeDidFocus() {
        guard pcodeOwner == nil else { return }
        existingPCodePopup?.windowSurfaceDidFocus()
    }
}
