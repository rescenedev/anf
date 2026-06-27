import Foundation
import PTYHelper

/// Manages a POSIX pseudo-terminal running a child process.
/// Uses a C helper for fork/exec so Swift's fork() restriction is bypassed.
final class PTYProcess {
    private(set) var masterFD: Int32 = -1
    private(set) var pid: pid_t = -1
    var onOutput: ((Data) -> Void)?
    var onExit: ((Int32) -> Void)?

    private var readSource: DispatchSourceRead?
    /// All masterFD lifetime ops (read, close) are serialized here so the read
    /// handler can never read a fd that teardown closed mid-call (and which the
    /// OS may have already reused for another file).
    private let ioQueue = DispatchQueue(label: "com.anf.pty.io")

    // MARK: - Spawn

    func spawn(executable: String, args: [String], environment: [String: String]? = nil,
               cwd: String? = nil, cols: Int = 80, rows: Int = 24) {
        // Build env: inherit current process environment, then layer extras.
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        if let extra = environment { extra.forEach { env[$0] = $1 } }

        let envList = env.map { "\($0)=\($1)" }
        let allArgs = [executable] + args
        var cArgv: [UnsafeMutablePointer<CChar>?] = allArgs.map { strdup($0) } + [nil]
        var cEnvp: [UnsafeMutablePointer<CChar>?] = envList.map { strdup($0) } + [nil]
        let cExe = strdup(executable)!
        var childPid: pid_t = -1

        // Invoke pty_spawn, bridging optional cwd to UnsafePointer<CChar>?
        func doSpawn(cwdPtr: UnsafePointer<CChar>?) -> Int32 {
            cArgv.withUnsafeMutableBufferPointer { av in
                cEnvp.withUnsafeMutableBufferPointer { ev in
                    pty_spawn(cExe, av.baseAddress!, ev.baseAddress!, cwdPtr,
                              UInt16(cols), UInt16(rows), &childPid)
                }
            }
        }
        let master: Int32
        if let cwdStr = cwd {
            master = cwdStr.withCString { doSpawn(cwdPtr: $0) }
        } else {
            master = doSpawn(cwdPtr: nil)
        }

        free(cExe)
        cArgv.forEach { if let p = $0 { free(p) } }
        cEnvp.forEach { if let p = $0 { free(p) } }

        guard master >= 0 else { return }
        masterFD = master
        self.pid = childPid
        startReading()
        watchExit()
    }

    // MARK: - I/O

    func write(_ data: Data) {
        guard masterFD >= 0 else { return }
        data.withUnsafeBytes { _ = Darwin.write(masterFD, $0.baseAddress!, $0.count) }
    }

    func write(_ string: String) {
        if let d = string.data(using: .utf8) { write(d) }
    }

    func resize(cols: Int, rows: Int) {
        guard masterFD >= 0 else { return }
        var ws = winsize()
        ws.ws_col = UInt16(cols); ws.ws_row = UInt16(rows)
        ioctl(masterFD, TIOCSWINSZ, &ws)
    }

    func kill() {
        if pid > 0 { Darwin.kill(pid, SIGTERM); pid = -1 }
        teardown()
    }

    // MARK: - Internals

    private func startReading() {
        let src = DispatchSource.makeReadSource(fileDescriptor: masterFD, queue: ioQueue)
        src.setEventHandler { [weak self] in
            // Runs on ioQueue — serialized with teardown's close().
            guard let self, self.masterFD >= 0 else { return }
            var buf = [UInt8](repeating: 0, count: 4096)
            let n = Darwin.read(self.masterFD, &buf, buf.count)
            if n > 0 {
                let data = Data(buf[0..<n])
                DispatchQueue.main.async { self.onOutput?(data) }
            } else if n <= 0 {
                self.teardownLocked()
            }
        }
        src.resume()
        readSource = src
    }

    private func watchExit() {
        let p = pid
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let code = pty_wait(p)   // reaps the child
            DispatchQueue.main.async {
                // The child has been reaped — clear pid BEFORE onExit so a later
                // kill() (e.g. closing the already-exited tab) can't SIGTERM a pid
                // the OS may have recycled for an unrelated process.
                self?.pid = -1
                self?.onExit?(code)
            }
        }
    }

    /// Public teardown (from kill/main): hop onto ioQueue so the close is
    /// serialized with any in-flight read on that queue.
    private func teardown() {
        ioQueue.async { [weak self] in self?.teardownLocked() }
    }

    /// Must run on ioQueue.
    private func teardownLocked() {
        readSource?.cancel(); readSource = nil
        if masterFD >= 0 { close(masterFD); masterFD = -1 }
    }
}
