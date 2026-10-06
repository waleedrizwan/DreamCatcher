import Foundation
import GRDB

/// Owns the SQLite database. The schema comes verbatim from the bundled copy
/// of `spec/schema/v1.sql` (SchemaSyncTests asserts the copy matches the
/// normative file). WAL mode; safe to use from the recording actor while the
/// app is backgrounded.
public struct AppDatabase: Sendable {
    public let writer: any DatabaseWriter

    public init(_ writer: any DatabaseWriter) throws {
        self.writer = writer
        try migrator.migrate(writer)
    }

    /// On-disk database in Application Support. The DB participates in OS
    /// backups (spec §6); the clips directory does not.
    public static func open(directory: URL) throws -> AppDatabase {
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        let dbURL = directory.appendingPathComponent("DreamCatcher.sqlite")
        var config = Configuration()
        config.journalMode = .wal
        #if os(iOS)
        // Writes must succeed while the device is locked (spec/design-ios §4):
        // never NSFileProtectionComplete.
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA secure_delete = ON")
        }
        #endif
        let queue = try DatabaseQueue(path: dbURL.path, configuration: config)
        return try AppDatabase(queue)
    }

    /// In-memory database for tests and previews.
    public static func inMemory() throws -> AppDatabase {
        try AppDatabase(DatabaseQueue())
    }

    private var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.execute(sql: Self.schemaV1SQL())
        }
        return migrator
    }

    /// The bundled, normative DDL. Internal so tests can compare it against
    /// spec/schema/v1.sql in the repo checkout.
    static func schemaV1SQL() throws -> String {
        guard let url = Bundle.module.url(forResource: "v1", withExtension: "sql") else {
            throw DatabaseError(message: "v1.sql resource missing")
        }
        // Strip the PRAGMA user_version line: GRDB's migrator owns versioning,
        // and SQLite ignores it inside migrations anyway. Everything else runs
        // verbatim.
        let sql = try String(contentsOf: url, encoding: .utf8)
        return sql
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.hasPrefix("PRAGMA user_version") }
            .joined(separator: "\n")
    }
}
