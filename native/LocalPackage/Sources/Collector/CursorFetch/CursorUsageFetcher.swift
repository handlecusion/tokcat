import Foundation

// Port of cursor_usage.rs — the opt-in Cursor usage fetcher.
//
// Cursor — unlike every other client Tokcat reads — keeps no local
// token/cost ledger on disk; its usage lives server-side. This fetches
// per-event usage from Cursor's dashboard API and writes a local JSON cache
// the graph pipeline reads, so the rest stays purely local and synchronous.
//
// Opt-in only: it makes a network request to cursor.com authenticated with
// the user's own Cursor session token, which breaks Tokcat's otherwise
// local-first guarantee. Gated behind the `cursorUsage` settings toggle.

private let usageEventsURL = "https://cursor.com/api/dashboard/get-filtered-usage-events"
private let pageSize: Int64 = 250
private let historyDays: Int64 = 400
private let dayMs: Int64 = 86_400_000

/// One usage event flattened to the fields the contribution graph needs.
public struct CachedCursorEvent: Codable, Sendable {
    public var timestampMs: Int64
    public var model: String
    public var inputTokens: Int64
    public var outputTokens: Int64
    public var cacheReadTokens: Int64
    public var cost: Double

    enum CodingKeys: String, CodingKey {
        case timestampMs = "timestamp_ms"
        case model
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cacheReadTokens = "cache_read_tokens"
        case cost
    }

    public init(timestampMs: Int64, model: String, inputTokens: Int64,
                outputTokens: Int64, cacheReadTokens: Int64, cost: Double) {
        self.timestampMs = timestampMs
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cost = cost
    }
}

public struct CursorCache: Codable, Sendable {
    public var fetchedAtMs: Int64
    public var events: [CachedCursorEvent]

    enum CodingKeys: String, CodingKey {
        case fetchedAtMs = "fetched_at_ms"
        case events
    }

    public init(fetchedAtMs: Int64, events: [CachedCursorEvent]) {
        self.fetchedAtMs = fetchedAtMs
        self.events = events
    }
}

public enum CursorUsageFetcher {
    /// `~/.config/tokscale/cursor-cache/tokcat-events.json` — the same
    /// directory the legacy CSV cache lived in, so the graph parser finds it.
    public static func cachePath() throws -> URL {
        guard let home = quotaHomeDirectory() else {
            throw QuotaError("HOME is not set")
        }
        return cachePath(home: home)
    }

    static func cachePath(home: String) -> URL {
        URL(fileURLWithPath: home)
            .appendingPathComponent(".config")
            .appendingPathComponent("tokscale")
            .appendingPathComponent("cursor-cache")
            .appendingPathComponent("tokcat-events.json")
    }

    /// The token's `sub` claim doubles as the WorkOS user id in the session
    /// cookie.
    static func jwtSubject(_ token: String) throws -> String {
        let segments = token.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count > 1 else {
            throw QuotaError("Cursor token is not a JWT")
        }
        var encoded = String(segments[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while encoded.count % 4 != 0 { encoded.append("=") }
        guard let data = Data(base64Encoded: encoded) else {
            throw QuotaError("decode Cursor token payload: invalid base64")
        }
        guard let claims = JSONValue.parse(data) else {
            throw QuotaError("parse Cursor token claims: invalid JSON")
        }
        guard let sub = claims["sub"]?.asString else {
            throw QuotaError("Cursor token has no subject claim")
        }
        return sub
    }

    static func nowMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000.0)
    }

    /// Fetch all recent usage events from Cursor and rewrite the local JSON
    /// cache. Best-effort: throws a user-facing error the toggle can show.
    public static func refreshCache() async throws {
        let token: String
        switch CursorState.readAccessToken() {
        case .failure(let error): throw error
        case .success(let value): token = value
        }
        let sub = try jwtSubject(token)
        let cookie = "WorkosCursorSessionToken=\(sub)::\(token)"

        // Pad a day past "now" so today's events are always inside the window.
        let endMs = nowMs() + dayMs
        let startMs = endMs - historyDays * dayMs

        var events: [CachedCursorEvent] = []
        var page: Int64 = 1
        while true {
            var request = URLRequest(url: URL(string: usageEventsURL)!)
            request.timeoutInterval = 30
            request.httpMethod = "POST"
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
            // Cursor's dashboard endpoints reject cross-origin POSTs without
            // a matching Origin/Referer (CSRF guard).
            request.setValue("https://cursor.com", forHTTPHeaderField: "Origin")
            request.setValue("https://cursor.com/dashboard", forHTTPHeaderField: "Referer")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: [
                "teamId": 0,
                "startDate": String(startMs),
                "endDate": String(endMs),
                "page": page,
                "pageSize": pageSize,
            ])

            let status: Int
            let body: Data
            do {
                (status, body) = try await QuotaHTTP.send(request)
            } catch {
                throw QuotaError("Cursor usage request failed: \(error.localizedDescription)")
            }
            if status == 401 {
                throw QuotaError("Cursor session expired. Open Cursor and sign in again.")
            }
            if !(200..<300).contains(status) {
                throw QuotaError("Cursor usage API returned \(status).")
            }
            guard let parsed = JSONValue.parse(body) else {
                throw QuotaError("decode Cursor usage response: invalid JSON")
            }
            let batch = parsed["usageEventsDisplay"]?.asArray ?? []
            let total = parsed["totalUsageEventsCount"]?.asInt64 ?? 0
            if batch.isEmpty { break }
            for raw in batch {
                guard
                    let ts = raw["timestamp"]?.asString
                        .map({ $0.trimmingCharacters(in: .whitespaces) })
                        .flatMap(Int64.init)
                else { continue }
                let tokenUsage = raw["tokenUsage"]
                events.append(CachedCursorEvent(
                    timestampMs: ts,
                    model: raw["model"]?.asString ?? "cursor",
                    inputTokens: max(tokenUsage?["inputTokens"]?.asInt64 ?? 0, 0),
                    outputTokens: max(tokenUsage?["outputTokens"]?.asInt64 ?? 0, 0),
                    cacheReadTokens: max(tokenUsage?["cacheReadTokens"]?.asInt64 ?? 0, 0),
                    cost: max(tokenUsage?["totalCents"]?.asDouble ?? 0.0, 0.0) / 100.0))
            }
            if total > 0 && Int64(events.count) >= total { break }
            page += 1
            if page > 1000 { break }  // safety valve against endless pagination
        }

        try writeCache(CursorCache(fetchedAtMs: nowMs(), events: events))
    }

    /// Remove the JSON cache this module owns. Best-effort and intentionally
    /// leaves any legacy `usage*.csv` cache (which predates Tokcat and we
    /// didn't create) untouched.
    public static func clearCache() {
        if let path = try? cachePath() {
            try? FileManager.default.removeItem(at: path)
        }
    }

    static func clearCache(home: String) {
        try? FileManager.default.removeItem(at: cachePath(home: home))
    }

    static func writeCache(_ cache: CursorCache) throws {
        guard let home = quotaHomeDirectory() else {
            throw QuotaError("HOME is not set")
        }
        try writeCache(cache, home: home)
    }

    /// Atomic tmp+rename write, mirroring `write_cache`.
    static func writeCache(_ cache: CursorCache, home: String) throws {
        let path = cachePath(home: home)
        let dir = path.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true)
        } catch {
            throw QuotaError("create cursor cache dir: \(error.localizedDescription)")
        }
        let json: Data
        do {
            json = try JSONEncoder().encode(cache)
        } catch {
            throw QuotaError("serialize cursor cache: \(error.localizedDescription)")
        }
        let tmp = path.deletingPathExtension().appendingPathExtension("json.tmp")
        do {
            try json.write(to: tmp)
        } catch {
            throw QuotaError("write cursor cache: \(error.localizedDescription)")
        }
        do {
            // rename(2) semantics: atomically replace any existing file.
            if FileManager.default.fileExists(atPath: path.path) {
                _ = try FileManager.default.replaceItemAt(path, withItemAt: tmp)
            } else {
                try FileManager.default.moveItem(at: tmp, to: path)
            }
        } catch {
            throw QuotaError("commit cursor cache: \(error.localizedDescription)")
        }
    }
}
