import Foundation
import SQLite3
import ServiceManagement

// First-run import of the Tauri app's state. Runs once (marker key), never
// throws, never blocks launch on failure — a user with unreadable legacy
// state just gets defaults.
//
// Sources, in preference order:
//  1. settings-export.json — written by Tokcat 0.1.42+ (the bridge release)
//     via the `export_settings` command on every settings change.
//  2. The Tauri WKWebView's localStorage sqlite — covers users who jumped
//     from any pre-bridge version straight to the Swift app. Layout
//     (verified on a live install): ~/Library/WebKit/<bundle id>/WebsiteData/
//     Default/<salt>/<salt>/LocalStorage/localstorage.sqlite3 with an
//     `origin` sibling containing "tauri", ItemTable(key, value) where
//     value is a UTF-16LE blob. WAL is in use, so the file must be opened
//     through SQLite (read-only), never raw-read.
//
// Also migrates autostart: the Tauri app used a LaunchAgent plist
// (~/Library/LaunchAgents/Tokcat.plist) pointing at the app binary; the
// native app uses SMAppService. The old plist is booted out and deleted
// even when autostart was off (a stale disabled plist may exist).
public enum TauriMigration {
    static let markerKey = "tokcat.migration.v1.done"

    public static func runIfNeeded(defaults: UserDefaults = .standard,
                                   fileManager: FileManager = .default) {
        guard !defaults.bool(forKey: markerKey) else { return }
        // Only migrate when running from the location the Tauri app is
        // updated in place at. A debug build launched from DerivedData must
        // never delete the production app's LaunchAgent or register itself
        // as a login item (this happened once during development — hence
        // the guard). TOKCAT_FORCE_MIGRATION=1 overrides for testing.
        let env = ProcessInfo.processInfo.environment
        guard Bundle.main.bundleURL.path.hasPrefix("/Applications/")
                || env["TOKCAT_FORCE_MIGRATION"] == "1" else { return }
        let home = fileManager.homeDirectoryForCurrentUser

        let imported = importFromExportFile(home: home)
            ?? importFromWebKitStorage(home: home, fileManager: fileManager)
        if let imported {
            apply(imported, to: defaults)
        }
        migrateAutostart(home: home, fileManager: fileManager,
                         wantsAutostart: imported?.autostart ?? false)

        defaults.set(true, forKey: markerKey)
    }

    // MARK: - Imported state

    struct Imported {
        var settingsJSON: Data?  // the tokcat:settings:v1 blob, verbatim
        var theme: String?
        var usageView: String?
        var autostart: Bool
    }

    private static func apply(_ imported: Imported, to defaults: UserDefaults) {
        // The DashboardStore blob decoder is lenient (optional fields,
        // legacy animationStyle collapse), so the TS JSON is stored as-is.
        if let json = imported.settingsJSON {
            defaults.set(json, forKey: "tokcat.settings.v1")
        }
        if let theme = imported.theme, !theme.isEmpty {
            defaults.set(theme, forKey: "tokcat.theme.v1")
        }
        if let view = imported.usageView, view == "2d" || view == "3d" {
            defaults.set(view, forKey: "tokcat.usageView.v1")
        }
    }

    private static func autostartFlag(fromSettingsJSON data: Data?) -> Bool {
        guard let data,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return obj["autostart"] as? Bool ?? false
    }

    // MARK: - Source 1: settings-export.json (bridge release)

    static func importFromExportFile(home: URL) -> Imported? {
        let path = home.appendingPathComponent(
            "Library/Application Support/com.handlecusion.tokcat/settings-export.json")
        guard let data = try? Data(contentsOf: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let settings = obj["settings"] as? [String: Any]
        else { return nil }
        let settingsJSON = try? JSONSerialization.data(withJSONObject: settings)
        return Imported(
            settingsJSON: settingsJSON,
            theme: obj["theme"] as? String,
            usageView: obj["usageView"] as? String,
            autostart: settings["autostart"] as? Bool ?? false)
    }

    // MARK: - Source 2: WKWebView localStorage sqlite

    static func importFromWebKitStorage(home: URL, fileManager: FileManager) -> Imported? {
        let base = home.appendingPathComponent(
            "Library/WebKit/com.handlecusion.tokcat/WebsiteData/Default")
        guard let level1 = try? fileManager.contentsOfDirectory(
            at: base, includingPropertiesForKeys: nil) else { return nil }

        for outer in level1 {
            guard let level2 = try? fileManager.contentsOfDirectory(
                at: outer, includingPropertiesForKeys: nil) else { continue }
            for inner in level2 {
                let originFile = inner.appendingPathComponent("origin")
                guard let origin = try? String(contentsOf: originFile, encoding: .utf8),
                      origin.contains("tauri") else { continue }
                let db = inner.appendingPathComponent("LocalStorage/localstorage.sqlite3")
                if let items = readItemTable(at: db.path) {
                    let settingsJSON = items["tokcat:settings:v1"]
                    return Imported(
                        settingsJSON: settingsJSON,
                        theme: items["tokcat:theme:v1"].flatMap { String(data: $0, encoding: .utf8) },
                        usageView: items["tokcat:usageview:v1"].flatMap { String(data: $0, encoding: .utf8) },
                        autostart: autostartFlag(fromSettingsJSON: settingsJSON))
                }
            }
        }
        return nil
    }

    // Reads ItemTable and decodes the UTF-16LE value blobs to UTF-8 Data.
    private static func readItemTable(at path: String) -> [String: Data]? {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let db = handle else {
            sqlite3_close(handle)
            return nil
        }
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT key, value FROM ItemTable", -1, &stmt, nil)
                == SQLITE_OK, let s = stmt else { return nil }
        defer { sqlite3_finalize(s) }

        var out: [String: Data] = [:]
        while sqlite3_step(s) == SQLITE_ROW {
            guard let keyC = sqlite3_column_text(s, 0) else { continue }
            let key = String(cString: keyC)
            guard let blob = sqlite3_column_blob(s, 1) else { continue }
            let count = Int(sqlite3_column_bytes(s, 1))
            let raw = Data(bytes: blob, count: count)
            // WebKit stores localStorage values as UTF-16LE.
            guard let text = String(data: raw, encoding: .utf16LittleEndian) else { continue }
            out[key] = Data(text.utf8)
        }
        return out.isEmpty ? nil : out
    }

    // MARK: - Autostart

    private static func migrateAutostart(home: URL, fileManager: FileManager,
                                         wantsAutostart: Bool) {
        let plist = home.appendingPathComponent("Library/LaunchAgents/Tokcat.plist")
        if fileManager.fileExists(atPath: plist.path) {
            // Boot the old agent out of launchd before deleting; failure is
            // fine (agent may not be loaded).
            let bootout = Process()
            bootout.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            bootout.arguments = ["bootout", "gui/\(getuid())/Tokcat"]
            bootout.standardOutput = FileHandle.nullDevice
            bootout.standardError = FileHandle.nullDevice
            try? bootout.run()
            bootout.waitUntilExit()
            try? fileManager.removeItem(at: plist)
        }
        if wantsAutostart {
            try? SMAppService.mainApp.register()
        }
    }
}
