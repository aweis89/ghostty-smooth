import AppKit
import SwiftUI

/// The fork's whole coupling to pcode's app code.
///
/// pcode's Swift (the workspace window, docked editor, popups, pickers) lives
/// in the pcode repo and is copied into `Features/PCode/` when the app is built
/// from there. Upstream files call `PCodeHooks.shared` and nothing else of
/// pcode's, so this fork builds and runs on its own as Ghostty with its
/// renderer patches: without that code every hook is `UpstreamHooks`, which
/// does what upstream does.
///
/// Add a hook only when pcode's code needs a new entry point into an upstream
/// file, and give `UpstreamHooks` the upstream behavior. There are no default
/// implementations on purpose: a mistyped signature in pcode's implementation
/// is then a compile error, not a hook that silently never runs. (Renaming the
/// implementation's `@objc` name is not caught: see the log in `shared`.)
protocol PCodeAppHooks: AnyObject {
    // MARK: App

    /// pcode's workspace window replaces Ghostty's terminal windows, tabs and
    /// splits (and their state restoration).
    var replacesTerminalWindows: Bool { get }

    /// Show the workspace window: at launch, and on reopen with no windows.
    func showWorkspace(_ ghostty: Ghostty.App)

    /// A new tab or window was asked for by a keybinding or the app.
    func newSession(_ ghostty: Ghostty.App)

    /// File > New Window.
    func newWindow(_ ghostty: Ghostty.App)

    /// Quit without asking: a restart already confirmed and is relaunching.
    var terminatesImmediately: Bool { get }

    /// App menu > Restart.
    func restart()

    // MARK: Window actions

    /// Cancel a native picker with the keyboard in `window`; false if none has it.
    func cancelKeyboardPicker(in window: NSWindow?) -> Bool

    /// Whether a native picker has the keyboard in `window`.
    func hasKeyboardPicker(in window: NSWindow?) -> Bool

    /// An overlay terminal with the keyboard in `window`, which close and
    /// reset act on instead of the window's focused surface.
    func keyboardOverlay(in window: NSWindow?) -> Ghostty.SurfaceView?

    // MARK: Surfaces

    /// For an overlay terminal, the pane it is laid over: split, tab and
    /// window actions from the overlay act on that pane.
    func pane(forOverlay view: Ghostty.SurfaceView) -> Ghostty.SurfaceView?

    /// A `GHOSTTY_ACTION_PCODE_EVENT` payload from `view`.
    func handleEvent(_ payload: String, from view: Ghostty.SurfaceView)

    /// The surface the window treats as focused while `view` has the keyboard.
    func windowSurface(for view: Ghostty.SurfaceView) -> Ghostty.SurfaceView

    /// Hide the resize size pill for `view`.
    func suppressesResizeOverlay(_ view: Ghostty.SurfaceView) -> Bool

    /// Height from the bottom of `view` that takes clicks; nil for all of it.
    func clickableHeight(_ view: Ghostty.SurfaceView) -> CGFloat?

    /// Skip upstream's "first click only focuses" for `view`.
    func clicksThroughOnFocus(_ view: Ghostty.SurfaceView) -> Bool

    /// Drop mouse movement over `view` (no cursor shape or mouse report).
    func ignoresMouse(_ view: Ghostty.SurfaceView) -> Bool

    /// Whether focus-follows-mouse may focus `view`.
    func allowsMouseFocus(_ view: Ghostty.SurfaceView) -> Bool

    func didBecomeFirstResponder(_ view: Ghostty.SurfaceView)
    func didMouseUp(_ view: Ghostty.SurfaceView)
    func willKeyDown(_ view: Ghostty.SurfaceView, _ event: NSEvent)

    /// The session `view` showed, saved with window state.
    func restorableSession(_ view: Ghostty.SurfaceView) -> String?

    /// The initial input that reopens a restored `session`.
    func resumeInput(session: String?) -> String?

    // MARK: SwiftUI

    /// What InspectorView shows for a surface (upstream: `SurfaceWrapper`).
    func surfaceContent(_ view: Ghostty.SurfaceView, isSplit: Bool) -> AnyView

    /// Laid over the surface and its inspector.
    func surfaceOverlay(_ view: Ghostty.SurfaceView) -> AnyView

    // MARK: Debug socket

    /// Run a debug socket command upstream's socket doesn't know; false if
    /// this doesn't know it either.
    func debugCommand(
        _ cmd: String,
        _ args: [String: Any],
        _ finish: @escaping DebugCommands.Reply
    ) throws -> Bool

    /// Extra fields for the debug socket's description of `view`.
    func debugInfo(_ view: Ghostty.SurfaceView) -> [String: Any]
}

enum PCodeHooks {
    /// pcode's implementation (`@objc(PCodeAppHooksImpl)`) when its code is
    /// built in, else upstream behavior.
    static let shared: PCodeAppHooks = {
        if let type = NSClassFromString("PCodeAppHooksImpl") as? NSObject.Type,
           let hooks = type.init() as? PCodeAppHooks {
            return hooks
        }
        // A fork-only build gets here by design; a Pcode.app build that does
        // has lost `@objc(PCodeAppHooksImpl)` and quietly runs as Ghostty.
        Ghostty.logger.notice("pcode hooks: no PCodeAppHooksImpl, using upstream behavior")
        return UpstreamHooks()
    }()
}

/// Upstream Ghostty's behavior at every hook.
private final class UpstreamHooks: PCodeAppHooks {
    var replacesTerminalWindows: Bool { false }
    func showWorkspace(_ ghostty: Ghostty.App) {}
    func newSession(_ ghostty: Ghostty.App) {}
    func newWindow(_ ghostty: Ghostty.App) {}
    var terminatesImmediately: Bool { false }
    func restart() {}

    func cancelKeyboardPicker(in window: NSWindow?) -> Bool { false }
    func hasKeyboardPicker(in window: NSWindow?) -> Bool { false }
    func keyboardOverlay(in window: NSWindow?) -> Ghostty.SurfaceView? { nil }

    func pane(forOverlay view: Ghostty.SurfaceView) -> Ghostty.SurfaceView? { nil }
    func handleEvent(_ payload: String, from view: Ghostty.SurfaceView) {}
    func windowSurface(for view: Ghostty.SurfaceView) -> Ghostty.SurfaceView { view }
    func suppressesResizeOverlay(_ view: Ghostty.SurfaceView) -> Bool { false }
    func clickableHeight(_ view: Ghostty.SurfaceView) -> CGFloat? { nil }
    func clicksThroughOnFocus(_ view: Ghostty.SurfaceView) -> Bool { false }
    func ignoresMouse(_ view: Ghostty.SurfaceView) -> Bool { false }
    func allowsMouseFocus(_ view: Ghostty.SurfaceView) -> Bool { true }
    func didBecomeFirstResponder(_ view: Ghostty.SurfaceView) {}
    func didMouseUp(_ view: Ghostty.SurfaceView) {}
    func willKeyDown(_ view: Ghostty.SurfaceView, _ event: NSEvent) {}
    func restorableSession(_ view: Ghostty.SurfaceView) -> String? { nil }
    func resumeInput(session: String?) -> String? { nil }

    func surfaceContent(_ view: Ghostty.SurfaceView, isSplit: Bool) -> AnyView {
        AnyView(Ghostty.SurfaceWrapper(surfaceView: view, isSplit: isSplit))
    }

    func surfaceOverlay(_ view: Ghostty.SurfaceView) -> AnyView { AnyView(EmptyView()) }

    func debugCommand(
        _ cmd: String,
        _ args: [String: Any],
        _ finish: @escaping DebugCommands.Reply
    ) throws -> Bool { false }

    func debugInfo(_ view: Ghostty.SurfaceView) -> [String: Any] { [:] }
}
