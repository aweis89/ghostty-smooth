import AppKit
import SwiftUI

/// A pick list pcode asked us to draw natively (`pcode;pick;<token>;<layout>`).
///
/// No terminal and no bridge: we connect to pcode's popup socket for the
/// token ourselves and speak newline-delimited JSON (`pcode.popup_surface`):
///
/// - we send `pcode-pick 1\n`;
/// - pcode sends a list, one JSON object per line (`pcode.pick_ui.payload`);
/// - we send `{"shown": true}` once it is on screen, or `{"error": …}` and
///   hang up if we cannot read it (pcode then shows it itself);
/// - we send the pick, `{"id": …, "action": …, "query": …}`, and wait;
/// - pcode sends another list to show in its place, or closes the socket,
///   which closes the picker. Us closing it is pcode's cancel.
///
/// The callbacks stay in pcode: we only filter, select and answer. The picker
/// is shown, and takes the keyboard, only once the first list has arrived.
/// Everything here runs on the main queue but the socket's own thread (not
/// `@MainActor`: `PCodePopup`, which drives it, is not isolated either).
final class PCodePicker: ObservableObject {
    struct Item: Decodable {
        let id: String
        let label: String
        let detail: String
        let marker: String
        let depth: Int
        let search: [String]
        let confirm: String
    }

    struct Action: Decodable {
        let key: String
        let label: String
        let needsItem: Bool
        let confirm: String
        let delete: Bool

        enum CodingKeys: String, CodingKey {
            case key, label, confirm, delete
            case needsItem = "needs_item"
        }
    }

    struct Payload: Decodable {
        let title: String
        let header: String
        let empty: String
        let selected: String?
        let query: String
        let match: String
        let custom: String?
        let items: [Item]
        let actions: [Action]
        /// Ctrl chords that cancel, as prompt_toolkit names them (`c-l`).
        let cancelKeys: [String]?

        enum CodingKeys: String, CodingKey {
            case title, header, empty, selected, query, match, custom, items, actions
            case cancelKeys = "cancel_keys"
        }
    }

    /// A row on show: an item, its tree guide, or the query as a custom row.
    struct Row {
        let id: String
        let label: String
        let detail: String
        let marker: String
        let guide: String
        let confirm: String
    }

    static let hello = Data("pcode-pick 1\n".utf8)
    static let customMarker = "custom"
    /// The longest list line we read.
    static let lineLimit = 16 << 20
    /// Lists this long refilter once typing pauses (`filterDelay`), not on every key.
    static let instantFilterLimit = 500
    static let filterDelay: TimeInterval = 0.06

    @Published private(set) var payload: Payload?
    @Published var query = "" {
        didSet { if query != oldValue { queryChanged() } }
    }
    @Published private(set) var rows: [Row] = []
    @Published private(set) var selected = 0
    @Published private(set) var status = ""
    /// A pick was sent; keys wait for pcode's next list or its close.
    @Published private(set) var busy = false

    /// The list's title, for the popup's header; called on each list.
    var onList: ((String) -> Void)?
    /// pcode closed the socket or it failed: the popup closes.
    var onClosed: (() -> Void)?

    weak var field: PCodePickField?
    private var guides: [String] = []
    private var custom: NSRegularExpression?
    private var armed: (key: String, id: String)?
    private var connection: Connection?
    private var keyMonitor: Any?
    private var pendingFilter: DispatchWorkItem?

    // MARK: The connection

    /// Connect to `token`'s socket and wait for pcode's list.
    func start(token: String) {
        let connection = Connection()
        self.connection = connection
        connection.start(
            path: PCode.statePath("popups/\(token).sock"),
            onLine: { [weak self] line in self?.receive(line) },
            onClosed: { [weak self] in self?.connectionClosed() })
    }

    /// Close the connection and stop taking keys; pcode takes it as a cancel.
    func stop() {
        connection?.close()
        connection = nil
        pendingFilter?.cancel()
        pendingFilter = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    private func connectionClosed() {
        guard connection != nil else { return }
        stop()
        onClosed?()
    }

    private func receive(_ line: Data) {
        guard let connection else { return }
        let list: Payload
        do {
            list = try JSONDecoder().decode(Payload.self, from: line)
        } catch {
            // Not a list we can show (a newer or older pcode): say so, so pcode
            // shows it itself, and close.
            connection.send(Self.line(["error": String(String(describing: error).prefix(300))]), thenClose: true)
            self.connection = nil
            stop()
            onClosed?()
            return
        }
        let first = payload == nil
        payload = list
        guides = PCodePickMatch.treeGuides(list.items.map(\.depth))
        custom = list.custom.flatMap(PCodePickMatch.anchored)
        armed = nil
        status = ""
        busy = false
        // A new list: no row carries over, so pcode's selection or the first.
        rows = []
        if query != list.query { query = list.query }
        // Filtered now, whatever the query's change left waiting.
        pendingFilter?.cancel()
        pendingFilter = nil
        refilter()
        select(list.selected.flatMap { wanted in rows.firstIndex { $0.id == wanted } } ?? 0)
        onList?(list.title)
        if first { watchKeys() }
        connection.send(Self.line(["shown": true]))
    }

    /// `object` as one line of JSON, if it can be.
    private static func line(_ object: [String: Any]) -> Data? {
        guard var data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        data.append(0x0A)
        return data
    }

    private func send(id: String?, action: String?) {
        guard let connection, !busy,
              let data = Self.line(["id": id ?? NSNull(), "action": action ?? NSNull(), "query": query])
        else { return }
        busy = true
        connection.send(data)
    }

    // MARK: Filtering and selection

    private func queryChanged() {
        pendingFilter?.cancel()
        pendingFilter = nil
        guard let payload, payload.items.count >= Self.instantFilterLimit else {
            refilter()
            return
        }
        let work = DispatchWorkItem { [weak self] in
            self?.flushFilter()
        }
        pendingFilter = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.filterDelay, execute: work)
    }

    /// Filter now if typing left a filter waiting: before acting on the rows.
    private func flushFilter() {
        guard pendingFilter != nil else { return }
        pendingFilter?.cancel()
        pendingFilter = nil
        refilter()
    }

    private func refilter() {
        guard let payload else { rows = []; return }
        let previous = rows.indices.contains(selected) ? rows[selected].id : nil
        let terms = PCodePickMatch.terms(query)
        let fuzzy = payload.match != "substring"
        // Guides only while the query is empty: matches list flat.
        let nested = terms.isEmpty
        var shown: [Row] = []
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if let custom, !trimmed.isEmpty, PCodePickMatch.fullMatch(custom, trimmed),
           !payload.items.contains(where: { $0.id == trimmed }) {
            shown.append(Row(id: trimmed, label: trimmed, detail: "", marker: Self.customMarker, guide: "", confirm: ""))
        }
        for (index, item) in payload.items.enumerated()
        where terms.isEmpty || PCodePickMatch.matches(item.search, terms: terms, fuzzy: fuzzy) {
            shown.append(Row(
                id: item.id, label: item.label, detail: item.detail, marker: item.marker,
                guide: nested ? guides[index] : "", confirm: item.confirm))
        }
        rows = shown
        select(shown.firstIndex(where: { $0.id == previous }) ?? 0)
    }

    func select(_ index: Int) {
        selected = max(0, min(rows.count - 1, index))
        // An armed action stays armed only on its own row.
        if let armed, current?.id != armed.id {
            self.armed = nil
            status = ""
        }
    }

    func move(_ offset: Int) {
        guard !busy else { return }
        flushFilter()
        select(selected + offset)
    }

    var current: Row? { rows.indices.contains(selected) ? rows[selected] : nil }

    // MARK: Keys

    func accept() {
        guard !busy else { return }
        flushFilter()
        guard let current else { return }
        send(id: current.id, action: nil)
    }

    /// Escape: clear the search, else cancel. Waiting on pcode, it cancels.
    func escape() {
        if busy || query.isEmpty { cancel() } else { query = "" }
    }

    /// Cancel: close the connection, then the popup.
    func cancel() {
        guard connection != nil else { return }
        stop()
        onClosed?()
    }

    /// Run `action`: once armed if it asks first, then picks.
    func run(_ action: Action, label: String) {
        guard !busy else { return }
        flushFilter()
        let row = current
        if action.needsItem && row == nil { return }
        if !action.confirm.isEmpty, let row, armed?.key != action.key || armed?.id != row.id {
            armed = (action.key, row.id)
            status = "Press \(label) again to \(row.confirm.isEmpty ? action.confirm : row.confirm)"
            return
        }
        send(id: row?.id, action: action.key)
    }

    /// The action Cmd+`key` runs, if any.
    func action(forKey key: String) -> Action? {
        payload?.actions.first { $0.key == key && PCode.valid($0.key, length: 1...1) }
    }

    /// The action Delete runs while the search is empty, if any.
    var deleteAction: Action? {
        query.isEmpty ? payload?.actions.first(where: \.delete) : nil
    }

    /// The empty list's text, with `{action:K}` as the key that runs action K.
    var emptyText: String {
        let text = payload?.empty ?? ""
        guard let pattern = try? NSRegularExpression(pattern: "\\{action:([a-z])\\}") else { return text }
        var result = text
        for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let whole = Range(match.range, in: text), let key = Range(match.range(at: 1), in: text)
            else { continue }
            let offset = text.distance(from: text.startIndex, to: whole.lowerBound)
            let start = result.index(result.startIndex, offsetBy: offset)
            let end = result.index(start, offsetBy: text.distance(from: whole.lowerBound, to: whole.upperBound))
            result.replaceSubrange(start..<end, with: Self.keyLabel(String(text[key])))
        }
        return result
    }

    static func keyLabel(_ key: String) -> String { "⌘" + key.uppercased() }

    /// Keys the search field would otherwise take, while it has the keyboard:
    /// Cmd+key actions; Cmd+W, which closes the picker rather than pcode's
    /// terminal under it; Ctrl+U/Ctrl+D half pages; and pcode's cancel chords.
    private func watchKeys() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKey(event) ?? event
        }
    }

    private func handleKey(_ event: NSEvent) -> NSEvent? {
        guard let field, field.hasKeyboard, event.window === field.window,
              let key = event.charactersIgnoringModifiers?.lowercased() else { return event }
        // Not `.deviceIndependentFlagsMask`, which has Caps Lock and the function key.
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if modifiers == .control {
            switch key {
            case "u":
                move(-PCodePickerView.pageRows / 2)
                return nil
            case "d":
                move(PCodePickerView.pageRows / 2)
                return nil
            default:
                if payload?.cancelKeys?.contains("c-\(key)") == true {
                    cancel()
                    return nil
                }
                return event
            }
        }
        guard modifiers.subtracting(.shift) == .command else { return event }
        if key == "w" {
            cancel()
            return nil
        }
        if let action = action(forKey: key) {
            run(action, label: Self.keyLabel(key))
            return nil
        }
        return event
    }

    /// Give the search field the keyboard.
    func focus() {
        guard let field, let window = field.window else { return }
        window.makeFirstResponder(field)
    }
}

// MARK: - The socket

extension PCodePicker {
    /// pcode's popup socket, read on a thread of its own; every callback is on the main queue.
    final class Connection {
        private let lock = NSLock()
        private var fd: Int32 = -1
        private var closed = false
        private let writes = DispatchQueue(label: "pcode.pick.write")

        func start(
            path: String,
            onLine: @escaping (Data) -> Void,
            onClosed: @escaping () -> Void
        ) {
            Thread.detachNewThread { [self] in
                if connect(path) {
                    readLines(onLine)
                }
                lock.lock()
                if fd >= 0 { Darwin.close(fd) }
                fd = -1
                closed = true
                lock.unlock()
                DispatchQueue.main.async(execute: onClosed)
            }
        }

        /// Hang up: a blocked reader or writer wakes, the reader closes the
        /// socket and reports it closed.
        func close() {
            lock.lock()
            closed = true
            if fd >= 0 { shutdown(fd, SHUT_RDWR) }
            lock.unlock()
        }

        /// Write `data`, off the main queue; then hang up if `thenClose`.
        func send(_ data: Data?, thenClose: Bool = false) {
            writes.async { [self] in
                // A copy of the socket, taken under the lock and written outside
                // it: `close()` never waits on a write, and its shutdown wakes one
                // that blocks. The reader closing its fd leaves this one valid.
                lock.lock()
                let copy = fd >= 0 && !closed ? dup(fd) : -1
                lock.unlock()
                if copy >= 0 {
                    if let data { Self.writeAll(copy, data) }
                    Darwin.close(copy)
                }
                if thenClose { close() }
            }
        }

        /// Connect to `path` and say hello, if it is this user's socket in this
        /// user's own directory, and this user is listening on it.
        private func connect(_ path: String) -> Bool {
            var directory = stat()
            var info = stat()
            let parent = (path as NSString).deletingLastPathComponent
            guard lstat(parent, &directory) == 0, directory.st_mode & S_IFMT == S_IFDIR,
                  directory.st_uid == getuid(), directory.st_mode & 0o077 == 0,
                  lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == getuid()
            else { return false }
            let socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
            guard socketFD >= 0 else { return false }
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(path.utf8)
            let capacity = MemoryLayout.size(ofValue: address.sun_path)
            guard bytes.count < capacity else {
                Darwin.close(socketFD)
                return false
            }
            withUnsafeMutableBytes(of: &address.sun_path) { buffer in
                buffer.copyBytes(from: bytes)
                buffer[bytes.count] = 0
            }
            var noSigPipe: Int32 = 1
            setsockopt(socketFD, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            let connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(socketFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            var peerUID = uid_t.max
            var peerGID = gid_t.max
            let samePeer = connected == 0 && getpeereid(socketFD, &peerUID, &peerGID) == 0 && peerUID == getuid()
            lock.lock()
            defer { lock.unlock() }
            guard samePeer, !closed else {
                Darwin.close(socketFD)
                return false
            }
            fd = socketFD
            return Self.writeAll(socketFD, PCodePicker.hello)
        }

        private func readLines(_ onLine: @escaping (Data) -> Void) {
            lock.lock()
            let socketFD = fd
            lock.unlock()
            var pending = Data()
            var chunk = [UInt8](repeating: 0, count: 65536)
            while true {
                let count = chunk.withUnsafeMutableBytes { read(socketFD, $0.baseAddress, $0.count) }
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { return }
                // Only the new bytes can hold the next newline.
                var searchFrom = pending.count
                pending.append(contentsOf: chunk[0..<count])
                var lineStart = 0
                while let newline = pending[(pending.startIndex + searchFrom)...].firstIndex(of: 0x0A) {
                    let line = Data(pending[(pending.startIndex + lineStart)..<newline])
                    DispatchQueue.main.async { onLine(line) }
                    lineStart = newline + 1 - pending.startIndex
                    searchFrom = lineStart
                }
                if lineStart > 0 { pending = Data(pending[(pending.startIndex + lineStart)...]) }
                if pending.count > PCodePicker.lineLimit { return }
            }
        }

        @discardableResult
        private static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
            data.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let written = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                    if written < 0 && errno == EINTR { continue }
                    guard written > 0 else { return false }
                    offset += written
                }
                return true
            }
        }
    }
}

// MARK: - The search field

/// The picker's search line: an AppKit text field, so the list's keys reach
/// us before the field editor acts on them (SwiftUI's key handling needs macOS 14).
final class PCodePickField: NSTextField, NSTextFieldDelegate {
    weak var picker: PCodePicker?

    /// True while this field's editor has its window's keyboard.
    var hasKeyboard: Bool {
        guard let editor = window?.firstResponder as? NSTextView else { return false }
        return (editor.delegate as AnyObject?) === self
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Mounted once the first list arrived: take the keyboard then.
        if window != nil { DispatchQueue.main.async { [weak self] in self?.picker?.focus() } }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard let picker else { return false }
        switch selector {
        // Ctrl+P and Ctrl+N are moveUp: and moveDown: in AppKit's key bindings.
        case #selector(NSResponder.moveUp(_:)):
            picker.move(-1)
        case #selector(NSResponder.moveDown(_:)):
            picker.move(1)
        case #selector(NSResponder.pageUp(_:)), #selector(NSResponder.scrollPageUp(_:)):
            picker.move(-PCodePickerView.pageRows)
        case #selector(NSResponder.pageDown(_:)), #selector(NSResponder.scrollPageDown(_:)):
            picker.move(PCodePickerView.pageRows)
        case #selector(NSResponder.insertNewline(_:)):
            picker.accept()
        case #selector(NSResponder.cancelOperation(_:)):
            picker.escape()
        case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)):
            break  // The search line keeps the keyboard: there is nothing else to focus.
        case #selector(NSResponder.deleteForward(_:)):
            // Only the forward-delete key: AppKit sends Ctrl+D here too.
            guard NSApp.currentEvent?.keyCode == 0x75, let action = picker.deleteAction else { return false }
            picker.run(action, label: "Delete")
        default:
            return false
        }
        return true
    }

    func controlTextDidChange(_ notification: Notification) {
        if picker?.query != stringValue { picker?.query = stringValue }
    }
}

struct PCodePickFieldView: NSViewRepresentable {
    @ObservedObject var picker: PCodePicker

    func makeNSView(context: Context) -> PCodePickField {
        let field = PCodePickField()
        field.picker = picker
        field.delegate = field
        field.placeholderString = "Search"
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 15)
        field.cell?.usesSingleLineMode = true
        field.cell?.lineBreakMode = .byTruncatingTail
        picker.field = field
        return field
    }

    func updateNSView(_ field: PCodePickField, context: Context) {
        // pcode's next list may bring a query of its own.
        if field.stringValue != picker.query { field.stringValue = picker.query }
    }
}

// MARK: - The view

/// The picker in the popup's panel: a search line over the rows, a status
/// line for an action that asks first, and the keys it answers.
struct PCodePickerView: View {
    @ObservedObject var picker: PCodePicker

    /// Rows PgUp/PgDn move by.
    static let pageRows = 10

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let header = picker.payload?.header, !header.isEmpty {
                Text(header)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                PCodePickFieldView(picker: picker)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
            .padding(.horizontal, 8)
            list
            if !picker.status.isEmpty {
                Text(picker.status)
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
            }
            footer
        }
        .padding(.vertical, 8)
        .opacity(picker.busy ? 0.6 : 1)
    }

    @ViewBuilder
    private var list: some View {
        if picker.rows.isEmpty {
            Text(picker.emptyText)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(picker.rows.enumerated()), id: \.offset) { index, row in
                            rowView(row, chosen: index == picker.selected)
                                .id(index)
                                .contentShape(Rectangle())
                                .onTapGesture(count: 2) {
                                    picker.select(index)
                                    picker.accept()
                                }
                                .onTapGesture { picker.select(index) }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                }
                .onChange(of: picker.selected) { index in proxy.scrollTo(index) }
            }
        }
    }

    private func rowView(_ row: PCodePicker.Row, chosen: Bool) -> some View {
        HStack(spacing: 8) {
            if !row.guide.isEmpty {
                Text(row.guide)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            Text(row.label)
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
            if !row.detail.isEmpty {
                Text(row.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if !row.marker.isEmpty {
                Text(row.marker)
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.primary.opacity(0.1)))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(chosen ? Color.accentColor.opacity(0.35) : Color.clear))
    }

    private var footer: some View {
        HStack(spacing: 14) {
            hint("↩", "Choose")
            ForEach(picker.payload?.actions ?? [], id: \.key) { action in
                hint(PCodePicker.keyLabel(action.key), action.label)
                if action.delete {
                    hint("⌦", action.label)
                }
            }
            hint("esc", "Cancel")
            Spacer()
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 4)
                .background(RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.08)))
            Text(label)
        }
    }
}
