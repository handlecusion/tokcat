import DataSource
import Foundation

// Port of the pricing engine (usage_graph.rs:2527-2836). The prefix chain in
// bundledPrice must stay in EXACT source order — order is semantics.

struct Price: Equatable {
    var input: Double
    var output: Double
    var cacheRead: Double
    var cacheWrite: Double
    var inputAbove200k: Double?
    var outputAbove200k: Double?
    var cacheReadAbove200k: Double?
    var cacheWriteAbove200k: Double?
    var inputAbove272k: Double?
    var outputAbove272k: Double?
    var cacheReadAbove272k: Double?

    init(_ input: Double, _ output: Double, _ cacheRead: Double, _ cacheWrite: Double) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
    }

    func above200k(_ input: Double, _ output: Double, _ cacheRead: Double, _ cacheWrite: Double)
        -> Price
    {
        var p = self
        p.inputAbove200k = input
        p.outputAbove200k = output
        p.cacheReadAbove200k = cacheRead
        p.cacheWriteAbove200k = cacheWrite
        return p
    }

    func above272k(_ input: Double, _ output: Double, _ cacheRead: Double) -> Price {
        var p = self
        p.inputAbove272k = input
        p.outputAbove272k = output
        p.cacheReadAbove272k = cacheRead
        return p
    }
}

/// Port of estimate_cost (usage_graph.rs:2575-2607). Reasoning tokens are
/// billed at the output rate.
func estimateCost(model: String, provider: String, tokens: TokenBreakdown) -> Double {
    estimateCost(price: bundledPrice(model: model, provider: provider), tokens: tokens)
}

func estimateCost(price: Price, tokens: TokenBreakdown) -> Double {
    let input = tieredCostPerMillion(
        tokens: tokens.input,
        basePrice: price.input,
        tiers: [
            (200_000.0, price.inputAbove200k),
            (272_000.0, price.inputAbove272k),
        ])
    let output = tieredCostPerMillion(
        tokens: satAdd(max(tokens.output, 0), max(tokens.reasoning, 0)),
        basePrice: price.output,
        tiers: [
            (200_000.0, price.outputAbove200k),
            (272_000.0, price.outputAbove272k),
        ])
    let cacheRead = tieredCostPerMillion(
        tokens: tokens.cacheRead,
        basePrice: price.cacheRead,
        tiers: [
            (200_000.0, price.cacheReadAbove200k),
            (272_000.0, price.cacheReadAbove272k),
        ])
    let cacheWrite = tieredCostPerMillion(
        tokens: tokens.cacheWrite,
        basePrice: price.cacheWrite,
        tiers: [(200_000.0, price.cacheWriteAbove200k)])
    return (input + output + cacheRead + cacheWrite) / 1_000_000.0
}

/// Port of tiered_cost_per_million (usage_graph.rs:2609-2631).
func tieredCostPerMillion(tokens: Int64, basePrice: Double, tiers: [(Double, Double?)])
    -> Double
{
    let tokens = Double(max(tokens, 0))
    var cost = 0.0
    var lowerBound = 0.0
    var activePrice = max(basePrice, 0.0)

    for (threshold, tierPriceOpt) in tiers {
        guard let tierPrice = tierPriceOpt, tierPrice.isFinite, tierPrice >= 0.0 else {
            continue
        }
        if !threshold.isFinite || threshold <= lowerBound { continue }
        if tokens <= threshold {
            return cost + max(tokens - lowerBound, 0.0) * activePrice
        }
        cost += (threshold - lowerBound) * activePrice
        lowerBound = threshold
        activePrice = tierPrice
    }
    return cost + max(tokens - lowerBound, 0.0) * activePrice
}

/// Port of bundled_price (usage_graph.rs:2633-2836) — one literal if-chain.
func bundledPrice(model: String, provider: String) -> Price {
    let m = model.lowercased()
    var normalized = ""
    normalized.reserveCapacity(m.count)
    for c in m {
        normalized.append(c == "." || c == "_" || c == " " ? "-" : c)
    }
    let terminal =
        normalized.range(of: "/", options: .backwards).map {
            String(normalized[$0.upperBound...])
        } ?? normalized

    if normalized.contains("fable") {
        return Price(10.0, 50.0, 1.0, 12.5)
    }
    if normalized.contains("opus-4-6-fast") || normalized.contains("opus-4-7-fast") {
        return Price(30.0, 150.0, 3.0, 37.5)
    }
    if normalized.contains("opus-4-8-fast") {
        return Price(10.0, 50.0, 1.0, 12.5)
    }
    if normalized.contains("opus-4-5") || normalized.contains("opus-4-6")
        || normalized.contains("opus-4-7") || normalized.contains("opus-4-8")
    {
        return Price(5.0, 25.0, 0.5, 6.25)
    }
    if m.contains("opus") {
        return Price(15.0, 75.0, 1.5, 18.75)
    }
    if normalized.contains("haiku-4-5") {
        return Price(1.0, 5.0, 0.1, 1.25)
    }
    if m.contains("haiku") {
        return Price(0.8, 4.0, 0.08, 1.0)
    }
    if normalized.contains("sonnet-4") {
        return Price(3.0, 15.0, 0.3, 3.75).above200k(6.0, 22.5, 0.6, 7.5)
    }
    if normalized.contains("sonnet-3-5") || normalized.contains("3-5-sonnet") {
        return Price(3.0, 15.0, 0.3, 3.75).above200k(6.0, 30.0, 0.6, 7.5)
    }
    if m.contains("sonnet") || m.contains("claude") {
        return Price(3.0, 15.0, 0.3, 3.75)
    }
    if terminal.contains("gpt-4o-2024-05-13") {
        return Price(5.0, 15.0, 0.0, 0.0)
    }
    if terminal.contains("gpt-4o-mini") {
        return Price(0.15, 0.6, 0.075, 0.0)
    }
    if m.contains("gpt-4o") {
        return Price(2.5, 10.0, 1.25, 0.0)
    }
    if terminal.contains("gpt-5-5-pro") || terminal.contains("gpt-5-4-pro") {
        return Price(30.0, 180.0, 0.0, 0.0).above272k(60.0, 270.0, 0.0)
    }
    if terminal.contains("gpt-5-2-pro") {
        return Price(21.0, 168.0, 0.0, 0.0)
    }
    if terminal.hasPrefix("gpt-5-pro") {
        return Price(15.0, 120.0, 0.0, 0.0)
    }
    if terminal.contains("gpt-5-4-mini") {
        return Price(0.75, 4.5, 0.075, 0.0)
    }
    if terminal.contains("gpt-5-4-nano") {
        return Price(0.2, 1.25, 0.02, 0.0)
    }
    if terminal.hasPrefix("gpt-5-5") || terminal.contains("gpt-5-5-codex") {
        return Price(5.0, 30.0, 0.5, 0.0).above272k(10.0, 45.0, 1.0)
    }
    if terminal.hasPrefix("gpt-5-4") || terminal.contains("gpt-5-4-codex") {
        return Price(2.5, 15.0, 0.25, 0.0).above272k(5.0, 22.5, 0.5)
    }
    if terminal.hasPrefix("gpt-5-3") || terminal.contains("gpt-5-3-codex") {
        return Price(1.75, 14.0, 0.175, 0.0)
    }
    if terminal.hasPrefix("gpt-5-2") || terminal.contains("gpt-5-2-codex") {
        return Price(1.75, 14.0, 0.175, 0.0)
    }
    if terminal.contains("gpt-5-1-codex-mini") || terminal.hasPrefix("gpt-5-mini") {
        return Price(0.25, 2.0, 0.025, 0.0)
    }
    if terminal.hasPrefix("gpt-5-nano") {
        return Price(0.05, 0.4, 0.005, 0.0)
    }
    if terminal.hasPrefix("gpt-5") || terminal.contains("codex") || m.contains("codex") {
        return Price(1.25, 10.0, 0.125, 0.0)
    }
    if terminal.hasPrefix("o3-pro") {
        return Price(20.0, 80.0, 0.0, 0.0)
    }
    if terminal.hasPrefix("o3-mini") {
        return Price(1.1, 4.4, 0.55, 0.0)
    }
    if terminal.hasPrefix("o3-deep-research") {
        return Price(10.0, 40.0, 2.5, 0.0)
    }
    if terminal.hasPrefix("o3") {
        return Price(2.0, 8.0, 0.5, 0.0)
    }
    if terminal.hasPrefix("o4-mini-deep-research") {
        return Price(2.0, 8.0, 0.5, 0.0)
    }
    if terminal.hasPrefix("o4-mini") {
        return Price(1.1, 4.4, 0.275, 0.0)
    }
    if terminal.hasPrefix("o4") {
        return Price(2.0, 8.0, 0.5, 0.0)
    }
    if normalized.contains("glm-4-7-flashx") {
        return Price(0.07, 0.4, 0.01, 0.0)
    }
    if normalized.contains("glm-4-7") {
        return Price(0.6, 2.2, 0.11, 0.0)
    }
    if normalized.contains("kimi-k2-5") {
        return Price(0.6, 3.0, 0.1, 0.0)
    }
    // Grok Build sometimes prefixes Composer ids as `grok-composer-*`.
    let composerId =
        terminal.hasPrefix("grok-") ? String(terminal.dropFirst("grok-".count)) : terminal
    if composerId == "composer-1" {
        return Price(1.25, 10.0, 0.125, 0.0)
    }
    if composerId == "composer-1-5" {
        return Price(3.5, 17.5, 0.35, 0.0)
    }
    if composerId == "composer-2" || composerId == "composer-2-5" {
        return Price(0.5, 2.5, 0.2, 0.0)
    }
    if composerId == "composer-2-fast" || composerId == "composer-2-5-fast" {
        return Price(1.5, 7.5, 0.35, 0.0)
    }
    if normalized.contains("gemini-3-5-flash") {
        return Price(1.5, 9.0, 0.15, 0.0)
    }
    if normalized.contains("gemini-3-1-flash-lite") {
        return Price(0.25, 1.5, 0.025, 0.0)
    }
    if normalized.contains("gemini-3-1-pro") || normalized.contains("gemini-3-pro") {
        return Price(2.0, 12.0, 0.2, 0.0).above200k(4.0, 18.0, 0.4, 0.0)
    }
    if normalized.contains("gemini-3-flash") {
        return Price(0.5, 3.0, 0.05, 0.0)
    }
    if normalized.contains("gemini-2-5-flash-lite") {
        return Price(0.1, 0.4, 0.01, 0.0)
    }
    if normalized.contains("gemini-2-5-flash") {
        return Price(0.3, 2.5, 0.03, 0.0)
    }
    if normalized.contains("gemini-2-0-flash-lite") {
        return Price(0.075, 0.3, 0.0, 0.0)
    }
    if normalized.contains("gemini-2-0-flash") {
        return Price(0.1, 0.4, 0.025, 0.0)
    }
    if normalized.contains("gemini-2-5-pro") {
        return Price(1.25, 10.0, 0.125, 0.0).above200k(2.5, 15.0, 0.25, 0.0)
    }
    if normalized.contains("gemini-flash-lite-latest") {
        return Price(0.1, 0.4, 0.025, 0.0)
    }
    if normalized.contains("gemini-flash-latest") {
        return Price(0.3, 2.5, 0.075, 0.0)
    }
    if m.contains("gemini") && m.contains("flash") {
        return Price(0.3, 2.5, 0.075, 0.0)
    }
    if m.contains("gemini") {
        return Price(1.25, 10.0, 0.125, 0.0)
    }
    // xAI Grok family — API list prices (per 1M tokens).
    if normalized.contains("grok-4-5") || terminal.contains("grok-4.5") {
        return Price(2.0, 6.0, 0.5, 0.0)
    }
    if normalized.contains("grok-4-3") || terminal.contains("grok-4.3") {
        return Price(1.25, 2.5, 0.2, 0.0)
    }
    if normalized.contains("grok-4-1-fast") || terminal.contains("grok-4.1-fast")
        || normalized.contains("grok-4-1")
    {
        return Price(0.2, 0.5, 0.05, 0.0)
    }
    if normalized.contains("grok-4") || terminal.hasPrefix("grok-4") {
        return Price(3.0, 15.0, 0.75, 0.0)
    }
    if normalized.contains("grok-3-mini") || terminal.contains("grok-3-mini") {
        return Price(0.3, 0.5, 0.075, 0.0)
    }
    if normalized.contains("grok-3") || terminal.hasPrefix("grok-3") {
        return Price(3.0, 15.0, 0.75, 0.0)
    }
    if m.contains("grok") {
        return Price(2.0, 6.0, 0.5, 0.0)
    }
    switch provider {
    case "anthropic": return Price(3.0, 15.0, 0.3, 3.75)
    case "openai": return Price(1.25, 10.0, 0.125, 0.0)
    case "google": return Price(1.25, 10.0, 0.125, 0.0)
    case "xai": return Price(2.0, 6.0, 0.5, 0.0)
    default: return Price(0.0, 0.0, 0.0, 0.0)
    }
}
