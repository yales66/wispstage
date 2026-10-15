import Foundation
import WispstageClient

/// The stage library's side of the socket: listens on the given path and accepts one driver at a time. Events before the driver connects are buffered
/// and sent first once it connects; after the driver disconnects they are buffered again until the next one connects. Commands are one JSON object per
/// line, passed to `handle`, which calls back with one reply line when done (possibly later, since mouse gestures run in steps); the next command is read
/// only after the previous one is answered, so commands run in arrival order.
final class StageServer: @unchecked Sendable {
    let path: String
    private let listener: Int32
    private let lock = NSLock()
    private var client: Int32 = -1
    private var pending: [String] = []
    private let handle: @Sendable (String, @escaping @Sendable (String) -> Void) -> Void

    init?(path: String, handle: @escaping @Sendable (String, @escaping @Sendable (String) -> Void) -> Void) {
        guard var addr = UnixSocketAddress.make(path) else { return nil }
        self.path = path
        self.handle = handle
        unlink(path)
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { return nil }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(s, 1) == 0 else { close(s); return nil }
        listener = s
        let thread = Thread { [weak self] in self?.acceptLoop() }
        thread.name = "Wispstage.accept"
        thread.start()
    }

    /// Sends one line (from any thread). Buffered while no driver is connected.
    func send(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        if client >= 0, write(line) { return }
        pending.append(line)
    }

    /// The caller holds the lock.
    private func write(_ line: String) -> Bool {
        let data = Array((line + "\n").utf8)
        let n = data.withUnsafeBytes { Darwin.write(client, $0.baseAddress, $0.count) }
        if n == data.count { return true }
        close(client)
        client = -1
        return false
    }

    private func acceptLoop() {
        while true {
            let c = accept(listener, nil, nil)
            if c < 0 { if errno == EINTR { continue }; return }
            var on: Int32 = 1
            setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            lock.lock()
            if client >= 0 { close(client) }
            client = c
            let backlog = pending
            pending = []
            var ok = true
            for line in backlog where ok { ok = write(line) }
            lock.unlock()
            readLoop(c)
        }
    }

    private func readLoop(_ c: Int32) {
        var splitter = LineSplitter()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = buf.withUnsafeMutableBytes { read(c, $0.baseAddress, $0.count) }
            if n <= 0 { break }
            for line in splitter.feed(Data(buf[0..<n])) where !line.isEmpty {
                let answered = DispatchSemaphore(value: 0)
                handle(line) { [weak self] reply in
                    self?.send(reply)
                    answered.signal()
                }
                answered.wait()
            }
        }
        lock.lock()
        if client == c { close(c); client = -1 }
        lock.unlock()
    }
}
