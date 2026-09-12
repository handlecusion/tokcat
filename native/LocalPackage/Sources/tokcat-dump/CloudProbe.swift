// `tokcat-dump cloud-probe` — measures the three candidate sources for
// cloud-session usage. Dev-only: nothing here ships in the app, it exists so
// the numbers in the PR (and the eventual decision) are reproducible.
//
//   A. local transcripts   — classify cloud sessions inside `~/.claude/projects`
//                            across the (marker × read) matrix
//   B. cloud task list     — `codex cloud list --json` (local Codex auth)
//   C. quota windows       — the OAuth usage endpoints Tokcat already calls
//
// Output is one JSON object on stdout.
import Collector
import DataSource
import Foundation

struct CloudProbeOutput: Encodable {
    var measuredAt: String
    var sourceA: SourceA
    var sourceB: SourceB?
    var sourceC: SourceC?

    enum CodingKeys: String, CodingKey {
        case measuredAt = "measured_at"
        case sourceA = "source_a"
        case sourceB = "source_b"
        case sourceC = "source_c"
    }
}

struct SourceA: Encodable {
    var claudeParseWallMs: Double
    var claudeParseMessages: Int
    var claudeDays: Int
    /// Ground truth: (cwdField, fullScan).
    var truthTranscripts: [String]
    var truthTokens: Int64
    var rows: [MatrixRow]
    var claudeDaily: [DailyTotals]
    var share: [CloudShare]

    enum CodingKeys: String, CodingKey {
        case claudeParseWallMs = "claude_parse_wall_ms"
        case claudeParseMessages = "claude_parse_messages"
        case claudeDays = "claude_days"
        case truthTranscripts = "truth_transcripts"
        case truthTokens = "truth_tokens"
        case rows
        case claudeDaily = "claude_daily"
        case share
    }
}

/// One (marker, variant) cell of the matrix.
struct MatrixRow: Encodable {
    var marker: String
    var variant: String
    var headBytes: Int
    var transcripts: Int
    var tokens: Int64
    var messages: Int
    var cost: Double
    /// Bytes read across all candidate transcripts.
    var bytesRead: Int64
    var candidateBytes: Int64
    var wallMs: Double
    var truePositives: Int
    var falsePositives: Int
    /// Accuracy is only meaningful when the ground-truth cell ran too.
    var missed: Int?
    var precision: Double?
    var recall: Double?
    /// Files the row flagged that ground truth did not.
    var falsePositivePaths: [String]

    enum CodingKeys: String, CodingKey {
        case marker, variant, transcripts, tokens, messages, cost, precision, recall, missed
        case headBytes = "head_bytes"
        case bytesRead = "bytes_read"
        case candidateBytes = "candidate_bytes"
        case wallMs = "wall_ms"
        case truePositives = "true_positives"
        case falsePositives = "false_positives"
        case falsePositivePaths = "false_positive_paths"
    }
}

struct DailyTotals: Encodable {
    var date: String
    var tokens: Int64
    var messages: Int
    var cost: Double
}

struct CloudShare: Encodable {
    var date: String
    var cloudTokens: Int64
    var claudeTokens: Int64
    var share: Double

    enum CodingKeys: String, CodingKey {
        case date
        case cloudTokens = "cloud_tokens"
        case claudeTokens = "claude_tokens"
        case share
    }
}

struct SourceB: Encodable {
    var command: String
    var exitCode: Int32?
    var wallMs: Double
    var stdoutBytes: Int
    var tasks: Int
    var taskFields: [String]
    var usageBearingFields: [String]
    var detail: String?

    enum CodingKeys: String, CodingKey {
        case command
        case exitCode = "exit_code"
        case wallMs = "wall_ms"
        case stdoutBytes = "stdout_bytes"
        case tasks
        case taskFields = "task_fields"
        case usageBearingFields = "usage_bearing_fields"
        case detail
    }
}

struct SourceC: Encodable {
    var claude: AgentUsageSnapshot?
    var claudeWallMs: Double
    var codex: AgentUsageSnapshot?
    var codexWallMs: Double
    var perDayTokenSeries: Bool
    var note: String

    enum CodingKeys: String, CodingKey {
        case claude
        case claudeWallMs = "claude_wall_ms"
        case codex
        case codexWallMs = "codex_wall_ms"
        case perDayTokenSeries = "per_day_token_series"
        case note
    }
}

func runCloudProbe(days: Int, only: [String], skipNetwork: Bool) {
    // URLSession needs the concurrency runtime alive, so run the whole probe
    // in a detached task and hold the CLI open, same shape as `tail-sim`.
    let semaphore = DispatchSemaphore(value: 0)
    Task.detached {
        let output = CloudProbeOutput(
            measuredAt: ISO8601DateFormatter().string(from: Date()),
            sourceA: measureSourceA(days: days, only: only),
            sourceB: skipNetwork ? nil : measureSourceB(),
            sourceC: skipNetwork ? nil : await measureSourceC())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        do {
            let data = try encoder.encode(output)
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        } catch {
            fail("encode cloud-probe output: \(error)", code: 1)
        }
        semaphore.signal()
    }
    semaphore.wait()
}

/// `--only marker:variant[:headBytes]` — restrict the matrix so each cell can
/// be measured in its own process (`/usr/bin/time -l` reports process totals,
/// which a combined run hides).
private func parseOnly(_ specs: [String]) -> [MatrixCell]? {
    guard !specs.isEmpty else { return nil }
    var cells: [MatrixCell] = []
    for spec in specs {
        let parts = spec.split(separator: ":").map(String.init)
        guard parts.count >= 2,
            let marker = CloudMarker(rawValue: parts[0]),
            let variant = CloudScanVariant(rawValue: parts[1])
        else {
            fail("--only expects marker:variant[:headBytes], got \(spec)")
        }
        let head = parts.count > 2 ? Int(parts[2]) ?? 8 * 1024 : 8 * 1024
        cells.append(MatrixCell(marker: marker, variant: variant, headBytes: head))
    }
    return cells
}

// MARK: - A. local transcripts

private struct MatrixCell {
    var marker: CloudMarker
    var variant: CloudScanVariant
    var headBytes: Int
}

private let matrix: [MatrixCell] = [
    // Zero-read path classification.
    MatrixCell(marker: .pathSlug, variant: .noRead, headBytes: 0),
    // Structured cwd, small and larger head budgets, then the ground truth.
    MatrixCell(marker: .cwdField, variant: .headSniff, headBytes: 8 * 1024),
    MatrixCell(marker: .cwdField, variant: .headSniff, headBytes: 64 * 1024),
    MatrixCell(marker: .cwdField, variant: .fullScan, headBytes: 0),
    // Raw substring: cheap, but quotes in shell output look identical.
    MatrixCell(marker: .rawSubstring, variant: .headSniff, headBytes: 8 * 1024),
    MatrixCell(marker: .rawSubstring, variant: .fullScan, headBytes: 0),
    // The loose bridge-id marker, for the over-attribution cost.
    MatrixCell(marker: .bridgeSessionID, variant: .headSniff, headBytes: 8 * 1024),
    MatrixCell(marker: .bridgeSessionID, variant: .fullScan, headBytes: 0),
]

private func measureSourceA(days: Int, only: [String]) -> SourceA {
    let cells = parseOnly(only) ?? matrix
    let parseStart = DispatchTime.now().uptimeNanoseconds
    let claude = try? UsageGraph.run(year: "", clients: ["claude"])
    let parseMs = Double(DispatchTime.now().uptimeNanoseconds - parseStart) / 1_000_000.0

    var reports: [CloudScanReport] = []
    for cell in cells {
        reports.append(
            CloudSessionScanner.scan(
                marker: cell.marker, variant: cell.variant, headBytes: cell.headBytes))
    }
    let truthReport = reports.first {
        $0.marker == .cwdField && $0.variant == .fullScan
    }
    let truthPaths = Set(truthReport?.transcripts.map(\.path) ?? [])
    let truthTokens = truthReport?.totalTokens ?? 0
    let truthMeasured = reports.contains {
        $0.marker == .cwdField && $0.variant == .fullScan
    }

    let rows = zip(cells, reports).map { cell, report -> MatrixRow in
        let paths = report.transcripts.map(\.path)
        let flagged = Set(paths)
        let falsePositives = flagged.subtracting(truthPaths).sorted()
        let truePositives = flagged.intersection(truthPaths).count
        return MatrixRow(
            marker: cell.marker.rawValue,
            variant: cell.variant.rawValue,
            headBytes: cell.headBytes,
            transcripts: paths.count,
            tokens: report.totalTokens,
            messages: report.totalMessages,
            cost: report.totalCost,
            bytesRead: report.bytesRead,
            candidateBytes: report.candidateBytes,
            wallMs: report.wallMs,
            truePositives: truePositives,
            falsePositives: falsePositives.count,
            missed: truthMeasured ? truthPaths.subtracting(flagged).count : nil,
            precision: truthMeasured
                ? (paths.isEmpty ? 0 : Double(truePositives) / Double(paths.count)) : nil,
            recall: truthMeasured
                ? (truthPaths.isEmpty ? 1 : Double(truePositives) / Double(truthPaths.count))
                : nil,
            falsePositivePaths: falsePositives)
    }

    // Every day the plain claude graph knows about, so the cloud share is
    // comparable instead of silently zero outside the recent window.
    var claudeTokensByDate: [String: Int64] = [:]
    var claudeDaily: [DailyTotals] = []
    for contribution in claude?.contributions ?? [] {
        claudeTokensByDate[contribution.date] = contribution.totals.tokens
    }
    for contribution in (claude?.contributions ?? []).suffix(days) {
        claudeDaily.append(
            DailyTotals(
                date: contribution.date,
                tokens: contribution.totals.tokens,
                messages: Int(contribution.totals.messages),
                cost: contribution.totals.cost))
    }
    let share = (truthReport?.daily ?? []).compactMap { day -> CloudShare? in
        guard let claudeTokens = claudeTokensByDate[day.date], claudeTokens > 0 else {
            return nil
        }
        return CloudShare(
            date: day.date,
            cloudTokens: day.tokens,
            claudeTokens: claudeTokens,
            share: Double(day.tokens) / Double(claudeTokens))
    }

    return SourceA(
        claudeParseWallMs: parseMs,
        claudeParseMessages: Int((claude?.contributions ?? []).reduce(Int64(0)) {
            $0 + $1.totals.messages
        }),
        claudeDays: claude?.contributions.count ?? 0,
        truthTranscripts: truthPaths.sorted(),
        truthTokens: truthTokens,
        rows: rows,
        claudeDaily: claudeDaily,
        share: share)
}

// MARK: - B. codex cloud task list

private func measureSourceB() -> SourceB {
    let args = ["cloud", "list", "--json", "--limit", "20"]
    let result = runCommand("/usr/bin/env", ["codex"] + args, timeout: 30)
    guard let result else {
        return SourceB(
            command: "codex cloud list --json --limit 20", exitCode: nil, wallMs: 0,
            stdoutBytes: 0, tasks: 0, taskFields: [], usageBearingFields: [],
            detail: "codex not found or timed out")
    }
    var fields: [String] = []
    var usageFields: [String] = []
    var tasks = 0
    if let json = try? JSONSerialization.jsonObject(with: result.stdout) as? [String: Any] {
        if let list = json["tasks"] as? [[String: Any]] {
            tasks = list.count
            var keys = Set<String>()
            for task in list { keys.formUnion(task.keys) }
            fields = keys.sorted()
        }
        usageFields = fields.filter {
            let lowered = $0.lowercased()
            return lowered.contains("token") || lowered.contains("usage")
                || lowered.contains("cost")
        }
    }
    return SourceB(
        command: "codex cloud list --json --limit 20",
        exitCode: result.exitCode,
        wallMs: result.wallMs,
        stdoutBytes: result.stdout.count,
        tasks: tasks,
        taskFields: fields,
        usageBearingFields: usageFields,
        detail: result.exitCode == 0 ? nil : String(data: result.stderr, encoding: .utf8))
}

// MARK: - C. quota windows

private func measureSourceC() async -> SourceC {
    let claudeStart = DispatchTime.now().uptimeNanoseconds
    let claude: AgentUsageSnapshot? = await ClaudeQuotaProvider.fetch()
    let claudeMs = Double(DispatchTime.now().uptimeNanoseconds - claudeStart) / 1_000_000.0
    let codexStart = DispatchTime.now().uptimeNanoseconds
    let codex: AgentUsageSnapshot? = await CodexQuotaProvider.fetch()
    let codexMs = Double(DispatchTime.now().uptimeNanoseconds - codexStart) / 1_000_000.0
    // Both endpoints answer with window utilization (`used_percent`) and a
    // reset instant. Neither returns tokens, and neither carries a per-day
    // series, so nothing here can be summed into a daily token graph.
    let note = """
        Claude/Codex usage endpoints report window utilization (percent + reset), \
        not tokens. A per-day cloud total would have to be inferred from \
        utilization deltas against an undisclosed plan budget.
        """
    return SourceC(
        claude: claude, claudeWallMs: claudeMs,
        codex: codex, codexWallMs: codexMs,
        perDayTokenSeries: false, note: note)
}

// MARK: - subprocess

private struct CommandResult {
    var exitCode: Int32
    var stdout: Data
    var stderr: Data
    var wallMs: Double
}

private func runCommand(
    _ launchPath: String, _ arguments: [String], timeout: Double
) -> CommandResult? {
    guard FileManager.default.isExecutableFile(atPath: launchPath) else { return nil }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: launchPath)
    process.arguments = arguments
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    let start = DispatchTime.now().uptimeNanoseconds
    do {
        try process.run()
    } catch {
        return nil
    }
    let deadline = Date().addingTimeInterval(timeout)
    while process.isRunning && Date() < deadline {
        usleep(20_000)
    }
    if process.isRunning {
        process.terminate()
        return nil
    }
    let out = (try? stdout.fileHandleForReading.readToEnd()) ?? Data()
    let err = (try? stderr.fileHandleForReading.readToEnd()) ?? Data()
    return CommandResult(
        exitCode: process.terminationStatus,
        stdout: out,
        stderr: err,
        wallMs: Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000.0)
}
