import Foundation
import SQLite3
import Testing

@testable import Model

@Suite struct TauriMigrationTests {
    private func makeTempHome() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokcat-migration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func importsFromExportFile() throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let dir = home.appendingPathComponent(
            "Library/Application Support/com.handlecusion.tokcat")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let export: [String: Any] = [
            "schema": 1,
            "exportedAt": "2026-08-06T00:00:00Z",
            "settings": ["trayMode": "today_cost", "autostart": true,
                         "animationStyle": "cat2"],
            "theme": "Orange",
            "usageView": "3d",
        ]
        try JSONSerialization.data(withJSONObject: export)
            .write(to: dir.appendingPathComponent("settings-export.json"))

        let imported = try #require(TauriMigration.importFromExportFile(home: home))
        #expect(imported.theme == "Orange")
        #expect(imported.usageView == "3d")
        #expect(imported.autostart == true)
        let blob = try JSONSerialization.jsonObject(
            with: try #require(imported.settingsJSON)) as? [String: Any]
        #expect(blob?["trayMode"] as? String == "today_cost")
        // Legacy style survives verbatim — DashboardStore's decoder does
        // the cube/cat1/cat2 → cat collapse.
        #expect(blob?["animationStyle"] as? String == "cat2")
    }

    @Test func importsFromWebKitStorage() throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let storageDir = home.appendingPathComponent(
            "Library/WebKit/com.handlecusion.tokcat/WebsiteData/Default/AAA/BBB")
        let localStorage = storageDir.appendingPathComponent("LocalStorage")
        try FileManager.default.createDirectory(at: localStorage,
                                                withIntermediateDirectories: true)
        try Data("tauri_localhost_0".utf8)
            .write(to: storageDir.appendingPathComponent("origin"))

        // Build a WebKit-shaped localstorage db: ItemTable with UTF-16LE
        // value blobs (the on-disk format verified on a live install).
        let dbPath = localStorage.appendingPathComponent("localstorage.sqlite3").path
        var handle: OpaquePointer?
        #expect(sqlite3_open(dbPath, &handle) == SQLITE_OK)
        let db = try #require(handle)
        defer { sqlite3_close(db) }
        sqlite3_exec(db, "CREATE TABLE ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB NOT NULL ON CONFLICT FAIL)", nil, nil, nil)
        func insert(_ key: String, _ value: String) {
            var stmt: OpaquePointer?
            sqlite3_prepare_v2(db, "INSERT INTO ItemTable (key, value) VALUES (?, ?)", -1, &stmt, nil)
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, key, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            let utf16 = value.data(using: .utf16LittleEndian)!
            _ = utf16.withUnsafeBytes { buf in
                sqlite3_bind_blob(stmt, 2, buf.baseAddress, Int32(buf.count),
                                  unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }
            #expect(sqlite3_step(stmt) == SQLITE_DONE)
        }
        insert("tokcat:settings:v1",
               #"{"trayMode":"plan_percent","autostart":true,"planProvider":"claude"}"#)
        insert("tokcat:theme:v1", "Graphite")
        insert("tokcat:usageview:v1", "2d")

        let imported = try #require(TauriMigration.importFromWebKitStorage(
            home: home, fileManager: .default))
        #expect(imported.theme == "Graphite")
        #expect(imported.usageView == "2d")
        #expect(imported.autostart == true)
        let blob = try JSONSerialization.jsonObject(
            with: try #require(imported.settingsJSON)) as? [String: Any]
        #expect(blob?["trayMode"] as? String == "plan_percent")
        #expect(blob?["planProvider"] as? String == "claude")
    }

    @Test func webKitStorageSkipsNonTauriOrigins() throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let storageDir = home.appendingPathComponent(
            "Library/WebKit/com.handlecusion.tokcat/WebsiteData/Default/AAA/BBB")
        try FileManager.default.createDirectory(
            at: storageDir.appendingPathComponent("LocalStorage"),
            withIntermediateDirectories: true)
        try Data("https_example.com_0".utf8)
            .write(to: storageDir.appendingPathComponent("origin"))
        #expect(TauriMigration.importFromWebKitStorage(home: home, fileManager: .default) == nil)
    }

    @Test func missingSourcesYieldNil() throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(TauriMigration.importFromExportFile(home: home) == nil)
        #expect(TauriMigration.importFromWebKitStorage(home: home, fileManager: .default) == nil)
    }
}
