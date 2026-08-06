import DataSource
import Foundation

// Port of UsageMessage + TokenBreakdown helpers (usage_graph.rs:13-75).
// Reuses DataSource.TokenBreakdown as the serialized shape.

extension TokenBreakdown {
    /// TokenBreakdown::add — saturating, negatives clamped to 0 per field.
    mutating func addClamped(_ other: TokenBreakdown) {
        input = satAdd(input, max(other.input, 0))
        output = satAdd(output, max(other.output, 0))
        cacheRead = satAdd(cacheRead, max(other.cacheRead, 0))
        cacheWrite = satAdd(cacheWrite, max(other.cacheWrite, 0))
        reasoning = satAdd(reasoning, max(other.reasoning, 0))
    }
}

struct UsageMessage {
    var client: String
    var modelId: String
    var providerId: String
    var timestampMs: Int64
    var date: String
    var tokens: TokenBreakdown
    var cost: Double
    var messages: Int32
    var dedupKey: String?

    init(
        client: String, modelId: String, providerId: String,
        timestampMs: Int64, tokens: TokenBreakdown, cost: Double
    ) {
        self.client = client
        self.modelId = normalizeModelId(modelId)
        self.providerId = providerId
        self.timestampMs = timestampMs
        self.date = dateFromTimestampMs(timestampMs)
        self.tokens = tokens
        self.cost = max(cost, 0.0)
        self.messages = 1
        self.dedupKey = nil
    }

    var totalTokens: Int64 { tokens.total }
}

/// Port of normalize_model_id (usage_graph.rs:2465-2467).
func normalizeModelId(_ id: String) -> String {
    rustTrim(id).lowercased()
}

/// Port of infer_provider (usage_graph.rs:2488-2514), incl. fable→anthropic.
func inferProvider(_ model: String) -> String {
    let model = model.lowercased()
    if model.contains("claude") || model.contains("sonnet") || model.contains("opus")
        || model.contains("haiku") || model.contains("fable")
    {
        return "anthropic"
    } else if model.hasPrefix("gpt-") || model.hasPrefix("o1") || model.hasPrefix("o3")
        || model.hasPrefix("o4")
    {
        return "openai"
    } else if model.contains("gemini") {
        return "google"
    } else if model.contains("grok") {
        return "xai"
    } else if model.contains("deepseek") {
        return "deepseek"
    } else if model.contains("llama") {
        return "meta"
    }
    return "unknown"
}
