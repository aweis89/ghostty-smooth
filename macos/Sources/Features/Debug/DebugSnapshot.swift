import AppKit
import CoreImage
import UniformTypeIdentifiers

/// Window snapshots and frame recordings for the debug socket, made inside the
/// app so they need no Screen Recording permission.
///
/// `CALayer.render(in:)` draws a window's whole layer tree (SwiftUI chrome,
/// clips, corner radii) but not IOSurface contents, which is how terminals
/// draw. For the render, each such layer's contents are swapped for an image
/// of its IOSurface and then put back, inside one transaction so the screen
/// never sees the swap. Effects the window server adds (blurs, vibrancy, the
/// window's own shadow) are not in the picture.
enum DebugSnapshot {
    typealias Reply = DebugCommands.Reply
    typealias Failure = DebugCommands.Failure

    static let ciContext = CIContext(options: [.cacheIntermediates: false])
    static let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
    /// How many terminal frames the last render drew, for the reply.
    static var lastSwapped = 0

    static func isIOSurface(_ contents: Any?) -> Bool {
        guard let contents else { return false }
        return CFGetTypeID(contents as CFTypeRef) == IOSurfaceGetTypeID()
    }

    static func image(of contents: Any) -> CGImage? {
        let surface = unsafeBitCast(contents as AnyObject, to: IOSurfaceRef.self)
        let image = CIImage(ioSurface: surface)
        return ciContext.createCGImage(image, from: image.extent)
    }

    /// The window's content at `scale` pixels per point, cropped to `crop`
    /// (top-left points) if given.
    static func render(_ window: NSWindow, scale: CGFloat, crop: CGRect?) throws -> CGImage {
        guard let content = window.contentView, let root = content.layer else {
            throw Failure("window content is not layer-backed")
        }
        let bounds = content.bounds
        let width = Int((bounds.width * scale).rounded()), height = Int((bounds.height * scale).rounded())
        guard width > 0, height > 0, let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { throw Failure("could not make a \(width)x\(height) bitmap") }
        ctx.setFillColor(window.backgroundColor.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.scaleBy(x: scale, y: scale)
        if root.isGeometryFlipped {
            ctx.translateBy(x: 0, y: bounds.height)
            ctx.scaleBy(x: 1, y: -1)
        }

        var swapped: [(CALayer, Any)] = []
        func swap(_ layer: CALayer) {
            if let contents = layer.contents, isIOSurface(contents), let image = image(of: contents) {
                swapped.append((layer, contents))
                layer.contents = image
            }
            layer.sublayers?.forEach(swap)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        swap(root)
        root.render(in: ctx)
        for (layer, contents) in swapped { layer.contents = contents }
        CATransaction.commit()
        lastSwapped = swapped.count

        guard let image = ctx.makeImage() else { throw Failure("render made no image") }
        guard let crop else { return image }
        let pixels = CGRect(x: crop.minX * scale, y: crop.minY * scale,
                            width: crop.width * scale, height: crop.height * scale).integral
        guard let cropped = image.cropping(to: pixels) else { throw Failure("crop is outside the window") }
        return cropped
    }

    static func writePNG(_ image: CGImage, to path: String) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw Failure("cannot write \(path)")
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw Failure("cannot write \(path)") }
    }

    /// The crop `args` ask for: `rect` ([x, y, w, h] points), or a surface's
    /// on-screen part (`surface` with `crop: true`).
    static func crop(_ args: [String: Any]) throws -> CGRect? {
        if let rect = args["rect"] as? [NSNumber], rect.count == 4 {
            let v = rect.map { CGFloat($0.doubleValue) }
            return CGRect(x: v[0], y: v[1], width: v[2], height: v[3])
        }
        guard args["crop"] as? Bool == true else { return nil }
        let view = try DebugCommands.surface(args["surface"] as? String)
        return DebugCommands.topLeftRect(view.visibleRect, of: view)
    }

    static func scale(_ args: [String: Any], _ window: NSWindow, default fallback: CGFloat) -> CGFloat {
        if args["retina"] as? Bool == true { return window.backingScaleFactor }
        return CGFloat((args["scale"] as? NSNumber)?.doubleValue ?? Double(fallback))
    }

    static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter.string(from: Date())
    }

    static func snap(_ args: [String: Any]) throws -> [String: Any] {
        let path = args["path"] as? String ?? "/tmp/ghostty-snap-\(timestamp()).png"
        if args["raw"] as? Bool == true {
            // A terminal's own last frame, its whole grid, before any clipping.
            let view = try DebugCommands.surface(args["surface"] as? String)
            guard let contents = view.layer?.contents, isIOSurface(contents), let image = image(of: contents) else {
                throw Failure("surface has no frame")
            }
            try writePNG(image, to: path)
            return ["path": path, "size": [image.width, image.height]]
        }
        let window = try DebugCommands.window(args)
        // One pixel per point by default: sharp enough to read, cheap to look at.
        let image = try render(window, scale: scale(args, window, default: 1), crop: crop(args))
        try writePNG(image, to: path)
        return ["path": path, "size": [image.width, image.height], "terminals": lastSwapped]
    }

    // MARK: Recording

    static func record(_ args: [String: Any], _ reply: @escaping Reply) throws {
        let window = try DebugCommands.window(args)
        let recording = Recording(
            window: window,
            dir: args["dir"] as? String ?? "/tmp/ghostty-record-\(timestamp())",
            seconds: (args["seconds"] as? NSNumber)?.doubleValue ?? 2,
            fps: (args["fps"] as? NSNumber)?.doubleValue ?? 30,
            scale: scale(args, window, default: 0.5),
            crop: try crop(args),
            reply: reply)
        try recording.start()
    }

    /// Captures a frame whenever a terminal presents one (its layer's contents
    /// change) and on a timer for everything else (SwiftUI animations), then
    /// scores how much each frame differs from the last, and flags frames that
    /// differ from both neighbours while the neighbours match: one-frame flashes.
    final class Recording {
        let window: NSWindow
        let dir: String
        let seconds: Double
        let fps: Double
        let scale: CGFloat
        let crop: CGRect?
        let reply: Reply

        private var observers: [NSKeyValueObservation] = []
        private var timer: Timer?
        private var scheduled = false
        private var started = Date()
        private var frames: [(t: Double, sample: [UInt8], trigger: String)] = []
        private var failures = 0
        private let writer = DispatchQueue(label: "ghostty.debug-record", qos: .utility)
        private static var retained: [ObjectIdentifier: Recording] = [:]

        static let maxFrames = 900

        init(window: NSWindow, dir: String, seconds: Double, fps: Double, scale: CGFloat,
             crop: CGRect?, reply: @escaping Reply) {
            self.window = window
            self.dir = dir
            self.seconds = min(max(seconds, 0.1), 30)
            self.fps = min(max(fps, 1), 120)
            self.scale = scale
            self.crop = crop
            self.reply = reply
        }

        func start() throws {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            Self.retained[ObjectIdentifier(self)] = self
            started = Date()
            var layers: [CALayer] = DebugCommands.surfaces(in: window).compactMap(\.layer)
            func collect(_ layer: CALayer) {
                if DebugSnapshot.isIOSurface(layer.contents), !layers.contains(where: { $0 === layer }) {
                    layers.append(layer)
                }
                layer.sublayers?.forEach(collect)
            }
            if let root = window.contentView?.layer { collect(root) }
            observers = layers.map { layer in
                layer.observe(\.contents) { [weak self] _, _ in
                    DispatchQueue.main.async { self?.schedule("present") }
                }
            }
            timer = Timer.scheduledTimer(withTimeInterval: 1 / fps, repeats: true) { [weak self] _ in
                self?.schedule("timer")
            }
            capture("start")
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in self?.finish() }
        }

        /// Captures at most once per run-loop pass however many layers changed.
        private func schedule(_ trigger: String) {
            guard timer != nil, !scheduled else { return }
            scheduled = true
            DispatchQueue.main.async { [weak self] in
                self?.scheduled = false
                self?.capture(trigger)
            }
        }

        private func capture(_ trigger: String) {
            guard timer != nil, frames.count < Self.maxFrames else { return }
            guard let image = try? DebugSnapshot.render(window, scale: scale, crop: crop) else {
                failures += 1
                return
            }
            let index = frames.count
            frames.append((Date().timeIntervalSince(started), Self.sample(image), trigger))
            let path = (dir as NSString).appendingPathComponent(String(format: "%04d.png", index))
            writer.async { try? DebugSnapshot.writePNG(image, to: path) }
        }

        private func finish() {
            timer?.invalidate()
            timer = nil
            observers.forEach { $0.invalidate() }
            observers = []

            let diffs = frames.indices.map { $0 == 0 ? 0 : Self.difference(frames[$0 - 1].sample, frames[$0].sample) }
            var flashes: [[String: Any]] = []
            if frames.count >= 3 {
                for i in 1..<(frames.count - 1) {
                    let inbound = diffs[i], outbound = diffs[i + 1]
                    let across = Self.difference(frames[i - 1].sample, frames[i + 1].sample)
                    let score = min(inbound, outbound) - across
                    if min(inbound, outbound) > 0.02, across < 0.5 * min(inbound, outbound) {
                        flashes.append(["frame": i, "score": score, "t": frames[i].t])
                    }
                }
            }
            flashes.sort { ($0["score"] as? Double ?? 0) > ($1["score"] as? Double ?? 0) }
            let index: [[String: Any]] = frames.indices.map { i in
                ["frame": i, "t": (frames[i].t * 1000).rounded() / 1000,
                 "diff": (diffs[i] * 10000).rounded() / 10000, "trigger": frames[i].trigger]
            }
            let result: [String: Any] = [
                "dir": dir, "frames": frames.count, "seconds": seconds, "failures": failures,
                "flashes": Array(flashes.prefix(20)),
                "biggest_changes": index.sorted { ($0["diff"] as? Double ?? 0) > ($1["diff"] as? Double ?? 0) }
                    .prefix(10).map { $0["frame"] ?? 0 },
            ]
            let dir = self.dir, reply = self.reply
            writer.async {
                var file = result
                file["index"] = index
                if let data = try? JSONSerialization.data(withJSONObject: file, options: [.prettyPrinted, .sortedKeys]) {
                    try? data.write(to: URL(fileURLWithPath: (dir as NSString).appendingPathComponent("index.json")))
                }
                DispatchQueue.main.async {
                    reply(result)
                    Self.retained[ObjectIdentifier(self)] = nil
                }
            }
        }

        static let sampleWidth = 128, sampleHeight = 80, block = 8

        /// The frame shrunk to a small RGBA grid, for comparing frames.
        static func sample(_ image: CGImage) -> [UInt8] {
            var pixels = [UInt8](repeating: 0, count: sampleWidth * sampleHeight * 4)
            pixels.withUnsafeMutableBytes { raw in
                guard let ctx = CGContext(
                    data: raw.baseAddress, width: sampleWidth, height: sampleHeight, bitsPerComponent: 8,
                    bytesPerRow: sampleWidth * 4, space: DebugSnapshot.srgb,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
                ctx.interpolationQuality = .medium
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: sampleWidth, height: sampleHeight))
            }
            return pixels
        }

        /// How much the most changed 8x8 block of two samples differs, 0...1:
        /// a small flash scores high even when the rest of the frame is still.
        static func difference(_ a: [UInt8], _ b: [UInt8]) -> Double {
            guard a.count == b.count, !a.isEmpty else { return 1 }
            var worst = 0
            for by in stride(from: 0, to: sampleHeight, by: block) {
                for bx in stride(from: 0, to: sampleWidth, by: block) {
                    var total = 0
                    for y in by..<(by + block) {
                        let row = (y * sampleWidth + bx) * 4
                        for i in row..<(row + block * 4) where i % 4 != 3 {
                            total += abs(Int(a[i]) - Int(b[i]))
                        }
                    }
                    worst = max(worst, total)
                }
            }
            return Double(worst) / Double(block * block * 3 * 255)
        }
    }
}
