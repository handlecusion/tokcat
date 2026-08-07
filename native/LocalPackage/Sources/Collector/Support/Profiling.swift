import Foundation

// Wall-clock profiler for `tokcat-dump profile`: times a cold full-scan
// collect, then a cache-backed cold fill + warm re-run (the app's
// steady-state refresh path through DashboardStore's UsageCache).
public enum CollectorProfiler {
    public static func run() {
        func timed(_ label: String, _ body: () -> Int) {
            let t0 = DispatchTime.now()
            let count = body()
            let secs =
                Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e9
            print("\(label): \(String(format: "%.2f", secs))s (\(count) messages)")
        }

        timed("cold (no cache)  ") { UsageGraph.collectMessages().count }
        let cache = UsageCache()
        timed("cold (cache fill)") { UsageGraph.collectMessages(cache: cache).count }
        timed("warm (cache hit) ") { UsageGraph.collectMessages(cache: cache).count }
        print("cached files: \(cache.entryCount)")
    }
}
