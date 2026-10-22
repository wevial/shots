import Foundation

/// The result of running a child process to completion.
public struct RunResult: Sendable, Equatable {
    /// Exit status; nil when the process couldn't start or was killed by a signal.
    public var code: Int32?
    public var stdout: String
    public var stderr: String
    public var timedOut: Bool

    public init(code: Int32?, stdout: String, stderr: String, timedOut: Bool) {
        self.code = code
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
    }
}

/// Child processes, ported from src/exec.ts.
public enum Exec {
    /// Runs `command` with `arguments` and collects its output.
    ///
    /// The child gets its own process group, so a timeout kills the whole tree (the CLI
    /// agents fork node and tool subprocesses that would otherwise linger). `stdin` nil means
    /// /dev/null. Never throws: a process that can't start comes back with `code == nil` and
    /// the reason in `stderr`. The blocking work (pipe reads, waitpid) runs on dispatch
    /// threads, not the cooperative pool.
    public static func run(
        _ command: String,
        _ arguments: [String],
        cwd: String? = nil,
        stdin: String? = nil,
        timeout: Duration? = nil,
        environment: [String: String]? = nil
    ) async -> RunResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: runBlocking(
                    command, arguments, cwd: cwd, stdin: stdin, timeout: timeout, environment: environment))
            }
        }
    }

    /// Resolves a binary name against `PATH`; an absolute path is checked as is.
    /// Nil when nothing executable is found.
    public static func which(_ binary: String, path: String = ProcessInfo.processInfo.environment["PATH"] ?? "") -> String? {
        let candidates = binary.hasPrefix("/") ? [binary] : path.split(separator: ":").map { Paths.join(String($0), binary) }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// `PATH` plus the places the agent CLIs usually live. An app launched from Finder gets
    /// a minimal PATH, and `claude` is a node script that needs `node` on it too.
    public static func augmentedPath(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = Paths.home()
    ) -> String {
        let extras = [
            Paths.join(home, ".local/bin"), Paths.join(home, ".npm-global/bin"),
            "/opt/homebrew/bin", "/usr/local/bin",
        ]
        var seen = Set<String>()
        let current = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        return (current + extras).filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: ":")
    }

    /// The inherited environment with the augmented PATH.
    public static func augmentedEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = augmentedPath(environment: env)
        return env
    }

    // MARK: - posix_spawn

    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func append(_ chunk: UnsafeRawBufferPointer) {
            lock.lock()
            data.append(contentsOf: chunk)
            lock.unlock()
        }
        var string: String {
            lock.lock()
            defer { lock.unlock() }
            return String(decoding: data, as: UTF8.self)
        }
    }

    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var reaped = false
        private var finished = false
        private(set) var timedOut = false
        /// Kills the whole group. Once the child is reaped its pid may belong to someone
        /// else, so only the group is signalled then (a group id isn't reused while any
        /// member, such as a grandchild holding our pipe, is alive).
        func timeoutFired(pid: pid_t) {
            lock.lock()
            defer { lock.unlock() }
            guard !finished else { return }
            timedOut = true
            if kill(-pid, SIGKILL) != 0 && !reaped { kill(pid, SIGKILL) }
        }
        func markReaped() {
            lock.withLock { reaped = true }
        }
        func markFinished() {
            lock.withLock { finished = true }
        }
    }

    private static func runBlocking(
        _ command: String, _ arguments: [String], cwd: String?, stdin: String?,
        timeout: Duration?, environment: [String: String]?
    ) -> RunResult {
        let env = environment ?? ProcessInfo.processInfo.environment
        let executable = command.contains("/") ? command : (which(command, path: env["PATH"] ?? "") ?? command)

        func failure(_ message: String) -> RunResult {
            RunResult(code: nil, stdout: "", stderr: message, timedOut: false)
        }

        var outPipe: [Int32] = [0, 0], errPipe: [Int32] = [0, 0], inPipe: [Int32] = [0, 0]
        guard pipe(&outPipe) == 0, pipe(&errPipe) == 0 else { return failure("pipe: \(String(cString: strerror(errno)))") }
        let hasStdin = stdin != nil
        if hasStdin, pipe(&inPipe) != 0 { return failure("pipe: \(String(cString: strerror(errno)))") }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        if hasStdin {
            posix_spawn_file_actions_adddup2(&actions, inPipe[0], 0)
        } else {
            posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        }
        posix_spawn_file_actions_adddup2(&actions, outPipe[1], 1)
        posix_spawn_file_actions_adddup2(&actions, errPipe[1], 2)
        if let cwd { posix_spawn_file_actions_addchdir(&actions, cwd) }

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setpgroup(&attributes, 0)
        // CLOEXEC_DEFAULT: the child gets only 0/1/2, so concurrent children never hold
        // each other's pipe ends open.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))

        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }

        var pid: pid_t = 0
        let spawnResult = posix_spawn(&pid, executable, &actions, &attributes, argv, envp)

        close(outPipe[1])
        close(errPipe[1])
        if hasStdin { close(inPipe[0]) }
        guard spawnResult == 0 else {
            close(outPipe[0])
            close(errPipe[0])
            if hasStdin { close(inPipe[1]) }
            return failure("\(executable): \(String(cString: strerror(spawnResult)))")
        }

        let out = Collector(), err = Collector(), group = DispatchGroup()
        for (fd, collector) in [(outPipe[0], out), (errPipe[0], err)] {
            group.enter()
            DispatchQueue.global().async {
                var buffer = [UInt8](repeating: 0, count: 64 * 1024)
                while true {
                    let n = read(fd, &buffer, buffer.count)
                    if n > 0 {
                        buffer.withUnsafeBytes { collector.append(UnsafeRawBufferPointer(rebasing: $0[0..<n])) }
                    } else if n < 0 && errno == EINTR {
                        continue
                    } else {
                        break
                    }
                }
                close(fd)
                group.leave()
            }
        }
        if let stdin {
            let fd = inPipe[1]
            _ = fcntl(fd, F_SETNOSIGPIPE, 1)
            DispatchQueue.global().async {
                var bytes = Array(stdin.utf8)[...]
                while !bytes.isEmpty {
                    let n = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
                    if n > 0 { bytes = bytes.dropFirst(n) } else if n < 0 && errno == EINTR { continue } else { break }
                }
                close(fd)
            }
        }

        let state = State()
        var timer: DispatchWorkItem?
        if let timeout {
            let item = DispatchWorkItem { state.timeoutFired(pid: pid) }
            timer = item
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(Int(timeout.milliseconds)), execute: item)
        }

        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        state.markReaped()
        // Like Node's "close": done when the pipes are, too. The timer stays armed until
        // then, so a grandchild that keeps stdout open still gets killed.
        group.wait()
        state.markFinished()
        timer?.cancel()

        // WIFEXITED / WEXITSTATUS are macros Swift can't import.
        let code: Int32? = (status & 0x7f) == 0 ? (status >> 8) & 0xff : nil
        return RunResult(code: code, stdout: out.string, stderr: err.string, timedOut: state.timedOut)
    }
}
