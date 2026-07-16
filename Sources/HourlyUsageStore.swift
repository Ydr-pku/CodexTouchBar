import Foundation
import SQLite3

final class HourlyUsageStore {
    enum StoreError: LocalizedError {
        case database(String)

        var errorDescription: String? {
            switch self {
            case .database(let message):
                return message
            }
        }
    }

    private static let directoryName = "TouchBarCodexToken"
    private static let databaseName = "token-usage.sqlite3"
    private static let csvName = "token-usage.csv"
    private static let quotaSnapshotName = "quota-status.json"

    func ensureStorageDirectory() throws -> URL {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directoryURL = baseURL.appendingPathComponent(Self.directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return directoryURL
    }

    func upsert(_ buckets: [HourlyTokenUsage]) throws {
        guard !buckets.isEmpty else {
            return
        }

        let database = try openDatabase()
        defer { sqlite3_close(database) }

        try execute("BEGIN IMMEDIATE", on: database)
        do {
            let incoming = Dictionary(uniqueKeysWithValues: buckets.map {
                (Int64($0.hourStart.timeIntervalSince1970.rounded()), $0.tokens)
            })
            guard let firstIncomingHour = incoming.keys.min(),
                  let currentHourDate = Calendar.current.dateInterval(of: .hour, for: Date())?.start else {
                try execute("COMMIT", on: database)
                return
            }

            let latestStoredHour = try scalarInt64("SELECT MAX(hour_start) FROM hourly_usage", on: database)
            let firstHour = min(firstIncomingHour, latestStoredHour ?? firstIncomingHour)
            let currentHour = Int64(currentHourDate.timeIntervalSince1970.rounded())

            let upsertSQL = "INSERT INTO hourly_usage(hour_start, tokens) VALUES (?, ?) ON CONFLICT(hour_start) DO UPDATE SET tokens = excluded.tokens"
            let zeroSQL = "INSERT OR IGNORE INTO hourly_usage(hour_start, tokens) VALUES (?, 0)"
            var upsertStatement: OpaquePointer?
            var zeroStatement: OpaquePointer?
            guard sqlite3_prepare_v2(database, upsertSQL, -1, &upsertStatement, nil) == SQLITE_OK,
                  let upsertStatement,
                  sqlite3_prepare_v2(database, zeroSQL, -1, &zeroStatement, nil) == SQLITE_OK,
                  let zeroStatement else {
                throw databaseError(database)
            }
            defer {
                sqlite3_finalize(upsertStatement)
                sqlite3_finalize(zeroStatement)
            }

            var hour = firstHour
            while hour <= currentHour {
                if let tokens = incoming[hour] {
                    sqlite3_reset(upsertStatement)
                    sqlite3_clear_bindings(upsertStatement)
                    sqlite3_bind_int64(upsertStatement, 1, hour)
                    sqlite3_bind_int64(upsertStatement, 2, Int64(tokens))
                    guard sqlite3_step(upsertStatement) == SQLITE_DONE else {
                        throw databaseError(database)
                    }
                } else {
                    sqlite3_reset(zeroStatement)
                    sqlite3_clear_bindings(zeroStatement)
                    sqlite3_bind_int64(zeroStatement, 1, hour)
                    guard sqlite3_step(zeroStatement) == SQLITE_DONE else {
                        throw databaseError(database)
                    }
                }
                guard hour <= Int64.max - 3_600 else {
                    throw databaseError(database)
                }
                hour += 3_600
            }
            try execute("COMMIT", on: database)
        } catch {
            try? execute("ROLLBACK", on: database)
            throw error
        }
    }

    func exportCSV() throws -> URL {
        let directoryURL = try ensureStorageDirectory()
        let database = try openDatabase()
        defer { sqlite3_close(database) }

        let sql = "SELECT hour_start, tokens FROM hourly_usage ORDER BY hour_start"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw databaseError(database)
        }
        defer { sqlite3_finalize(statement) }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm"

        var csv = "datetime,tokens\n"
        while sqlite3_step(statement) == SQLITE_ROW {
            let timestamp = sqlite3_column_int64(statement, 0)
            let tokens = sqlite3_column_int64(statement, 1)
            let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
            csv += "\(formatter.string(from: date)),\(tokens)\n"
        }

        let csvURL = directoryURL.appendingPathComponent(Self.csvName)
        try csv.write(to: csvURL, atomically: true, encoding: .utf8)
        return csvURL
    }

    func saveQuotaSnapshot(_ meter: LimitMeter) throws {
        let directoryURL = try ensureStorageDirectory()
        let snapshotURL = directoryURL.appendingPathComponent(Self.quotaSnapshotName)
        var snapshot: [String: Any] = [
            "title": meter.title,
            "remainingPercent": meter.remainingPercent,
            "updatedAt": Date().timeIntervalSince1970
        ]
        if let resetDate = meter.resetDate {
            snapshot["resetAt"] = resetDate.timeIntervalSince1970
        }
        if let durationMinutes = meter.durationMinutes {
            snapshot["durationMinutes"] = durationMinutes
        }
        let data = try JSONSerialization.data(withJSONObject: snapshot, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: snapshotURL, options: .atomic)
    }

    private func openDatabase() throws -> OpaquePointer {
        let directoryURL = try ensureStorageDirectory()
        let databaseURL = directoryURL.appendingPathComponent(Self.databaseName)
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &database, flags, nil) == SQLITE_OK,
              let database else {
            if let database {
                let error = databaseError(database)
                sqlite3_close(database)
                throw error
            }
            throw StoreError.database("无法打开 token 用量数据库")
        }

        sqlite3_busy_timeout(database, 5_000)
        do {
            try execute("PRAGMA journal_mode=WAL", on: database)
            try execute(
                "CREATE TABLE IF NOT EXISTS hourly_usage (hour_start INTEGER PRIMARY KEY NOT NULL, tokens INTEGER NOT NULL CHECK(tokens >= 0))",
                on: database
            )
            return database
        } catch {
            sqlite3_close(database)
            throw error
        }
    }

    private func execute(_ sql: String, on database: OpaquePointer) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw databaseError(database)
        }
    }

    private func scalarInt64(_ sql: String, on database: OpaquePointer) throws -> Int64? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw databaseError(database)
        }
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw databaseError(database)
        }
        guard sqlite3_column_type(statement, 0) != SQLITE_NULL else {
            return nil
        }
        return sqlite3_column_int64(statement, 0)
    }

    private func databaseError(_ database: OpaquePointer) -> StoreError {
        StoreError.database(String(cString: sqlite3_errmsg(database)))
    }
}
