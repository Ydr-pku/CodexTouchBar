import Foundation

protocol RateLimitStoreDelegate: AnyObject {
    func rateLimitStore(_ store: RateLimitStore, didUpdate state: RateLimitDisplayState)
}

final class RateLimitStore {
    weak var delegate: RateLimitStoreDelegate?

    private let client = CodexAppServerClient()
    private let hourlyUsageStore = HourlyUsageStore()
    private let tokenUsageQueue = DispatchQueue(label: "TouchBarCodexToken.LocalTokenUsageReader", qos: .utility)
    private var timer: Timer?
    private var state = RateLimitDisplayState.initial
    private var refreshInFlight = false
    private var tokenUsageInFlight = false
    private var accountTokenUsageInFlight = false
    private var isStarted = false

    func start() {
        guard !isStarted else {
            refresh()
            return
        }
        isStarted = true

        client.onRateLimitsUpdated = { [weak self] in
            self?.refresh()
        }

        client.start { [weak self] result in
            guard let self else {
                return
            }

            switch result {
            case .success:
                self.refresh()
                self.startTimer()
            case .failure(let error):
                self.publishError(error.localizedDescription)
            }
        }
    }

    func stop() {
        isStarted = false
        refreshInFlight = false
        tokenUsageInFlight = false
        accountTokenUsageInFlight = false
        timer?.invalidate()
        timer = nil
        client.stop()
    }

    func refresh() {
        guard !refreshInFlight else {
            return
        }

        refreshInFlight = true
        state.isRefreshing = true
        state.errorMessage = nil
        publish()

        client.readRateLimits { [weak self] result in
            guard let self else {
                return
            }

            self.refreshInFlight = false

            switch result {
            case .success(let response):
                self.apply(response)
            case .failure(let error):
                self.state.isRefreshing = false
                self.state.errorMessage = error.localizedDescription
                self.publish()
            }
        }
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    private func apply(_ response: GetAccountRateLimitsResponse) {
        let snapshot = response.rateLimitsByLimitId?["codex"] ?? response.rateLimits
        let windows = classifyWindows(primary: snapshot.primary, secondary: snapshot.secondary)

        state.fiveHour = windows.fiveHour
        state.weekly = windows.weekly
        state.isRefreshing = false
        state.lastUpdated = Date()
        state.errorMessage = nil
        if let meter = state.weekly ?? state.fiveHour {
            do {
                try hourlyUsageStore.saveQuotaSnapshot(meter)
            } catch {
                NSLog("Unable to save quota snapshot: \(error.localizedDescription)")
            }
        }
        publish()
        refreshTokenUsage()
        refreshAccountTokenUsage()
    }

    private func classifyWindows(primary: RateLimitWindow?, secondary: RateLimitWindow?) -> (fiveHour: LimitMeter?, weekly: LimitMeter?) {
        let candidates = [primary, secondary].compactMap { $0 }

        let fiveHourWindow = candidates.first { window in
            guard let duration = window.windowDurationMins else {
                return false
            }
            return abs(duration - 300) < 30
        } ?? (primary?.windowDurationMins == nil ? primary : nil)

        let weeklyWindow = candidates.first { window in
            guard let duration = window.windowDurationMins else {
                return false
            }
            return duration >= 7 * 24 * 60 - 60
        } ?? (secondary?.windowDurationMins == nil ? secondary : nil)

        let fiveHour = fiveHourWindow.map {
            LimitMeter(title: "5 小时", shortTitle: "5h", window: $0)
        }

        let weekly = weeklyWindow.map {
            LimitMeter(title: "周限额", shortTitle: "W", window: $0)
        }

        return (fiveHour, weekly)
    }

    private func publishError(_ message: String) {
        state.isRefreshing = false
        state.errorMessage = message
        publish()
    }

    private func publish() {
        delegate?.rateLimitStore(self, didUpdate: state)
    }

    private func refreshTokenUsage() {
        guard !tokenUsageInFlight else {
            return
        }

        tokenUsageInFlight = true
        tokenUsageQueue.async { [weak self] in
            let tokenUsage = LocalTokenUsageReader.read()
            if let tokenUsage {
                do {
                    try self?.hourlyUsageStore.upsert(tokenUsage.hourlyBuckets)
                } catch {
                    NSLog("Unable to save hourly token usage: \(error.localizedDescription)")
                }
            }

            DispatchQueue.main.async {
                guard let self else {
                    return
                }

                self.tokenUsageInFlight = false
                guard self.isStarted else {
                    return
                }

                self.state.tokenUsage = tokenUsage
                self.publish()
            }
        }
    }

    private func refreshAccountTokenUsage() {
        guard !accountTokenUsageInFlight else {
            return
        }

        accountTokenUsageInFlight = true
        client.readAccountTokenUsage { [weak self] result in
            guard let self else {
                return
            }

            self.accountTokenUsageInFlight = false
            guard self.isStarted else {
                return
            }

            switch result {
            case .success(let response):
                self.state.accountTokenUsage = self.makeAccountTokenUsage(from: response)
                self.publish()
            case .failure(let error):
                NSLog("Unable to read account token usage: \(error.localizedDescription)")
            }
        }
    }

    private func makeAccountTokenUsage(from response: GetAccountTokenUsageResponse) -> AccountTokenUsage {
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: Date())
        let thirtyDayStart = calendar.date(byAdding: .day, value: -29, to: todayStart) ?? todayStart
        var dailyTokens = Array(repeating: 0, count: 30)

        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"

        for bucket in response.dailyUsageBuckets ?? [] {
            guard let date = formatter.date(from: bucket.startDate),
                  let dayIndex = calendar.dateComponents(
                    [.day],
                    from: thirtyDayStart,
                    to: calendar.startOfDay(for: date)
                  ).day,
                  dailyTokens.indices.contains(dayIndex) else {
                continue
            }
            dailyTokens[dayIndex] += bucket.tokens
        }

        return AccountTokenUsage(
            dailyTokens: dailyTokens,
            lifetimeTokens: response.summary.lifetimeTokens
        )
    }
}
