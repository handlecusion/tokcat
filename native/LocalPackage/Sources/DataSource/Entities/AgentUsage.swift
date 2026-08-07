import Foundation

// Ports of src/lib/agentUsage.ts / the Rust AgentUsagePayload shape.

public struct AgentIdentity: Sendable, Codable, Equatable {
    public var email: String?
    public var plan: String?

    public init(email: String? = nil, plan: String? = nil) {
        self.email = email
        self.plan = plan
    }
}

public struct UsageWindow: Sendable, Codable, Equatable {
    public var label: String
    public var usedPercent: Double
    public var remainingPercent: Double
    public var resetsAt: String?
    public var resetText: String?

    public init(label: String, usedPercent: Double, remainingPercent: Double,
                resetsAt: String? = nil, resetText: String? = nil) {
        self.label = label
        self.usedPercent = usedPercent
        self.remainingPercent = remainingPercent
        self.resetsAt = resetsAt
        self.resetText = resetText
    }
}

public struct CreditsSnapshot: Sendable, Codable, Equatable {
    public var remaining: Double?
    public var unlimited: Bool

    public init(remaining: Double? = nil, unlimited: Bool) {
        self.remaining = remaining
        self.unlimited = unlimited
    }
}

public struct AgentUsageSnapshot: Sendable, Codable, Equatable {
    public var clientId: String
    public var source: String
    public var updatedAt: String
    public var identity: AgentIdentity?
    public var windows: [UsageWindow]
    public var credits: CreditsSnapshot?
    public var error: String?

    public init(clientId: String, source: String, updatedAt: String,
                identity: AgentIdentity? = nil, windows: [UsageWindow] = [],
                credits: CreditsSnapshot? = nil, error: String? = nil) {
        self.clientId = clientId
        self.source = source
        self.updatedAt = updatedAt
        self.identity = identity
        self.windows = windows
        self.credits = credits
        self.error = error
    }
}

public struct AgentUsagePayload: Sendable, Codable, Equatable {
    public var generatedAt: String
    public var agents: [AgentUsageSnapshot]

    public init(generatedAt: String, agents: [AgentUsageSnapshot]) {
        self.generatedAt = generatedAt
        self.agents = agents
    }
}
