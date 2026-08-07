import DataSource
import Foundation

// Port of the Grok Build quota provider in agent_usage.rs (:361-461,
// 1528-2200): auth.json credential candidates, the grpc-web billing ladder,
// REST task-usage/subscription fallbacks, and the agent-stdio billing RPC.

private let grokSubscriptionsURL = "https://grok.com/rest/subscriptions"
private let grokTaskUsageURL = "https://grok.com/rest/tasks/usage"
private let grokBillingGrpcURL =
    "https://grok.com/grok_api_v2.GrokBuildBilling/GetGrokCreditsConfig"
private let grokUserAgent = "Grok Build"

struct GrokCredentials {
    var token: String
    var email: String?
}

struct GrokMetric {
    var label: String
    var usedPercent: Double
    var remainingPercent: Double
    var remainingLabel: String?
    var resetsAt: String?
}

enum GrokProtoValue {
    case varint(UInt64)
    case fixed32(UInt32)
    case fixed64
    case bytes([UInt8])
}

public enum GrokQuotaProvider {
    /// Whether Grok Build OAuth credentials exist under `$GROK_HOME/auth.json`
    /// (default `~/.grok/auth.json`). Missing file hides the Grok tile.
    public static var isConfigured: Bool {
        var isDirectory: ObjCBool = false
        let path = grokAuthPath().path
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
    }

    public static func fetch() async -> AgentUsageSnapshot {
        do {
            return try await fetchInner()
        } catch {
            return AgentUsageSnapshot(
                clientId: "grok", source: "oauth",
                updatedAt: QuotaDates.rfc3339Millis(Date()),
                identity: nil, windows: [], credits: nil,
                error: "\(error)")
        }
    }

    static func grokAuthPath() -> URL {
        grokHome().appendingPathComponent("auth.json")
    }

    static func fetchInner() async throws -> AgentUsageSnapshot {
        let credentials = try loadGrokCredentials()
        var errors: [String] = []
        var planOnly: (plan: String?, email: String?)?
        let now = Date()

        for (index, credential) in credentials.enumerated() {
            do {
                let (plan, email, windows) = try await fetchGrokNetworkUsage(credential)
                if !windows.isEmpty {
                    return AgentUsageSnapshot(
                        clientId: "grok", source: "oauth",
                        updatedAt: QuotaDates.rfc3339Millis(now),
                        identity: AgentIdentity(
                            email: email ?? credential.email, plan: plan),
                        windows: windows, credits: nil, error: nil)
                }
                if planOnly == nil {
                    planOnly = (plan, email ?? credential.email)
                }
            } catch {
                errors.append("Grok credential #\(index + 1) failed: \(error)")
            }
        }

        // Agent stdio billing has no credential context — skip when multiple
        // accounts are present (same policy as tokscale).
        if credentials.count == 1 {
            if let billing = fetchGrokAgentBilling(timeout: 4) {
                var metrics: [GrokMetric] = []
                if let metric = parseGrokBillingJSONMetric(billing) {
                    metrics.append(metric)
                }
                collectGrokTaskUsageMetrics(billing, into: &metrics)
                if !metrics.isEmpty {
                    let (plan, email) = planOnly ?? (nil, credentials[0].email)
                    return AgentUsageSnapshot(
                        clientId: "grok", source: "oauth",
                        updatedAt: QuotaDates.rfc3339Millis(now),
                        identity: AgentIdentity(email: email, plan: plan),
                        windows: metrics.map { mapGrokMetric($0, now: now) },
                        credits: nil, error: nil)
                }
            } else {
                errors.append("Grok agent billing RPC unavailable")
            }
        } else if credentials.count > 1 {
            errors.append("Grok agent billing fallback skipped: multiple credentials present")
        }

        if let (plan, email) = planOnly {
            // Plan-only: show SuperGrok identity even when percent metrics
            // fail. Do not set error — AgentLimitsCard prefers error over
            // identity and would hide a valid plan behind a red "Error".
            return AgentUsageSnapshot(
                clientId: "grok", source: "oauth",
                updatedAt: QuotaDates.rfc3339Millis(now),
                identity: AgentIdentity(email: email, plan: plan),
                windows: [], credits: nil, error: nil)
        }

        let detail = errors.isEmpty
            ? "no usage or active subscription data returned"
            : errors.joined(separator: "; ")
        throw QuotaError("Grok usage unavailable: \(detail)")
    }

    // MARK: Credentials

    static func loadGrokCredentials() throws -> [GrokCredentials] {
        guard let content = try? String(contentsOf: grokAuthPath(), encoding: .utf8) else {
            throw QuotaError("Grok auth.json not found. Run `grok login` to authenticate.")
        }
        guard let doc = JSONValue.parse(content) else {
            throw QuotaError("parse Grok auth.json: invalid JSON")
        }
        return try grokCredentialCandidates(from: doc)
    }

    /// Port of `grok_credential_candidates_from_value` (:1576-1610).
    /// serde_json's Map is a BTreeMap, so scopes are visited in sorted key
    /// order; the priority sort is stable, so auth.x.ai scopes lead while
    /// keeping that order within each priority class.
    static func grokCredentialCandidates(from doc: JSONValue) throws -> [GrokCredentials] {
        guard let entries = doc.asObject else {
            throw QuotaError("Grok auth.json must contain an object.")
        }
        var candidates: [(priority: Int, credentials: GrokCredentials)] = []
        for scope in entries.keys.sorted() {
            guard let entry = entries[scope]?.asObject else { continue }
            guard let token = entry["key"]?.asString, !token.isEmpty else { continue }
            let email = entry["email"]?.asString.flatMap { $0.isEmpty ? nil : $0 }
            let priority = scope.contains("auth.x.ai") ? 0 : 1
            candidates.append((priority, GrokCredentials(token: token, email: email)))
        }
        let sorted = candidates.filter { $0.priority == 0 } + candidates.filter { $0.priority == 1 }
        let credentials = sorted.map(\.credentials)
        if credentials.isEmpty {
            throw QuotaError("No Grok token found. Run `grok login`.")
        }
        return credentials
    }

    // MARK: Network ladder

    private static func bearerRequest(token: String, url: String) -> URLRequest {
        var request = URLRequest(url: URL(string: url)!)
        request.timeoutInterval = 12
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("xai-grok-cli", forHTTPHeaderField: "X-XAI-Token-Auth")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(grokUserAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    /// Port of `fetch_grok_network_usage` (:1625-1677): billing gRPC first,
    /// task-usage REST as the metrics fallback, subscriptions for the plan.
    static func fetchGrokNetworkUsage(
        _ credentials: GrokCredentials
    ) async throws -> (plan: String?, email: String?, windows: [UsageWindow]) {
        var plan: String?
        var metrics: [GrokMetric] = []
        var errors: [String] = []
        let now = Date()

        do {
            let body = try await fetchGrokBillingGrpc(token: credentials.token)
            if let metric = parseGrokGrpcBillingMetric(Array(body)) {
                metrics.append(metric)
            } else {
                errors.append("Grok billing response was not recognized")
            }
        } catch {
            errors.append("Grok billing request failed: \(error)")
        }

        if metrics.isEmpty {
            do {
                let taskUsage = try await fetchGrokTaskUsage(token: credentials.token)
                collectGrokTaskUsageMetrics(taskUsage, into: &metrics)
            } catch {
                errors.append("Grok task usage request failed: \(error)")
            }
        }

        do {
            let subscriptions = try await fetchGrokSubscriptions(token: credentials.token)
            plan = parseGrokSubscriptionPlan(subscriptions)
        } catch {
            errors.append("Grok subscriptions request failed: \(error)")
        }

        if metrics.isEmpty && plan == nil {
            let detail = errors.isEmpty
                ? "no usage or active subscription data returned"
                : errors.joined(separator: "; ")
            throw QuotaError(detail)
        }

        return (plan, credentials.email, metrics.map { mapGrokMetric($0, now: now) })
    }

    static func fetchGrokSubscriptions(token: String) async throws -> JSONValue {
        let request = bearerRequest(token: token, url: grokSubscriptionsURL)
        let (status, body): (Int, Data)
        do {
            (status, body) = try await QuotaHTTP.send(request)
        } catch {
            throw QuotaError(error.localizedDescription)
        }
        if !(200..<300).contains(status) {
            throw QuotaError("HTTP \(status)")
        }
        guard let text = String(data: body, encoding: .utf8) else {
            throw QuotaError("invalid UTF-8")
        }
        if text.drop(while: { $0.isWhitespace }).first == "<" {
            throw QuotaError("returned HTML")
        }
        guard let value = JSONValue.parse(text) else {
            throw QuotaError("invalid JSON")
        }
        return value
    }

    static func fetchGrokTaskUsage(token: String) async throws -> JSONValue {
        let request = bearerRequest(token: token, url: grokTaskUsageURL)
        let (status, body): (Int, Data)
        do {
            (status, body) = try await QuotaHTTP.send(request)
        } catch {
            throw QuotaError(error.localizedDescription)
        }
        if status == 401 || status == 403 {
            throw QuotaError("NEEDS_AUTH")
        }
        if !(200..<300).contains(status) {
            throw QuotaError("HTTP \(status)")
        }
        guard let value = JSONValue.parse(body) else {
            throw QuotaError("invalid JSON")
        }
        return value
    }

    static func fetchGrokBillingGrpc(token: String) async throws -> Data {
        var request = URLRequest(url: URL(string: grokBillingGrpcURL)!)
        request.timeoutInterval = 12
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("xai-grok-cli", forHTTPHeaderField: "X-XAI-Token-Auth")
        request.setValue("application/grpc-web+proto", forHTTPHeaderField: "Accept")
        request.setValue("application/grpc-web+proto", forHTTPHeaderField: "Content-Type")
        request.setValue(grokUserAgent, forHTTPHeaderField: "User-Agent")
        // Empty request message in a grpc-web frame: flag 0 + zero length.
        request.httpBody = Data([0, 0, 0, 0, 0])

        let (status, body): (Int, Data)
        do {
            (status, body) = try await QuotaHTTP.send(request)
        } catch {
            throw QuotaError(error.localizedDescription)
        }
        if status == 401 || status == 403 {
            throw QuotaError("NEEDS_AUTH")
        }
        if !(200..<300).contains(status) {
            throw QuotaError("HTTP \(status)")
        }
        return body
    }

    // MARK: Agent stdio fallback

    /// Port of `resolve_grok_binary` (:1732-1748): packaged apps do not
    /// source shell rc, so prefer the install locations Grok Build uses.
    static func resolveGrokBinary() -> String {
        let env = ProcessInfo.processInfo.environment
        if let home = env["GROK_HOME"], !home.isEmpty {
            let candidate = URL(fileURLWithPath: home)
                .appendingPathComponent("bin").appendingPathComponent("grok").path
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate, isDirectory: &isDirectory),
               !isDirectory.boolValue {
                return candidate
            }
        }
        if let home = env["HOME"], !home.isEmpty {
            let candidate = URL(fileURLWithPath: home)
                .appendingPathComponent(".grok/bin/grok").path
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate, isDirectory: &isDirectory),
               !isDirectory.boolValue {
                return candidate
            }
        }
        return "grok"
    }

    /// Port of `fetch_grok_agent_billing` (:1750-1802): spawn
    /// `grok agent --no-leader stdio`, speak two JSON-RPC lines, wait for
    /// the id=2 response within `timeout`, then kill the child.
    static func fetchGrokAgentBilling(timeout: TimeInterval) -> JSONValue? {
        let binary = resolveGrokBinary()
        let process = Process()
        if binary == "grok" {
            // Bare name: PATH lookup via env (Foundation.Process has none).
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["grok", "agent", "--no-leader", "stdio"]
        } else {
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = ["agent", "--no-leader", "stdio"]
        }
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        defer { killAndReap(process) }

        let lines = LineChannel()
        let readBox = UncheckedHandleBox(handle: stdout.fileHandleForReading)
        Thread.detachNewThread {
            while true {
                let chunk = readBox.handle.availableData
                if chunk.isEmpty { break }
                lines.append(chunk)
            }
            lines.finish()
        }

        let initialize: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": [
                "protocolVersion": "1",
                "clientCapabilities": [
                    "fs": ["readTextFile": false, "writeTextFile": false],
                    "terminal": false,
                ],
            ],
        ]
        let billing: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 2,
            "method": "x.ai/billing",
            "params": [String: Any](),
        ]
        guard
            let initData = try? JSONSerialization.data(withJSONObject: initialize),
            let billingData = try? JSONSerialization.data(withJSONObject: billing)
        else { return nil }
        let writer = stdin.fileHandleForWriting
        do {
            try writer.write(contentsOf: initData + Data("\n".utf8))
            try writer.write(contentsOf: billingData + Data("\n".utf8))
        } catch {
            return nil
        }

        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { return nil }
            guard let line = lines.next(timeout: remaining) else { return nil }
            guard let value = JSONValue.parse(line) else { continue }
            if value["id"]?.asInt64 == 2 {
                if value["error"] != nil { return nil }
                return value["result"]
            }
        }
    }

    // MARK: Metric mapping

    /// Port of `map_grok_metric` (:1822-1834).
    static func mapGrokMetric(_ metric: GrokMetric, now: Date) -> UsageWindow {
        let resets = metric.resetsAt.flatMap(QuotaDates.parse)
        let resetText = metric.remainingLabel
            ?? resets.map { quotaResetText(reset: $0, now: now) }
        return UsageWindow(
            label: metric.label,
            usedPercent: metric.usedPercent,
            remainingPercent: metric.remainingPercent,
            resetsAt: resets.map(QuotaDates.rfc3339Millis),
            resetText: resetText)
    }

    static func grokTitleWords(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .filter { !$0.isEmpty }
            .map { word -> String in
                let lower = word.lowercased()
                return lower.prefix(1).uppercased() + lower.dropFirst()
            }
            .joined(separator: " ")
    }

    static func normalizeGrokSubscriptionTier(_ raw: String) -> String {
        var trimmed = raw
        if trimmed.hasPrefix("SUBSCRIPTION_TIER_") {
            trimmed = String(trimmed.dropFirst("SUBSCRIPTION_TIER_".count))
        }
        if trimmed.hasPrefix("TIER_") {
            trimmed = String(trimmed.dropFirst("TIER_".count))
        }
        return grokTitleWords(trimmed)
    }

    /// Real responses use `SUBSCRIPTION_STATUS_ACTIVE`; older/simple APIs
    /// may use plain `active`. Avoid matching `…_INACTIVE`.
    static func grokSubscriptionIsActive(_ status: String) -> Bool {
        let upper = status.trimmingCharacters(in: .whitespaces).uppercased()
        return upper == "ACTIVE" || upper.hasSuffix("STATUS_ACTIVE")
    }

    static func parseGrokSubscriptionPlan(_ value: JSONValue) -> String? {
        guard let subscriptions = value["subscriptions"]?.asArray else { return nil }
        let chosen = subscriptions.first { sub in
            sub["status"]?.asString.map(grokSubscriptionIsActive) ?? false
        }
        guard let tier = chosen?["tier"]?.asString else { return nil }
        return normalizeGrokSubscriptionTier(tier)
    }

    /// Port of `grok_numeric_value`: finite number, numeric string, or a
    /// nested `{ "val": … }` / `{ "value": … }` wrapper.
    static func grokNumericValue(_ value: JSONValue) -> Double? {
        if let number = value.asDouble {
            return number.isFinite ? number : nil
        }
        if let text = value.asString {
            guard let number = Double(text), number.isFinite else { return nil }
            return number
        }
        if let object = value.asObject {
            if let inner = object["val"] ?? object["value"] {
                return grokNumericValue(inner)
            }
        }
        return nil
    }

    static func grokNumber(at path: [String], in value: JSONValue) -> Double? {
        var current = value
        for segment in path {
            guard let next = current[segment] else { return nil }
            current = next
        }
        return grokNumericValue(current)
    }

    static func grokString(at path: [String], in value: JSONValue) -> String? {
        var current = value
        for segment in path {
            guard let next = current[segment] else { return nil }
            current = next
        }
        return current.asString
    }

    static func grokEpoch(at path: [String], in value: JSONValue) -> String? {
        grokNumber(at: path, in: value).map { grokEpochToRFC3339(Int64($0)) }
    }

    static func formatGrokCents(_ cents: Double) -> String {
        String(format: "$%.2f", cents / 100.0)
    }

    /// Port of `grok_cycle_label` (:1914-1935).
    static func grokCycleLabel(start: String?, end: String?) -> String {
        guard let start, let end,
              let startDate = QuotaDates.parse(start),
              let endDate = QuotaDates.parse(end)
        else { return "Credits" }
        let days = Int64(endDate.timeIntervalSince(startDate) / 86_400)
        if (6...8).contains(days) { return "Weekly" }
        if (27...33).contains(days) { return "Monthly" }
        return "Credits"
    }

    /// Port of `parse_grok_billing_json_metric` (:1937-1946): the object
    /// itself, else a depth-first search of arrays/objects (objects in
    /// sorted key order, matching serde_json's BTreeMap).
    static func parseGrokBillingJSONMetric(_ value: JSONValue) -> GrokMetric? {
        if let metric = parseGrokBillingJSONObject(value) {
            return metric
        }
        if let items = value.asArray {
            for item in items {
                if let metric = parseGrokBillingJSONMetric(item) { return metric }
            }
        }
        if let object = value.asObject {
            for key in object.keys.sorted() {
                if let metric = parseGrokBillingJSONMetric(object[key]!) { return metric }
            }
        }
        return nil
    }

    /// Port of `parse_grok_billing_json_object` (:1948-1992).
    static func parseGrokBillingJSONObject(_ value: JSONValue) -> GrokMetric? {
        let monthlyLimit = grokNumber(at: ["monthlyLimit"], in: value)
            ?? grokNumber(at: ["config", "monthlyLimit"], in: value)
        let totalUsed = grokNumber(at: ["usage", "totalUsed"], in: value)
            ?? grokNumber(at: ["totalUsed"], in: value)
            ?? grokNumber(at: ["config", "usage", "totalUsed"], in: value)

        var percent: Double?
        if let limit = monthlyLimit, let used = totalUsed {
            percent = limit > 0 ? min(100.0, max(0.0, used / limit * 100.0)) : nil
        } else {
            percent = grokNumber(at: ["usedPercent"], in: value)
                ?? grokNumber(at: ["usagePercent"], in: value)
                ?? grokNumber(at: ["creditUsagePercent"], in: value)
        }
        guard var percentValue = percent, percentValue.isFinite else { return nil }
        percentValue = min(100.0, max(0.0, percentValue))

        let start = grokString(at: ["billingCycle", "billingPeriodStart"], in: value)
            ?? grokString(at: ["billingPeriodStart"], in: value)
            ?? grokEpoch(at: ["billingPeriodStart"], in: value)
        let end = grokString(at: ["billingCycle", "billingPeriodEnd"], in: value)
            ?? grokString(at: ["billingPeriodEnd"], in: value)
            ?? grokEpoch(at: ["billingPeriodEnd"], in: value)

        var remainingLabel: String?
        if let limit = monthlyLimit, let used = totalUsed {
            let remaining = max(limit - used, 0.0)
            remainingLabel = "\(formatGrokCents(remaining))/\(formatGrokCents(limit)) left"
        }

        return GrokMetric(
            label: grokCycleLabel(start: start, end: end),
            usedPercent: percentValue,
            remainingPercent: 100.0 - percentValue,
            remainingLabel: remainingLabel,
            resetsAt: end)
    }

    /// Port of `push_grok_limit_metric` (:1994-2021).
    static func pushGrokLimitMetric(
        _ metrics: inout [GrokMetric], label: String,
        used: Double?, limit: Double?, reset: String?
    ) {
        guard let limit, limit > 0 else { return }
        let usedValue = min(max(used ?? 0.0, 0.0), limit)
        let usedPercent = min(100.0, max(0.0, usedValue / limit * 100.0))
        let remainingLabel = String(format: "%.0f/%.0f left", limit - usedValue, limit)
        let duplicate = metrics.contains { metric in
            metric.label == label
                && abs(metric.usedPercent - usedPercent) < 0.0001
                && metric.remainingLabel == remainingLabel
        }
        if duplicate { return }
        metrics.append(GrokMetric(
            label: label,
            usedPercent: usedPercent,
            remainingPercent: 100.0 - usedPercent,
            remainingLabel: remainingLabel,
            resetsAt: reset))
    }

    /// Port of `collect_grok_task_usage_metrics` (:2023-2060). Child values
    /// are visited in sorted key order (serde_json BTreeMap).
    static func collectGrokTaskUsageMetrics(_ value: JSONValue, into metrics: inout [GrokMetric]) {
        if let object = value.asObject {
            let reset = (object["resetTime"] ?? object["resetsAt"] ?? object["resetAt"])?.asString
            pushGrokLimitMetric(
                &metrics, label: "Tasks",
                used: object["usage"].flatMap(grokNumericValue),
                limit: object["limit"].flatMap(grokNumericValue),
                reset: reset)
            pushGrokLimitMetric(
                &metrics, label: "Frequent",
                used: object["frequentUsage"].flatMap(grokNumericValue),
                limit: object["frequentLimit"].flatMap(grokNumericValue),
                reset: reset)
            pushGrokLimitMetric(
                &metrics, label: "Occasional",
                used: object["occasionalUsage"].flatMap(grokNumericValue),
                limit: object["occasionalLimit"].flatMap(grokNumericValue),
                reset: reset)
            for key in object.keys.sorted() {
                collectGrokTaskUsageMetrics(object[key]!, into: &metrics)
            }
        } else if let items = value.asArray {
            for child in items {
                collectGrokTaskUsageMetrics(child, into: &metrics)
            }
        }
    }

    // MARK: Hand-rolled protobuf (grpc-web GetGrokCreditsConfig)

    /// Port of `read_grok_varint` (:2062-2075): LEB128 with a shift<=63
    /// guard; running out of bytes or overshifting returns nil.
    static func readGrokVarint(_ data: [UInt8], _ pos: inout Int) -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt32 = 0
        while pos < data.count && shift <= 63 {
            let byte = data[pos]
            pos += 1
            result |= UInt64(byte & 0x7f) &<< UInt64(shift)
            if byte & 0x80 == 0 {
                return result
            }
            shift += 7
        }
        return nil
    }

    /// Port of `next_grok_proto_field` (:2077-2110): wire types 0 (varint),
    /// 1 (fixed64, skipped), 2 (length-delimited), 5 (fixed32 LE).
    static func nextGrokProtoField(
        _ data: [UInt8], _ pos: inout Int
    ) -> (field: UInt32, value: GrokProtoValue)? {
        guard let key = readGrokVarint(data, &pos) else { return nil }
        guard let field = UInt32(exactly: key >> 3) else { return nil }
        switch key & 0x07 {
        case 0:
            guard let value = readGrokVarint(data, &pos) else { return nil }
            return (field, .varint(value))
        case 1:
            guard pos + 8 <= data.count else { return nil }
            pos += 8
            return (field, .fixed64)
        case 2:
            guard let lenRaw = readGrokVarint(data, &pos),
                  let len = Int(exactly: lenRaw),
                  pos + len <= data.count
            else { return nil }
            let bytes = Array(data[pos..<pos + len])
            pos += len
            return (field, .bytes(bytes))
        case 5:
            guard pos + 4 <= data.count else { return nil }
            let value = UInt32(data[pos])
                | (UInt32(data[pos + 1]) << 8)
                | (UInt32(data[pos + 2]) << 16)
                | (UInt32(data[pos + 3]) << 24)
            pos += 4
            return (field, .fixed32(value))
        default:
            return nil
        }
    }

    /// google.protobuf.Timestamp: field 1 varint seconds.
    static func grokTimestampMessageToRFC3339(_ data: [UInt8]) -> String? {
        var pos = 0
        while pos < data.count {
            guard let (field, value) = nextGrokProtoField(data, &pos) else { return nil }
            if field == 1, case .varint(let seconds) = value {
                guard let signed = Int64(exactly: seconds) else { return nil }
                return grokEpochToRFC3339(signed)
            }
        }
        return nil
    }

    static func grokEpochToRFC3339(_ seconds: Int64) -> String {
        QuotaDates.rfc3339Seconds(Date(timeIntervalSince1970: TimeInterval(seconds)))
    }

    /// Port of `parse_grok_billing_config_proto` (:2131-2169). Config
    /// message: field 1 fixed32 = f32 percent bits, fields 4/5 = nested
    /// Timestamps for the period bounds. Proto3 omits default fixed32 (0%
    /// used): if the frame only carries period bounds, missing percent is
    /// zero instead of dropping the window.
    static func parseGrokBillingConfigProto(_ data: [UInt8]) -> GrokMetric? {
        var pos = 0
        var usedPercent: Double?
        var start: String?
        var end: String?

        while pos < data.count {
            guard let (field, value) = nextGrokProtoField(data, &pos) else { return nil }
            switch (field, value) {
            case (1, .fixed32(let bits)):
                let percent = Double(Float(bitPattern: bits))
                if percent.isFinite {
                    usedPercent = min(100.0, max(0.0, percent))
                }
            case (4, .bytes(let bytes)):
                start = grokTimestampMessageToRFC3339(bytes)
            case (5, .bytes(let bytes)):
                end = grokTimestampMessageToRFC3339(bytes)
            default:
                break
            }
        }

        if usedPercent == nil && start == nil && end == nil {
            return nil
        }
        let percent = usedPercent ?? 0.0
        return GrokMetric(
            label: grokCycleLabel(start: start, end: end),
            usedPercent: percent,
            remainingPercent: 100.0 - percent,
            remainingLabel: nil,
            resetsAt: end)
    }

    /// Port of `parse_grok_grpc_billing_metric` (:2171-2200): grpc-web
    /// framing — 1 flag byte + BE u32 length; trailer frames (flag & 0x80)
    /// are skipped. The response message's field 1 nests the config.
    static func parseGrokGrpcBillingMetric(_ body: [UInt8]) -> GrokMetric? {
        var pos = 0
        while pos + 5 <= body.count {
            let flag = body[pos]
            let len = Int(
                (UInt32(body[pos + 1]) << 24)
                    | (UInt32(body[pos + 2]) << 16)
                    | (UInt32(body[pos + 3]) << 8)
                    | UInt32(body[pos + 4]))
            pos += 5
            if pos + len > body.count { return nil }
            let payload = Array(body[pos..<pos + len])
            pos += len
            if flag & 0x80 != 0 { continue }

            var payloadPos = 0
            while payloadPos < payload.count {
                guard let (field, value) = nextGrokProtoField(payload, &payloadPos) else {
                    return nil
                }
                if field == 1, case .bytes(let config) = value {
                    if let metric = parseGrokBillingConfigProto(config) {
                        return metric
                    }
                }
            }
        }
        return nil
    }
}

// MARK: - stdio line channel

/// Thread-safe accumulating line splitter feeding the agent-stdio consumer.
final class LineChannel: @unchecked Sendable {
    private let condition = NSCondition()
    private var buffer = Data()
    private var lines: [String] = []
    private var finished = false

    func append(_ chunk: Data) {
        condition.lock()
        buffer.append(chunk)
        while let index = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer.subdata(in: buffer.startIndex..<index)
            buffer.removeSubrange(buffer.startIndex...index)
            if let line = String(data: lineData, encoding: .utf8) {
                lines.append(line)
            }
        }
        condition.signal()
        condition.unlock()
    }

    func finish() {
        condition.lock()
        finished = true
        condition.signal()
        condition.unlock()
    }

    /// Next complete line, or nil when the deadline passes / stream ends.
    func next(timeout: TimeInterval) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while lines.isEmpty {
            if finished { return nil }
            if !condition.wait(until: deadline) { return nil }
        }
        return lines.removeFirst()
    }
}

/// FileHandle mover for reader threads; safe because only that thread
/// touches the handle after spawn.
struct UncheckedHandleBox: @unchecked Sendable {
    let handle: FileHandle
}
