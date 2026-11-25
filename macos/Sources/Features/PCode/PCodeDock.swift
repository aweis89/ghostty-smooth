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
    /// The dock's terminal is always this tall and never resizes; the card
    /// shows only its bottom `rows`, so growing is a clip, not a grid resize.
    static let gridRows = maxRows

    /// Rows of slack the card takes on top of the rows it shows: the margins
    /// around it, the terminal's own padding and a part row of headroom.
    /// pcode reckons the pane rows the card hides from it, so keep this in
    /// step with `CARD_SLACK_ROWS` in pcode's `pcode/dock.py`.
    static let slackRows: CGFloat = 1.75
    /// The card's top and bottom margins, inside `footprint`.
    static let topMargin: CGFloat = 2
    static let bottomMargin: CGFloat = 8

    /// Everything the card covers at the bottom of pcode's pane for `rows`
    /// rows of `cell` points, margins included: whole cells, so pcode can
    /// work it out from its own cell size.
    static func footprint(rows: Int, cell: CGFloat) -> CGFloat {
        (CGFloat(rows) + slackRows) * cell
    }

    /// The card's own height for `rows` terminal rows of `cell` points.
    static func cardHeight(rows: Int, cell: CGFloat) -> CGFloat {
        footprint(rows: rows, cell: cell) - topMargin - bottomMargin
    }

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
/// An overlay, not a stack: pcode's terminal keeps its full height, and the
/// card covers its bottom rows. pcode keeps those rows clear (a scroll region
/// above the card, `pcode/dock.py`), so growing the editor scrolls the
/// transcript like any output, which glides, instead of resizing the pane
/// (a reflow and a redraw per step of the card's animation).
struct PCodeDockedSurface: View {
    @EnvironmentObject var ghostty: Ghostty.App
    @ObservedObject var surfaceView: Ghostty.SurfaceView
    @ObservedObject var dock: PCodeDock
    var isSplit: Bool

    private static let cornerRadius: CGFloat = 12
    private static let fallbackLineHeight: CGFloat = 18

    /// Rows of card the /btw drawer leaves room for; a taller card draws over its bottom.
    private static let drawerClearRows = 6

    var body: some View {
        ZStack(alignment: .bottom) {
            // pcode's terminal, full height under the card: its size never
            // follows the card's.
            PCodeDrawerSurface(
                surfaceView: surfaceView, drawer: surfaceView.pcodeDrawer, isSplit: isSplit,
                drawsDrawer: false)
            // The drawer over the whole area, card included, at a size the
            // card never changes: resizing its terminal as the card grew with
            // streamed output scrolled whatever the user was reading in it.
            PCodeDrawerSurface(
                surfaceView: surfaceView, drawer: surfaceView.pcodeDrawer, isSplit: isSplit,
                drawsSurface: false,
                bottomInset: dock.surface == nil ? nil : drawerInset)
            // The card over the drawer: a card taller than the drawer leaves
            // room for keeps its typing row in view. Its terminal is taller
            // than the card; the clipped-off top lets clicks through to what
            // is under it (`SurfaceScrollView.hitTest`).
            if let docked = dock.surface {
                // The card's whole footprint, margins included, takes the
                // clicks the card itself doesn't: the pane rows under it are
                // hidden, and a click there would start a selection in them.
                Color.clear
                    .frame(height: PCodeDock.footprint(rows: dock.rows, cell: cell))
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0))
                    .allowsHitTesting(dock.ready)
                card(docked)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.86), value: dock.ready)
        // Neither terminal resizes as the card grows (the dock's grid is
        // fixed, the pane is full height), so only the card's clip animates.
        .animation(.easeOut(duration: 0.12), value: dock.rows)
    }

    /// Space under the drawer: the card at `drawerClearRows` rows, with its margins.
    private var drawerInset: CGFloat {
        PCodeDock.footprint(rows: Self.drawerClearRows, cell: cell)
    }

    /// The dock's row height, or the pane's until the dock has one.
    private var cell: CGFloat {
        if let docked = dock.surface, docked.cellSize.height > 0 { return docked.cellSize.height }
        return surfaceView.cellSize.height > 0 ? surfaceView.cellSize.height : Self.fallbackLineHeight
    }

    private func card(_ docked: Ghostty.SurfaceView) -> some View {
        let cell = docked.cellSize.height > 0
            ? docked.cellSize.height
            : (surfaceView.cellSize.height > 0 ? surfaceView.cellSize.height : Self.fallbackLineHeight)
        // The card is the dock's terminal itself, edge to edge: pcode tints its
        // background (OSC 11) a shade off the pane's, and its own padding takes
        // that tint, so the whole card is one raised surface. The backdrop only
        // gives the shadow its shape.
        //
        // The terminal keeps a fixed `gridRows` height, bottom-aligned in the
        // card and clipped: pcode draws its layout at the bottom of it, so a
        // taller layout is already drawn when the card grows to show it.
        return ZStack(alignment: .bottom) {
            Ghostty.SurfaceWrapper(surfaceView: docked, isSplit: false)
                .id(ObjectIdentifier(docked))
                .frame(height: PCodeDock.cardHeight(rows: PCodeDock.gridRows, cell: cell))
        }
            .frame(height: PCodeDock.cardHeight(rows: dock.rows, cell: cell), alignment: .bottom)
            .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius))
            .background(
                RoundedRectangle(cornerRadius: Self.cornerRadius)
                    .fill(ghostty.config.backgroundColor)
                    .shadow(color: .black.opacity(0.28), radius: 18, x: 0, y: -2))
            .padding(.horizontal, PCodeDock.bottomMargin)
            .padding(.top, PCodeDock.topMargin)
            .padding(.bottom, PCodeDock.bottomMargin)
            .opacity(dock.ready ? 1 : 0)
            .allowsHitTesting(dock.ready)
    }
}
