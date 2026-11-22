import AppKit
import GhosttyKit
import SwiftUI

/// A modal popup over a terminal surface, in which pcode draws one of its own popups.
///
/// pcode keeps the popup in-process: a small bridge it runs in the popup's
/// terminal hands pcode that terminal's tty, and pcode reads keys from and
/// draws onto it directly. We only host the terminal: its place, size and the
/// keyboard. APCs (protocol 1, see `PCode`):
///
/// - `pcode;popup?` is answered in Zig (`stream_handler.zig`) with `pcode;popup;1`.
/// - `pcode;popup;<token>;<layout>`, from the terminal: open a popup, replacing
///   any open one. `token` is 16 lowercase hex digits, `layout` is `sheet` or
///   `wide`. Its interpreter is `python` in
///   `~/.local/state/pcode/popups/<token>.json`; without a valid one nothing
///   opens and pcode falls back on its own. The popup's terminal runs
///   `python -I -m pcode.popup_bridge <token>`, laid out at its real size but
///   unseen and without the keyboard.
/// - `pcode;ready`, from the popup's own terminal once pcode holds its tty:
///   show the popup over a dimmed terminal and give it the keyboard. Only that
///   terminal can, so output in the main terminal cannot pull the keyboard away.
/// - `pcode;title;<base64 utf-8>`, from the popup's own terminal: the
///   popup's title, shown in a slim header above its terminal (hidden while
///   empty). Cut to `titleLimit` characters, with control characters dropped.
/// - `pcode;done`, from the popup's own terminal: close the popup.
/// - `pcode;popup-close;<token>`, from the terminal: close the popup if it is
///   still `token`'s (pcode gave up waiting for it).
///
/// Cmd+W in the popup, its bridge exiting, or a click on the dimmed terminal
/// also close it. Closing drops the popup's terminal, which hangs up its tty;
/// pcode takes that as a cancel. Escape and other keys are pcode's.
final class PCodePopup: NSObject, ObservableObject, PCodeOverlayOwner {
    enum Layout: String {
        case sheet, wide
    }

    struct Slot {
        let token: String
        let layout: Layout
        let surface: Ghostty.SurfaceView
    }

    /// The open popup: its terminal is mounted, unseen until `ready`.
    @Published private(set) var slot: Slot?
    /// pcode holds the popup's tty: it is shown and has the keyboard.
    @Published private(set) var ready = false
    /// The popup's title, from pcode in its terminal: empty for none.
    @Published private(set) var title = ""

    static let titleLimit = 200

    weak var surfaceView: Ghostty.SurfaceView?
    private var closeObserver: NSObjectProtocol?

    init(surfaceView: Ghostty.SurfaceView) {
        self.surfaceView = surfaceView
    }

    deinit {
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
    }

    // MARK: Commands

    /// From pcode in the terminal this popup belongs to.
    func handle(_ payload: String) {
        let parts = payload.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        switch parts.first {
        case "popup" where parts.count == 3 || parts.count == 4:
            guard PCode.valid(parts[1], length: 16...16, hex: true), let layout = Layout(rawValue: parts[2]) else {
                return
            }
            // A title given at open is laid out before the terminal first
            // reports its size, so pcode's first frame already fits under it.
            let title = parts.count == 4 ? Self.title(fromBase64: parts[3]) : ""
            open(token: parts[1], layout: layout, title: title)
        case "popup-close" where parts.count == 2:
            // Only the popup it opened: a stale token never closes a newer one.
            if let slot, slot.token == parts[1] { close() }
        default:
            break
        }
    }

    /// From the popup's own terminal.
    func handleFromOverlay(_ payload: String, from overlay: Ghostty.SurfaceView) {
        guard let slot, slot.surface === overlay else { return }
        if payload.hasPrefix("title;") {
            let decoded = Self.title(fromBase64: String(payload.dropFirst("title;".count)))
            if decoded != title { title = decoded }
            return
        }
        switch payload {
        case "ready":
            guard !ready else { return }
            ready = true
            Ghostty.moveFocus(to: slot.surface)
        case "done":
            close()
        default:
            break
        }
    }

    func close() {
        guard let slot else { return }
        let hadFocus = Self.hasFocus(slot.surface)
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
        ready = false
        title = ""
        self.slot = nil
        // Hung up now, whatever still holds the view: pcode's cancel.
        PCode.retire(slot.surface)
        if hadFocus, let surfaceView { Ghostty.moveFocus(to: surfaceView) }
    }

    /// True if `surface` is this popup's terminal and is shown.
    func isShowing(_ surface: Ghostty.SurfaceView) -> Bool {
        ready && slot?.surface === surface
    }

    /// The terminal this popup is over took the keyboard, which the open
    /// popup should have: by a split or tab change, say. Give it back.
    func windowSurfaceDidFocus() {
        guard ready, let slot else { return }
        Ghostty.moveFocus(to: slot.surface)
    }

    // MARK: The popup's terminal

    private func open(token: String, layout: Layout, title: String) {
        close()
        guard let python = PCode.entryPython(PCode.statePath("popups/\(token).json")) else { return }
        // The token is plain by now.
        let command = PCode.pythonCommand(python, module: "pcode.popup_bridge", args: [token])
        self.title = title
        guard let surface = PCode.makeOverlaySurface(over: surfaceView, command: command, owner: self) else {
            self.title = ""
            return
        }
        // Cmd+W in the popup, or the bridge exiting, asks to close its surface.
        // No window controller owns this one, so the popup closes instead.
        closeObserver = NotificationCenter.default.addObserver(
            forName: Ghostty.Notification.ghosttyCloseSurface, object: surface, queue: .main
        ) { [weak self, weak surface] _ in
            // After the notification, not inside the callback that posted it,
            // which is still using the surface this frees. Only if it is still
            // this popup: a later one may have replaced it meanwhile.
            DispatchQueue.main.async {
                guard let self, let surface, self.slot?.surface === surface else { return }
                self.close()
            }
        }
        slot = Slot(token: token, layout: layout, surface: surface)
    }

    /// A title as pcode sends it: base64 UTF-8, shown as plain text on one line.
    private static let bidi: Set<UInt32> = Set(0x202A...0x202E).union(0x2066...0x2069)

    static func title(fromBase64 encoded: String) -> String {
        // Base64 grows text by a third, and a character is at most 4 bytes.
        guard encoded.count <= titleLimit * 6,
              let data = Data(base64Encoded: encoded),
              let text = String(data: data, encoding: .utf8) else { return "" }
        let plain = String(String.UnicodeScalarView(
            // Controls (Cc) and bidi overrides go; joiners in emoji stay.
            text.unicodeScalars.filter { $0.properties.generalCategory != .control && !bidi.contains($0.value) }
        ))
        return String(plain.trimmingCharacters(in: .whitespaces).prefix(titleLimit))
    }

    private static func hasFocus(_ view: NSView) -> Bool {
        guard let responder = view.window?.firstResponder as? NSView else { return false }
        return responder === view || responder.isDescendant(of: view)
    }
}

/// The open popup of a terminal, centered over it and a dimmed scrim.
///
/// Laid over everything the terminal shows, its /btw drawer and inspector
/// included. Until pcode is ready the popup's terminal is mounted at its real
/// size but unseen and passes clicks through.
struct PCodePopupLayer: View {
    @EnvironmentObject var ghostty: Ghostty.App
    @ObservedObject var popup: PCodePopup

    private static let cornerRadius: CGFloat = 10
    /// Keeps the terminal's square corners inside the rounded ones.
    private static let inset: CGFloat = 4
    private static let minSheet = CGSize(width: 480, height: 280)
    private static let headerFontSize: CGFloat = 12

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if popup.ready {
                    Color.black.opacity(0.4)
                        .contentShape(Rectangle())
                        .onTapGesture { popup.close() }
                        .transition(.opacity)
                }
                if let slot = popup.slot {
                    let size = Self.size(slot.layout, in: geometry.size)
                    VStack(spacing: 0) {
                        if !popup.title.isEmpty {
                            header(popup.title)
                        }
                        // The terminal's grid gets whatever the header leaves.
                        Ghostty.SurfaceWrapper(surfaceView: slot.surface, isSplit: false)
                            .id(ObjectIdentifier(slot.surface))
                            .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius - Self.inset))
                    }
                    .padding(Self.inset)
                    .frame(width: size.width, height: size.height)
                    .background(ghostty.config.backgroundColor)
                    .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius))
                    .overlay(
                        RoundedRectangle(cornerRadius: Self.cornerRadius)
                            .strokeBorder(ghostty.config.splitDividerColor, lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.45), radius: 18, x: 0, y: 6)
                    .opacity(popup.ready ? 1 : 0)
                    .allowsHitTesting(popup.ready)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .animation(.easeOut(duration: 0.12), value: popup.ready)
        }
        // Clicks reach the terminal underneath until the popup is shown.
        .allowsHitTesting(popup.ready)
    }

    /// The popup's title above its terminal, in the system font, as secondary
    /// text for the panel's own background rather than the system appearance.
    private func header(_ title: String) -> some View {
        Text(title)
            .font(.system(size: Self.headerFontSize, weight: .medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 12)
            .padding(.top, 4)
            .padding(.bottom, 6)
            .environment(\.colorScheme, NSColor(ghostty.config.backgroundColor).isLightColor ? .light : .dark)
            .accessibilityAddTraits(.isHeader)
    }

    private static func size(_ layout: PCodePopup.Layout, in total: CGSize) -> CGSize {
        switch layout {
        case .sheet:
            CGSize(
                width: min(total.width, max(minSheet.width, total.width * 0.64)),
                height: min(total.height, max(minSheet.height, total.height * 0.62)))
        case .wide:
            CGSize(width: total.width * 0.94, height: total.height * 0.92)
        }
    }
}
