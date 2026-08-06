import DataSource
import Foundation
import Testing

@testable import Collector

// Ports of the Grok tests in agent_usage.rs (:2759-2969): credential
// priority, billing JSON metrics, task-usage metrics, subscription plans,
// and the hand-rolled grpc-web protobuf parser.

private func date(_ epochSeconds: Int64) -> Date {
    Date(timeIntervalSince1970: TimeInterval(epochSeconds))
}

// MARK: - In-test protobuf frame builders (mirrors the Rust test helpers)

private func pushVarint(_ value: UInt64, _ out: inout [UInt8]) {
    var value = value
    while value >= 0x80 {
        out.append(UInt8(value & 0x7f) | 0x80)
        value >>= 7
    }
    out.append(UInt8(value))
}

private func pushLenField(_ field: UInt64, _ payload: [UInt8], _ out: inout [UInt8]) {
    pushVarint((field << 3) | 2, &out)
    pushVarint(UInt64(payload.count), &out)
    out.append(contentsOf: payload)
}

private func pushFixed32Field(_ field: UInt64, _ value: UInt32, _ out: inout [UInt8]) {
    pushVarint((field << 3) | 5, &out)
    out.append(UInt8(value & 0xff))
    out.append(UInt8((value >> 8) & 0xff))
    out.append(UInt8((value >> 16) & 0xff))
    out.append(UInt8((value >> 24) & 0xff))
}

private func timestampMessage(_ seconds: UInt64) -> [UInt8] {
    var out: [UInt8] = []
    pushVarint(1 << 3, &out)
    pushVarint(seconds, &out)
    return out
}

private func grpcFrame(flag: UInt8, message: [UInt8]) -> [UInt8] {
    var frame: [UInt8] = [flag]
    let len = UInt32(message.count)
    frame.append(UInt8((len >> 24) & 0xff))
    frame.append(UInt8((len >> 16) & 0xff))
    frame.append(UInt8((len >> 8) & 0xff))
    frame.append(UInt8(len & 0xff))
    frame.append(contentsOf: message)
    return frame
}

private func billingFrame(config: [UInt8], flag: UInt8 = 0) -> [UInt8] {
    var message: [UInt8] = []
    pushLenField(1, config, &message)
    return grpcFrame(flag: flag, message: message)
}

@Suite(.serialized) struct QuotaGrokTests {
    @Test func tileGatedOnAuthJSONPresence() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokcat-grok-cfg-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer {
            unsetenv("GROK_HOME")
            try? FileManager.default.removeItem(at: dir)
        }
        setenv("GROK_HOME", dir.path, 1)
        #expect(!GrokQuotaProvider.isConfigured)
        try Data("{}".utf8).write(to: dir.appendingPathComponent("auth.json"))
        #expect(GrokQuotaProvider.isConfigured)
    }

    @Test func resolveBinaryPrefersGrokHomeBin() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokcat-grok-bin-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.removeItem(at: dir)
        let binDir = dir.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        let binary = binDir.appendingPathComponent("grok")
        try Data("#!/bin/sh\n".utf8).write(to: binary)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: binary.path)
        defer {
            unsetenv("GROK_HOME")
            try? FileManager.default.removeItem(at: dir)
        }
        setenv("GROK_HOME", dir.path, 1)
        #expect(GrokQuotaProvider.resolveGrokBinary() == binary.path)
    }

    @Test func readsCredentialsAuthScopeFirst() throws {
        let doc = JSONValue.parse("""
            {
                "https://example.com": {
                    "key": "secondary-token",
                    "email": "secondary@example.com"
                },
                "https://auth.x.ai": {
                    "key": "primary-token",
                    "email": "primary@example.com"
                }
            }
            """)!
        let credentials = try GrokQuotaProvider.grokCredentialCandidates(from: doc)
        #expect(credentials.count == 2)
        #expect(credentials[0].token == "primary-token")
        #expect(credentials[0].email == "primary@example.com")
        #expect(credentials[1].token == "secondary-token")
    }

    @Test func credentialErrors() {
        #expect(throws: (any Error).self) {
            _ = try GrokQuotaProvider.grokCredentialCandidates(from: .array([]))
        }
        #expect(throws: (any Error).self) {
            _ = try GrokQuotaProvider.grokCredentialCandidates(from: .object([:]))
        }
    }

    @Test func parsesBillingJSONMetric() {
        let value = JSONValue.parse("""
            {
                "billingCycle": {
                    "billingPeriodStart": "2026-06-01T00:00:00Z",
                    "billingPeriodEnd": "2026-07-01T00:00:00Z"
                },
                "monthlyLimit": { "val": 10000 },
                "usage": { "totalUsed": { "val": 1250 } }
            }
            """)!
        let metric = GrokQuotaProvider.parseGrokBillingJSONMetric(value)
        #expect(metric?.label == "Monthly")
        #expect(abs((metric?.usedPercent ?? 0) - 12.5) < 1e-9)
        #expect(metric?.remainingLabel == "$87.50/$100.00 left")
        let window = GrokQuotaProvider.mapGrokMetric(metric!, now: date(1_700_000_000))
        #expect(window.label == "Monthly")
        #expect(abs(window.remainingPercent - 87.5) < 1e-9)
        #expect(window.resetText == "$87.50/$100.00 left")
    }

    @Test func parsesTaskUsageMetrics() {
        let value = JSONValue.parse("""
            {
                "frequentUsage": 3,
                "frequentLimit": 10,
                "occasionalUsage": 1,
                "occasionalLimit": 5
            }
            """)!
        var metrics: [GrokMetric] = []
        GrokQuotaProvider.collectGrokTaskUsageMetrics(value, into: &metrics)
        #expect(metrics.count == 2)
        #expect(metrics[0].label == "Frequent")
        #expect(abs(metrics[0].usedPercent - 30) < 1e-9)
        #expect(metrics[0].remainingLabel == "7/10 left")
        #expect(metrics[1].label == "Occasional")
        #expect(abs(metrics[1].usedPercent - 20) < 1e-9)
    }

    @Test func parsesSubscriptionPlan() {
        let active = JSONValue.parse("""
            {
                "subscriptions": [
                    { "tier": "SUBSCRIPTION_TIER_SUPER_GROK_PRO",
                      "status": "SUBSCRIPTION_STATUS_ACTIVE" }
                ]
            }
            """)!
        #expect(GrokQuotaProvider.parseGrokSubscriptionPlan(active) == "Super Grok Pro")

        let inactive = JSONValue.parse("""
            {
                "subscriptions": [
                    { "tier": "SUBSCRIPTION_TIER_SUPER_GROK_PRO",
                      "status": "SUBSCRIPTION_STATUS_INACTIVE" }
                ]
            }
            """)!
        #expect(GrokQuotaProvider.parseGrokSubscriptionPlan(inactive) == nil)
    }

    // MARK: Protobuf parser

    @Test func parsesGrpcBillingPercentFrame() {
        var config: [UInt8] = []
        pushFixed32Field(1, Float(25.0).bitPattern, &config)
        pushLenField(4, timestampMessage(1_780_272_000), &config)
        pushLenField(5, timestampMessage(1_782_864_000), &config)

        let frame = billingFrame(config: config)
        let metric = GrokQuotaProvider.parseGrokGrpcBillingMetric(frame)
        #expect(metric?.label == "Monthly")
        #expect(abs((metric?.usedPercent ?? 0) - 25.0) < 1e-6)
        #expect(metric?.resetsAt != nil)
    }

    @Test func parsesGrpcBillingWithOmittedZeroPercent() {
        // Period bounds only — proto3 omits default 0% fixed32 field 1.
        var config: [UInt8] = []
        pushLenField(4, timestampMessage(1_780_272_000), &config)
        pushLenField(5, timestampMessage(1_782_864_000), &config)

        let frame = billingFrame(config: config)
        let metric = GrokQuotaProvider.parseGrokGrpcBillingMetric(frame)
        #expect(metric != nil)
        #expect(metric?.label == "Monthly")
        #expect(metric?.usedPercent == 0)
        #expect(metric?.remainingPercent == 100)
    }

    @Test func skipsTrailerFramesAndEmptyConfigs() {
        // A trailer-only body (flag & 0x80) yields nothing.
        let trailer = grpcFrame(flag: 0x80, message: Array("grpc-status: 0".utf8))
        #expect(GrokQuotaProvider.parseGrokGrpcBillingMetric(trailer) == nil)

        // Trailer first, then a data frame: the trailer must be skipped.
        var config: [UInt8] = []
        pushFixed32Field(1, Float(40.0).bitPattern, &config)
        pushLenField(5, timestampMessage(1_782_864_000), &config)
        let body = trailer + billingFrame(config: config)
        let metric = GrokQuotaProvider.parseGrokGrpcBillingMetric(body)
        #expect(abs((metric?.usedPercent ?? 0) - 40.0) < 1e-6)
        // End bound alone (no start) cannot classify the cycle → Credits.
        #expect(metric?.label == "Credits")

        // An empty config message carries no fields at all → no metric.
        #expect(GrokQuotaProvider.parseGrokGrpcBillingMetric(billingFrame(config: [])) == nil)
    }

    @Test func varintEdgeCases() {
        // Truncated varint (continuation bit set, no next byte) fails.
        var pos = 0
        #expect(GrokQuotaProvider.readGrokVarint([0x80], &pos) == nil)
        // Ten 0x80 bytes overshoot the shift<=63 guard.
        pos = 0
        let overlong = [UInt8](repeating: 0x80, count: 10) + [0x01]
        #expect(GrokQuotaProvider.readGrokVarint(overlong, &pos) == nil)
        // Two-byte varint decodes.
        pos = 0
        #expect(GrokQuotaProvider.readGrokVarint([0xAC, 0x02], &pos) == 300)
        #expect(pos == 2)
        // Truncated fixed32 / length-delimited fields fail cleanly.
        pos = 0
        #expect(GrokQuotaProvider.nextGrokProtoField([0x0D, 0x01, 0x02], &pos) == nil)
        pos = 0
        #expect(GrokQuotaProvider.nextGrokProtoField([0x0A, 0x05, 0x01], &pos) == nil)
    }

    @Test func labelsAndTiers() {
        #expect(GrokQuotaProvider.grokTitleWords("SUPER_GROK-pro") == "Super Grok Pro")
        #expect(GrokQuotaProvider.normalizeGrokSubscriptionTier("TIER_BASIC") == "Basic")
        #expect(GrokQuotaProvider.grokSubscriptionIsActive("active"))
        #expect(!GrokQuotaProvider.grokSubscriptionIsActive("SUBSCRIPTION_STATUS_INACTIVE"))
        #expect(GrokQuotaProvider.grokCycleLabel(
            start: "2026-06-01T00:00:00Z", end: "2026-06-08T00:00:00Z") == "Weekly")
        #expect(GrokQuotaProvider.grokCycleLabel(
            start: "2026-06-01T00:00:00Z", end: "2026-06-15T00:00:00Z") == "Credits")
        #expect(GrokQuotaProvider.grokCycleLabel(start: nil, end: nil) == "Credits")
    }
}
