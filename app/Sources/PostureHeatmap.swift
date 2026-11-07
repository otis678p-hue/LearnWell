import Foundation

/// A local calendar hour. Empty and short samples stay distinct from 0% bad.
struct PostureHeatmapCell: Identifiable, Equatable, Sendable {
    let day: String
    let weekday: Int // Monday = 0
    let hour: Int
    let good: Double
    let bad: Double
    let isFuture: Bool
    var id: String { "\(day)-\(hour)" }
    var total: Double { good + bad }
    var hasData: Bool { total > 0 }
    var isQualified: Bool { total >= PostureHeatmap.minimumSeconds }
    var badFraction: Double { total > 0 ? bad / total : 0 }
    var badPercent: Int { Int((badFraction * 100).rounded()) }
    var timeTitle: String { String(format: "%02d:00–%02d:00", hour, (hour + 1) % 24) }
}

struct PostureHeatmap: Equatable, Sendable {
    static let minimumSeconds: Double = 180
    static let weekdayTitles = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
    let dates: [Date]
    let cells: [PostureHeatmapCell]
    var hasData: Bool { cells.contains { $0.hasData } }

    /// Highest bad share; ties prefer more observed time, then the earlier hour.
    var worst: PostureHeatmapCell? {
        cells.filter { $0.isQualified && $0.bad > 0 && !$0.isFuture }.sorted {
            if $0.badFraction != $1.badFraction { return $0.badFraction > $1.badFraction }
            if $0.total != $1.total { return $0.total > $1.total }
            return $0.day == $1.day ? $0.hour < $1.hour : $0.day < $1.day
        }.first
    }

    static func build(
        records: [PostureDayRecord], today: PostureStats,
        now: Date = Date(), calendar: Calendar = .current
    ) -> PostureHeatmap {
        // Persisted keys are Gregorian, while the timezone follows the user.
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = calendar.timeZone
        let startOfToday = cal.startOfDay(for: now)
        let mondayOffset = (cal.component(.weekday, from: now) + 5) % 7
        let monday = cal.date(byAdding: .day, value: -mondayOffset, to: startOfToday)!
        let dates = (0..<7).map { cal.date(byAdding: .day, value: $0, to: monday)! }
        func key(_ date: Date) -> String {
            let c = cal.dateComponents([.year, .month, .day], from: date)
            return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
        }
        var days: [String: PostureDayRecord] = [:]
        for record in records { days[record.day] = record }
        let todayKey = key(now)
        // A stale live snapshot must never replace a completed day's history.
        if today.dayKey.isEmpty || today.dayKey == todayKey {
            days[todayKey] = PostureDayRecord(
                day: todayKey, good: today.goodSeconds, bad: today.badSeconds,
                met: false, hourly: today.hourly
            )
        }
        let currentHour = cal.component(.hour, from: now)
        let cells = dates.enumerated().flatMap { weekday, date in
            let day = key(date)
            return (0..<24).map { hour in
                let future = date > startOfToday || (day == todayKey && hour > currentHour)
                let bucket = days[day]?.hourly[hour] ?? PostureHourBucket()
                return PostureHeatmapCell(
                    day: day, weekday: weekday, hour: hour,
                    good: future ? 0 : max(0, bucket.good),
                    bad: future ? 0 : max(0, bucket.bad), isFuture: future
                )
            }
        }
        return PostureHeatmap(dates: dates, cells: cells)
    }
}
