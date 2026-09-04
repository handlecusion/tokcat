import Collector
import Foundation

// Port of the collapse logic in src/components/UsageTraceCard.tsx (:25-59).
// Pure — the view calls it when the user prefers the compact (non-detailed)
// trace, exactly like the React card.

/// UI-facing trace row. Mirrors the tailer's TraceBucket but lives in Model
/// so UserInterface never needs to import Collector directly.
public struct TraceRow: Equatable, Sendable, Identifiable {
    public var client: String
    public var agent: String
    public var model: String
    public var tokens: Int64
    public var messages: Int
    public var tokensPerMin: Double

    public var id: String { "\(client)|\(agent)|\(model)" }

    public init(client: String, agent: String, model: String,
                tokens: Int64, messages: Int, tokensPerMin: Double) {
        self.client = client
        self.agent = agent
        self.model = model
        self.tokens = tokens
        self.messages = messages
        self.tokensPerMin = tokensPerMin
    }

    public init(_ bucket: TraceBucket) {
        self.init(client: bucket.client, agent: bucket.agent, model: bucket.model,
                  tokens: bucket.tokens, messages: bucket.messages,
                  tokensPerMin: bucket.tokensPerMin)
    }
}

public enum TraceClients {
    // Port of normalizeTraceClient (AgentLimitsCard.tsx:33-39): trace ids
    // ("claude-code") → dashboard client-registry ids ("claude").
    public static func normalize(_ id: String) -> String {
        switch id {
        case "claude-code": return "claude"
        case "codex-cli": return "codex"
        case "gemini-cli": return "gemini"
        default:
            return id.hasSuffix("-cli") ? String(id.dropLast(4)) : id
        }
    }

    /// Clients with tokens flowing right now — drives the "Live" chip.
    public static func liveClientIds(_ rows: [TraceRow]) -> Set<String> {
        Set(rows.filter { $0.tokensPerMin > 0 }.map { normalize($0.client) })
    }
}

public enum TraceCollapse {
    /// Collapse (client, agent, model) buckets to one row per client:
    /// sum tokens/messages/rate, join sorted agent/model names, drop the
    /// "unknown" model when concrete ones exist, sort by tokens desc.
    public static func collapseByClient(_ buckets: [TraceRow]) -> [TraceRow] {
        // Group preserving first-seen client order (JS Map semantics).
        var order: [String] = []
        var tokens: [String: Int64] = [:]
        var messages: [String: Int] = [:]
        var rates: [String: Double] = [:]
        var agents: [String: Set<String>] = [:]
        var models: [String: Set<String>] = [:]

        for b in buckets {
            if tokens[b.client] == nil {
                order.append(b.client)
                tokens[b.client] = 0
                messages[b.client] = 0
                rates[b.client] = 0
                agents[b.client] = []
                models[b.client] = []
            }
            tokens[b.client] = satAdd(tokens[b.client]!, b.tokens)
            messages[b.client]! += b.messages
            rates[b.client]! += b.tokensPerMin
            agents[b.client]!.insert(b.agent)
            models[b.client]!.insert(b.model)
        }

        let rows = order.map { client -> TraceRow in
            let agentList = agents[client]!.sorted()
            var modelList = models[client]!.sorted()
            if modelList.count > 1 {
                modelList = modelList.filter { $0 != "unknown" }
            }
            return TraceRow(
                client: client,
                agent: agentList.joined(separator: ", "),
                model: modelList.joined(separator: ", "),
                tokens: tokens[client]!,
                messages: messages[client]!,
                tokensPerMin: rates[client]!)
        }
        // JS Array.sort is stable; keep insertion order on ties.
        return rows.enumerated()
            .sorted { a, b in
                if a.element.tokens != b.element.tokens {
                    return a.element.tokens > b.element.tokens
                }
                return a.offset < b.offset
            }
            .map(\.element)
    }
}
