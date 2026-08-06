import Foundation

// Port of the subprocess guard in agent_usage.rs (:865-946).
//
// `Command::output()` with a deadline, killing the child if it overruns.
// Both callers run on the refresh loop's schedule and shell out to binaries
// that can block forever: `security` raises a modal when the keychain ACL no
// longer matches the caller, and a wedged `claude` shim never returns.
//
// A spawn failure is a `.failure`. Otherwise the three outcomes stay
// distinct: `.failed` means the binary ran and answered no, `.timedOut`
// means we learned nothing. Callers must not collapse those two — for
// `security`, "no such keychain item" and "the read stalled" lead to
// opposite conclusions about whether Claude is set up at all.
// (Encodes commit a804dd5: the reap shares the read's deadline, and a
// timeout is never folded into "ran and said no".)

/// Ceiling for the helper binaries we shell out to (`security`, `claude`).
let subprocessTimeout: TimeInterval = 5

/// Outcome of `outputWithTimeout`, kept three-way on purpose.
enum SubprocessOutcome {
    /// Exited zero; stdout captured.
    case ok(Data)
    /// Ran to completion and exited non-zero.
    case failed
    /// Hit the deadline and was killed. Says nothing about the answer.
    case timedOut
}

/// Wrapper for moving non-Sendable Foundation handles into the reader
/// thread. Safe here because the semaphore orders every access.
private struct UncheckedSendable<T>: @unchecked Sendable {
    let value: T
}

private final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func store(_ new: Data) {
        lock.lock()
        data = new
        lock.unlock()
    }

    func take() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}

/// `output_with_timeout`: run `executable` with `arguments`, reading stdout
/// with a deadline. `.failure(message)` is a spawn failure only.
func outputWithTimeout(
    _ executable: String,
    _ arguments: [String],
    timeout: TimeInterval
) -> Result<SubprocessOutcome, QuotaError> {
    let deadline = Date().addingTimeInterval(timeout)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardInput = FileHandle.nullDevice
    let stdout = Pipe()
    process.standardOutput = stdout
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
    } catch {
        return .failure(QuotaError("\(error.localizedDescription)"))
    }

    // Read on a separate thread: past ~64KB the child blocks writing until
    // someone drains the pipe, so an in-line read before wait() can deadlock.
    let buffer = OutputBuffer()
    let semaphore = DispatchSemaphore(value: 0)
    let handleBox = UncheckedSendable(value: stdout.fileHandleForReading)
    Thread.detachNewThread {
        let data = (try? handleBox.value.readToEnd()) ?? Data()
        buffer.store(data)
        semaphore.signal()
    }

    if semaphore.wait(timeout: .now() + timeout) == .timedOut {
        killAndReap(process)
        return .success(.timedOut)
    }
    // A closed pipe doesn't mean the child is gone — it can close stdout and
    // keep running, so the reap gets the same deadline the read did. An
    // unbounded wait here would park this thread for the child's lifetime
    // and hand back a success as if nothing were wrong.
    guard let status = waitUntil(process, deadline: deadline) else {
        killAndReap(process)
        return .success(.timedOut)
    }
    return .success(status == 0 ? .ok(buffer.take()) : .failed)
}

/// Poll for exit until `deadline`. `nil` means still running.
private func waitUntil(_ process: Process, deadline: Date) -> Int32? {
    while true {
        if !process.isRunning {
            return process.terminationStatus
        }
        if Date() >= deadline {
            return nil
        }
        usleep(10_000)
    }
}

/// SIGKILL then reap. The wait is bounded because the signal is uncatchable;
/// note the reader thread can still outlive this if a grandchild inherited
/// the pipe, since kill() signals the child alone.
func killAndReap(_ process: Process) {
    kill(process.processIdentifier, SIGKILL)
    process.waitUntilExit()
}
