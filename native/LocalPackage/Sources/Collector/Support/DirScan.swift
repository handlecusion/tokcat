import Foundation

// Bulk directory enumeration for the live tailer's hot loop.
//
// UsageTailer.tick() re-walks every Claude/Codex/Grok session root once per
// TAIL_TICK_SECS to spot file growth, which on a working machine means a few
// thousand entries every 5 seconds. Doing that with
// FileManager.contentsOfDirectory + one lstat per entry cost ~2.3% CPU
// continuously (measured with `sample`: ~35% of it inside CoreServices'
// URL enumerator, ~25% in lstat) — an order of magnitude more energy than a
// menu-bar app should draw.
//
// getattrlistbulk returns name + object type + mtime + data length for many
// entries per syscall, so one directory costs a couple of syscalls instead of
// 1 + N. Semantics match the previous readdir/lstat pair: entries are
// described as themselves, symlinks are NOT followed.
//
// Set TOKCAT_NO_BULK_SCAN=1 to force the readdir + lstat fallback (also used
// automatically on any filesystem that rejects getattrlistbulk).

/// One directory entry with the attributes the tailer needs.
struct DirEntryInfo: Equatable {
    var name: String
    var isDir: Bool
    var isRegular: Bool
    /// Data-fork length; 0 for non-regular entries.
    var size: UInt64
    /// mtime in whole milliseconds; 0 for pre-epoch/unavailable, matching
    /// `statMtimeMs`.
    var mtimeMs: Int64
}

// vnode types from sys/vnode.h (not re-exported by the Darwin module).
private let vtypeRegular: UInt32 = 1  // VREG
private let vtypeDirectory: UInt32 = 2  // VDIR

// The ATTR_* macros import with mixed signedness (ATTR_CMN_RETURNED_ATTRS is
// 0x80000000); normalize them to attrgroup_t once.
private let attrCmnReturnedAttrs = attrgroup_t(truncatingIfNeeded: ATTR_CMN_RETURNED_ATTRS)
private let attrCmnName = attrgroup_t(truncatingIfNeeded: ATTR_CMN_NAME)
private let attrCmnObjType = attrgroup_t(truncatingIfNeeded: ATTR_CMN_OBJTYPE)
private let attrCmnModTime = attrgroup_t(truncatingIfNeeded: ATTR_CMN_MODTIME)
private let attrFileDataLength = attrgroup_t(truncatingIfNeeded: ATTR_FILE_DATALENGTH)

private let bulkScanDisabled: Bool =
    ProcessInfo.processInfo.environment["TOKCAT_NO_BULK_SCAN"] == "1"

/// Enumerate `path`, returning every entry (excluding `.`/`..`) with its
/// type, size and mtime. Empty when the directory can't be read.
func scanDirectory(_ path: String) -> [DirEntryInfo] {
    scanDirectoryForTesting(path, forceFallback: bulkScanDisabled)
}

/// `scanDirectory` with the bulk path switchable, so tests can assert the two
/// implementations agree.
func scanDirectoryForTesting(_ path: String, forceFallback: Bool) -> [DirEntryInfo] {
    if !forceFallback, let bulk = scanDirectoryBulk(path) { return bulk }
    return scanDirectoryFallback(path)
}

// MARK: - getattrlistbulk

private func scanDirectoryBulk(_ path: String) -> [DirEntryInfo]? {
    let fd = open(path, O_RDONLY | O_DIRECTORY)
    guard fd >= 0 else { return nil }
    defer { close(fd) }

    var request = attrlist()
    request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
    request.commonattr =
        attrCmnReturnedAttrs | attrCmnName | attrCmnObjType | attrCmnModTime
    request.fileattr = attrFileDataLength

    var out: [DirEntryInfo] = []
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
        let returned: Int = buffer.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return -1 }
            return Int(getattrlistbulk(fd, &request, base, raw.count, 0))
        }
        if returned == 0 { break }  // no more entries
        if returned < 0 {
            // Unsupported (or a mid-walk failure): let the caller's fallback
            // produce the whole listing rather than a partial one.
            return nil
        }
        let ok = buffer.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            return decodeBulkEntries(base, limit: raw.count, count: returned, into: &out)
        }
        guard ok else { return nil }
    }
    return out
}

/// Walk `count` packed attribute records. getattrlist packs fields back to
/// back in canonical bitmap order with no alignment padding, so every read is
/// unaligned; each record's leading `u_int32_t` length includes its trailing
/// variable-length data.
private func decodeBulkEntries(
    _ base: UnsafeRawPointer, limit: Int, count: Int, into out: inout [DirEntryInfo]
) -> Bool {
    var entry = base
    var consumed = 0
    for _ in 0..<count {
        guard limit - consumed >= MemoryLayout<UInt32>.size else { return false }
        let length = Int(entry.loadUnaligned(as: UInt32.self))
        guard length > 0, consumed + length <= limit else { return false }

        var offset = MemoryLayout<UInt32>.size
        let returnedAttrs = entry.loadUnaligned(
            fromByteOffset: offset, as: attribute_set_t.self)
        offset += MemoryLayout<attribute_set_t>.size

        var name = ""
        if returnedAttrs.commonattr & attrCmnName != 0 {
            let reference = entry.loadUnaligned(
                fromByteOffset: offset, as: attrreference_t.self)
            let nameOffset = offset + Int(reference.attr_dataoffset)
            guard nameOffset >= 0, nameOffset < length else { return false }
            name = String(
                cString: entry.advanced(by: nameOffset).assumingMemoryBound(to: CChar.self))
            offset += MemoryLayout<attrreference_t>.size
        }

        var objectType: UInt32 = 0
        if returnedAttrs.commonattr & attrCmnObjType != 0 {
            objectType = entry.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
            offset += MemoryLayout<UInt32>.size
        }

        var mtimeMs: Int64 = 0
        if returnedAttrs.commonattr & attrCmnModTime != 0 {
            let modified = entry.loadUnaligned(fromByteOffset: offset, as: timespec.self)
            mtimeMs = timespecToMs(modified)
            offset += MemoryLayout<timespec>.size
        }

        var size: UInt64 = 0
        if returnedAttrs.fileattr & attrFileDataLength != 0 {
            let dataLength = entry.loadUnaligned(fromByteOffset: offset, as: off_t.self)
            size = dataLength > 0 ? UInt64(dataLength) : 0
        }

        if name != "." && name != ".." && !name.isEmpty {
            let isRegular = objectType == vtypeRegular
            out.append(DirEntryInfo(
                name: name,
                isDir: objectType == vtypeDirectory,
                isRegular: isRegular,
                // The kernel reports a data length for symlinks too (the
                // target string); only a regular file's length is a size.
                size: isRegular ? size : 0,
                mtimeMs: mtimeMs))
        }

        entry = entry.advanced(by: length)
        consumed += length
    }
    return true
}

// MARK: - readdir + lstat fallback

private func scanDirectoryFallback(_ path: String) -> [DirEntryInfo] {
    guard let dir = opendir(path) else { return [] }
    defer { closedir(dir) }
    var out: [DirEntryInfo] = []
    while let entry = readdir(dir) {
        let name = withUnsafeBytes(of: &entry.pointee.d_name) { raw -> String in
            String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
        }
        if name == "." || name == ".." { continue }
        // lstat, not d_type: the tailer needs size and mtime anyway.
        var sb = stat()
        guard lstat(joinPath(path, name), &sb) == 0 else { continue }
        let mode = sb.st_mode & S_IFMT
        out.append(DirEntryInfo(
            name: name,
            isDir: mode == S_IFDIR,
            isRegular: mode == S_IFREG,
            size: mode == S_IFREG ? UInt64(max(sb.st_size, 0)) : 0,
            mtimeMs: timespecToMs(sb.st_mtimespec)))
    }
    return out
}

private func timespecToMs(_ ts: timespec) -> Int64 {
    let seconds = Int64(ts.tv_sec)
    guard seconds >= 0 else { return 0 }
    return seconds * 1000 + Int64(ts.tv_nsec) / 1_000_000
}
