import Foundation

// Ports of the filesystem helpers in usage_graph.rs (:2213-2308).

/// collect_files: recursive walk (symlinks NOT followed, like Rust's
/// `DirEntry::file_type`), extension-style predicate, then a deterministic
/// final sort matching `Vec<PathBuf>::sort()` — component-wise, each
/// component compared byte-wise.
func collectFiles(_ root: String, _ pred: (String) -> Bool) -> [String] {
    var out: [String] = []
    collectFilesInner(root, pred, &out)
    out.sort { pathComponentsLess($0, $1) }
    return out
}

private func collectFilesInner(_ root: String, _ pred: (String) -> Bool, _ out: inout [String]) {
    guard let entries = try? FileManager.default.contentsOfDirectory(atPath: root) else {
        return
    }
    for name in entries {
        let path = joinPath(root, name)
        var sb = stat()
        guard lstat(path, &sb) == 0 else { continue }
        let mode = sb.st_mode & S_IFMT
        if mode == S_IFDIR {
            collectFilesInner(path, pred, &out)
        } else if mode == S_IFREG, pred(path) {
            out.append(path)
        }
    }
}

/// PathBuf ordering: compare component sequences; components compare as raw
/// bytes (OsStr order), not Unicode-collated Strings.
func pathComponentsLess(_ a: String, _ b: String) -> Bool {
    let ca = a.split(separator: "/", omittingEmptySubsequences: true)
    let cb = b.split(separator: "/", omittingEmptySubsequences: true)
    var i = 0
    while i < ca.count, i < cb.count {
        let x = Array(ca[i].utf8)
        let y = Array(cb[i].utf8)
        if x != y { return x.lexicographicallyPrecedes(y) }
        i += 1
    }
    return ca.count < cb.count
}

/// `Path::extension()`: text after the final '.' of the file name, unless the
/// name starts with that dot (hidden files have no extension).
func rustExtension(_ path: String) -> String? {
    let name = path.split(separator: "/", omittingEmptySubsequences: true).last ?? ""
    guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return nil }
    return String(name[name.index(after: dot)...])
}

/// `Path::file_name()`: the final path component.
func rustFileName(_ path: String) -> String? {
    let name = path.split(separator: "/", omittingEmptySubsequences: true).last
    return name.map(String.init)
}

/// `Path::file_stem()`: the file name without its extension. A leading-dot
/// name with no other dot is its own stem, matching Rust.
func rustFileStem(_ path: String) -> String? {
    guard let name = rustFileName(path) else { return nil }
    guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return name }
    return String(name[..<dot])
}

/// `fs::read_to_string`: whole-file read that fails on invalid UTF-8.
func readToString(_ path: String) -> String? {
    guard let data = FileManager.default.contents(atPath: path) else { return nil }
    return String(data: data, encoding: .utf8)
}

/// `str::lines()`: split on '\n', strip one trailing '\r' per line, and no
/// trailing empty line for a final newline.
func rustLines(_ s: String) -> [String] {
    var chunks = s.utf8.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
        .map { chunk -> String in
            if chunk.last == UInt8(ascii: "\r") {
                return String(decoding: chunk.dropLast(), as: UTF8.self)
            }
            return String(decoding: chunk, as: UTF8.self)
        }
    if chunks.last?.isEmpty == true { chunks.removeLast() }
    return chunks
}

/// `PathBuf::join` for the relative tails used here.
func joinPath(_ a: String, _ b: String) -> String {
    if a.isEmpty { return b }
    if a.hasSuffix("/") { return a + b }
    return a + "/" + b
}

func homeDir() -> String? {
    ProcessInfo.processInfo.environment["HOME"]
}

func xdgDataHome(_ home: String) -> String {
    if let xdg = ProcessInfo.processInfo.environment["XDG_DATA_HOME"] {
        return xdg
    }
    return joinPath(joinPath(home, ".local"), "share")
}

/// Port of orca_codex_homes (usage_graph.rs:2251-2281): every immediate
/// child of `<data dir>/orca/codex-runtime-home/` holding a sessions or
/// archived_sessions directory.
func orcaCodexHomes(_ home: String) -> [String] {
    var homes: [String] = []
    var dataDirs = [
        joinPath(joinPath(joinPath(home, "Library"), "Application Support"), "orca"),
        joinPath(xdgDataHome(home), "orca"),
    ]
    if let appdata = ProcessInfo.processInfo.environment["APPDATA"] {
        dataDirs.append(joinPath(appdata, "orca"))
    }
    for dataDir in dataDirs {
        let runtimeRoot = joinPath(dataDir, "codex-runtime-home")
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: runtimeRoot)
        else { continue }
        for name in entries {
            let candidate = joinPath(runtimeRoot, name)
            if isDirectory(joinPath(candidate, "sessions"))
                || isDirectory(joinPath(candidate, "archived_sessions"))
            {
                homes.append(candidate)
            }
        }
    }
    return homes
}

/// `Path::is_file()` — follows symlinks.
func isFile(_ path: String) -> Bool {
    var sb = stat()
    guard stat(path, &sb) == 0 else { return false }
    return (sb.st_mode & S_IFMT) == S_IFREG
}

/// `Path::is_dir()` — follows symlinks.
func isDirectory(_ path: String) -> Bool {
    var sb = stat()
    guard stat(path, &sb) == 0 else { return false }
    return (sb.st_mode & S_IFMT) == S_IFDIR
}

/// Port of file_modified_timestamp_ms: mtime in whole milliseconds
/// (truncated), falling back to now for errors or pre-epoch mtimes.
func fileModifiedTimestampMs(_ path: String) -> Int64 {
    var sb = stat()
    guard stat(path, &sb) == 0 else { return nowMs() }
    let sec = Int64(sb.st_mtimespec.tv_sec)
    let nsec = Int64(sb.st_mtimespec.tv_nsec)
    if sec < 0 { return nowMs() }
    return sec * 1000 + nsec / 1_000_000
}

func nowMs() -> Int64 {
    Int64(Date().timeIntervalSince1970 * 1000.0)
}

/// BufRead::lines() semantics over raw file bytes: split on '\n', strip a
/// trailing '\r' per line, no trailing empty line for a final '\n', and STOP
/// at the first non-UTF-8 line (Rust's `map_while(Result::ok)` ends the
/// iteration on an invalid-UTF-8 error).
func jsonlLines(_ data: Data) -> [String] {
    var chunks = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
    if chunks.last?.isEmpty == true { chunks.removeLast() }
    var lines: [String] = []
    lines.reserveCapacity(chunks.count)
    for chunk in chunks {
        var c = chunk
        if c.last == UInt8(ascii: "\r") { c = c.dropLast() }
        guard let s = String(bytes: c, encoding: .utf8) else { break }
        lines.append(s)
    }
    return lines
}
