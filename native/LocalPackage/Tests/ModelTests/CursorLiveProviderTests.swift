import Collector
import Foundation
import Testing

@testable import Model

@Suite struct CursorLiveProviderTests {
    @Test func firstPollIsBaselineSecondPollIngestsDelta() async {
        let now: Int64 = 1_800_000_000_000
        let tailer = UsageTailer(config: UsageTailerConfig(nowMs: { now }))
        let snaps = [
            CursorAggregateSnapshot(models: [
                "m": CursorModelTotals(input: 10, output: 0, cacheWrite: 0, cacheRead: 0)
            ]),
            CursorAggregateSnapshot(models: [
                "m": CursorModelTotals(input: 15, output: 4, cacheWrite: 0, cacheRead: 0)
            ]),
        ]
        let box = FetchBox(snaps: snaps)
        let provider = CursorLiveProvider(
            tailer: tailer,
            fetch: { _, _ in try box.next() },
            processSnapshot: { .init(running: true, pid: 1) },
            clock: { Date(timeIntervalSince1970: Double(now) / 1000.0) },
            nowMs: { now })

        let d1 = await provider.pollOnce()
        #expect(d1 == CursorLiveSchedule.activeSecs)
        #expect(await tailer.eventsSnapshot().isEmpty)

        let d2 = await provider.pollOnce()
        #expect(d2 == CursorLiveSchedule.activeSecs)
        let events = await tailer.eventsSnapshot()
        #expect(events.count == 1)
        #expect(events[0].input == 5)
        #expect(events[0].output == 4)
        #expect(events[0].client == "cursor")
        #expect(box.calls == 2)
    }

    @Test func skippedWhenCursorNotRunning() async {
        let tailer = UsageTailer()
        let box = FetchBox(snaps: [
            CursorAggregateSnapshot(models: [
                "m": CursorModelTotals(input: 1, output: 0, cacheWrite: 0, cacheRead: 0)
            ])
        ])
        let provider = CursorLiveProvider(
            tailer: tailer,
            fetch: { _, _ in try box.next() },
            processSnapshot: { .init(running: false) },
            clock: { Date(timeIntervalSince1970: 1) },
            nowMs: { 1_000 })

        let delay = await provider.pollOnce()
        #expect(delay == CursorLiveSchedule.processCheckSecs)
        #expect(box.calls == 0)
        #expect(await tailer.eventsSnapshot().isEmpty)
    }

    @Test func rateLimit429BacksOff() async {
        let tailer = UsageTailer()
        let provider = CursorLiveProvider(
            tailer: tailer,
            fetch: { _, _ in throw CursorLiveHTTPError.status(429) },
            processSnapshot: { .init(running: true, pid: 1) },
            clock: { Date(timeIntervalSince1970: 1) },
            nowMs: { 1_000 })

        #expect(await provider.pollOnce() == CursorLiveSchedule.rateLimitSecs)
        #expect(await provider.pollOnce() == CursorLiveSchedule.rateLimitLongSecs)
        #expect(await tailer.eventsSnapshot().isEmpty)
    }

    @Test func unauthorizedSuspendsUntilPidChanges() async {
        let tailer = UsageTailer()
        let box = FetchBox(snaps: [
            CursorAggregateSnapshot(models: [
                "m": CursorModelTotals(input: 1, output: 0, cacheWrite: 0, cacheRead: 0)
            ])
        ])
        box.throwStatus = 401
        let proc = ProcessBox(running: true, pid: 11)
        let provider = CursorLiveProvider(
            tailer: tailer,
            fetch: { _, _ in try box.next() },
            processSnapshot: { proc.snapshot },
            clock: { Date(timeIntervalSince1970: 1) },
            nowMs: { 1_000 })

        #expect(await provider.pollOnce() == CursorLiveSchedule.processCheckSecs)
        #expect(box.calls == 1)
        #expect(await provider.pollOnce() == CursorLiveSchedule.processCheckSecs)
        #expect(box.calls == 1)

        // Fast relaunch: never sampled as not-running.
        proc.pid = 12
        box.throwStatus = nil
        _ = await provider.pollOnce()
        #expect(box.calls == 2)
    }

    @Test func mixedErrorDoesNotSkipFirst429Step() async {
        let tailer = UsageTailer()
        let box = FetchBox(snaps: [])
        box.throwStatus = 500
        let provider = CursorLiveProvider(
            tailer: tailer,
            fetch: { _, _ in try box.next() },
            processSnapshot: { .init(running: true, pid: 1) },
            clock: { Date(timeIntervalSince1970: 1) },
            nowMs: { 1_000 })

        #expect(await provider.pollOnce() == CursorLiveSchedule.idleSecs)
        box.throwStatus = 429
        #expect(await provider.pollOnce() == CursorLiveSchedule.rateLimitSecs)
    }

    @Test func pinsStartDateAcrossPolls() async {
        let clock = ClockBox(nowMs: 1_800_000_000_000)
        let tailer = UsageTailer(config: UsageTailerConfig(nowMs: { clock.nowMs }))
        let box = FetchBox(snaps: [
            CursorAggregateSnapshot(models: [
                "m": CursorModelTotals(input: 1, output: 0, cacheWrite: 0, cacheRead: 0)
            ]),
            CursorAggregateSnapshot(models: [
                "m": CursorModelTotals(input: 2, output: 0, cacheWrite: 0, cacheRead: 0)
            ]),
        ])
        let provider = CursorLiveProvider(
            tailer: tailer,
            fetch: { start, end in try box.next(start: start, end: end) },
            processSnapshot: { .init(running: true, pid: 1) },
            clock: { Date(timeIntervalSince1970: Double(clock.nowMs) / 1000.0) },
            nowMs: { clock.nowMs })

        _ = await provider.pollOnce()
        clock.nowMs += 60_000
        _ = await provider.pollOnce()
        #expect(box.starts.count == 2)
        #expect(box.starts[0] == box.starts[1])
        #expect(box.ends[1] > box.ends[0])
    }

    @Test func staleEnableRevisionIsIgnored() async {
        let tailer = UsageTailer()
        let provider = CursorLiveProvider(
            tailer: tailer,
            fetch: { _, _ in throw CursorLiveHTTPError.status(500) },
            processSnapshot: { .init(running: true, pid: 1) },
            clock: { Date(timeIntervalSince1970: 1) },
            nowMs: { 1_000 })

        await provider.setEnabled(true, revision: 1)
        await provider.setEnabled(false, revision: 2)
        await provider.setEnabled(true, revision: 1)
        #expect(await provider.isRunning() == false)
    }

    @Test func storeEnableDisableConvergesOff() async {
        let tailer = UsageTailer()
        let box = FetchBox(snaps: [
            CursorAggregateSnapshot(models: [
                "m": CursorModelTotals(input: 1, output: 0, cacheWrite: 0, cacheRead: 0)
            ])
        ])
        let provider = CursorLiveProvider(
            tailer: tailer,
            fetch: { _, _ in try box.next() },
            processSnapshot: { .init(running: true, pid: 1) },
            clock: { Date(timeIntervalSince1970: 1) },
            nowMs: { 1_000 })
        let store = await MainActor.run {
            LiveTraceStore(tailer: tailer, cursorLive: provider)
        }
        await MainActor.run {
            store.start()
            store.setCursorLiveEnabled(true)
            store.setCursorLiveEnabled(false)
        }
        for _ in 0..<50 {
            await Task.yield()
            if await provider.isRunning() == false { break }
        }
        #expect(await provider.isRunning() == false)
        #expect(box.calls == 0)
    }

    @Test func accountKeyChangeRebaselinesSilently() async {
        let now: Int64 = 1_800_000_000_000
        let tailer = UsageTailer(config: UsageTailerConfig(nowMs: { now }))
        let box = FetchBox(snaps: [
            CursorAggregateSnapshot(models: [
                "m": CursorModelTotals(input: 10, output: 0, cacheWrite: 0, cacheRead: 0)
            ], accountKey: "user-a"),
            CursorAggregateSnapshot(models: [
                "m": CursorModelTotals(input: 10_000, output: 0, cacheWrite: 0, cacheRead: 0)
            ], accountKey: "user-b"),
            CursorAggregateSnapshot(models: [
                "m": CursorModelTotals(input: 10_001, output: 0, cacheWrite: 0, cacheRead: 0)
            ], accountKey: "user-b"),
        ])
        let provider = CursorLiveProvider(
            tailer: tailer,
            fetch: { _, _ in try box.next() },
            processSnapshot: { .init(running: true, pid: 1) },
            clock: { Date(timeIntervalSince1970: Double(now) / 1000.0) },
            nowMs: { now })

        _ = await provider.pollOnce()
        _ = await provider.pollOnce()
        #expect(await tailer.eventsSnapshot().isEmpty)
        _ = await provider.pollOnce()
        let events = await tailer.eventsSnapshot()
        #expect(events.count == 1)
        #expect(events[0].input == 1)
    }

    @Test func looksLikeCursorCLIAcceptsAgentAndBinCursor() {
        #expect(CursorProcess.looksLikeCursorCLI(
            path: "/Users/me/.local/bin/cursor"))
        #expect(CursorProcess.looksLikeCursorCLI(
            path: "/Users/me/.local/bin/cursor-agent"))
        #expect(CursorProcess.looksLikeCursorCLI(
            path: "/Users/me/.local/share/cursor-agent/versions/2026.08.25-3e8eec8/node"))
        #expect(!CursorProcess.looksLikeCursorCLI(
            path: "/System/Library/PrivateFrameworks/TextInputUIMacHelper.framework/Versions/A/XPCServices/CursorUIViewService.xpc/Contents/MacOS/CursorUIViewService"))
        #expect(!CursorProcess.looksLikeCursorCLI(
            path: "/Applications/Cursor.app/Contents/MacOS/Cursor"))
        #expect(!CursorProcess.looksLikeCursorCLI(
            path: "/Users/me/git-repos/tokcat-worktrees/tokcat-cursor-live-session/native/build-local/Build/Products/Debug/Tokcat.app/Contents/MacOS/tokcat"))
        #expect(!CursorProcess.looksLikeCursorCLI(
            path: "/Users/me/.grok/bin/agent"))
        #expect(CursorProcess.looksLikeCursorCLI(
            path: "/opt/homebrew/Caskroom/cursor-cli/2026.08.25-3e8eec8/dist-package/node"))
        #expect(CursorProcess.looksLikeCursorCLI(
            path: "/usr/local/Caskroom/cursor-cli/2026.01.23-916f423/dist-package/cursor-agent"))
        #expect(!CursorProcess.looksLikeCursorCLI(
            path: "/Applications/Cursor.app/Contents/Resources/app/bin/code"))
        #expect(!CursorProcess.looksLikeCursorCLI(
            path: "/opt/homebrew/Caskroom/some-other-cli/1.0/dist-package/node"))
        #expect(CursorProcess.looksLikeCursorGUI(
            path: "/Applications/Cursor.app/Contents/MacOS/Cursor"))
        #expect(CursorProcess.looksLikeCursor(
            path: "/Applications/Cursor.app/Contents/MacOS/Cursor"))
        #expect(!CursorProcess.looksLikeCursorGUI(
            path: "/Applications/Cursor.app/Contents/Frameworks/Cursor Helper.app/Contents/MacOS/Cursor Helper"))
        #expect(!CursorProcess.looksLikeCursorGUI(
            path: "/Applications/Cursor.app/Contents/Resources/app/bin/code"))
        #expect(!CursorProcess.looksLikeCursor(
            path: "/Applications/Cursor.app/Contents/Resources/app/bin/code"))
        #expect(!CursorProcess.looksLikeCursorCLI(
            path: "/tmp/cursor-cli/unrelated-daemon"))
        #expect(!CursorProcess.looksLikeCursorCLI(
            path: "/tmp/cursor-agent/unrelated-daemon"))
        #expect(!CursorProcess.looksLikeCursorCLI(
            path: "/tmp/cursor-cli/readme-preview"))
        #expect(!CursorProcess.looksLikeCursorCLI(
            path: "/opt/homebrew/Caskroom/cursor-cli/2026.08.25-3e8eec8/unrelated"))
    }

    @Test func isGUICursorRejectsCursorUIViewService() {
        #expect(CursorProcess.isGUICursor(
            localizedName: "Cursor", bundleName: "Cursor.app",
            bundleId: "com.todesktop.230313mzl4w4u92"))
        #expect(CursorProcess.isGUICursor(
            localizedName: "Cursor", bundleName: nil, bundleId: nil))
        #expect(CursorProcess.isGUICursor(
            localizedName: nil, bundleName: "Cursor.app", bundleId: nil))
        #expect(!CursorProcess.isGUICursor(
            localizedName: "CursorUIViewService",
            bundleName: "CursorUIViewService.xpc",
            bundleId: "com.apple.TextInputUI.xpc.CursorUIViewService"))
        #expect(!CursorProcess.isGUICursor(
            localizedName: "Cursor Helper",
            bundleName: "Cursor Helper.app",
            bundleId: "com.github.Electron.helper"))
        #expect(!CursorProcess.isGUICursor(
            localizedName: nil, bundleName: nil,
            bundleId: "com.apple.TextInputUI.xpc.CursorUIViewService"))
    }

    @Test func looksLikeCursorCLIResolvesAgentSymlink() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokcat-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let target = dir.appendingPathComponent("cursor-agent")
        try Data("x".utf8).write(to: target)
        let agent = dir.appendingPathComponent("agent")
        try FileManager.default.createSymbolicLink(
            atPath: agent.path, withDestinationPath: target.path)
        #expect(CursorProcess.looksLikeCursorCLI(path: agent.path))

        let grok = dir.appendingPathComponent("grok")
        try Data("g".utf8).write(to: grok)
        let grokAgent = dir.appendingPathComponent("bin-agent")
        try FileManager.default.createSymbolicLink(
            atPath: grokAgent.path, withDestinationPath: grok.path)
        #expect(!CursorProcess.looksLikeCursorCLI(path: grokAgent.path))

        let appBin = dir.appendingPathComponent("Cursor.app/Contents/Resources/app/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: appBin, withIntermediateDirectories: true)
        let code = appBin.appendingPathComponent("code")
        try Data("c".utf8).write(to: code)
        let brewCursor = dir.appendingPathComponent("bin/cursor")
        try FileManager.default.createDirectory(
            at: brewCursor.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: brewCursor.path, withDestinationPath: code.path)
        #expect(!CursorProcess.looksLikeCursorCLI(path: brewCursor.path))
    }
}

private final class FetchBox: @unchecked Sendable {
    private let snaps: [CursorAggregateSnapshot]
    private(set) var calls = 0
    private(set) var starts: [Int64] = []
    private(set) var ends: [Int64] = []
    private var index = 0
    var throwStatus: Int?

    init(snaps: [CursorAggregateSnapshot]) { self.snaps = snaps }

    func next(start: Int64 = 0, end: Int64 = 0) throws -> CursorAggregatePayload {
        calls += 1
        starts.append(start)
        ends.append(end)
        if let throwStatus {
            throw CursorLiveHTTPError.status(throwStatus)
        }
        guard index < snaps.count else {
            throw CursorLiveHTTPError.status(500)
        }
        defer { index += 1 }
        return snaps[index].asPayload
    }
}

private final class ProcessBox: @unchecked Sendable {
    var running: Bool
    var pid: Int32?
    init(running: Bool, pid: Int32?) {
        self.running = running
        self.pid = pid
    }
    var snapshot: CursorProcessSnapshot { .init(running: running, pid: pid) }
}

private final class ClockBox: @unchecked Sendable {
    var nowMs: Int64
    init(nowMs: Int64) { self.nowMs = nowMs }
}
