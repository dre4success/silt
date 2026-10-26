import Foundation

/// Runs a tool and collects its output, giving up after `timeout` seconds so a hung
/// daemon (Docker not running, say) can't stall the app.
enum Shell {
    struct Output: Sendable {
        let status: Int32
        let stdout: String
        let stderr: String
        /// The tool itself ran out of time and was stopped.
        let timedOut: Bool
        /// False when a helper kept the pipes open past `drainLimit`, so output may be cut short.
        let drained: Bool
    }

    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 20,
                    drainLimit: TimeInterval = 5) -> Output? {
        guard FileManager.default.isExecutableFile(atPath: executable) else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        // Apps launched from Finder get a bare PATH; tools like docker shell out to helpers.
        env["PATH"] = "/usr/local/bin:/opt/homebrew/bin:/usr/local/go/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        // Docker commands are pinned to a checked context instead (see KnownCommand).
        for key in ["DOCKER_HOST", "DOCKER_CONTEXT", "DOCKER_CONFIG"] { env.removeValue(forKey: key) }
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        do { try p.run() } catch { return nil }
        // Drain pipes while waiting so a chatty tool can't fill the buffer and block. Each read
        // gets a thread of its own: it blocks until the tool closes the pipe, and on GCD's shared
        // pool enough blocked reads (other tools, a helper holding a pipe) can leave a new one
        // waiting seconds to be started at all.
        let outData = Locked(Data()), errData = Locked(Data())
        let readers = DispatchGroup()
        for (pipe, sink) in [(out, outData), (err, errData)] {
            readers.enter()
            Thread {
                sink.set(pipe.fileHandleForReading.readDataToEndOfFile())
                readers.leave()
            }.start()
        }
        let timedOut = done.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            p.terminate()
            // A tool that ignores SIGTERM gets SIGKILL a second later.
            if done.wait(timeout: .now() + 1) == .timedOut { kill(p.processIdentifier, SIGKILL) }
        }
        // A helper the tool started can inherit the pipes and hold them open after the tool
        // exits. Its output isn't worth waiting for indefinitely; the tool's own status still counts.
        let drained = readers.wait(timeout: .now() + drainLimit) == .success
        return Output(status: timedOut ? -1 : p.terminationStatus,
                      stdout: String(decoding: outData.get(), as: UTF8.self),
                      stderr: String(decoding: errData.get(), as: UTF8.self),
                      timedOut: timedOut, drained: drained)
    }

    static func firstExecutable(_ candidates: [String]) -> String? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

final class Locked<T: Sendable>: @unchecked Sendable {
    private var value: T
    private let lock = NSLock()
    init(_ value: T) { self.value = value }
    func get() -> T { lock.withLock { value } }
    func set(_ v: T) { lock.withLock { value = v } }
}
