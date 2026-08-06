import Foundation

// Port of the Cursor state-DB readers in cursor_usage.rs (:88-132).
// Cursor keeps its live session token in the Electron key/value store
// (state.vscdb); the macOS Keychain copy is only written at login and goes
// stale, so the state DB is the reliable source.

enum CursorState {
    static func stateDBPath() -> Result<String, QuotaError> {
        guard let home = quotaHomeDirectory() else {
            return .failure("HOME is not set")
        }
        return .success(
            home + "/Library/Application Support/Cursor/User/globalStorage/state.vscdb")
    }

    /// Read one value out of Cursor's Electron key/value store, or nil when
    /// Cursor isn't installed / the key is absent. Cursor stores JSON
    /// scalars, so plain strings arrive quoted — strip them the same way
    /// `readAccessToken` does.
    ///
    /// Only ever called with compile-time constant keys, which is why plain
    /// SQL interpolation is safe here (the shared SQLite wrapper has no
    /// binder).
    static func readStateValue(_ key: String) -> String? {
        guard case .success(let path) = stateDBPath() else { return nil }
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        guard let db = SQLiteDatabase(readOnlyAtPath: path) else { return nil }
        guard
            let stmt = db.prepare("SELECT value FROM ItemTable WHERE key = '\(key)'"),
            stmt.step(),
            let value = stmt.text(0)
        else { return nil }
        let cleaned = value
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? nil : cleaned
    }

    /// Read Cursor's live OAuth access token from the state DB, with the
    /// user-facing error strings the toggle command shows.
    static func readAccessToken() -> Result<String, QuotaError> {
        let path: String
        switch stateDBPath() {
        case .failure(let error): return .failure(error)
        case .success(let value): path = value
        }
        guard FileManager.default.fileExists(atPath: path) else {
            return .failure("Cursor not found. Install Cursor and sign in to enable usage.")
        }
        guard let db = SQLiteDatabase(readOnlyAtPath: path) else {
            return .failure("open Cursor state.vscdb: cannot open database")
        }
        guard
            let stmt = db.prepare(
                "SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken'"),
            stmt.step(),
            let raw = stmt.text(0)
        else {
            return .failure("Cursor session token not found. Open Cursor and sign in.")
        }
        let token = raw
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            .trimmingCharacters(in: .whitespaces)
        if token.isEmpty {
            return .failure("Cursor session token is empty. Sign in to Cursor.")
        }
        return .success(token)
    }
}
