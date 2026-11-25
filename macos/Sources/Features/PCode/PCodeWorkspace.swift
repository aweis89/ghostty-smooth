import AppKit
import GhosttyKit
import SwiftUI

/// SPIKE: pcode's own window, in place of Ghostty's terminal windows, tabs and splits.
///
/// A sidebar lists the sessions open here and the recent ones pcode saved;
/// picking one shows its pane: pcode's terminal (with its docked editor,
/// popups, drawer and toasts, as in a Ghostty window) and, toggled with ⌘J,
/// a shell along the bottom in the session's directory. Sessions are not
/// tabs or windows: every one lives in this window, and switching only swaps
/// which pane is shown, so a hidden session keeps running.
///
/// On with `PCODE_WORKSPACE=1` (or the `PCodeWorkspace` default). pcode runs as
/// `$PCODE_COMMAND` (default `pcode`), resumed with `-c <id>` in the session's
/// own directory.
enum PCodeWorkspaceMode {
    static let enabled: Bool =
        ProcessInfo.processInfo.environment["PCODE_WORKSPACE"] == "1"
        || UserDefaults.standard.bool(forKey: "PCodeWorkspace")

    static var command: String {
        let value = ProcessInfo.processInfo.environment["PCODE_COMMAND"] ?? ""
        return value.isEmpty ? "pcode" : value
    }
}

/// A saved session, read from pcode's `sessions/<id>/session.json`.
struct PCodeSessionInfo: Identifiable, Hashable, Decodable {
    let id: String
    let workspace: String
    let updated: String
    let name: String?
    let title: String?
    let turns: Int

    var label: String {
        if let name, !name.isEmpty { return name }
        if let title, !title.isEmpty { return title }
        return "Untitled session"
    }

    var directoryName: String { (workspace as NSString).lastPathComponent }

    static var root: URL {
        let env = ProcessInfo.processInfo.environment
        if let dir = env["PCODE_SESSION_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath)
        }
        let state = env["XDG_STATE_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? (NSHomeDirectory() as NSString).appendingPathComponent(".local/state")
        return URL(fileURLWithPath: state).appendingPathComponent("pcode/sessions")
    }

    /// Saved sessions with at least one turn, newest first.
    static func load(limit: Int = 200) -> [PCodeSessionInfo] {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        let decoder = JSONDecoder()
        let all = dirs.compactMap { dir -> PCodeSessionInfo? in
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("session.json")),
                  let info = try? decoder.decode(PCodeSessionInfo.self, from: data),
                  info.id == dir.lastPathComponent, info.turns > 0
            else { return nil }
            return info
        }
        return Array(all.sorted { $0.updated > $1.updated }.prefix(limit))
    }
}

/// One session shown in the workspace: pcode's terminal and its optional bottom shell.
final class PCodeSessionPane: ObservableObject, Identifiable {
    let id = UUID()
    let surface: Ghostty.SurfaceView
    let directory: String
    /// The session pcode reports (`pcode;session;<id>`), once it has.
    @Published var sessionID: String?
    @Published private(set) var shell: Ghostty.SurfaceView?
    @Published var shellVisible = false

    init(surface: Ghostty.SurfaceView, directory: String, sessionID: String?) {
        self.surface = surface
        self.directory = directory
        self.sessionID = sessionID
    }

    /// The surface keys should go to: pcode's docked editor once shown, else its terminal.
    var keyboardSurface: Ghostty.SurfaceView {
        if let dock = surface.existingPCodeDock, dock.ready, let docked = dock.surface { return docked }
        return surface
    }

    func setShell(_ view: Ghostty.SurfaceView?) { shell = view }
}

final class PCodeWorkspace: ObservableObject {
    @Published private(set) var panes: [PCodeSessionPane] = []
    @Published var selected: UUID?
    @Published private(set) var history: [PCodeSessionInfo] = []

    let ghostty: Ghostty.App
    private var observers: [NSObjectProtocol] = []
    private static let openKey = "PCodeWorkspaceOpenSessions"

    init(ghostty: Ghostty.App) {
        self.ghostty = ghostty
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: Ghostty.Notification.ghosttyCloseSurface, object: nil, queue: .main
        ) { [weak self] note in
            guard let view = note.object as? Ghostty.SurfaceView else { return }
            let processAlive = note.userInfo?["process_alive"] as? Bool ?? false
            // Posted from inside the surface's own close callback, which is
            // still using it: free it (or ask about it) on the next turn.
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, let view else { return }
                self.surfaceClosed(view, processAlive: processAlive)
            }
        })
        observers.append(center.addObserver(
            forName: PCodeWorkspace.sessionChanged, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, let view = note.object as? Ghostty.SurfaceView,
                  let pane = self.panes.first(where: { $0.surface === view }) else { return }
            pane.sessionID = view.pcodeSession
            self.saveOpen()
            self.reloadHistory()
        })
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    /// Posted by a surface whose `pcodeSession` changed.
    static let sessionChanged = Notification.Name("com.pcode.workspace.sessionChanged")

    var selectedPane: PCodeSessionPane? { panes.first { $0.id == selected } }

    /// Reopen the sessions open at last quit, or start a fresh one.
    func restore() {
        let ids = UserDefaults.standard.stringArray(forKey: Self.openKey) ?? []
        guard !ids.isEmpty else {
            newSession()
            reloadHistory()
            return
        }
        reloadHistory { [weak self] all in
            guard let self, self.panes.isEmpty else { return }
            let infos = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            for id in ids { if let info = infos[id] { self.open(info, select: false) } }
            if self.panes.isEmpty { self.newSession() } else { self.select(self.panes[0]) }
        }
    }

    /// Reload the saved sessions off the main thread; only the newest load lands.
    func reloadHistory(then done: (([PCodeSessionInfo]) -> Void)? = nil) {
        historyGeneration += 1
        let generation = historyGeneration
        DispatchQueue.global(qos: .userInitiated).async {
            let all = PCodeSessionInfo.load(limit: .max)
            DispatchQueue.main.async { [weak self] in
                guard let self, generation == self.historyGeneration else { return }
                self.history = Array(all.prefix(200))
                done?(all)
            }
        }
    }

    private var historyGeneration = 0

    /// Recent sessions not already open here.
    var recent: [PCodeSessionInfo] {
        let open = Set(panes.compactMap(\.sessionID))
        return history.filter { !open.contains($0.id) }
    }

    func info(for pane: PCodeSessionPane) -> PCodeSessionInfo? {
        guard let id = pane.sessionID else { return nil }
        return history.first { $0.id == id }
    }

    func newSession(directory: String? = nil) {
        let dir = directory ?? selectedPane?.directory ?? NSHomeDirectory()
        guard let pane = makePane(args: [], directory: dir, sessionID: nil) else { return }
        panes.insert(pane, at: 0)
        select(pane)
    }

    func open(_ info: PCodeSessionInfo, select shouldSelect: Bool = true) {
        if let pane = panes.first(where: { $0.sessionID == info.id }) {
            if shouldSelect { select(pane) }
            return
        }
        guard PCode.valid(info.id, length: 1...64) else { return }
        guard let pane = makePane(args: ["-c", info.id], directory: info.workspace, sessionID: info.id) else { return }
        panes.append(pane)
        saveOpen()
        if shouldSelect { select(pane) }
    }

    func select(_ pane: PCodeSessionPane) {
        selected = pane.id
        // After SwiftUI has put the pane's views in the window.
        DispatchQueue.main.async { Ghostty.moveFocus(to: pane.keyboardSurface) }
    }

    /// Ask to close `pane`: pcode's terminal reports back through the close
    /// notification, which confirms first if pcode is still running.
    func requestClose(_ pane: PCodeSessionPane) {
        guard let surface = pane.surface.surface else { return close(pane) }
        ghostty.requestClose(surface: surface)
    }

    /// Remove `pane` and end its terminals. Not from inside one of their callbacks.
    func close(_ pane: PCodeSessionPane) {
        guard let index = panes.firstIndex(where: { $0 === pane }) else { return }
        panes.remove(at: index)
        if let shell = pane.shell { PCode.retire(shell) }
        PCode.retire(pane.surface)
        saveOpen()
        reloadHistory()
        if selected == pane.id {
            if panes.isEmpty { selected = nil } else { select(panes[min(index, panes.count - 1)]) }
        }
    }

    func toggleShell() {
        guard let pane = selectedPane else { return }
        if pane.shell == nil {
            var config = Ghostty.SurfaceConfiguration()
            config.workingDirectory = pane.directory
            guard let app = ghostty.app else { return }
            pane.setShell(Ghostty.SurfaceView(app, baseConfig: config))
        }
        pane.shellVisible.toggle()
        let target = pane.shellVisible ? pane.shell! : pane.keyboardSurface
        DispatchQueue.main.async { Ghostty.moveFocus(to: target) }
    }

    private func makePane(args: [String], directory: String, sessionID: String?) -> PCodeSessionPane? {
        guard let app = ghostty.app else { return nil }
        var config = Ghostty.SurfaceConfiguration()
        config.command = ([PCodeWorkspaceMode.command] + args.map(PCode.shellQuoted)).joined(separator: " ")
        config.workingDirectory = FileManager.default.fileExists(atPath: directory) ? directory : NSHomeDirectory()
        // The docked editor (PCodeDock) is what the workspace shows under each session.
        config.environmentVariables["PCODE_DOCK"] = "1"
        config.waitAfterCommand = false
        let view = Ghostty.SurfaceView(app, baseConfig: config)
        return PCodeSessionPane(surface: view, directory: config.workingDirectory ?? directory, sessionID: sessionID)
    }

    private func surfaceClosed(_ view: Ghostty.SurfaceView, processAlive: Bool) {
        if let pane = panes.first(where: { $0.shell === view }) {
            pane.shellVisible = false
            pane.setShell(nil)
            view.freeSurface()
            Ghostty.moveFocus(to: pane.keyboardSurface)
            return
        }
        guard let pane = panes.first(where: { $0.surface === view }) else { return }
        guard processAlive, let window = view.window ?? NSApp.keyWindow else { return close(pane) }
        let alert = NSAlert()
        alert.messageText = "Close this session?"
        alert.informativeText = "pcode is still running in it. The session is saved and can be reopened from the sidebar."
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self, weak pane] response in
            guard response == .alertFirstButtonReturn, let self, let pane else { return }
            self.close(pane)
        }
    }

    private func saveOpen() {
        UserDefaults.standard.set(panes.compactMap(\.sessionID), forKey: Self.openKey)
    }
}

/// What the sidebar can select: an open pane, or a saved session to reopen.
private enum PCodeSidebarItem: Hashable {
    case pane(UUID)
    case saved(String)
}

struct PCodeWorkspaceView: View {
    @EnvironmentObject var ghostty: Ghostty.App
    @ObservedObject var workspace: PCodeWorkspace

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 260, max: 400)
        } detail: {
            ZStack {
                if let pane = workspace.selectedPane {
                    PCodeSessionPaneView(pane: pane)
                        .id(pane.id)
                } else {
                    Text("No session open").foregroundStyle(.secondary)
                }
            }
            .background(ghostty.config.backgroundColor)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { workspace.toggleShell() } label: {
                        Label("Shell", systemImage: "terminal")
                    }
                    .keyboardShortcut("j", modifiers: .command)
                    .help("Toggle the shell under this session (⌘J)")
                }
            }
        }
    }

    private var selection: Binding<PCodeSidebarItem?> {
        Binding(
            get: { workspace.selected.map(PCodeSidebarItem.pane) },
            set: { item in
                switch item {
                case .pane(let id):
                    if let pane = workspace.panes.first(where: { $0.id == id }) { workspace.select(pane) }
                case .saved(let id):
                    if let info = workspace.history.first(where: { $0.id == id }) { workspace.open(info) }
                case nil:
                    break
                }
            })
    }

    private var sidebar: some View {
        List(selection: selection) {
            Section("Open") {
                ForEach(workspace.panes) { pane in
                    PCodePaneRow(pane: pane, info: workspace.info(for: pane))
                        .tag(PCodeSidebarItem.pane(pane.id))
                        .contextMenu {
                            Button("Close Session") { workspace.requestClose(pane) }
                        }
                }
            }
            Section("Recent") {
                ForEach(workspace.recent) { info in
                    PCodeSessionRow(title: info.label, subtitle: info.directoryName, running: false)
                        .tag(PCodeSidebarItem.saved(info.id))
                }
            }
        }
        .listStyle(.sidebar)
        .toolbar {
            ToolbarItem {
                Button { workspace.newSession() } label: {
                    Label("New Session", systemImage: "square.and.pencil")
                }
                .help("New session (⌘N)")
            }
        }
    }
}

private struct PCodePaneRow: View {
    @ObservedObject var pane: PCodeSessionPane
    var info: PCodeSessionInfo?

    var body: some View {
        PCodePaneTitle(surface: pane.surface, info: info, directory: pane.directory)
    }
}

private struct PCodePaneTitle: View {
    @ObservedObject var surface: Ghostty.SurfaceView
    var info: PCodeSessionInfo?
    var directory: String

    var body: some View {
        let title = info?.label ?? (surface.title.isEmpty ? "New session" : surface.title)
        PCodeSessionRow(title: title, subtitle: (directory as NSString).lastPathComponent, running: true)
    }
}

private struct PCodeSessionRow: View {
    var title: String
    var subtitle: String
    var running: Bool

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(running ? Color.green : Color.clear)
                .frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).lineLimit(1).truncationMode(.tail)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}

/// A session: pcode's terminal with everything pcode lays over it, and the bottom shell.
private struct PCodeSessionPaneView: View {
    @ObservedObject var pane: PCodeSessionPane
    private static let shellHeight: CGFloat = 200

    var body: some View {
        VStack(spacing: 0) {
            Ghostty.InspectableSurface(surfaceView: pane.surface, isSplit: false)
            if pane.shellVisible, let shell = pane.shell {
                Divider()
                Ghostty.SurfaceWrapper(surfaceView: shell, isSplit: false)
                    .id(ObjectIdentifier(shell))
                    .frame(height: Self.shellHeight)
            }
        }
    }
}

/// The one workspace window.
final class PCodeWorkspaceController: NSWindowController, NSWindowDelegate {
    private static var instance: PCodeWorkspaceController?
    let workspace: PCodeWorkspace

    static func shared(_ ghostty: Ghostty.App) -> PCodeWorkspaceController {
        if let instance { return instance }
        let controller = PCodeWorkspaceController(ghostty: ghostty)
        instance = controller
        return controller
    }

    /// Show the window, starting its sessions the first time.
    static func show(_ ghostty: Ghostty.App) {
        let controller = shared(ghostty)
        if controller.workspace.panes.isEmpty { controller.workspace.restore() }
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private init(ghostty: Ghostty.App) {
        workspace = PCodeWorkspace(ghostty: ghostty)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "pcode"
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        let hosting = NSHostingController(
            rootView: PCodeWorkspaceView(workspace: workspace)
                .frame(minWidth: 700, minHeight: 400)
                .environmentObject(ghostty))
        // The window keeps its own size; by default the controller shrinks it
        // to SwiftUI's ideal size, which for a split view is tiny.
        hosting.sizingOptions = [.minSize]
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: 1200, height: 800))
        window.setFrameAutosaveName("PCodeWorkspace")
        if !window.setFrameUsingName("PCodeWorkspace") || window.frame.width < 700 {
            window.setContentSize(NSSize(width: 1200, height: 800))
            window.center()
        }
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("not restorable from a coder") }

    // MARK: First Responder

    /// ⌘W: a picker or popup with the keyboard closes itself; otherwise the
    /// focused shell, or the session (the docked editor stands for its session).
    @IBAction func close(_ sender: Any) {
        if let picker = PCode.keyboardPicker(in: window) {
            picker.cancel()
            return
        }
        if let overlay = PCode.keyboardOverlay(in: window)?.surface {
            workspace.ghostty.requestClose(surface: overlay)
            return
        }
        guard let pane = workspace.selectedPane else { return }
        if pane.shellVisible, let shell = pane.shell, let surface = shell.surface,
           let responder = window?.firstResponder as? NSView,
           responder === shell || responder.isDescendant(of: shell) {
            workspace.ghostty.requestClose(surface: surface)
            return
        }
        workspace.requestClose(pane)
    }

    @IBAction func closeWindow(_ sender: Any) {
        window?.performClose(sender)
    }
}
