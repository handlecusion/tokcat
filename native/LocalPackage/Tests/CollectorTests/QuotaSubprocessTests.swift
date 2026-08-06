import Foundation
import Testing

@testable import Collector

// Ports of the subprocess-guard tests in agent_usage.rs (:2342-2405),
// including the two defects fixed in commit a804dd5: the reap shares the
// read's deadline, and a timeout is never folded into "ran and said no".

@Suite struct QuotaSubprocessTests {
    @Test func returnsStdoutWhenTheChildExitsCleanly() {
        let out = outputWithTimeout("/bin/echo", ["hello"], timeout: 5)
        guard case .success(.ok(let data)) = out else {
            Issue.record("expected ok, got \(out)")
            return
        }
        #expect(data == Data("hello\n".utf8))
    }

    @Test func separatesANonzeroExitFromATimeout() {
        // Distinct from timedOut on purpose: the Keychain caller turns one
        // into "not configured" and the other into a surfaced error.
        let out = outputWithTimeout("/usr/bin/false", [], timeout: 5)
        guard case .success(.failed) = out else {
            Issue.record("expected failed, got \(out)")
            return
        }
    }

    @Test func killsAChildThatOverruns() {
        let started = Date()
        let out = outputWithTimeout("/bin/sleep", ["30"], timeout: 0.2)
        guard case .success(.timedOut) = out else {
            Issue.record("expected timedOut, got \(out)")
            return
        }
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test func doesNotWaitOutAChildThatClosesStdoutAndLingers() {
        // The failure this guards: the read returns as soon as the pipe
        // closes, so an unbounded wait would block here for the child's full
        // lifetime and report success as if nothing were wrong.
        let started = Date()
        let out = outputWithTimeout(
            "/bin/sh", ["-c", "echo hi; exec 1>&-; sleep 30"], timeout: 0.3)
        guard case .success(.timedOut) = out else {
            Issue.record("expected timedOut, got \(out)")
            return
        }
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test func readsStdoutLargerThanThePipeBuffer() {
        // Why the read happens on its own thread at all: past ~64KB the
        // child blocks writing until someone drains the pipe.
        let out = outputWithTimeout(
            "/bin/sh", ["-c", "yes tokcat | head -c 200000"], timeout: 10)
        guard case .success(.ok(let data)) = out else {
            Issue.record("expected full stdout, got \(out)")
            return
        }
        #expect(data.count == 200_000)
    }

    @Test func errorsWhenTheBinaryIsMissing() {
        let out = outputWithTimeout("/nonexistent/tokcat-test-binary", [], timeout: 5)
        guard case .failure = out else {
            Issue.record("expected spawn failure, got \(out)")
            return
        }
    }
}
