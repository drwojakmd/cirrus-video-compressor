import Foundation

public struct ProcessResult: Sendable {
    public let status: Int32
    public let stdout: Data
    public let stderr: String
    public var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
}

/// Every child process the engine starts is registered here so the app can
/// terminate them all when it quits — no orphaned encoders burning CPU.
public final class ProcessRegistry: @unchecked Sendable {
    public static let shared = ProcessRegistry()
    private let lock = NSLock()
    private var running: [ObjectIdentifier: Process] = [:]

    func add(_ p: Process) { lock.lock(); running[ObjectIdentifier(p)] = p; lock.unlock() }
    func remove(_ p: Process) { lock.lock(); running[ObjectIdentifier(p)] = nil; lock.unlock() }

    public func terminateAll() {
        lock.lock(); let all = Array(running.values); lock.unlock()
        for p in all where p.isRunning { p.terminate() }
        // give FFmpeg a moment to exit cleanly, then make sure
        Thread.sleep(forTimeInterval: 0.5)
        for p in all where p.isRunning { kill(p.processIdentifier, SIGKILL) }
    }
}

/// Splits a byte stream into lines on \n or \r (FFmpeg uses \r for stat updates).
final class LineSplitter {
    private var buffer = Data()
    func feed(_ data: Data, _ emit: (String) -> Void) {
        buffer.append(data)
        while let idx = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            let line = buffer[buffer.startIndex..<idx]
            buffer.removeSubrange(buffer.startIndex...idx)
            if !line.isEmpty { emit(String(decoding: line, as: UTF8.self)) }
        }
    }
    func flush(_ emit: (String) -> Void) {
        if !buffer.isEmpty { emit(String(decoding: buffer, as: UTF8.self)); buffer.removeAll() }
    }
}

/// Async, cancellable wrapper around `Process`.
///
/// * Task cancellation sends SIGTERM (FFmpeg then stops promptly), escalating
///   to SIGKILL after 3 s.
/// * Output can be streamed line-by-line (progress parsing) and/or collected.
/// * stderr retention is capped so a chatty encoder cannot exhaust memory.
public enum ProcessRunner {
    public struct Options: Sendable {
        public var collectStdout = true
        public var allowFailure = false
        public var qos: QualityOfService = .userInitiated
        public var stderrTailBytes = 64 * 1024
        public var currentDirectory: URL? = nil
        public init() {}
    }

    @discardableResult
    public static func run(_ executable: URL, _ arguments: [String],
                           options: Options = Options(),
                           onStdoutLine: (@Sendable (String) -> Void)? = nil,
                           onStderrLine: (@Sendable (String) -> Void)? = nil) async throws -> ProcessResult {
        try Task.checkCancellation()
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.qualityOfService = options.qos
        if let cwd = options.currentDirectory { process.currentDirectoryURL = cwd }
        process.standardInput = FileHandle.nullDevice
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        final class State: @unchecked Sendable {
            let lock = NSLock()
            var stdout = Data()
            var stderr = Data()
            var outDone = false, errDone = false, exited = false
            var continuation: CheckedContinuation<Void, Never>?
            let outSplit = LineSplitter(), errSplit = LineSplitter()
            func snapshot() -> (Data, Data) { lock.lock(); defer { lock.unlock() }; return (stdout, stderr) }
            func maybeFinish() {
                lock.lock()
                let done = outDone && errDone && exited
                let c = done ? continuation : nil
                if done { continuation = nil }
                lock.unlock()
                c?.resume()
            }
        }
        let state = State()
        let tail = options.stderrTailBytes
        let collect = options.collectStdout

        outPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty {
                h.readabilityHandler = nil
                state.lock.lock()
                if let cb = onStdoutLine { state.outSplit.flush(cb) }
                state.outDone = true
                state.lock.unlock()
                state.maybeFinish(); return
            }
            state.lock.lock()
            if collect { state.stdout.append(d) }
            if let cb = onStdoutLine { state.outSplit.feed(d, cb) }
            state.lock.unlock()
        }
        errPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty {
                h.readabilityHandler = nil
                state.lock.lock()
                if let cb = onStderrLine { state.errSplit.flush(cb) }
                state.errDone = true
                state.lock.unlock()
                state.maybeFinish(); return
            }
            state.lock.lock()
            state.stderr.append(d)
            if state.stderr.count > tail * 2 { state.stderr = state.stderr.suffix(tail) }
            if let cb = onStderrLine { state.errSplit.feed(d, cb) }
            state.lock.unlock()
        }
        process.terminationHandler = { _ in
            state.lock.lock(); state.exited = true; state.lock.unlock()
            state.maybeFinish()
        }

        let name = executable.lastPathComponent
        Log.debug("exec \(name) \(arguments.map { $0.contains(" ") ? "'\($0)'" : $0 }.joined(separator: " "))")

        try await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                state.lock.lock(); state.continuation = c; state.lock.unlock()
                do {
                    try process.run()
                    ProcessRegistry.shared.add(process)
                } catch {
                    Log.error("failed to launch \(name): \(error)")
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    state.lock.lock(); state.outDone = true; state.errDone = true; state.exited = true; state.lock.unlock()
                    state.maybeFinish()
                }
            }
        } onCancel: {
            terminate(process)
        }
        ProcessRegistry.shared.remove(process)

        if Task.isCancelled { throw CirrusError.cancelled }
        let status = process.isRunning ? -1 : process.terminationStatus
        let (out, err) = state.snapshot()
        let result = ProcessResult(status: status, stdout: out, stderr: String(decoding: err, as: UTF8.self))
        if status != 0 && !options.allowFailure {
            Log.error("\(name) exited \(status): \(CirrusError.summarise(result.stderr))")
            throw CirrusError.processFailed(tool: name == "ffprobe" ? "FFprobe" : "The encoder", status: status, detail: result.stderr)
        }
        return result
    }

    static func terminate(_ p: Process) {
        guard p.isRunning else { return }
        p.terminate()
        let pid = p.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            if p.isRunning { kill(pid, SIGKILL) }
        }
    }
}
