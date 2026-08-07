import Testing

@testable import Model

// Port of collapseByClient in src/components/UsageTraceCard.tsx (:25-59).

private func row(_ client: String, _ agent: String, _ model: String,
                 tokens: Int64, messages: Int = 1, rate: Double) -> TraceRow {
    TraceRow(client: client, agent: agent, model: model,
             tokens: tokens, messages: messages, tokensPerMin: rate)
}

@Suite struct TailTraceCollapseTests {
    @Test func collapsesToOneRowPerClientSummingFields() {
        let collapsed = TraceCollapse.collapseByClient([
            row("claude-code", "main", "claude-sonnet-4", tokens: 100, messages: 2, rate: 10),
            row("claude-code", "subagent:a1", "claude-opus-4", tokens: 50, messages: 1, rate: 5),
            row("codex-cli", "main", "gpt-5.3-codex", tokens: 400, messages: 3, rate: 40),
        ])

        #expect(collapsed.count == 2)
        // Sorted by tokens desc: codex first.
        #expect(collapsed[0].client == "codex-cli")
        #expect(collapsed[0].tokens == 400)
        #expect(collapsed[1].client == "claude-code")
        #expect(collapsed[1].tokens == 150)
        #expect(collapsed[1].messages == 3)
        #expect(collapsed[1].tokensPerMin == 15)
        // Agent/model names joined sorted.
        #expect(collapsed[1].agent == "main, subagent:a1")
        #expect(collapsed[1].model == "claude-opus-4, claude-sonnet-4")
    }

    @Test func dropsUnknownModelWhenOthersExist() {
        let collapsed = TraceCollapse.collapseByClient([
            row("grok", "main", "unknown", tokens: 10, rate: 1),
            row("grok", "main", "grok-4.5", tokens: 20, rate: 2),
        ])
        #expect(collapsed.count == 1)
        #expect(collapsed[0].model == "grok-4.5")

        // A lone unknown model is kept.
        let lone = TraceCollapse.collapseByClient([
            row("grok", "main", "unknown", tokens: 10, rate: 1)
        ])
        #expect(lone[0].model == "unknown")
    }

    @Test func sortsByTokensDescendingStable() {
        let collapsed = TraceCollapse.collapseByClient([
            row("hermes", "main", "gpt-5.5", tokens: 30, rate: 3),
            row("grok", "main", "grok-4.5", tokens: 30, rate: 3),
            row("codex-cli", "main", "gpt-5.3-codex", tokens: 90, rate: 9),
        ])
        #expect(collapsed.map(\.client) == ["codex-cli", "hermes", "grok"])
    }

    @Test func emptyInputYieldsEmptyOutput() {
        #expect(TraceCollapse.collapseByClient([]).isEmpty)
    }
}
