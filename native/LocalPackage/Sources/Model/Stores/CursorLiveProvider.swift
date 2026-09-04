import AppKit
import Collector
import Darwin
import Foundation

// Polls Cursor's aggregated usage endpoint and pushes diffs into the
// shared live-event ring. Separate from UsageTailer.tick — that actor
// owns file offsets and must not grow a network source.
//
// Gated by the same `cursorUsage` opt-in as the historical event cache:
// one consent covers every Cursor.com / api2.cursor.sh call. Polling
// pauses while Cursor IDE and Cursor CLI are both quit and backs off
// while the account is idle.

public struct CursorProcessSnapshot: Sendable, Equatable {
    public var running: Bool
    public var pid: Int32?

    public init(running: Bool, pid: Int32? = nil) {
        self.running = running
        self.pid = pid
    }
}

public actor CursorLiveProvider {
    public typealias Fetch = @Sendable (Int64, Int64) async throws -> CursorAggregatePayload
    public typealias ProcessCheck = @Sendable () -> CursorProcessSnapshot
    public typealias Clock = @Sendable () -> Date

    private let tailer: UsageTailer
    private let fetch: Fetch
    private let processSnapshot: ProcessCheck
    private let clock: Clock
    private let nowMs: @Sendable () -> Int64

    private var task: Task<Void, Never>?
    private var differ = CursorAggregateDiffer()
    private var schedule = CursorLiveSchedule()
    private var windowStartMs: Int64?
    private var accountKey: String?
    /// 401/403: do not keep POSTing a dead token. Cleared on Cursor
    /// relaunch (pid change) or when the opt-in is toggled off then on.
    private var authSuspended = false
    private var lastCursorPid: Int32?
    private var appliedRevision: UInt64 = 0

    public init(
        tailer: UsageTailer,
        fetch: Fetch? = nil,
        processSnapshot: ProcessCheck? = nil,
        clock: Clock? = nil,
        nowMs: (@Sendable () -> Int64)? = nil
    ) {
        self.tailer = tailer
        self.fetch = fetch ?? { start, end in
            try await CursorAggregatedUsageFetcher.fetch(startMs: start, endMs: end)
        }
        self.processSnapshot = processSnapshot ?? { CursorProcess.snapshot() }
        self.clock = clock ?? { Date() }
        self.nowMs = nowMs ?? { Int64(Date().timeIntervalSince1970 * 1000.0) }
    }

    /// Apply desired state if `revision` is not stale. LiveTraceStore
    /// increments a monotonic revision so a late `true` cannot outrun a
    /// later `false` even if actor messages reorder.
    public func setEnabled(_ enabled: Bool, revision: UInt64) {
        guard revision >= appliedRevision else { return }
        appliedRevision = revision
        if enabled {
            start()
        } else {
            stop()
        }
    }

    /// Start the poll loop. Idempotent: a live task is left running.
    public func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            await self?.runLoop()
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
        differ = CursorAggregateDiffer()
        schedule = CursorLiveSchedule()
        windowStartMs = nil
        accountKey = nil
        authSuspended = false
        lastCursorPid = nil
    }

    func isRunning() -> Bool { task != nil }

    private func runLoop() async {
        while !Task.isCancelled {
            let delay = await pollOnce()
            let ns = UInt64(max(delay, 1) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: ns)
        }
    }

    /// One poll. Returns the seconds to wait before the next attempt.
    @discardableResult
    func pollOnce() async -> TimeInterval {
        let now = clock()
        let proc = processSnapshot()
        if authSuspended {
            let relaunched = proc.running && proc.pid != nil && proc.pid != lastCursorPid
            if relaunched {
                authSuspended = false
            } else {
                if proc.running { lastCursorPid = proc.pid }
                return CursorLiveSchedule.processCheckSecs
            }
        }
        guard proc.running else {
            lastCursorPid = nil
            return schedule.delay(now: now, cursorRunning: false)
        }
        lastCursorPid = proc.pid

        let nowMillis = nowMs()
        if windowStartMs == nil {
            windowStartMs = CursorAggregatedUsageFetcher.defaultStartMs(nowMs: nowMillis)
        }
        let start = windowStartMs!
        let end = CursorAggregatedUsageFetcher.defaultEndMs(nowMs: nowMillis)

        do {
            let payload = try await fetch(start, end)
            if Task.isCancelled { return CursorLiveSchedule.processCheckSecs }
            if let key = payload.accountKey {
                if let previous = accountKey, previous != key {
                    differ = CursorAggregateDiffer()
                }
                accountKey = key
            }
            let events = differ.consume(payload: payload, nowMs: nowMillis)
            if !events.isEmpty {
                _ = await tailer.ingest(events)
            }
            schedule.noteSuccess(hadDelta: !events.isEmpty, now: now)
            return schedule.delay(now: now, cursorRunning: true)
        } catch let error as CursorLiveHTTPError {
            if Task.isCancelled { return CursorLiveSchedule.processCheckSecs }
            switch error {
            case .status(401), .status(403):
                authSuspended = true
                lastCursorPid = proc.pid
                return CursorLiveSchedule.processCheckSecs
            case .status(429):
                schedule.noteRateLimited()
                return schedule.delay(now: now, cursorRunning: true)
            case .status:
                return CursorLiveSchedule.idleSecs
            }
        } catch {
            if Task.isCancelled { return CursorLiveSchedule.processCheckSecs }
            return CursorLiveSchedule.idleSecs
        }
    }
}

enum CursorProcess {
    /// Cursor's production bundle id is a ToDesktop wrapper
    /// (`com.todesktop.<id>`) that does not contain "cursor". Match the
    /// exact localized name `Cursor` and the `Cursor.app` bundle path.
    /// Do not substring-match bundle ids: `CursorUIViewService` is
    /// `com.apple.TextInputUI.xpc.CursorUIViewService` and would keep
    /// the gate open with no Cursor IDE or CLI present.
    ///
    /// Cursor CLI is not an `NSRunningApplication`. Also walk process
    /// executable paths: the GUI main binary
    /// (`.../Cursor.app/Contents/MacOS/Cursor`), official curl layout
    /// (`~/.local/share/cursor-agent/versions/.../node`), Homebrew
    /// `cursor-cli` (`.../Caskroom/cursor-cli/.../dist-package/node`),
    /// and `cursor-agent` / `~/.local/bin/cursor`.
    ///
    /// A PATH `cursor` that resolves into `Cursor.app/.../app/bin/code`
    /// is the IDE opener, not the agent CLI — do not treat that as CLI.
    /// The running GUI app itself still gates polling via
    /// `NSRunningApplication` and `looksLikeCursorGUI`.
    /// A PATH `agent` symlink counts only after it resolves into a CLI
    /// path. Skip Grok `agent`, helpers, `CursorUIViewService`, `tokcat`.
    static func snapshot() -> CursorProcessSnapshot {
        if let app = NSWorkspace.shared.runningApplications.first(where: isGUICursor) {
            return CursorProcessSnapshot(running: true, pid: app.processIdentifier)
        }
        if let pid = matchingPid() {
            return CursorProcessSnapshot(running: true, pid: pid)
        }
        return CursorProcessSnapshot(running: false, pid: nil)
    }

    static func isGUICursor(_ app: NSRunningApplication) -> Bool {
        isGUICursor(
            localizedName: app.localizedName,
            bundleName: app.bundleURL?.lastPathComponent,
            bundleId: app.bundleIdentifier)
    }

    /// Testable GUI predicate. Bundle-id substring matches are rejected
    /// on purpose (`CursorUIViewService` contains "cursor").
    static func isGUICursor(
        localizedName: String?,
        bundleName: String?,
        bundleId _: String? = nil
    ) -> Bool {
        if localizedName == "Cursor" { return true }
        if bundleName == "Cursor.app" { return true }
        return false
    }

    /// Main GUI executable only. Helpers and the `code` shim do not count.
    static func looksLikeCursorGUI(path: String) -> Bool {
        let resolved = (path as NSString).resolvingSymlinksInPath
        return isGUICursorExecutable(path) || isGUICursorExecutable(resolved)
    }

    static func looksLikeCursorCLI(path: String) -> Bool {
        let resolved = (path as NSString).resolvingSymlinksInPath
        if isInsideCursorApp(path) || isInsideCursorApp(resolved) {
            return false
        }
        return matchesCursorCLIPath(path) || matchesCursorCLIPath(resolved)
    }

    static func looksLikeCursor(path: String) -> Bool {
        looksLikeCursorGUI(path: path) || looksLikeCursorCLI(path: path)
    }

    static func isInsideCursorApp(_ path: String) -> Bool {
        path.lowercased().contains("/cursor.app/")
    }

    private static func isGUICursorExecutable(_ path: String) -> Bool {
        path.lowercased().hasSuffix("/cursor.app/contents/macos/cursor")
    }

    private static func matchesCursorCLIPath(_ path: String) -> Bool {
        let lower = path.lowercased()
        if isInsideCursorApp(lower) { return false }
        // Official curl install: ~/.local/share/cursor-agent/versions/<ver>/node
        if lower.contains("/cursor-agent/versions/") && lower.hasSuffix("/node") {
            return true
        }
        if lower.hasSuffix("/cursor-agent") { return true }
        // Homebrew cask `cursor-cli`: long-lived process is dist-package/node.
        if lower.contains("/cursor-cli/") && lower.hasSuffix("/dist-package/node") {
            return true
        }
        if lower.hasSuffix("/bin/cursor") { return true }
        return false
    }

    private static func matchingPid() -> pid_t? {
        let needed = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard needed > 0 else { return nil }
        var pids = [pid_t](repeating: 0, count: Int(needed))
        let filled = proc_listpids(
            UInt32(PROC_ALL_PIDS), 0, &pids,
            Int32(MemoryLayout<pid_t>.stride * pids.count))
        guard filled > 0 else { return nil }
        let count = Int(filled) / MemoryLayout<pid_t>.stride
        var pathBuf = [CChar](repeating: 0, count: Int(4 * MAXPATHLEN))
        var preferred: pid_t?
        var fallback: pid_t?
        for pid in pids.prefix(count) where pid > 0 {
            let n = proc_pidpath(pid, &pathBuf, UInt32(pathBuf.count))
            guard n > 0 else { continue }
            let bytes = pathBuf.prefix(Int(n)).map { UInt8(bitPattern: $0) }
            let path = String(decoding: bytes, as: UTF8.self)
            guard looksLikeCursor(path: path) else { continue }
            let lower = path.lowercased()
            if isGUICursorExecutable(lower)
                || lower.hasSuffix("/bin/cursor")
                || lower.hasSuffix("/cursor-agent") {
                preferred = pid
                break
            }
            if fallback == nil { fallback = pid }
        }
        return preferred ?? fallback
    }
}
