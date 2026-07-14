import Foundation

enum LocalTokenUsageReader {
    private static let sessionDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex/sessions", isDirectory: true)

    static func read() -> TokenUsageSummary? {
        guard let enumerator = FileManager.default.enumerator(
            at: sessionDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        let calendar = Calendar.current
        let now = Date()
        let todayStart = calendar.startOfDay(for: now)
        guard
            let thirtyDayStart = calendar.date(byAdding: .day, value: -29, to: todayStart),
            let tomorrowStart = calendar.date(byAdding: .day, value: 1, to: todayStart),
            let oneHourStart = calendar.date(byAdding: .hour, value: -1, to: now),
            let fiveHourStart = calendar.date(byAdding: .hour, value: -5, to: now),
            let sevenDayUsageStart = calendar.date(byAdding: .day, value: -7, to: now)
        else {
            return nil
        }

        var cumulativeTokens = 0
        var oneHourTokens = 0
        var fiveHourTokens = 0
        var sevenDayTokens = 0
        var dailyTokens = Array(repeating: 0, count: 30)
        var hourlyTokens = Array(repeating: 0, count: 24)

        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "jsonl" else {
                continue
            }

            let fileUsage = readUsage(
                from: fileURL,
                calendar: calendar,
                thirtyDayStart: thirtyDayStart,
                todayStart: todayStart,
                tomorrowStart: tomorrowStart,
                oneHourStart: oneHourStart,
                fiveHourStart: fiveHourStart,
                sevenDayUsageStart: sevenDayUsageStart,
                now: now
            )
            cumulativeTokens += fileUsage.finalTotalTokens
            oneHourTokens += fileUsage.oneHourTokens
            fiveHourTokens += fileUsage.fiveHourTokens
            sevenDayTokens += fileUsage.sevenDayTokens

            for index in dailyTokens.indices {
                dailyTokens[index] += fileUsage.dailyTokens[index]
            }
            for index in hourlyTokens.indices {
                hourlyTokens[index] += fileUsage.hourlyTokens[index]
            }
        }

        return TokenUsageSummary(
            yesterdayTokens: dailyTokens[28],
            cumulativeTokens: cumulativeTokens,
            oneHourTokens: oneHourTokens,
            fiveHourTokens: fiveHourTokens,
            sevenDayTokens: sevenDayTokens,
            dailyTokens: dailyTokens,
            hourlyTokens: hourlyTokens
        )
    }

    private static func readUsage(
        from fileURL: URL,
        calendar: Calendar,
        thirtyDayStart: Date,
        todayStart: Date,
        tomorrowStart: Date,
        oneHourStart: Date,
        fiveHourStart: Date,
        sevenDayUsageStart: Date,
        now: Date
    ) -> (dailyTokens: [Int], hourlyTokens: [Int], oneHourTokens: Int, fiveHourTokens: Int, sevenDayTokens: Int, finalTotalTokens: Int) {
        guard let contents = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return (Array(repeating: 0, count: 30), Array(repeating: 0, count: 24), 0, 0, 0, 0)
        }

        var dailyTokens = Array(repeating: 0, count: 30)
        var hourlyTokens = Array(repeating: 0, count: 24)
        var oneHourTokens = 0
        var fiveHourTokens = 0
        var sevenDayTokens = 0
        var finalTotalTokens = 0

        for line in contents.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.range(of: "\"token_count\"") != nil else {
                continue
            }

            let data = Data(line.utf8)
            guard
                let object = try? JSONSerialization.jsonObject(with: data),
                let event = object as? [String: Any],
                let payload = event["payload"] as? [String: Any],
                payload["type"] as? String == "token_count",
                let info = payload["info"] as? [String: Any]
            else {
                continue
            }

            if let totalUsage = info["total_token_usage"] as? [String: Any],
               let totalTokens = intValue(totalUsage["total_tokens"]) {
                finalTotalTokens = totalTokens
            }

            guard
                let timestampString = event["timestamp"] as? String,
                let timestamp = parseDate(timestampString),
                let lastUsage = info["last_token_usage"] as? [String: Any],
                let lastTokens = intValue(lastUsage["total_tokens"])
            else {
                continue
            }

            if timestamp >= thirtyDayStart && timestamp < tomorrowStart {
                let eventDay = calendar.startOfDay(for: timestamp)
                if let dayIndex = calendar.dateComponents([.day], from: thirtyDayStart, to: eventDay).day,
                   dailyTokens.indices.contains(dayIndex) {
                    dailyTokens[dayIndex] += lastTokens
                }
            }

            if timestamp >= todayStart && timestamp < tomorrowStart {
                let hour = calendar.component(.hour, from: timestamp)
                if hourlyTokens.indices.contains(hour) {
                    hourlyTokens[hour] += lastTokens
                }
            }

            if timestamp >= fiveHourStart && timestamp <= now {
                fiveHourTokens += lastTokens
            }

            if timestamp >= oneHourStart && timestamp <= now {
                oneHourTokens += lastTokens
            }

            if timestamp >= sevenDayUsageStart && timestamp <= now {
                sevenDayTokens += lastTokens
            }
        }

        return (dailyTokens, hourlyTokens, oneHourTokens, fiveHourTokens, sevenDayTokens, finalTotalTokens)
    }

    private static func parseDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) {
            return date
        }

        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int {
            return int
        }
        if let double = value as? Double {
            return Int(double)
        }
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let string = value as? String {
            return Int(string)
        }
        return nil
    }
}
