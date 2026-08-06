import Foundation
import SQLite3

// Minimal SQLite C-API wrapper mirroring the rusqlite usage in
// usage_graph.rs: read-only + no-mutex open, prepare, step, and the strict
// per-column type conversions rusqlite's FromSql applies (an INTEGER column
// value is required for i64/i32, INTEGER-or-REAL for f64, TEXT for String;
// anything else fails the row, which the Rust code then skips via
// `rows.flatten()`).

final class SQLiteDatabase {
    private(set) var handle: OpaquePointer?

    /// `Connection::open_with_flags(path, READ_ONLY | NO_MUTEX)`.
    /// Fails soft (nil) on any error, like the parsers' early returns.
    init?(readOnlyAtPath path: String) {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK else {
            sqlite3_close_v2(db)
            return nil
        }
        // rusqlite verifies the connection is usable on open; a corrupt or
        // non-database file fails at prepare time either way.
        handle = db
    }

    deinit {
        sqlite3_close_v2(handle)
    }

    func prepare(_ sql: String) -> SQLiteStatement? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return nil
        }
        return SQLiteStatement(stmt)
    }
}

final class SQLiteStatement {
    let stmt: OpaquePointer

    init(_ stmt: OpaquePointer) {
        self.stmt = stmt
    }

    deinit {
        sqlite3_finalize(stmt)
    }

    /// True while a row is available; any error ends iteration, matching the
    /// Rust `rows.flatten()` loops which stop at the first step error.
    func step() -> Bool {
        sqlite3_step(stmt) == SQLITE_ROW
    }

    /// rusqlite `row.get::<_, i64>`: INTEGER storage class only.
    func i64(_ index: Int32) -> Int64? {
        guard sqlite3_column_type(stmt, index) == SQLITE_INTEGER else { return nil }
        return sqlite3_column_int64(stmt, index)
    }

    /// rusqlite `row.get::<_, i32>`: INTEGER storage class, must fit i32.
    func i32(_ index: Int32) -> Int32? {
        guard let value = i64(index) else { return nil }
        return Int32(exactly: value)
    }

    /// rusqlite `row.get::<_, f64>`: INTEGER or REAL storage class.
    func f64(_ index: Int32) -> Double? {
        switch sqlite3_column_type(stmt, index) {
        case SQLITE_INTEGER: return Double(sqlite3_column_int64(stmt, index))
        case SQLITE_FLOAT: return sqlite3_column_double(stmt, index)
        default: return nil
        }
    }

    /// rusqlite `row.get::<_, String>`: TEXT storage class only.
    func text(_ index: Int32) -> String? {
        guard sqlite3_column_type(stmt, index) == SQLITE_TEXT,
            let cString = sqlite3_column_text(stmt, index)
        else { return nil }
        return String(cString: cString)
    }
}

/// Port of sqlite_table_columns (usage_graph.rs:2191-2203).
func sqliteTableColumns(_ db: SQLiteDatabase, table: String) -> Set<String> {
    var columns = Set<String>()
    guard let stmt = db.prepare("PRAGMA table_info(\(table))") else { return columns }
    while stmt.step() {
        if let name = stmt.text(1) {
            columns.insert(name)
        }
    }
    return columns
}

/// Port of sqlite_column_or (usage_graph.rs:2205-2211).
func sqliteColumnOr(_ columns: Set<String>, _ name: String, _ fallback: String) -> String {
    columns.contains(name) ? "COALESCE(\(name), \(fallback))" : fallback
}
