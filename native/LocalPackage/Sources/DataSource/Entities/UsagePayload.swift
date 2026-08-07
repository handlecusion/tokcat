import Foundation

// Direct ports of src/lib/types.ts. Field names and JSON casing must match
// the Rust backend's camelCase serialization exactly — these types are also
// used by the parity harness to compare against the Rust dump.

public struct TokenBreakdown: Sendable, Codable, Equatable {
    public var input: Int64
    public var output: Int64
    public var cacheRead: Int64
    public var cacheWrite: Int64
    public var reasoning: Int64

    public init(input: Int64 = 0, output: Int64 = 0, cacheRead: Int64 = 0,
                cacheWrite: Int64 = 0, reasoning: Int64 = 0) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
        self.reasoning = reasoning
    }

    public var total: Int64 { input + output + cacheRead + cacheWrite + reasoning }
}

public struct ContributionClient: Sendable, Codable, Equatable {
    public var client: String
    public var modelId: String
    public var providerId: String
    public var tokens: TokenBreakdown
    public var cost: Double
    public var messages: Int64

    public init(client: String, modelId: String, providerId: String,
                tokens: TokenBreakdown, cost: Double, messages: Int64) {
        self.client = client
        self.modelId = modelId
        self.providerId = providerId
        self.tokens = tokens
        self.cost = cost
        self.messages = messages
    }
}

public struct ContributionTotals: Sendable, Codable, Equatable {
    public var tokens: Int64
    public var cost: Double
    public var messages: Int64

    public init(tokens: Int64, cost: Double, messages: Int64) {
        self.tokens = tokens
        self.cost = cost
        self.messages = messages
    }
}

public struct Contribution: Sendable, Codable, Equatable {
    public var date: String
    public var totals: ContributionTotals
    public var intensity: Int
    public var tokenBreakdown: TokenBreakdown
    public var clients: [ContributionClient]

    public init(date: String, totals: ContributionTotals, intensity: Int,
                tokenBreakdown: TokenBreakdown, clients: [ContributionClient]) {
        self.date = date
        self.totals = totals
        self.intensity = intensity
        self.tokenBreakdown = tokenBreakdown
        self.clients = clients
    }
}

public struct DateRange: Sendable, Codable, Equatable {
    public var start: String
    public var end: String

    public init(start: String, end: String) {
        self.start = start
        self.end = end
    }
}

public struct YearMeta: Sendable, Codable, Equatable {
    public var year: String
    public var totalTokens: Int64
    public var totalCost: Double
    public var range: DateRange

    public init(year: String, totalTokens: Int64, totalCost: Double, range: DateRange) {
        self.year = year
        self.totalTokens = totalTokens
        self.totalCost = totalCost
        self.range = range
    }
}

public struct UsageMeta: Sendable, Codable, Equatable {
    public var generatedAt: String
    public var version: String
    public var dateRange: DateRange

    public init(generatedAt: String, version: String, dateRange: DateRange) {
        self.generatedAt = generatedAt
        self.version = version
        self.dateRange = dateRange
    }
}

public struct UsageSummary: Sendable, Codable, Equatable {
    public var totalTokens: Int64
    public var totalCost: Double
    public var totalDays: Int
    public var activeDays: Int
    public var averagePerDay: Double
    public var maxCostInSingleDay: Double
    public var clients: [String]
    public var models: [String]

    public init(totalTokens: Int64, totalCost: Double, totalDays: Int, activeDays: Int,
                averagePerDay: Double, maxCostInSingleDay: Double,
                clients: [String], models: [String]) {
        self.totalTokens = totalTokens
        self.totalCost = totalCost
        self.totalDays = totalDays
        self.activeDays = activeDays
        self.averagePerDay = averagePerDay
        self.maxCostInSingleDay = maxCostInSingleDay
        self.clients = clients
        self.models = models
    }
}

public struct UsagePayload: Sendable, Codable, Equatable {
    public var meta: UsageMeta
    public var summary: UsageSummary
    public var years: [YearMeta]
    public var contributions: [Contribution]

    public init(meta: UsageMeta, summary: UsageSummary, years: [YearMeta],
                contributions: [Contribution]) {
        self.meta = meta
        self.summary = summary
        self.years = years
        self.contributions = contributions
    }
}
