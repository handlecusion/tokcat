import DataSource
import Foundation
import Testing

@testable import Collector

// Pins the Codex Cloud daily-usage decode: plan percent per day, split into
// cloud surfaces (this is not the Mac) vs local ones (Tokcat already parses
// those from disk, so counting them again would double count).

@Suite struct CodexCloudUsageTests {
    private let wire = """
        {
          "units": "percent",
          "group_by": "day",
          "data": [
            {
              "date": "2026-09-05",
              "product_surface_usage_values": {
                "cli": 0.0, "vscode": 0.0, "web": 0.024, "mobile": 0.0,
                "desktop_app": 31.972, "agent_identity": 0.487, "unknown": 0.0
              },
              "models": [
                {"model": "gpt-6-astra", "speed": "standard", "credits": 31.257}
              ]
            },
            {
              "date": "2026-09-06",
              "product_surface_usage_values": {"desktop_app": 100.0},
              "models": []
            }
          ]
        }
        """

    private func decode(_ json: String) throws -> CodexDailyUsageResponse {
        try JSONDecoder().decode(CodexDailyUsageResponse.self, from: Data(json.utf8))
    }

    @Test func splitsCloudFromLocalSurfaces() throws {
        let report = CodexCloudUsageProvider.report(from: try decode(wire))
        #expect(report.units == "percent")
        #expect(report.days.count == 2)
        #expect(report.cloudDays == 1)
        // web 0.024 + agent_identity 0.487
        #expect(abs(report.days[0].cloudPercent - 0.511) < 1e-9)
        #expect(abs(report.days[0].localPercent - 31.972) < 1e-9)
        #expect(abs(report.days[1].cloudPercent) < 1e-12)
        #expect(abs(report.days[1].localPercent - 100.0) < 1e-9)
        #expect(abs(report.cloudTotalPercent - 0.511) < 1e-9)
        #expect(abs(report.localTotalPercent - 131.972) < 1e-9)
    }

    @Test func keepsModelRows() throws {
        let report = CodexCloudUsageProvider.report(from: try decode(wire))
        #expect(report.days[0].models.count == 1)
        #expect(report.days[0].models[0].model == "gpt-6-astra")
        #expect(abs(report.days[0].models[0].credits - 31.257) < 1e-9)
    }

    /// A surface we have never seen must land in the local bucket rather than
    /// failing the decode — a new server surface should not break refresh.
    @Test func unknownSurfaceDoesNotFailDecode() throws {
        let json = """
            {"units":"percent","group_by":"day","data":[
              {"date":"2026-09-05","product_surface_values_missing":true}
            ]}
            """
        let report = CodexCloudUsageProvider.report(from: try decode(json))
        #expect(report.days.count == 1)
        #expect(report.days[0].surfaces.isEmpty)
        #expect(report.cloudDays == 0)

        let extra = """
            {"units":"percent","group_by":"day","data":[
              {"date":"2026-09-05","product_surface_usage_values":{"some_new_thing":2.5},
               "models":[{"model":"gpt-6-astra","speed":"standard","credits":null}]}
            ]}
            """
        let newSurface = CodexCloudUsageProvider.report(from: try decode(extra))
        #expect(abs(newSurface.days[0].localPercent - 2.5) < 1e-9)
        #expect(newSurface.days[0].models[0].credits == 0)
    }

    @Test func daysAreSortedByDate() throws {
        let json = """
            {"units":"percent","group_by":"day","data":[
              {"date":"2026-09-07","product_surface_usage_values":{"web":1},"models":[]},
              {"date":"2026-09-01","product_surface_usage_values":{"web":2},"models":[]}
            ]}
            """
        let report = CodexCloudUsageProvider.report(from: try decode(json))
        #expect(report.days.map(\.date) == ["2026-09-01", "2026-09-07"])
    }

    @Test func dateStringIsUTC() {
        // 2026-09-13T00:30:00+09:00 is 2026-09-12T15:30:00Z.
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let date = formatter.date(from: "2026-09-12T15:30:00Z")!
        #expect(CodexCloudUsageProvider.dateString(date) == "2026-09-12")
    }
}
