import Darwin
import Foundation

/// A read-only observer connection to one pcode session host's Unix socket.
///
/// Reads newline-delimited JSON on a thread of its own and hands each line to
/// `onLine` on the main queue, in order; `onClose` follows once it ends. Lines
/// can be large (a long answer, rendered), so the buffer grows as needed.
final class PCodeHostConnection: @unchecked Sendable {
    /// The `observe` hello pcode's host answers with the page and every side question.
    static let hello = Data(#"{"type": "observe", "version": 1}"#.utf8 + [UInt8(ascii: "\n")])

    let path: String
    var onLine: ((Data) -> Void)?
    var onClose: (() -> Void)?

    private let lock = NSLock()
    private var descriptor: Int32 = -1
    private var stopped = false

    init(path: String) {
        self.path = path
    }

    func start() {
        let thread = Thread { [self] in run() }
        thread.name = "pcode drawer socket"
        thread.start()
    }

    /// Ends the connection; the reading thread closes the descriptor.
    func stop() {
        // Under the lock: the reader closes the descriptor only while holding
        // it, so the number cannot have been reused by something else.
        lock.lock()
        stopped = true
        if descriptor >= 0 { shutdown(descriptor, SHUT_RDWR) }
        lock.unlock()
    }

    private func run() {
        defer { DispatchQueue.main.async { [self] in onClose?() } }
        guard let fd = Self.connect(path) else {
            Ghostty.logger.warning("pcode drawer: cannot reach a session host at \(self.path, privacy: .public)")
            return
        }
        lock.lock()
        if stopped {
            lock.unlock()
            close(fd)
            return
        }
        descriptor = fd
        lock.unlock()
        defer {
            lock.lock()
            descriptor = -1
            lock.unlock()
            close(fd)
        }

        // A few dozen bytes into an empty socket buffer: written whole or not at all.
        let wrote = Self.hello.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard wrote == Self.hello.count else { return }

        var buffer = Data()
        var scanned = 0
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count < 0 && errno == EINTR { continue }
            if count <= 0 { return }
            buffer.append(contentsOf: chunk[0..<count])
            var start = buffer.startIndex
            var index = buffer.startIndex + scanned
            while index < buffer.endIndex {
                if buffer[index] == UInt8(ascii: "\n") {
                    let line = Data(buffer[start..<index])
                    DispatchQueue.main.async { [self] in onLine?(line) }
                    start = index + 1
                }
                index += 1
            }
            buffer.removeSubrange(buffer.startIndex..<start)
            scanned = buffer.count
        }
    }

    /// A connected socket, if `path` is a socket this user owns and the peer runs as this user.
    private static func connect(_ path: String) -> Int32? {
        var info = stat()
        guard lstat(path, &info) == 0,
              info.st_mode & S_IFMT == S_IFSOCK,
              info.st_uid == getuid() else { return nil }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard connected == 0, getpeereid(fd, &uid, &gid) == 0, uid == getuid() else {
            close(fd)
            return nil
        }
        return fd
    }
}
