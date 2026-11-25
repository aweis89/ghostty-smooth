import AppKit
import Combine
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
/// On by default (see `PCodeWorkspaceMode.enabled` to turn it off). pcode runs
/// as `$PCODE_COMMAND` (default `pcode`) through the user's login shell,
/// resumed with `-c <id>` in the session's own directory.
enum PCodeWorkspaceMode {
    /// On unless turned off: `PCODE_WORKSPACE=0`, or
    /// `defaults write com.pcode.terminal PCodeWorkspace -bool false` for
    /// Ghostty's own terminal windows, tabs and splits.
    static let enabled: Bool = {
        if let env = ProcessInfo.processInfo.environment["PCODE_WORKSPACE"], !env.isEmpty {
            return env != "0"
        }
        return UserDefaults.standard.object(forKey: "PCodeWorkspace") as? Bool ?? true
    }()

    static var command: String {
        let value = ProcessInfo.processInfo.environment["PCODE_COMMAND"] ?? ""
        return value.isEmpty ? "pcode" : value
    }

    /// The user's login shell: `$SHELL`, else their account's (a Dock or
    /// Finder launch may have no `SHELL`).
    static var loginShell: String {
        if let shell = ProcessInfo.processInfo.environment["SHELL"], !shell.isEmpty { return shell }
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell {
            let path = String(cString: shell)
            if !path.isEmpty { return path }
        }
        return "/bin/zsh"
    }

    /// `pcode` with `args`, through a login shell: an app launched from the
    /// Dock gets launchd's bare PATH, where a Homebrew or `uv tool` pcode is
    /// not, so only the user's own shell setup finds it.
    static func shellCommand(_ args: [String]) -> String {
        let inner = "exec " + ([command] + args.map(PCode.shellQuoted)).joined(separator: " ")
        return "\(PCode.shellQuoted(loginShell)) -l -c \(PCode.shellQuoted(inner))"
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
    /// The main checkout, for a session in one of its worktrees; absent in old sessions.
    let project: String?

    /// What the sidebar's project filter groups by.
    var projectPath: String { project.flatMap { $0.isEmpty ? nil : $0 } ?? workspace }

    /// Whether a pcode process holds this session now: pcode keeps an
    /// exclusive `flock` on its `.lock` while it is open (`sessions.is_open`).
    /// Reopening one of those would only continue a copy of it.
    static func isOpen(_ id: String) -> Bool {
        let path = root.appendingPathComponent(id).appendingPathComponent(".lock").path
        let fd = Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        guard flock(fd, LOCK_SH | LOCK_NB) == 0 else { return errno == EWOULDBLOCK }
        flock(fd, LOCK_UN)
        return false
    }

    var label: String {
        if let name, !name.isEmpty { return name }
        if let title, !title.isEmpty { return title }
        return "Untitled session"
    }

    var directoryName: String { (workspace as NSString).lastPathComponent }

    /// Sessions a running background host holds (pcode's `hosts/<id>.json`
    /// entries, as `host_protocol.list_hosts` reads them).
    static func hosted() -> Set<String> {
        struct Entry: Decodable {
            let pid: Int32
            let session_id: String?
        }
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: hostRoot, includingPropertiesForKeys: nil) else { return [] }
        let decoder = JSONDecoder()
        var ids = Set<String>()
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let entry = try? decoder.decode(Entry.self, from: data),
                  let id = entry.session_id, !id.isEmpty, entry.pid > 0,
                  // Alive and still a host, not a reused pid.
                  kill(entry.pid, 0) == 0, PCodeProcess.isPCodeOrHost(entry.pid)
            else { continue }
            ids.insert(id)
        }
        return ids
    }

    /// Of `ids`, sessions a Restart Pcode moved, those ready to reopen: held
    /// by a host, or unlocked on two checks half a second apart (not in the
    /// gap between the old pcode letting go and its host taking over).
    /// Waits up to `timeout` for the rest; one still locked then, with no
    /// host, is held by some other process and left out. Blocks: call it
    /// off the main thread.
    static func awaitRestarted(_ ids: [String], timeout: TimeInterval = 5) -> Set<String> {
        guard !ids.isEmpty else { return [] }
        let deadline = Date().addingTimeInterval(timeout)
        var ready = Set<String>()
        var unlocked = Set<String>()
        while true {
            let hosted = hosted()
            for id in ids where !ready.contains(id) {
                if hosted.contains(id) {
                    ready.insert(id)
                } else if isOpen(id) {
                    unlocked.remove(id)
                } else if !unlocked.insert(id).inserted {
                    ready.insert(id)
                }
            }
            if ready.count == Set(ids).count || Date() >= deadline { break }
            Thread.sleep(forTimeInterval: 0.5)
        }
        // Unlocked at the last check, with no time left for a second.
        return ready.union(unlocked)
    }

    static var hostRoot: URL {
        let env = ProcessInfo.processInfo.environment
        if let dir = env["PCODE_HOST_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath)
        }
        return stateRoot.appendingPathComponent("pcode/hosts")
    }

    private static var stateRoot: URL {
        let state = ProcessInfo.processInfo.environment["XDG_STATE_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? (NSHomeDirectory() as NSString).appendingPathComponent(".local/state")
        return URL(fileURLWithPath: state)
    }

    static var root: URL {
        let env = ProcessInfo.processInfo.environment
        if let dir = env["PCODE_SESSION_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath)
        }
        return stateRoot.appendingPathComponent("pcode/sessions")
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
    /// The terminal's title, for the sidebar. Copied out so the sidebar does
    /// not observe the whole surface, which publishes on every resize and focus change.
    @Published private(set) var title = ""
    private var titleSubscription: AnyCancellable?
    private var dockSubscription: AnyCancellable?
    private var progressSubscription: AnyCancellable?

    /// What the session is doing, from the progress pcode reports to its
    /// terminal (OSC 9;4): a turn running, a failed one not yet seen, or idle.
    enum Activity { case idle, running, failed }
    @Published private(set) var activity: Activity = .idle
    /// Called when pcode's docked editor comes or goes, so a hidden pane can size it.
    var onDockChange: (() -> Void)?

    init(surface: Ghostty.SurfaceView, directory: String, sessionID: String?) {
        self.surface = surface
        self.directory = directory
        self.sessionID = sessionID
        titleSubscription = surface.$title.removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.title = $0 }
        progressSubscription = surface.$progressReport
            .map { report -> Activity in
                switch report?.state {
                case .set?, .indeterminate?, .pause?: return .running
                case .error?: return .failed
                default: return .idle
                }
            }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.activity = $0 }
        dockSubscription = surface.pcodeDock.$surface
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                // After the publish: the new surface is in place by then.
                DispatchQueue.main.async { self?.onDockChange?() }
            }
    }

    /// Every terminal this pane shows: pcode's, its docked editor's, and the shell.
    var surfaces: [Ghostty.SurfaceView] {
        [surface, surface.existingPCodeDock?.surface, shell].compactMap { $0 }
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
    /// Whether the workspace window is on screen; set by its controller.
    var windowVisible: () -> Bool = { false }
    /// The workspace window, for confirmation sheets; set by its controller.
    weak var window: NSWindow?
    private var observers: [NSObjectProtocol] = []
    private static let openKey = "PCodeWorkspaceOpenSessions"
    private static let selectedKey = "PCodeWorkspaceSelectedSession"

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
            if pane.id == self.selected { self.saveSelected() }
            self.reloadHistory()
        })
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    private var appearanceObserver: NSKeyValueObservation?

    /// Follow macOS light/dark: each surface needs the scheme set on it, as
    /// Ghostty's own windows do for their surface trees, for a
    /// `theme = light:…,dark:…` config to switch it (and for pcode in it to
    /// hear the change, as a mode 2031 report).
    func followAppearance() {
        appearanceObserver = NSApplication.shared.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.syncColorScheme() }
        }
    }

    func syncColorScheme() {
        for pane in panes { pane.surfaces.forEach(PCode.applyColorScheme) }
    }

    /// Posted by a surface whose `pcodeSession` changed.
    static let sessionChanged = Notification.Name("com.pcode.workspace.sessionChanged")

    var selectedPane: PCodeSessionPane? { panes.first { $0.id == selected } }

    /// Reopen the sessions open at last quit, or start a fresh one.
    /// Reopen the sessions open at last quit, and every session a background
    /// host holds, or start a fresh one.
    func restore() {
        // Not into a window that is quitting to restart (a Dock click while
        // its panes close): the relaunched app reopens them. Nor twice.
        guard !restarting, !restoring else { return }
        restoring = true
        let saved = UserDefaults.standard.stringArray(forKey: Self.openKey) ?? []
        let marked = Self.restartMarker()
        let selectedID = UserDefaults.standard.string(forKey: Self.selectedKey)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // Sessions a Restart Pcode just moved may still be on their way
            // into their hosts.
            let ready = PCodeSessionInfo.awaitRestarted(marked)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.restoring = false
                Self.clearRestartMarker()
                self.reloadHistory { [weak self] all in
                    guard let self, self.panes.isEmpty else { return }
                    self.reopen(saved: saved, marked: Set(marked), ready: ready, all: all, selectedID: selectedID)
                }
            }
        }
    }

    private var restoring = false

    private func reopen(
        saved: [String], marked: Set<String>, ready: Set<String>,
        all: [PCodeSessionInfo], selectedID: String?
    ) {
        let infos = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        // Any session a host holds, even one a terminal is attached to as
        // well: `pcode -c` attaches to the host, and the window shows them all.
        let hosted = PCodeSessionInfo.hosted()
        let extra = all.map(\.id).filter { hosted.contains($0) && !saved.contains($0) }
        for id in saved + extra {
            guard let info = infos[id] else { continue }
            // Not one open in another process (a terminal, another window)
            // without a host: that would start a copy of it here instead.
            // A restarted one may have been seen ready before its host
            // registered.
            let openable = hosted.contains(id) || (marked.contains(id) ? ready.contains(id) : !PCodeSessionInfo.isOpen(id))
            if openable { open(info, select: false) }
        }
        if panes.isEmpty {
            newSession()
        } else {
            select(panes.first { $0.sessionID != nil && $0.sessionID == selectedID } ?? panes[0])
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

    /// Recent sessions not already open here, in the chosen project if one is.
    var recent: [PCodeSessionInfo] {
        let open = Set(panes.compactMap(\.sessionID))
        return history.filter { !open.contains($0.id) && (projectFilter == nil || $0.projectPath == projectFilter) }
    }

    /// The project (`PCodeSessionInfo.projectPath`) the Recent list is limited to, if any.
    @Published var projectFilter: String? = UserDefaults.standard.string(forKey: PCodeWorkspace.filterKey) {
        didSet { UserDefaults.standard.set(projectFilter, forKey: Self.filterKey) }
    }
    private static let filterKey = "PCodeWorkspaceProjectFilter"

    /// Projects with saved sessions, most recently used first, with how many each has.
    var projects: [(path: String, count: Int)] {
        var order: [String] = []
        var counts: [String: Int] = [:]
        for info in history {
            if counts[info.projectPath] == nil { order.append(info.projectPath) }
            counts[info.projectPath, default: 0] += 1
        }
        return order.map { ($0, counts[$0] ?? 0) }
    }

    func info(for pane: PCodeSessionPane) -> PCodeSessionInfo? {
        guard let id = pane.sessionID else { return nil }
        return history.first { $0.id == id }
    }

    func newSession(directory: String? = nil) {
        let dir = directory ?? selectedPane?.directory ?? NSHomeDirectory()
        guard let pane = makePane(args: [], directory: dir, sessionID: nil) else { return }
        adopt(pane)
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
        adopt(pane)
        panes.append(pane)
        schedulePresize()
        saveOpen()
        if shouldSelect { select(pane) }
    }

    // MARK: Sidebar actions

    static func reveal(_ directory: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: directory)])
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func confirmDelete(info: PCodeSessionInfo) {
        confirm("Delete “\(info.label)”?") { [weak self] in self?.delete(id: info.id) }
    }

    func confirmDelete(pane: PCodeSessionPane) {
        guard let id = pane.sessionID else { return }
        let title = info(for: pane)?.label ?? "this session"
        confirm("Delete “\(title)”?", detail: "It is closed first, ending pcode in it.") { [weak self, weak pane] in
            guard let self, let pane else { return }
            self.close(pane)
            // pcode lets go of the session a moment after its terminal closes.
            self.delete(id: id, retries: 10)
        }
    }

    private func confirm(_ message: String, detail: String? = nil, then action: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = [detail, "Its transcript and history are removed. This can't be undone."]
            .compactMap { $0 }.joined(separator: " ")
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        guard let window else { return }
        alert.beginSheetModal(for: window) { if $0 == .alertFirstButtonReturn { action() } }
    }

    /// `pcode --delete-session <id>`, which refuses a session still open in
    /// a process: retried while one is letting go of it.
    private func delete(id: String, retries: Int = 0) {
        guard PCode.valid(id, length: 1...64) else { return }
        let command = "\(PCodeWorkspaceMode.command) --delete-session \(PCode.shellQuoted(id))"
        let shell = PCodeWorkspaceMode.loginShell
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: shell)
            // A login shell, as the session terminals get: `pcode` is on its PATH.
            process.arguments = ["-l", "-c", command]
            let errors = Pipe()
            process.standardError = errors
            process.standardOutput = FileHandle.nullDevice
            var status: Int32 = -1
            if (try? process.run()) != nil {
                process.waitUntilExit()
                status = process.terminationStatus
            }
            let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            DispatchQueue.main.async {
                guard let self else { return }
                if status != 0, retries > 0, message.contains("open in another process") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.delete(id: id, retries: retries - 1) }
                    return
                }
                self.reloadHistory()
                guard status != 0 else { return }
                let alert = NSAlert()
                alert.messageText = "Couldn't delete the session"
                alert.informativeText = message.isEmpty ? "pcode exited with status \(status)." : message
                if let window = self.window { alert.beginSheetModal(for: window) } else { alert.runModal() }
            }
        }
    }

    /// Tell each terminal's renderer whether it is on screen, as Ghostty's own
    /// windows do: a hidden session must not keep drawing frames that
    /// compete with the one being watched.
    func syncOcclusion() {
        let windowVisible = windowVisible()
        for pane in panes {
            let visible = windowVisible && pane.id == selected
            for view in pane.surfaces {
                // Always sent: a new surface's flag starts false while its
                // renderer starts visible, so comparing would skip hiding it.
                guard let surface = view.surface else { continue }
                ghostty_surface_set_occlusion(surface, visible)
                view.isWindowVisible = visible
            }
        }
    }

    // MARK: Hidden panes' sizes

    /// The session area's size, measured by the view; hidden panes are sized to it.
    var detailSize: CGSize = .zero {
        didSet { if detailSize != oldValue { schedulePresize() } }
    }

    private var presizeWork: DispatchWorkItem?

    /// Presize once things settle: not on every frame of a live window resize
    /// (each one reflows every hidden terminal and signals every hidden pcode),
    /// and after a newly shown pane has been laid out, so it can be measured.
    func schedulePresize() {
        presizeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.presizeHidden() }
        presizeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    /// Give every hidden pane's terminals the size they will have when shown.
    ///
    /// A hidden pane is in no window, so nothing lays its terminals out: they
    /// keep the size they were made with (a few dozen columns), pcode in them
    /// draws to that, and showing one reflows everything at once. Sized to
    /// match the shown pane, showing it changes nothing.
    func presizeHidden() {
        guard let window, detailSize.width > 0, detailSize.height > 0 else { return }
        let scale = window.backingScaleFactor
        let shown = selectedPane
        // The shown terminals' own pixel sizes, as their layout gave them
        // (scrollers and padding included), else estimates from the area.
        let transcript = Self.pixels(shown?.surface)
            ?? (UInt32(detailSize.width * scale), UInt32(detailSize.height * scale))
        let shownDock = Self.pixels(shown?.surface.existingPCodeDock?.surface)
        for pane in panes where pane.id != selected {
            Self.setSize(pane.surface, transcript, scale: scale)
            if let docked = pane.surface.existingPCodeDock?.surface {
                let cell = docked.cellSize.height > 0 ? docked.cellSize.height : 18
                let dock = shownDock ?? (
                    UInt32((detailSize.width - 16) * scale),
                    UInt32(PCodeDock.cardHeight(rows: PCodeDock.gridRows, cell: cell) * scale))
                Self.setSize(docked, dock, scale: scale)
            }
        }
    }

    private static func pixels(_ view: Ghostty.SurfaceView?) -> (UInt32, UInt32)? {
        guard let view, view.window != nil, let surface = view.surface else { return nil }
        let size = ghostty_surface_size(surface)
        guard size.width_px > 0, size.height_px > 0 else { return nil }
        return (size.width_px, size.height_px)
    }

    private static func setSize(_ view: Ghostty.SurfaceView, _ pixels: (UInt32, UInt32), scale: CGFloat) {
        guard let surface = view.surface, view.window == nil else { return }
        let current = ghostty_surface_size(surface)
        guard current.width_px != pixels.0 || current.height_px != pixels.1 else { return }
        ghostty_surface_set_content_scale(surface, scale, scale)
        ghostty_surface_set_size(surface, pixels.0, pixels.1)
    }

    private func adopt(_ pane: PCodeSessionPane) {
        pane.onDockChange = { [weak self] in self?.schedulePresize() }
    }

    func select(_ pane: PCodeSessionPane) {
        selected = pane.id
        saveSelected()
        syncOcclusion()
        // The pane just hidden keeps its size; the others follow the shown one.
        schedulePresize()
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
            let shell = Ghostty.SurfaceView(app, baseConfig: config)
            PCode.applyColorScheme(to: shell)
            pane.setShell(shell)
        }
        pane.shellVisible.toggle()
        syncOcclusion()
        let target = pane.shellVisible ? pane.shell! : pane.keyboardSurface
        DispatchQueue.main.async { Ghostty.moveFocus(to: target) }
    }

    private func makePane(args: [String], directory: String, sessionID: String?) -> PCodeSessionPane? {
        guard let app = ghostty.app else { return nil }
        var config = Ghostty.SurfaceConfiguration()
        config.command = PCodeWorkspaceMode.shellCommand(args)
        config.workingDirectory = FileManager.default.fileExists(atPath: directory) ? directory : NSHomeDirectory()
        // The docked editor (PCodeDock) is what the workspace shows under each session.
        config.environmentVariables["PCODE_DOCK"] = "1"
        config.waitAfterCommand = false
        let view = Ghostty.SurfaceView(app, baseConfig: config)
        PCode.applyColorScheme(to: view)
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
        guard !restarting else { return }
        UserDefaults.standard.set(panes.compactMap(\.sessionID), forKey: Self.openKey)
    }

    /// Remember the shown session, for `restore` to show again.
    private func saveSelected() {
        guard !restarting, let id = selectedPane?.sessionID else { return }
        UserDefaults.standard.set(id, forKey: Self.selectedKey)
    }

    /// Whether the app is quitting to restart (`PCodeRestart`): the saved
    /// open sessions and selection are kept as they were when it began,
    /// while pcode in each pane exits and the panes close.
    private(set) var restarting = false

    /// Save what is open and shown, then stop saving until the app quits.
    /// The sessions are marked as restarting, for the relaunched app to
    /// wait for their hosts (`PCodeSessionInfo.awaitRestarted`).
    func beginRestart() {
        saveOpen()
        saveSelected()
        let defaults = UserDefaults.standard
        defaults.set(panes.compactMap(\.sessionID), forKey: Self.restartIDsKey)
        defaults.set(Date(), forKey: Self.restartTimeKey)
        restarting = true
    }

    private static let restartIDsKey = "PCodeWorkspaceRestartIDs"
    private static let restartTimeKey = "PCodeWorkspaceRestartTime"

    /// The sessions a recent Restart Pcode moved to hosts. A marker older
    /// than the restart could take (the relaunch failed, and Pcode was
    /// opened by hand much later) is ignored.
    private static func restartMarker() -> [String] {
        let defaults = UserDefaults.standard
        guard let time = defaults.object(forKey: restartTimeKey) as? Date,
              abs(time.timeIntervalSinceNow) < 600 else { return [] }
        return defaults.stringArray(forKey: restartIDsKey) ?? []
    }

    private static func clearRestartMarker() {
        UserDefaults.standard.removeObject(forKey: restartIDsKey)
        UserDefaults.standard.removeObject(forKey: restartTimeKey)
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

    private static let sidebarWidth: CGFloat = 250

    // A plain stack, not NavigationSplitView, and no toolbar: on macOS 26+
    // those lay glass (blur sampled every frame) over the terminal, which is
    // a scroll view, and make the window composite translucent layers.
    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: Self.sidebarWidth)
            Divider()
            ZStack {
                if let pane = workspace.selectedPane {
                    PCodeSessionPaneView(pane: pane)
                        .id(pane.id)
                } else {
                    Text("No session open").foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(ghostty.config.backgroundColor)
            .background(GeometryReader { proxy in
                Color.clear
                    .onAppear { workspace.detailSize = proxy.size }
                    .onChange(of: proxy.size) { workspace.detailSize = $0 }
            })
        }
    }

    private var sidebarHeader: some View {
        HStack(spacing: 4) {
            Text("Sessions").font(.headline)
            Spacer()
            Button { workspace.toggleShell() } label: { Image(systemName: "terminal") }
                .keyboardShortcut("j", modifiers: .command)
                .help("Toggle the shell under this session (⌘J)")
            Button { workspace.newSession() } label: { Image(systemName: "square.and.pencil") }
                .help("New session (⌘N)")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
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
        VStack(spacing: 0) {
            sidebarHeader
            sessionList
        }
        // Solid, a shade off the terminal's background: no vibrancy behind it.
        .background(Color(nsColor: NSColor(ghostty.config.backgroundColor).blended(
            withFraction: 0.06, of: .white) ?? .windowBackgroundColor))
    }

    private var sessionList: some View {
        List(selection: selection) {
            Section("Open") {
                ForEach(workspace.panes) { pane in
                    PCodePaneRow(pane: pane, info: workspace.info(for: pane)) { openMenu(pane) }
                        .tag(PCodeSidebarItem.pane(pane.id))
                        .contextMenu { openMenu(pane) }
                }
            }
            Section {
                ForEach(workspace.recent) { info in
                    PCodeSessionRow(title: info.label, subtitle: info.directoryName, activity: nil) {
                        recentMenu(info)
                    }
                    .tag(PCodeSidebarItem.saved(info.id))
                    .contextMenu { recentMenu(info) }
                }
            } header: {
                recentHeader
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
    }

    private var recentHeader: some View {
        HStack(spacing: 4) {
            Text(workspace.projectFilter.map { "Recent · \(($0 as NSString).lastPathComponent)" } ?? "Recent")
                .lineLimit(1)
            Spacer(minLength: 0)
            Menu {
                Picker("Project", selection: $workspace.projectFilter) {
                    Text("All Projects").tag(String?.none)
                    Divider()
                    ForEach(workspace.projects, id: \.path) { project in
                        Text("\((project.path as NSString).lastPathComponent)  (\(project.count))")
                            .tag(String?.some(project.path))
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                Image(systemName: workspace.projectFilter == nil
                    ? "line.3.horizontal.decrease.circle"
                    : "line.3.horizontal.decrease.circle.fill")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Show one project's sessions")
        }
    }

    @ViewBuilder private func openMenu(_ pane: PCodeSessionPane) -> some View {
        Button("Close Session") { workspace.requestClose(pane) }
        if pane.sessionID != nil {
            Button("Delete Session…", role: .destructive) { workspace.confirmDelete(pane: pane) }
        }
        Divider()
        Button("Reveal Directory in Finder") { PCodeWorkspace.reveal(pane.directory) }
        if let id = pane.sessionID {
            Button("Copy Session ID") { PCodeWorkspace.copy(id) }
        }
    }

    @ViewBuilder private func recentMenu(_ info: PCodeSessionInfo) -> some View {
        Button("Open") { workspace.open(info) }
        Button("Delete Session…", role: .destructive) { workspace.confirmDelete(info: info) }
        Divider()
        Button("Reveal Directory in Finder") { PCodeWorkspace.reveal(info.workspace) }
        Button("Copy Session ID") { PCodeWorkspace.copy(info.id) }
    }
}

private struct PCodePaneRow<Actions: View>: View {
    @ObservedObject var pane: PCodeSessionPane
    var info: PCodeSessionInfo?
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        // Ghostty's placeholder title until pcode sets one.
        let placeholder = pane.title.isEmpty || pane.title == "👻"
        let title = info?.label ?? (placeholder ? "New session" : pane.title)
        PCodeSessionRow(
            title: title, subtitle: (pane.directory as NSString).lastPathComponent,
            activity: pane.activity, actions: actions)
    }
}

/// A sidebar row; its actions are a right-click menu and, on hover, a … button.
private struct PCodeSessionRow<Actions: View>: View {
    var title: String
    var subtitle: String
    /// Nil for a session not open here.
    var activity: PCodeSessionPane.Activity?
    @ViewBuilder var actions: () -> Actions
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            PCodeActivityIndicator(activity: activity)
                .frame(width: 12, height: 12)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).lineLimit(1).truncationMode(.tail)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            Menu { actions() } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .opacity(hovering ? 1 : 0)
                .help("Session actions")
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

/// Open and idle: a dot. A turn running: pcode's `dual` spinner (two
/// counter-rotating crescents, `kitty_spinner._render_dual`). Failed: red.
private struct PCodeActivityIndicator: View {
    var activity: PCodeSessionPane.Activity?

    var body: some View {
        switch activity {
        case .running?:
            // 30 fps is plenty for 12 points, and keeps the sidebar from
            // redrawing at the terminal's 120.
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                Canvas { gc, size in
                    let side = min(size.width, size.height)
                    let center = CGPoint(x: size.width / 2, y: size.height / 2)
                    Self.arc(gc, center: center, radius: side * 0.40, width: side * 0.13,
                             head: t * 3.6, sweep: 2.65, color: .accentColor)
                    Self.arc(gc, center: center, radius: side * 0.22, width: side * 0.12,
                             head: -t * 5.4, sweep: 2.45, color: .accentColor.opacity(0.75))
                }
            }
        case .failed?:
            Circle().fill(Color.red).frame(width: 6, height: 6)
        case .idle?:
            Circle().fill(Color.secondary.opacity(0.7)).frame(width: 6, height: 6)
        case nil:
            Color.clear
        }
    }

    /// A crescent whose tail fades behind its head, as in pcode's spinner.
    private static func arc(
        _ gc: GraphicsContext, center: CGPoint, radius: CGFloat, width: CGFloat,
        head: Double, sweep: Double, color: Color
    ) {
        let steps = 12
        for step in 0..<steps {
            let from = head - sweep * Double(step + 1) / Double(steps)
            let to = head - sweep * Double(step) / Double(steps)
            var path = Path()
            path.addArc(center: center, radius: radius, startAngle: .radians(from), endAngle: .radians(to), clockwise: false)
            let fade = 1.0 - 0.85 * Double(step) / Double(steps)
            gc.stroke(path, with: .color(color.opacity(fade)), style: StrokeStyle(lineWidth: width, lineCap: step == 0 ? .round : .butt))
        }
    }
}

/// A session: pcode's terminal with everything pcode lays over it, and the bottom shell.
private struct PCodeSessionPaneView: View {
    @ObservedObject var pane: PCodeSessionPane
    @EnvironmentObject var ghostty: Ghostty.App
    /// The shell's height, set by dragging its top edge; shared by every session.
    @AppStorage("PCodeWorkspaceShellHeight") private var shellHeight: Double = 200
    @State private var dragStart: Double?
    private static let minShell: CGFloat = 80
    /// pcode's own pane keeps at least this much above the shell.
    private static let minSession: CGFloat = 200

    var body: some View {
        GeometryReader { geometry in
            let maxShell = max(Self.minShell, geometry.size.height - Self.minSession)
            VStack(spacing: 0) {
                Ghostty.InspectableSurface(surfaceView: pane.surface, isSplit: false)
                if pane.shellVisible, let shell = pane.shell {
                    handle(maxShell: maxShell)
                    Ghostty.SurfaceWrapper(surfaceView: shell, isSplit: false)
                        .id(ObjectIdentifier(shell))
                        .frame(height: min(maxShell, max(Self.minShell, shellHeight)))
                }
            }
        }
    }

    /// The shell's top edge: a hairline to see, a taller strip to drag.
    private func handle(maxShell: CGFloat) -> some View {
        Rectangle()
            .fill(ghostty.config.splitDividerColor)
            .frame(height: 1)
            .overlay(
                Color.clear
                    .frame(height: 9)
                    .contentShape(Rectangle())
                    .backport.pointerStyle(.resizeUpDown)
                    .onHover { inside in
                        if #available(macOS 15, *) { return }
                        if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(coordinateSpace: .global)
                            .onChanged { gesture in
                                let start = dragStart ?? shellHeight
                                dragStart = start
                                shellHeight = min(maxShell, max(Self.minShell, start - gesture.translation.height))
                            }
                            .onEnded { _ in dragStart = nil }
                    )
            )
            .zIndex(1)
    }
}

/// The one workspace window.
final class PCodeWorkspaceController: NSWindowController, NSWindowDelegate {
    private static var instance: PCodeWorkspaceController?
    let workspace: PCodeWorkspace

    /// The controller, if the window was ever made.
    static var existing: PCodeWorkspaceController? { instance }

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
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "pcode"
        // Opaque, in the terminal's own color, as Ghostty's windows are: the
        // window server then never blends anything under the terminal.
        window.titlebarAppearsTransparent = true
        window.isOpaque = true
        window.backgroundColor = NSColor(ghostty.config.backgroundColor).withAlphaComponent(1)
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
        workspace.window = window
        workspace.followAppearance()
        workspace.windowVisible = { [weak window] in
            window?.occlusionState.contains(.visible) ?? false
        }
        // A light/dark switch (`theme = light:…,dark:…`) reloads the config;
        // the titlebar and any gap must take the new background too.
        configSubscription = ghostty.$config
            .receive(on: DispatchQueue.main)
            .sink { [weak window] config in
                window?.backgroundColor = NSColor(config.backgroundColor).withAlphaComponent(1)
            }
    }

    private var configSubscription: AnyCancellable?

    func windowDidChangeOcclusionState(_ notification: Notification) {
        workspace.syncOcclusion()
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
