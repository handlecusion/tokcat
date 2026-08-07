// Parity CLI:
//   tokcat-dump graph [--year YYYY] [--clients a,b]
//     prints the Swift-built UsagePayload as JSON, for diffing against the
//     Rust `usage_dump` bin via scripts/parity-check.sh.
//   tokcat-dump tail-sim --dir DIR [--window-secs N] [--now-ms N]
//     replays a fixture directory through the live tailer (one cold tick)
//     and dumps the event ring + trace as JSON, mirroring
//     `usage_dump tail-sim`. DIR is treated as a fake home: it may contain
//     .claude/projects/**/*.jsonl, .codex/sessions/**/*.jsonl,
//     .grok/sessions/**/updates.jsonl, and .hermes/state.db. Pass --now-ms
//     with fixtures carrying fixed timestamps for deterministic windows.
//   tokcat-dump tail-live [--ticks N] [--window-secs N]
//     dev smoke: runs the live tailer against the real environment for N
//     ticks (5s apart) and prints the observed rates.
import Collector
import DataSource
import Foundation

func fail(_ message: String, code: Int32 = 2) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

let usageText = """
usage: tokcat-dump graph [--year YYYY] [--clients a,b]
       tokcat-dump tail-sim --dir DIR [--window-secs N] [--now-ms N]
       tokcat-dump tail-live [--ticks N] [--window-secs N]
"""

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { fail(usageText) }
args.removeFirst()

func intFlag(_ name: String, _ args: [String], _ i: inout Int) -> Int64 {
    i += 1
    guard i < args.count, let v = Int64(args[i]) else {
        fail("\(name) requires an integer")
    }
    return v
}

switch command {
case "graph":
    var year = ""
    // Default to the full ten-client roster so both dump CLIs stay comparable
    // even if one side's registry grows first; --clients still overrides.
    var clients: [String]? = [
        "claude", "codex", "cursor", "opencode", "gemini",
        "copilot", "amp", "droid", "hermes", "grok",
    ]
    var i = 0
    while i < args.count {
        switch args[i] {
        case "--year":
            i += 1
            year = i < args.count ? args[i] : ""
        case "--clients":
            i += 1
            guard i < args.count else { fail("--clients requires a value") }
            clients = args[i].split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        default:
            fail("unknown arg: \(args[i])")
        }
        i += 1
    }

    do {
        let payload = try UsageGraph.run(year: year, clients: clients)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(payload)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    } catch {
        fail("\(error)", code: 1)
    }

case "profile":
    CollectorProfiler.run()

case "tail-sim":
    var dir: String?
    var windowSecs: Int64 = 600
    var nowMsOverride: Int64?
    var i = 0
    while i < args.count {
        switch args[i] {
        case "--dir":
            i += 1
            guard i < args.count else { fail("--dir requires a value") }
            dir = args[i]
        case "--window-secs":
            windowSecs = intFlag("--window-secs", args, &i)
        case "--now-ms":
            nowMsOverride = intFlag("--now-ms", args, &i)
        default:
            fail("unknown arg: \(args[i])")
        }
        i += 1
    }
    guard let dir else {
        fail("usage: tokcat-dump tail-sim --dir DIR [--window-secs N] [--now-ms N]")
    }

    struct TailSimDump: Encodable {
        var added: Int
        var events: [UsageEvent]
        var ratePerMin: Double
        var rateInWindow: Double
        var trace: [TraceBucket]
        var windowSecs: Int64

        enum CodingKeys: String, CodingKey {
            case added, events
            case ratePerMin = "rate_per_min"
            case rateInWindow = "rate_in_window"
            case trace
            case windowSecs = "window_secs"
        }
    }

    let semaphore = DispatchSemaphore(value: 0)
    var nowClosure: (@Sendable () -> Int64)?
    if let fixed = nowMsOverride {
        nowClosure = { fixed }
    }
    let config = UsageTailerConfig(simulatedHome: dir, nowMs: nowClosure)
    Task.detached {
        // A single cold tick: recent-mtime fixture files are read in full;
        // a Hermes state.db only gets its baseline stamped (no events),
        // matching the Rust tailer's cold behavior.
        let tailer = UsageTailer(config: config)
        let added = await tailer.tick()
        // Deterministic output ordering: scan order depends on readdir
        // order, so sort events by all fields and break trace ties
        // lexicographically (same as `usage_dump tail-sim`).
        var events = await tailer.eventsSnapshot()
        events.sort {
            ($0.tsMs, $0.client, $0.agent, $0.model, $0.input, $0.output)
                != ($1.tsMs, $1.client, $1.agent, $1.model, $1.input, $1.output)
                ? ($0.tsMs, $0.client, $0.agent, $0.model, $0.input, $0.output)
                    < ($1.tsMs, $1.client, $1.agent, $1.model, $1.input, $1.output)
                : ($0.cacheRead, $0.cacheWrite) < ($1.cacheRead, $1.cacheWrite)
        }
        var trace = await tailer.trace(windowSecs: windowSecs)
        trace.sort {
            if $0.tokens != $1.tokens { return $0.tokens > $1.tokens }
            if $0.client != $1.client { return $0.client < $1.client }
            if $0.agent != $1.agent { return $0.agent < $1.agent }
            return $0.model < $1.model
        }
        let dump = TailSimDump(
            added: added,
            events: events,
            ratePerMin: await tailer.ratePerMin(),
            rateInWindow: await tailer.rateInWindow(windowSecs),
            trace: trace,
            windowSecs: windowSecs)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            let data = try encoder.encode(dump)
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exit(1)
        }
        semaphore.signal()
    }
    semaphore.wait()

case "tail-live":
    var ticks = 3
    var windowSecs: Int64 = 600
    var i = 0
    while i < args.count {
        switch args[i] {
        case "--ticks":
            ticks = Int(intFlag("--ticks", args, &i))
        case "--window-secs":
            windowSecs = intFlag("--window-secs", args, &i)
        default:
            fail("unknown arg: \(args[i])")
        }
        i += 1
    }

    let semaphore = DispatchSemaphore(value: 0)
    Task.detached {
        let tailer = UsageTailer()
        for n in 1...max(ticks, 1) {
            let added = await tailer.tick()
            let rate60 = await tailer.ratePerMin()
            let rateWindow = await tailer.rateInWindow(windowSecs)
            let events = await tailer.eventsSnapshot().count
            print(
                "tick \(n): added=\(added) events=\(events) "
                    + "rate60s=\(rate60)/m rate\(windowSecs)s=\(rateWindow)/m")
            if n < ticks {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
        semaphore.signal()
    }
    semaphore.wait()

default:
    fail(usageText)
}
