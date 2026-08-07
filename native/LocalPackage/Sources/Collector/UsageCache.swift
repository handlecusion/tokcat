import Foundation

/// In-memory per-file parse cache for the collector: (path, size, mtime-ns)
/// → parsed [UsageMessage]. Owned by DashboardStore so the 30-minute
/// auto-refresh and manual refreshes only re-parse files that changed;
/// tokcat-dump / parity runs pass no cache and stay cold.
///
/// Only parsers whose output is a pure per-file function use it (claude,
/// codex — both keep all merge/delta state local to one file). Parsers with
/// cross-file inputs (grok reads sibling metadata files) do not.
///
/// Entries for paths not seen during a run are evicted at the end of that
/// run (beginRun/endRun bracket one collectMessages pass). Never persisted.
public final class UsageCache: @unchecked Sendable {
    struct Entry {
        var size: Int64
        var mtimeNs: Int64
        var messages: [UsageMessage]
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var touched: Set<String> = []
    /// Test hook: total number of cache-miss parses performed.
    private(set) var missCount = 0

    public init() {}

    func beginRun() {
        lock.lock()
        touched.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    /// Evict entries whose files were not seen this run (vanished files).
    func endRun() {
        lock.lock()
        if entries.count != touched.count {
            entries = entries.filter { touched.contains($0.key) }
        }
        lock.unlock()
    }

    var entryCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    /// Return cached messages for `path` when its (size, mtime-ns) is
    /// unchanged; otherwise run `parse` and cache the result. The stat is
    /// taken BEFORE parsing so a file growing mid-parse invalidates on the
    /// next run rather than caching new metadata over old content.
    func messages(for path: String, parse: (String) -> [UsageMessage]) -> [UsageMessage] {
        var sb = stat()
        guard stat(path, &sb) == 0 else {
            // Unreadable/vanished: don't cache; parse decides (returns []).
            return parse(path)
        }
        let size = Int64(sb.st_size)
        let mtimeNs =
            Int64(sb.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(sb.st_mtimespec.tv_nsec)

        lock.lock()
        touched.insert(path)
        if let entry = entries[path], entry.size == size, entry.mtimeNs == mtimeNs {
            let messages = entry.messages
            lock.unlock()
            return messages
        }
        missCount += 1
        lock.unlock()

        let messages = parse(path)
        lock.lock()
        entries[path] = Entry(size: size, mtimeNs: mtimeNs, messages: messages)
        lock.unlock()
        return messages
    }
}

/// Parse `files` concurrently (per-file parses are independent) and return
/// the concatenation IN THE GIVEN ORDER — dedup downstream is first-wins, so
/// per-client file order (path-sorted) must be preserved exactly.
func parseFilesInOrder(
    _ files: [String],
    cache: UsageCache?,
    _ parseFile: @escaping @Sendable (String) -> [UsageMessage]
) -> [UsageMessage] {
    @Sendable func parseOne(_ path: String) -> [UsageMessage] {
        if let cache { return cache.messages(for: path, parse: parseFile) }
        return parseFile(path)
    }

    if files.count <= 1 {
        return files.flatMap(parseOne)
    }

    final class Slots: @unchecked Sendable {
        let lock = NSLock()
        var results: [[UsageMessage]]
        init(count: Int) { results = Array(repeating: [], count: count) }
        func set(_ index: Int, _ value: [UsageMessage]) {
            lock.lock()
            results[index] = value
            lock.unlock()
        }
    }

    let slots = Slots(count: files.count)
    DispatchQueue.concurrentPerform(iterations: files.count) { index in
        slots.set(index, parseOne(files[index]))
    }

    var out: [UsageMessage] = []
    out.reserveCapacity(slots.results.reduce(0) { $0 + $1.count })
    for messages in slots.results {
        out.append(contentsOf: messages)
    }
    return out
}
