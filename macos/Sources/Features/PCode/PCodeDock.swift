import AppKit
import GhosttyKit
import SwiftUI

/// SPIKE: pcode's editor, tasks and status bar in a card docked under its terminal.
///
/// pcode (run with `PCODE_DOCK=1`) asks for the dock, and runs its whole
/// prompt_toolkit editor on the dock's terminal, the same way it runs an
/// overlay popup: the dock's terminal runs `pcode.popup_bridge <token>`, which
/// hands its tty to pcode. pcode's own terminal is left as scrollback only.
///
/// - `pcode;dock;<token>`, from the terminal: open the dock (unseen until ready).
/// - `pcode;dock-close`, from the terminal: remove it.
/// - `pcode;ready`, from the dock's terminal: show it and give it the keyboard.
/// - `pcode;dock-rows;<n>`, from the dock's terminal: the rows its layout needs.
/// - Anything else from the dock's terminal is handled as if pcode had sent it
///   in its own terminal (popups, the /btw drawer, toasts, its session id):
///   pcode now writes everything to the terminal its editor runs on.
///
/// The dock ending (pcode exits and its bridge with it) removes it.
final class PCodeDock: NSObject, ObservableObject, PCodeOverlayOwner {
    @Published private(set) var surface: Ghostty.SurfaceView?
    @Published private(set) var ready = false
    @Published private(set) var rows = 3

    static let maxRows = 40

    weak var surfaceView: Ghostty.SurfaceView?
    private var closeObserver: NSObjectProtocol?

    init(surfaceView: Ghostty.SurfaceView) {
        self.surfaceView = surfaceView
    }

    deinit {
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        if let surface { PCode.retire(surface) }
    }

    /// From pcode in the terminal this dock belongs to.
    func handle(_ payload: String) {
        let parts = payload.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        switch parts.first {
        case "dock" where parts.count == 2:
            guard PCode.valid(parts[1], length: 16...16, hex: true) else { return }
            open(token: parts[1])
        case "dock-close":
            close()
        default:
            break
        }
    }

    /// From the dock's own terminal, where pcode's editor now runs.
    func handleFromOverlay(_ payload: String, from overlay: Ghostty.SurfaceView) {
        guard overlay === surface else { return }
        let parts = payload.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        switch parts.first {
        case "ready":
            guard !ready else { return }
            ready = true
            Ghostty.moveFocus(to: overlay)
        case "dock-rows" where parts.count == 2:
            guard let wanted = Int(parts[1]) else { return }
            let clamped = min(Self.maxRows, max(1, wanted))
            if clamped != rows { rows = clamped }
        case "dock", "dock-close", "done", "title", "hints", "focus":
            break
        default:
            surfaceView?.pcodeEvent(payload)
        }
    }

    func close() {
        guard let surface else { return }
        let hadFocus = Self.hasFocus(surface)
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
        ready = false
        rows = 3
        self.surface = nil
        PCode.retire(surface)
        if hadFocus, let surfaceView { Ghostty.moveFocus(to: surfaceView) }
    }

    private func open(token: String) {
        close()
        guard let python = PCode.entryPython(PCode.statePath("popups/\(token).json")) else { return }
        let command = PCode.pythonCommand(python, module: "pcode.popup_bridge", args: [token])
        guard let view = PCode.makeOverlaySurface(over: surfaceView, command: command, owner: self) else { return }
        // The bridge exits a moment after pcode lets go of it (or dies).
        closeObserver = NotificationCenter.default.addObserver(
            forName: Ghostty.Notification.ghosttyCloseSurface, object: view, queue: .main
        ) { [weak self, weak view] _ in
            DispatchQueue.main.async {
                guard let self, let view, self.surface === view else { return }
                self.close()
            }
        }
        surface = view
    }

    private static func hasFocus(_ view: NSView) -> Bool {
        guard let responder = view.window?.firstResponder as? NSView else { return false }
        return responder === view || responder.isDescendant(of: view)
    }
}

/// The terminal (with its /btw drawer) above pcode's docked editor card.
///
/// A stack, not an overlay: pcode's terminal gives up the card's rows, so no
/// scrollback hides under it. The card's shadow falls on the terminal's
/// bottom edge.
struct PCodeDockedSurface: View {
    @EnvironmentObject var ghostty: Ghostty.App
    @ObservedObject var surfaceView: Ghostty.SurfaceView
    @ObservedObject var dock: PCodeDock
    var isSplit: Bool

    private static let margin: CGFloat = 8
    private static let inset: CGFloat = 6
    private static let cornerRadius: CGFloat = 12
    private static let fallbackLineHeight: CGFloat = 18

    var body: some View {
        VStack(spacing: 0) {
            PCodeDrawerSurface(surfaceView: surfaceView, drawer: surfaceView.pcodeDrawer, isSplit: isSplit)
                .zIndex(0)
            if let docked = dock.surface {
                card(docked)
                    .zIndex(1)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.86), value: dock.ready)
        .animation(.easeOut(duration: 0.1), value: dock.rows)
    }

    private func card(_ docked: Ghostty.SurfaceView) -> some View {
        let cell = docked.cellSize.height > 0
            ? docked.cellSize.height
            : (surfaceView.cellSize.height > 0 ? surfaceView.cellSize.height : Self.fallbackLineHeight)
        // Room for the rows, the terminal's own padding, and a part row of
        // slack so a rounding never costs a row (pcode bottom-aligns its layout).
        let height = CGFloat(dock.rows) * cell + cell * 0.5 + 12
        return Ghostty.SurfaceWrapper(surfaceView: docked, isSplit: false)
            .id(ObjectIdentifier(docked))
            .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius - Self.inset))
            .padding(Self.inset)
            .frame(height: height)
            .background(ghostty.config.backgroundColor)
            .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Self.cornerRadius)
                    .strokeBorder(ghostty.config.splitDividerColor, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.4), radius: 16, x: 0, y: -3)
            .padding(.horizontal, Self.margin)
            .padding(.top, 2)
            .padding(.bottom, Self.margin)
            .opacity(dock.ready ? 1 : 0)
            .allowsHitTesting(dock.ready)
    }
}
