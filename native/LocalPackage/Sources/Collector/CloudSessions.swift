import DataSource
import Foundation

// Cloud-session measurement surface (dev probe; not wired into the graph).
//
// Claude Code cloud sessions run either in Anthropic's VM or — when the
// account has a Remote Control bridge registered — on this Mac, inside
// `<repo>/.claude/worktrees/bridge-cse_<id>`. Only the bridged case leaves a
// transcript under `~/.claude/projects/`, and today the graph counts it as an
// ordinary `claude` session.
//
// The measurement has two axes, because both decide the answer:
//
//   marker   — what counts as evidence of a cloud session
//     .pathSlug        the project directory encodes the worktree path
//                      (`.claude/worktrees/bridge-cse_<id>`, which the slug
//                      flattens to `-claude-worktrees-bridge-cse-<id>`)
//     .cwdField        a row's structured `cwd` is the bridge worktree
//     .rawSubstring    the marker bytes appear anywhere in the file
//     .bridgeSessionID any `bridgeSessionId` whose value starts `cse_`
//
//   variant  — how much of each transcript is read to apply the marker
//     .noRead          path only, zero reads
//     .headSniff       first `headBytes`
//     .fullScan        whole file (ground truth, and the cost ceiling)
//
// `.rawSubstring` and `.bridgeSessionID` are the two traps: transcripts of
// ordinary local sessions quote the worktree path in shell output, and every
// session the Claude app bridges locally carries a `cse_` bridge id.
//
// `tokcat-dump cloud-probe` renders this as JSON; the numbers in the PR come
// from that command.

/// What counts as evidence that a transcript belongs to a cloud session.
public enum CloudMarker: String, Sendable, Codable, CaseIterable {
    case pathSlug
    case cwdField
    case rawSubstring
    case bridgeSessionID
}

/// How much of a transcript is read before the marker is applied.
public enum CloudScanVariant: String, Sendable, Codable, CaseIterable {
    case noRead
    case headSniff
    case fullScan
}

public struct CloudTranscriptReport: Sendable, Codable {
    public var path: String
    public var fileBytes: Int64
    public var messages: Int
    public var tokens: TokenBreakdown
    public var cost: Double
    public var dates: [String]
}

public struct CloudDayReport: Sendable, Codable {
    public var date: String
    public var messages: Int
    public var tokens: Int64
    public var cost: Double
}

public struct CloudScanReport: Sendable, Codable {
    public var marker: CloudMarker
    public var variant: CloudScanVariant
    /// Bytes read per candidate file before the marker decision.
    public var headBytes: Int
    public var roots: [String]
    public var filesCandidate: Int
    /// Sum of the on-disk sizes of every candidate transcript.
    public var candidateBytes: Int64
    /// Bytes this (marker, variant) pair actually read.
    public var bytesRead: Int64
    public var wallMs: Double
    public var transcripts: [CloudTranscriptReport]
    public var totalMessages: Int
    public var totalTokens: Int64
    public var totalCost: Double
    public var daily: [CloudDayReport]
}

public enum CloudSessionScanner {
    /// Scan the Claude transcript roots for cloud-session transcripts.
    ///
    /// `home` overrides HOME so fixtures replay deterministically.
    public static func scan(
        marker: CloudMarker,
        variant: CloudScanVariant,
        headBytes: Int = 8 * 1024,
        home: String? = nil
    ) -> CloudScanReport {
        let root = home ?? homeDir() ?? ""
        let started = DispatchTime.now().uptimeNanoseconds
        var files: [String] = []
        var roots: [String] = []
        for transcriptRoot in claudeTranscriptRoots(root) {
            let found = collectFiles(transcriptRoot) { path in
                let ext = rustExtension(path)
                return ext == "jsonl" || ext == "json"
            }
            if !found.isEmpty { roots.append(transcriptRoot) }
            files.append(contentsOf: found)
        }
        files.sort(by: utf8Less)

        var candidateBytes: Int64 = 0
        var bytesRead: Int64 = 0
        var detected: [String] = []
        for path in files {
            candidateBytes += fileSizeBytes(path)
            let effective = marker == .pathSlug ? CloudScanVariant.noRead : variant
            switch effective {
            case .noRead:
                if pathIsCloudWorktree(path) { detected.append(path) }
            case .headSniff:
                let (hit, read) = fileMatches(path, marker: marker, limit: headBytes)
                bytesRead += read
                if hit { detected.append(path) }
            case .fullScan:
                let (hit, read) = fileMatches(path, marker: marker, limit: nil)
                bytesRead += read
                if hit { detected.append(path) }
            }
        }

        var transcripts: [CloudTranscriptReport] = []
        var cloudMessages: [UsageMessage] = []
        for path in detected {
            let messages = applyPricing(dedupMessages(parseClaudeFile(path)))
            guard !messages.isEmpty else { continue }
            var tokens = TokenBreakdown()
            var cost = 0.0
            var dates = Set<String>()
            for message in messages {
                tokens.addClamped(message.tokens)
                cost += message.cost
                dates.insert(message.date)
            }
            cloudMessages.append(contentsOf: messages)
            transcripts.append(
                CloudTranscriptReport(
                    path: path,
                    fileBytes: fileSizeBytes(path),
                    messages: messages.count,
                    tokens: tokens,
                    cost: cost,
                    dates: dates.sorted(by: utf8Less)))
        }

        // Same aggregation the graph would use, so the daily rows are directly
        // comparable with `tokcat-dump graph` output.
        let payload = buildPayload(cloudMessages)
        let daily = payload.contributions.map {
            CloudDayReport(
                date: $0.date,
                messages: Int($0.totals.messages),
                tokens: $0.totals.tokens,
                cost: $0.totals.cost)
        }

        return CloudScanReport(
            marker: marker,
            variant: variant,
            headBytes: variant == .headSniff ? headBytes : 0,
            roots: roots,
            filesCandidate: files.count,
            candidateBytes: candidateBytes,
            bytesRead: bytesRead,
            wallMs: Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000.0,
            transcripts: transcripts,
            totalMessages: cloudMessages.count,
            totalTokens: cloudMessages.reduce(0) { satAdd($0, $1.tokens.total) },
            totalCost: cloudMessages.reduce(0.0) { $0 + $1.cost },
            daily: daily)
    }
}

// MARK: - Markers

/// The bridge worktree a cloud session runs in, as it appears in a real path
/// (`.../.claude/worktrees/bridge-cse_01TS…`). The project-directory slug
/// flattens it to `-claude-worktrees-bridge-cse-01TS…`.
private let cloudWorktreePathMarker = Array("worktrees/bridge-cse".utf8)
private let cloudWorktreeSlugMarker = Array("worktrees-bridge-cse".utf8)
private let bridgeSessionKey = Array("bridgeSessionId".utf8)
private let cloudEnvPrefix = Array("cse_".utf8)
/// How far past `bridgeSessionId` the `cse_` value may sit (JSON spacing slop).
private let bridgeValueWindow = 200
private let cwdKey = Array("\"cwd\"".utf8)

/// Zero-read marker: the project directory slug encodes the cloud worktree.
func pathIsCloudWorktree(_ path: String) -> Bool {
    path.contains("worktrees-bridge-cse") || path.contains("worktrees/bridge-cse")
}

/// Read `limit` bytes (nil = whole file) and apply `marker`.
func fileMatches(
    _ path: String, marker: CloudMarker, limit: Int?
) -> (Bool, Int64) {
    let data: Data
    let read: Int64
    if let limit {
        guard let handle = FileHandle(forReadingAtPath: path) else { return (false, 0) }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: max(limit, 1)), !head.isEmpty else {
            return (false, 0)
        }
        data = head
        read = Int64(head.count)
    } else {
        guard let whole = FileManager.default.contents(atPath: path) else { return (false, 0) }
        data = whole
        read = Int64(whole.count)
    }
    let hit = data.withUnsafeBytes { raw -> Bool in
        guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return false }
        let bytes = UnsafeBufferPointer(start: base, count: raw.count)
        switch marker {
        case .pathSlug:
            return pathIsCloudWorktree(path)
        case .rawSubstring:
            return containsCloudWorktreePath(bytes)
        case .cwdField:
            return containsCloudWorktreeCwd(bytes)
        case .bridgeSessionID:
            return containsBridgeCloudSessionID(bytes)
        }
    }
    return (hit, read)
}

/// Raw bytes anywhere: over-matches transcripts that merely quote the path.
func containsCloudWorktreePath(_ bytes: UnsafeBufferPointer<UInt8>) -> Bool {
    indexOfBytes(bytes, cloudWorktreePathMarker, from: 0) != nil
        || indexOfBytes(bytes, cloudWorktreeSlugMarker, from: 0) != nil
}

/// Structured check: some row's `cwd` value is the cloud worktree. Reads the
/// JSON string itself, so a path quoted inside a tool result — `git worktree
/// list` output, an `ls` error — stays a non-match.
func containsCloudWorktreeCwd(_ bytes: UnsafeBufferPointer<UInt8>) -> Bool {
    let quote = UInt8(ascii: "\"")
    let colon = UInt8(ascii: ":")
    let space = UInt8(ascii: " ")
    /// Longest `cwd` value worth considering (paths, not payloads).
    let valueLimit = 1024
    var cursor = 0
    while let key = indexOfBytes(bytes, cwdKey, from: cursor) {
        var i = key + cwdKey.count
        while i < bytes.count, bytes[i] == colon || bytes[i] == space { i += 1 }
        if i < bytes.count, bytes[i] == quote {
            let valueStart = i + 1
            var end = valueStart
            while end < bytes.count, bytes[end] != quote, end - valueStart < valueLimit {
                end += 1
            }
            if end < bytes.count, end - valueStart < valueLimit {
                let value = UnsafeBufferPointer(rebasing: bytes[valueStart..<end])
                if indexOfBytes(value, cloudWorktreePathMarker, from: 0) != nil
                    || indexOfBytes(value, cloudWorktreeSlugMarker, from: 0) != nil
                {
                    return true
                }
            }
        }
        cursor = key + cwdKey.count
    }
    return false
}

/// A `bridgeSessionId` whose value starts with the cloud-session-env prefix.
/// Over-matches: locally bridged sessions carry one too.
func containsBridgeCloudSessionID(_ bytes: UnsafeBufferPointer<UInt8>) -> Bool {
    var cursor = 0
    while let key = indexOfBytes(bytes, bridgeSessionKey, from: cursor) {
        let windowEnd = min(bytes.count, key + bridgeSessionKey.count + bridgeValueWindow)
        if indexOfBytes(bytes, cloudEnvPrefix, from: key, limit: windowEnd) != nil {
            return true
        }
        cursor = key + bridgeSessionKey.count
    }
    return false
}

/// First index of `needle` in `bytes` at or after `from`, bounded by `limit`.
func indexOfBytes(
    _ bytes: UnsafeBufferPointer<UInt8>, _ needle: [UInt8], from: Int, limit: Int? = nil
) -> Int? {
    guard !needle.isEmpty, bytes.count >= needle.count else { return nil }
    let end = min(bytes.count, limit ?? bytes.count) - needle.count
    var i = max(from, 0)
    while i <= end {
        if bytes[i] == needle[0] {
            var matched = true
            for j in 1..<needle.count where bytes[i + j] != needle[j] {
                matched = false
                break
            }
            if matched { return i }
        }
        i += 1
    }
    return nil
}

func fileSizeBytes(_ path: String) -> Int64 {
    var sb = stat()
    guard stat(path, &sb) == 0 else { return 0 }
    return max(Int64(sb.st_size), 0)
}
