import Foundation
import Darwin

/// Runs one process and streams its output. SPEC.md §13.5, §13.6.
///
/// Commands run through the user's LOGIN shell (`$SHELL -lc`). A GUI app launched from the Dock does not
/// inherit the terminal's PATH, so without a login shell `python3` would not resolve even though it
/// works in Terminal. That is one of the three documented platform traps (CLAUDE.md, trap 3).
final class ProcessRunner {

    enum StreamKind: String { case stdout, stderr }

    struct Result: Equatable {
        var exitCode: Int32
        var elapsed: TimeInterval
        var timedOut: Bool
        var stopped: Bool
        var truncated: Bool
    }

    /// Handle used to stop a run that is in progress.
    final class Handle {
        fileprivate weak var process: Process?
        fileprivate var stopRequested = false
        fileprivate var timedOut = false
        func stop() { stopRequested = true; ProcessRunner.terminate(process) }
    }

    /// Output beyond this is dropped, so a runaway command cannot exhaust memory.
    static let outputLimit = 2_000_000

    /// The user's shell: an explicit override, then $SHELL, then zsh.
    static func resolveShell(override: String?, environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        func usable(_ p: String) -> Bool { p.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: p) }
        if let override, !override.trimmingCharacters(in: .whitespaces).isEmpty {
            return usable(override) ? override : nil            // a bad override is an error, never silently ignored
        }
        if let s = environment["SHELL"], usable(s) { return s }
        return "/bin/zsh"
    }

    /// `~` and blank both mean the home folder.
    static func resolveDirectory(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        let path = trimmed.isEmpty ? NSHomeDirectory() : (trimmed as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        guard path.hasPrefix("/"), FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// Starts `executable arguments…`. Callbacks arrive on the main queue.
    @discardableResult
    func start(executable: String, arguments: [String], cwd: URL, timeout: TimeInterval,
               environment: [String: String] = ProcessInfo.processInfo.environment,
               onOutput: @escaping (StreamKind, String) -> Void,
               completion: @escaping (Result) -> Void) -> Handle {
        let handle = Handle()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = cwd
        process.environment = environment
        process.standardInput = FileHandle.nullDevice        // a script must never sit waiting on the keyboard
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        handle.process = process

        let started = Date()
        let lock = NSLock()
        var total = 0
        var truncated = false
        var pending: [StreamKind: [UInt8]] = [.stdout: [], .stderr: []]

        // Decode only complete UTF-8; carry a split multi-byte character over to the next chunk.
        // Plain [UInt8] on purpose: an earlier version kept a Data SLICE (whose indices do not start at
        // zero) and indexed it from zero, which trapped on any output that arrived in more than one read.
        func deliver(_ kind: StreamKind, _ chunk: [UInt8], final: Bool) {
            lock.lock()
            var bytes = pending[kind]! + chunk
            var keep = 0
            if !final {
                var i = bytes.count - 1, back = 0
                while i >= 0, back < 4, bytes[i] & 0xC0 == 0x80 { i -= 1; back += 1 }
                if i >= 0, bytes[i] >= 0xC0 {
                    let need = bytes[i] >= 0xF0 ? 4 : bytes[i] >= 0xE0 ? 3 : 2
                    if back + 1 < need { keep = back + 1 }
                }
            }
            pending[kind] = Array(bytes.suffix(keep))
            bytes.removeLast(keep)
            if total + bytes.count > ProcessRunner.outputLimit {
                bytes = Array(bytes.prefix(max(0, ProcessRunner.outputLimit - total)))
                truncated = true
            }
            total += bytes.count
            lock.unlock()
            guard !bytes.isEmpty else { return }
            let text = String(decoding: bytes, as: UTF8.self)
            DispatchQueue.main.async { onOutput(kind, text) }
        }

        // Each pipe is drained by a plain blocking read loop on its own thread. (An earlier version used
        // FileHandle.readabilityHandler and then read the rest in the termination handler; the two raced
        // on a closing descriptor and could crash the whole app when a command printed a lot.)
        let state = NSLock()
        var readersLeft = 2
        var terminated = false
        var status: Int32 = 0
        var finished = false

        func finishIfReady(force: Bool = false) {
            state.lock()
            let ready = terminated && (readersLeft == 0 || force) && !finished
            if ready { finished = true }
            state.unlock()
            guard ready else { return }
            let result = Result(exitCode: status, elapsed: Date().timeIntervalSince(started),
                                timedOut: handle.timedOut, stopped: handle.stopRequested && !handle.timedOut, truncated: truncated)
            DispatchQueue.main.async { completion(result) }
        }

        func pump(_ pipe: Pipe, _ kind: StreamKind) {
            let fd = pipe.fileHandleForReading.fileDescriptor
            DispatchQueue.global(qos: .userInitiated).async {
                var buffer = [UInt8](repeating: 0, count: 65_536)
                while true {
                    let n = read(fd, &buffer, buffer.count)
                    if n > 0 { deliver(kind, Array(buffer[0..<n]), final: false) }
                    else if n < 0 && errno == EINTR { continue }
                    else { break }
                }
                deliver(kind, [], final: true)
                state.lock(); readersLeft -= 1; state.unlock()
                finishIfReady()
            }
        }

        process.terminationHandler = { p in
            state.lock(); terminated = true; status = p.terminationStatus; state.unlock()
            finishIfReady()
            // A background job that inherited the pipes can hold them open after the shell exits. Do not
            // wait for it forever: report the run as finished after a short grace period.
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) { finishIfReady(force: true) }
        }

        do {
            try process.run()
        } catch {
            DispatchQueue.main.async {
                onOutput(.stderr, "Could not start: \(error.localizedDescription)\n")
                completion(Result(exitCode: 127, elapsed: 0, timedOut: false, stopped: false, truncated: false))
            }
            return handle
        }
        // The parent must close ITS copy of the write ends, or the readers would never see end-of-file.
        try? out.fileHandleForWriting.close()
        try? err.fileHandleForWriting.close()
        pump(out, .stdout)
        pump(err, .stderr)

        if timeout > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak process] in
                guard let process, process.isRunning else { return }
                handle.timedOut = true
                ProcessRunner.terminate(process)
            }
        }
        return handle
    }

    /// SIGTERM the shell and its children, then SIGKILL anything still alive two seconds later.
    fileprivate static func terminate(_ process: Process?) {
        guard let process, process.isRunning else { return }
        let pid = process.processIdentifier
        signalChildren(of: pid, SIGTERM)
        process.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if kill(pid, 0) == 0 {
                signalChildren(of: pid, SIGKILL)
                kill(pid, SIGKILL)
            }
        }
    }

    /// `zsh -lc "a | b"` may leave children behind when the shell dies, so signal them too.
    private static func signalChildren(of pid: pid_t, _ sig: Int32) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        p.arguments = ["-\(sig)", "-P", "\(pid)"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
    }
}
