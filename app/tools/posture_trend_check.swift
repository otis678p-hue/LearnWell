import Foundation

@main
enum PostureTrendCheck {
    @MainActor
    static func main() throws {
        var checks = 0
        var failures = 0
        func check(_ value: Bool, _ label: String) {
            checks += 1
            if !value { failures += 1; print("FAIL: \(label)") }
        }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
            cal.date(from: .init(year: year, month: month, day: day, hour: hour))!
        }
        func record(_ day: String, _ hour: Int, _ good: Double, _ bad: Double) -> PostureDayRecord {
            var hours = PostureDayRecord.emptyHourly
            hours[hour] = .init(good: good, bad: bad)
            return .init(day: day, good: good, bad: bad, met: false, hourly: hours)
        }
        let now = date(2026, 10, 23, 18)
        let monday = record("2026-10-19", 9, 900, 100)
        let tuesday = record("2026-10-20", 15, 100, 900)
        var live = PostureStats(dayKey: "2026-10-23", goodSeconds: 300, badSeconds: 100)
        live.hourly[9] = .init(good: 300, bad: 100)
        let records = [monday, tuesday, record("2026-10-23", 9, 999, 999), record("2026-10-24", 9, 900, 0)]
        func trend(_ range: PostureTrendRange, _ anchor: Date? = nil) -> PostureTrend {
            PostureTrendBuilder.trend(range: range, records: records, today: live, anchor: anchor, now: now, calendar: cal)
        }
        let day = trend(.day)
        check(day.bars.count == 24 && day.good == 300 && day.bad == 100, "day uses live hourly totals")
        check(day.bars[18].isCurrent, "current hour marked")
        let week = trend(.week)
        check(week.bars.count == 7 && week.bars.first?.id == "2026-10-19", "Monday-first week")
        check(week.good == 1300 && week.bad == 1100, "week sums unique historical days plus live today")
        check(week.bars[5].total == 0, "future records excluded")
        check(week.best?.hour == 9 && week.worst?.hour == 15, "weighted best and worst hours")
        check(abs(week.best!.goodFraction - 1200.0 / 1400) < 0.00001, "ratios weight tracked seconds")
        let month = trend(.month)
        check(month.bars.count == 31 && month.good == week.good, "31 daily bars for October")
        let year = trend(.year)
        check(year.bars.count == 12 && year.bars[9].total == week.trackedSeconds, "year aggregates by month")
        let historical = trend(.day, date(2026, 10, 19))
        check(historical.good == 900 && historical.bad == 100, "previous day loads archived hourly buckets")
        check(historical.bars.allSatisfy { !$0.isCurrent }, "historical hours never marked current")
        let leap = trend(.month, date(2024, 2, 20))
        check(leap.bars.count == 29, "leap-year February")
        let boundary = trend(.week, date(2027, 1, 1))
        check(boundary.bars.first?.id == "2026-12-28" && boundary.bars.last?.id == "2027-01-03", "week across year boundary")
        let duplicate = PostureTrendBuilder.trend(range: .week, records: records + [monday], today: live, now: now, calendar: cal)
        check(duplicate.good == week.good && duplicate.bad == week.bad, "duplicate days neither crash nor double count")
        let stale = PostureTrendBuilder.trend(range: .week, records: records, today: .init(dayKey: "2026-10-19"), now: now, calendar: cal)
        check(stale.bars[0].good == 900, "stale live stats cannot erase archive")
        let single = PostureTrendBuilder.slotSummary(from: [monday.hourly])
        check(single.best?.hour == 9 && single.worst?.hour == 9, "single qualifying slot is both extrema")
        let tiny = PostureTrendBuilder.slotSummary(from: [record("2026-10-19", 9, 179, 0).hourly])
        check(tiny.best == nil && tiny.worst == nil, "179-second samples excluded")
        let exact = PostureTrendBuilder.slotSummary(from: [record("2026-10-19", 9, 180, 0).hourly])
        check(exact.best != nil && exact.worst != nil, "180-second threshold is inclusive")
        let ties = PostureTrendBuilder.slotSummary(from: [monday.hourly, record("2026-10-20", 8, 900, 100).hourly])
        check(ties.best?.hour == 8 && ties.worst?.hour == 8, "equal ratios have deterministic ties")

        // The date controls must work on the first day, before history exists.
        let firstDayNav = PostureTrendNavigation(records: [], now: now, calendar: cal)
        let yesterday = firstDayNav.shifted(-1, range: .day, anchor: nil)
        check(yesterday == cal.startOfDay(for: date(2026, 10, 22)), "first-day user can browse an empty previous date")
        check(firstDayNav.shifted(1, range: .day, anchor: yesterday) == cal.startOfDay(for: now), "next returns from yesterday to today")
        check(firstDayNav.shifted(1, range: .day, anchor: nil) == nil, "next is disabled at today")
        check(firstDayNav.clamped(date(2027, 1, 1)) == cal.startOfDay(for: now), "date picker cannot select a future day")
        check(firstDayNav.clamped(date(2020, 1, 1)) == firstDayNav.minimumDate, "date picker respects lower bound")
        for range in PostureTrendRange.allCases {
            let previous = firstDayNav.shifted(-1, range: range, anchor: nil)
            check(previous != nil, "previous works without history for \(range)")
            let picked = PostureTrendBuilder.trend(range: range, records: [], today: live,
                anchor: previous, now: now, calendar: cal)
            check(picked.start < cal.dateInterval(of: range.component, for: now)!.start,
                  "previous button changes the displayed calendar period for \(range)")
            check(firstDayNav.shifted(-1, range: range, anchor: firstDayNav.minimumDate) == nil,
                  "previous stops at earliest period for \(range)")
            check(firstDayNav.shifted(1, range: range, anchor: nil) == nil,
                  "next never enters a future period for \(range)")
        }
        let oldNav = PostureTrendNavigation(records: [record("2024-01-01", 9, 300, 0)], now: now, calendar: cal)
        check(oldNav.minimumDate == date(2024, 1, 1, 0), "older stored records remain reachable")
        let monthNav = PostureTrendNavigation(records: [], now: date(2026, 3, 31), calendar: cal)
        check(monthNav.shifted(-1, range: .month, anchor: nil) == date(2026, 2, 1, 0), "month navigation avoids month-end overflow")
        check(firstDayNav.shifted(0, range: .day, anchor: nil) == nil, "invalid navigation step ignored")

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("posture-trends-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = PostureHistoryFile(url: folder.appendingPathComponent("history.json"))
        check(file.loadIfPresent() == nil, "missing file distinguished from empty history")
        check(file.save([monday, tuesday, monday]), "atomic history save succeeds")
        check(file.load().count == 2, "one record per day on disk")
        check(file.load().first == monday, "hourly seconds survive round trip")
        check((try Data(contentsOf: file.url)).count < 600, "two days stay under 600 bytes")
        let many = (0..<450).map { offset in
            let d = cal.date(byAdding: .day, value: offset, to: date(2025, 1, 1))!
            let c = cal.dateComponents([.year, .month, .day], from: d)
            return record(String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!), 9, 60, 0)
        }
        file.save(many)
        check(file.load().count == 400 && file.load().first?.day == many[50].day, "retain newest 400 daily entries")

        var domains: [String] = []
        defer { for name in domains { UserDefaults.standard.removePersistentDomain(forName: name) } }
        func defaults() -> UserDefaults {
            let name = "posture-trends-test-\(UUID().uuidString)"
            domains.append(name)
            return UserDefaults(suiteName: name)!
        }
        let prefs = defaults()
        prefs.set(live.dayKey, forKey: "notch.posture.stats.day")
        prefs.set(live.goodSeconds, forKey: "notch.posture.stats.good")
        prefs.set(live.badSeconds, forKey: "notch.posture.stats.bad")
        prefs.set(try JSONEncoder().encode(live.hourly), forKey: "notch.posture.stats.hourly")
        let sessionFile = PostureHistoryFile(url: folder.appendingPathComponent("session/history.json"))
        let tracker = PostureSessionTracker(defaults: prefs, historyFile: sessionFile, now: now)
        check(sessionFile.load().first?.good == 300, "launch checkpoints live stats to history.json")
        tracker.tick(now: now, state: .good, isRunning: true)
        tracker.tick(now: now.addingTimeInterval(1), state: .good, isRunning: true)
        tracker.flushHistory(now: now.addingTimeInterval(1))
        tracker.flushHistory(now: now.addingTimeInterval(2))
        check(sessionFile.load().count == 1 && sessionFile.load()[0].good == 301, "repeated checkpoints replace today")
        let restarted = PostureSessionTracker(defaults: prefs, historyFile: sessionFile, now: now.addingTimeInterval(2))
        check(restarted.stats.goodSeconds == 301 && restarted.stats.hourly[9].good == 300, "relaunch preserves totals and buckets")
        let recovered = PostureSessionTracker(defaults: defaults(), historyFile: sessionFile, now: now)
        check(recovered.stats.goodSeconds == 301, "file checkpoint recovers today without live preferences")
        tracker.tick(now: date(2026, 10, 24, 0), state: nil, isRunning: false)
        check(tracker.stats.dayKey == "2026-10-24" && tracker.stats.trackedSeconds == 0, "midnight resets today's stats")
        check(sessionFile.load().first?.day == "2026-10-23" && sessionFile.load().first?.good == 301, "midnight archives previous day against supplied clock")
        let offline = PostureSessionTracker(defaults: prefs, historyFile: sessionFile, now: date(2026, 10, 25))
        check(offline.history.records.count == 1, "offline relaunch never duplicates archived day")

        let migrationPrefs = defaults()
        migrationPrefs.set(try JSONEncoder().encode([monday]), forKey: "notch.posture.history")
        let migratedFile = PostureHistoryFile(url: folder.appendingPathComponent("migration.json"))
        _ = PostureSessionTracker(defaults: migrationPrefs, historyFile: migratedFile, now: now)
        check(migratedFile.load().first == monday && migrationPrefs.data(forKey: "notch.posture.history") == nil, "legacy history migrates once after successful save")
        let blocker = folder.appendingPathComponent("not-a-directory")
        try Data().write(to: blocker)
        let failedPrefs = defaults()
        failedPrefs.set(try JSONEncoder().encode([monday]), forKey: "notch.posture.history")
        _ = PostureSessionTracker(defaults: failedPrefs, historyFile: .init(url: blocker.appendingPathComponent("history.json")), now: now)
        check(failedPrefs.data(forKey: "notch.posture.history") != nil, "failed migration keeps original data")
        let emptyFile = PostureHistoryFile(url: folder.appendingPathComponent("empty.json"))
        emptyFile.save([])
        check(emptyFile.loadIfPresent() == [], "valid empty history is recognized")
        migrationPrefs.set(try JSONEncoder().encode([monday]), forKey: "notch.posture.history")
        let emptyTracker = PostureSessionTracker(defaults: migrationPrefs, historyFile: emptyFile, now: now)
        check(emptyTracker.history.records.isEmpty, "valid empty file cannot resurrect legacy days")
        print("Trends/history: \(checks) checks, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
