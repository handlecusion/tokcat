import DataSource
import Foundation

// Port of agent_usage::run() (:293-312).
//
// Each provider is gated by its own isConfigured check: unconfigured agents
// are omitted from the payload entirely (no tile), while configured-but-
// broken ones surface an error snapshot. Output order is fixed (codex,
// claude, grok, cursor) to match the Rust payload.
//
// The Rust version awaits the four providers sequentially; here they run
// concurrently (per the QuotaStore contract) — the payload is identical
// because each snapshot is independent and the order is reassembled below.
public enum AgentQuota {
    public static func run() async -> AgentUsagePayload {
        let generatedAt = QuotaDates.rfc3339Millis(Date())

        async let codex: AgentUsageSnapshot? = CodexQuotaProvider.isConfigured
            ? CodexQuotaProvider.fetch() : nil
        async let claude: AgentUsageSnapshot? = ClaudeQuotaProvider.isConfigured
            ? ClaudeQuotaProvider.fetch() : nil
        async let grok: AgentUsageSnapshot? = GrokQuotaProvider.isConfigured
            ? GrokQuotaProvider.fetch() : nil
        async let cursor: AgentUsageSnapshot? = CursorQuotaProvider.isConfigured
            ? CursorQuotaProvider.fetch() : nil

        let agents = await [codex, claude, grok, cursor].compactMap { $0 }
        return AgentUsagePayload(generatedAt: generatedAt, agents: agents)
    }
}
