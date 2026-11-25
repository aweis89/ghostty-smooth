import AppKit

/// Synthetic keyboard and mouse input for the debug socket. Events are real
/// `NSEvent`s sent through the window, so hit-testing, the responder chain
/// and key equivalents run as they do for a person.
enum DebugInput {
    typealias Reply = DebugCommands.Reply
    typealias Failure = DebugCommands.Failure

    // MARK: Keys

    /// US ANSI virtual key codes.
    static let keyCodes: [Character: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19,
        "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28,
        "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38,
        "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47,
        " ": 49, "`": 50,
    ]

    /// Characters typed with Shift, and the key they are on.
    static let shifted: [Character: Character] = [
        "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8",
        "(": "9", ")": "0", "_": "-", "+": "=", "{": "[", "}": "]", "|": "\\", ":": ";",
        "\"": "'", "<": ",", ">": ".", "?": "/", "~": "`",
    ]

    static func function(_ key: Int) -> String {
        String(Character(UnicodeScalar(UInt32(key))!))
    }

    /// Keys by name: their key code and the characters they type.
    static let named: [String: (UInt16, String)] = {
        var keys: [String: (UInt16, String)] = [
            "enter": (36, "\r"), "return": (36, "\r"), "tab": (48, "\t"), "space": (49, " "),
            "esc": (53, "\u{1b}"), "escape": (53, "\u{1b}"), "backspace": (51, "\u{7f}"),
            "delete": (117, function(NSDeleteFunctionKey)),
            "up": (126, function(NSUpArrowFunctionKey)), "down": (125, function(NSDownArrowFunctionKey)),
            "left": (123, function(NSLeftArrowFunctionKey)), "right": (124, function(NSRightArrowFunctionKey)),
            "home": (115, function(NSHomeFunctionKey)), "end": (119, function(NSEndFunctionKey)),
            "pageup": (116, function(NSPageUpFunctionKey)), "pagedown": (121, function(NSPageDownFunctionKey)),
            "backslash": (42, "\\"), "plus": (24, "="), "minus": (27, "-"),
        ]
        let fkeys: [UInt16] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
        for (index, code) in fkeys.enumerated() {
            keys["f\(index + 1)"] = (code, function(NSF1FunctionKey + index))
        }
        return keys
    }()

    struct Stroke {
        let keyCode: UInt16
        let chars: String
        let mods: NSEvent.ModifierFlags
        /// A named key whose characters are fixed rather than read from the layout.
        let fixed: Bool
    }

    static func modifiers(_ names: [String]) throws -> NSEvent.ModifierFlags {
        var mods: NSEvent.ModifierFlags = []
        for name in names where !name.isEmpty {
            switch name.lowercased() {
            case "ctrl", "control": mods.insert(.control)
            case "shift": mods.insert(.shift)
            case "alt", "opt", "option": mods.insert(.option)
            case "cmd", "command", "super": mods.insert(.command)
            default: throw Failure("unknown modifier \(name)")
            }
        }
        return mods
    }

    /// A stroke from a spec like `ctrl+a`, `cmd+shift+]`, `enter`, `ctrl++`.
    static func stroke(_ spec: String) throws -> Stroke {
        var parts = spec.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        var key = parts.removeLast()
        if key.isEmpty {
            // The key is "+" itself: "ctrl++" splits as ["ctrl", "", ""].
            key = "+"
            if parts.last == "" { parts.removeLast() }
        }
        return try stroke(key: key, mods: modifiers(parts))
    }

    static func stroke(key: String, mods: NSEvent.ModifierFlags) throws -> Stroke {
        if key.count > 1, let (code, chars) = named[key.lowercased()] {
            return Stroke(keyCode: code, chars: chars, mods: mods, fixed: true)
        }
        guard key.count == 1, let char = key.first else { throw Failure("unknown key \(key)") }
        if char == "\n" || char == "\r" { return try stroke(key: "enter", mods: mods) }
        if char == "\t" { return try stroke(key: "tab", mods: mods) }
        var mods = mods
        var base = char
        if let unshifted = shifted[char] {
            base = unshifted
            mods.insert(.shift)
        } else if char.isLetter, char.isUppercase {
            base = Character(char.lowercased())
            mods.insert(.shift)
        }
        guard let code = keyCodes[base] else { throw Failure("no key code for \(key)") }
        return Stroke(keyCode: code, chars: String(base), mods: mods, fixed: false)
    }

    static func keyEvents(_ stroke: Stroke, window: NSWindow) -> [NSEvent] {
        func make(_ type: NSEvent.EventType, _ chars: String, _ ignoring: String) -> NSEvent? {
            NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: stroke.mods,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: chars, charactersIgnoringModifiers: ignoring,
                isARepeat: false, keyCode: stroke.keyCode)
        }
        var chars = stroke.chars
        var ignoring = stroke.chars
        if !stroke.fixed, let probe = make(.keyDown, stroke.chars, stroke.chars) {
            // What the key types with these modifiers, per the keyboard layout
            // (ctrl+a is "\u{1}"); AppKit's "ignoring modifiers" still applies Shift.
            chars = probe.characters(byApplyingModifiers: stroke.mods) ?? chars
            ignoring = probe.characters(byApplyingModifiers: stroke.mods.intersection(.shift)) ?? ignoring
        }
        return [make(.keyDown, chars, ignoring), make(.keyUp, chars, ignoring)].compactMap { $0 }
    }

    /// Sends a key event as `NSApplication` would: key equivalents first.
    /// The faithful path needs the window to be key in the active app; when it
    /// is not (the app is behind another), the window gets the event directly.
    static func deliverKey(_ event: NSEvent, to window: NSWindow) {
        if NSApp.isActive, window.isKeyWindow {
            NSApp.sendEvent(event)
            return
        }
        if event.type == .keyDown, !event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            if window.performKeyEquivalent(with: event) { return }
            if NSApp.mainMenu?.performKeyEquivalent(with: event) == true { return }
        }
        window.sendEvent(event)
    }

    /// Runs `steps` one after another, `gap` seconds apart, then `done`.
    static func play(_ steps: [() -> Void], gap: Double, done: @escaping () -> Void) {
        guard let first = steps.first else {
            DispatchQueue.main.asyncAfter(deadline: .now() + gap, execute: done)
            return
        }
        first()
        DispatchQueue.main.asyncAfter(deadline: .now() + gap) {
            play(Array(steps.dropFirst()), gap: gap, done: done)
        }
    }

    /// The window input goes to, focusing `surface` first if one is named.
    static func keyTarget(_ args: [String: Any]) throws -> NSWindow {
        if let id = args["surface"] as? String {
            let view = try DebugCommands.surface(id)
            guard let window = view.window else { throw Failure("surface is not in a window") }
            if window.firstResponder !== view { window.makeFirstResponder(view) }
            return window
        }
        return try DebugCommands.window(args)
    }

    static func keyReply(_ window: NSWindow) -> [String: Any] {
        var body: [String: Any] = ["window_key": window.isKeyWindow, "app_active": NSApp.isActive]
        if let view = window.firstResponder as? Ghostty.SurfaceView {
            body["first_responder"] = DebugCommands.shortID(view)
        } else if let responder = window.firstResponder {
            body["first_responder"] = String(describing: type(of: responder))
        }
        return body
    }

    /// `keys`: strokes like `["ctrl+a", "\\"]`, or one string of them split on spaces.
    static func keys(_ args: [String: Any], _ reply: @escaping Reply) throws {
        let specs: [String]
        if let list = args["keys"] as? [String] {
            specs = list
        } else if let text = args["keys"] as? String {
            specs = text.split(separator: " ").map(String.init)
        } else {
            throw Failure("key needs keys")
        }
        let window = try keyTarget(args)
        let strokes = try specs.map(stroke)
        let gap = (args["gap"] as? NSNumber)?.doubleValue ?? 0.05
        let steps = strokes.map { stroke in
            { keyEvents(stroke, window: window).forEach { deliverKey($0, to: window) } }
        }
        play(steps, gap: gap) { reply(keyReply(window)) }
    }

    /// `text`: typed one key at a time; characters with no key are inserted as text.
    static func type(_ args: [String: Any], _ reply: @escaping Reply) throws {
        guard let text = args["text"] as? String else { throw Failure("type needs text") }
        let window = try keyTarget(args)
        let gap = (args["gap"] as? NSNumber)?.doubleValue ?? 0.01
        let steps: [() -> Void] = text.map { char in
            if let stroke = try? stroke(key: String(char), mods: []) {
                return { keyEvents(stroke, window: window).forEach { deliverKey($0, to: window) } }
            }
            return {
                (window.firstResponder as? NSTextInputClient)?
                    .insertText(String(char), replacementRange: NSRange(location: NSNotFound, length: 0))
            }
        }
        play(steps, gap: gap) { reply(keyReply(window)) }
    }

    // MARK: Mouse

    private static var eventNumber = 0

    static func mouseEvent(
        _ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow,
        mods: NSEvent.ModifierFlags = [], clicks: Int = 1
    ) -> NSEvent? {
        eventNumber += 1
        let pressed: Set<NSEvent.EventType> = [.leftMouseDown, .leftMouseDragged, .rightMouseDown, .rightMouseDragged]
        return NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: mods,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: eventNumber, clickCount: clicks,
            pressure: pressed.contains(type) ? 1 : 0)
    }

    /// The view a point in `window` hits.
    static func hitView(_ point: NSPoint, in window: NSWindow) -> NSView? {
        guard let content = window.contentView else { return nil }
        let root = content.superview ?? content
        return root.hitTest(root.convert(point, from: nil))
    }

    /// Moves the pointer: AppKit sends `mouseMoved` through tracking areas,
    /// which a synthetic event can't reach, so the view under it gets it directly.
    static func hover(_ point: NSPoint, in window: NSWindow, mods: NSEvent.ModifierFlags) {
        guard let view = hitView(point, in: window),
              let event = mouseEvent(.mouseMoved, at: point, in: window, mods: mods) else { return }
        view.mouseMoved(with: event)
    }

    static func mods(_ args: [String: Any]) throws -> NSEvent.ModifierFlags {
        guard let spec = args["mods"] as? String, !spec.isEmpty else { return [] }
        return try modifiers(spec.split(separator: "+").map(String.init))
    }

    /// What ended up under the point: the terminal, and its selection.
    static func mouseReply(_ point: NSPoint, in window: NSWindow) -> [String: Any] {
        var body: [String: Any] = keyReply(window)
        var cursor = hitView(point, in: window)
        while let view = cursor, !(view is Ghostty.SurfaceView) { cursor = view.superview }
        if let surface = cursor as? Ghostty.SurfaceView {
            body["surface"] = DebugCommands.shortID(surface)
            body["selection"] = (try? DebugCommands.readText(surface, scope: "selection")) ?? ""
        } else {
            body["hit"] = hitView(point, in: window).map { String(describing: type(of: $0)) } ?? NSNull()
        }
        return body
    }

    static func click(_ args: [String: Any], _ reply: @escaping Reply) throws {
        let (window, x, y) = try DebugCommands.target(args)
        let point = try DebugCommands.windowPoint(x, y, in: window)
        let mods = try self.mods(args)
        let right = args["button"] as? String == "right"
        let count = max(1, min(3, args["count"] as? Int ?? 1))
        let (down, up): (NSEvent.EventType, NSEvent.EventType) =
            right ? (.rightMouseDown, .rightMouseUp) : (.leftMouseDown, .leftMouseUp)
        var steps: [() -> Void] = [{ hover(point, in: window, mods: mods) }]
        for clicks in 1...count {
            steps.append {
                for type in [down, up] {
                    mouseEvent(type, at: point, in: window, mods: mods, clicks: clicks).map(window.sendEvent)
                }
            }
        }
        play(steps, gap: 0.03) { reply(mouseReply(point, in: window)) }
    }

    /// `from`/`to` as points (or `from_cell`/`to_cell` of `surface`).
    static func drag(_ args: [String: Any], _ reply: @escaping Reply) throws {
        let (window, x1, y1) = try DebugCommands.target(args, key: "from")
        let (_, x2, y2) = try DebugCommands.target(args, key: "to")
        let start = try DebugCommands.windowPoint(x1, y1, in: window)
        let end = try DebugCommands.windowPoint(x2, y2, in: window)
        let mods = try self.mods(args)
        let count = max(1, args["steps"] as? Int ?? 12)
        var steps: [() -> Void] = [
            { hover(start, in: window, mods: mods) },
            { mouseEvent(.leftMouseDown, at: start, in: window, mods: mods).map(window.sendEvent) },
        ]
        for step in 1...count {
            let t = CGFloat(step) / CGFloat(count)
            let point = NSPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
            steps.append { mouseEvent(.leftMouseDragged, at: point, in: window, mods: mods).map(window.sendEvent) }
        }
        steps.append { mouseEvent(.leftMouseUp, at: end, in: window, mods: mods).map(window.sendEvent) }
        play(steps, gap: (args["gap"] as? NSNumber)?.doubleValue ?? 0.016) {
            reply(mouseReply(start, in: window))
        }
    }

    static func move(_ args: [String: Any], _ reply: Reply) throws {
        let (window, x, y) = try DebugCommands.target(args)
        let point = try DebugCommands.windowPoint(x, y, in: window)
        hover(point, in: window, mods: try mods(args))
        reply(mouseReply(point, in: window))
    }

    /// `dy` lines; positive scrolls back (up), as a wheel turned away does.
    static func scroll(_ args: [String: Any], _ reply: Reply) throws {
        let (window, x, y) = try DebugCommands.target(args)
        let point = try DebugCommands.windowPoint(x, y, in: window)
        let lines = Int32((args["dy"] as? NSNumber)?.intValue ?? 3)
        guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
                               wheel1: lines, wheel2: 0, wheel3: 0) else { throw Failure("no scroll event") }
        let screen = window.convertPoint(toScreen: point)
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        cg.location = CGPoint(x: screen.x, y: primaryHeight - screen.y)
        guard let event = NSEvent(cgEvent: cg), let view = hitView(point, in: window) else {
            throw Failure("nothing to scroll at \(x), \(y)")
        }
        hover(point, in: window, mods: [])
        view.scrollWheel(with: event)
        reply(mouseReply(point, in: window))
    }
}
