import Foundation

/// Browsing bounds include empty dates, even on the first day of tracking.
/// Older stored dates remain reachable beyond the default 400-day window.
struct PostureTrendNavigation {
    let calendar: Calendar
    let minimumDate: Date
    let maximumDate: Date

    init(records: [PostureDayRecord], now: Date, calendar: Calendar = .current) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = calendar.timeZone
        cal.firstWeekday = 2
        self.calendar = cal
        maximumDate = cal.startOfDay(for: now)
        let fallback = cal.date(byAdding: .day, value: -399, to: maximumDate)!
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = cal
        formatter.timeZone = cal.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        let oldest = records.compactMap { record -> Date? in
            guard let date = formatter.date(from: record.day),
                  formatter.string(from: date) == record.day else { return nil }
            return date
        }.min()
        minimumDate = min(fallback, oldest ?? fallback)
    }

    func clamped(_ date: Date) -> Date {
        min(max(calendar.startOfDay(for: date), minimumDate), maximumDate)
    }

    func shifted(_ step: Int, range: PostureTrendRange, anchor: Date?) -> Date? {
        guard step == -1 || step == 1 else { return nil }
        let start = calendar.dateInterval(of: range.component, for: clamped(anchor ?? maximumDate))!.start
        let currentStart = calendar.dateInterval(of: range.component, for: maximumDate)!.start
        guard step < 0 ? start > minimumDate : start < currentStart else { return nil }
        guard let shifted = calendar.date(byAdding: range.component, value: step, to: start) else { return nil }
        return clamped(shifted)
    }
}

/// The window the trend card is showing.
enum PostureTrendRange: String, CaseIterable, Identifiable, Sendable {
    case day
    case week
    case month
    case year

    var id: String { rawValue }

    var title: String {
        switch self {
        case .day: return "Day"
        case .week: return "Week"
        case .month: return "Month"
        case .year: return "Year"
        }
    }

    /// What each bar stands for, shown next to the chart.
    var unit: String {
        switch self {
        case .day: return "Hourly · today"
        case .week: return "Daily · this week"
        case .month: return "Daily · this month"
        case .year: return "Monthly · this year"
        }
    }

    var component: Calendar.Component {
        switch self {
        case .day: return .day
        case .week: return .weekOfYear
        case .month: return .month
        case .year: return .year
        }
    }
}

/// One bar of the calendar chart.
struct PostureTrendBar: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    /// Axis caption; empty for unlabelled bars.
    let label: String
    let good: Double
    let bad: Double
    /// The bucket that contains "now", captioned darker.
    let isCurrent: Bool

    var total: Double { good + bad }
    var hasData: Bool { total > 0.5 }

    var goodFraction: Double {
        guard total > 0 else { return 0 }
        return good / total
    }
}

/// A single hour-of-day read out of the aggregated history.
struct PostureSlotSummary: Identifiable, Equatable, Sendable {
    let hour: Int
    let good: Double
    let bad: Double

    var id: Int { hour }
    var total: Double { good + bad }

    var goodFraction: Double {
        guard total > 0 else { return 0 }
        return good / total
    }

    var percent: Int { Int((goodFraction * 100).rounded()) }
    var badPercent: Int { 100 - percent }

    var title: String {
        String(format: "%02d:00–%02d:00", hour, (hour + 1) % 24)
    }
}

/// Everything the trend card renders for one range.
struct PostureTrend: Equatable, Sendable {
    var range: PostureTrendRange
    var start: Date
    var end: Date // Exclusive calendar boundary
    var bars: [PostureTrendBar]
    var best: PostureSlotSummary?
    var worst: PostureSlotSummary?
    var good: Double
    var bad: Double

    var trackedSeconds: Double { good + bad }
    var hasData: Bool { trackedSeconds > 0.5 }

    var goodFraction: Double {
        guard trackedSeconds > 0 else { return 0 }
        return good / trackedSeconds
    }
}

/// Turns stored days into the trend card's bars and slots. Free of SwiftUI and
/// of the tracker, so the logic checks can exercise it directly.
enum PostureTrendBuilder {
    /// An hour needs this much detected time before it may be called the best
    /// or the worst — a single minute should not win the day.
    static let slotMinimumSeconds: Double = 180

    /// Monday-first captions for the seven day bars of the week range.
    static let weekdayTitles = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

    // MARK: - Trends

    static func trend(
        range: PostureTrendRange,
        records: [PostureDayRecord],
        today: PostureStats,
        anchor: Date? = nil,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> PostureTrend {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = calendar.timeZone
        cal.firstWeekday = 2  // Monday first, matching the heatmap rows
        let reference = anchor ?? now
        let interval = cal.dateInterval(of: range.component, for: reference)!

        let days = dayMap(records: records, today: today, now: now, calendar: cal)
        let todayKey = dayKey(for: now, calendar: cal)
        let referenceKey = dayKey(for: reference, calendar: cal)
        let year = cal.component(.year, from: reference)
        let currentMonth = cal.component(.month, from: now)

        let bars: [PostureTrendBar]
        let window: Set<String>

        switch range {
        case .day:
            let hourly = days[referenceKey]?.hourly ?? PostureDayRecord.emptyHourly
            let currentHour = cal.component(.hour, from: now)
            bars = (0..<24).map { hour in
                PostureTrendBar(
                    id: "\(referenceKey)-h\(hour)",
                    title: "\(referenceKey) · " + String(format: "%02d:00–%02d:00", hour, (hour + 1) % 24),
                    label: hour % 3 == 0 ? "\(hour)" : "",
                    good: hourly[hour].good,
                    bad: hourly[hour].bad,
                    isCurrent: referenceKey == todayKey && hour == currentHour
                )
            }
            window = [referenceKey]

        case .week:
            let start = interval.start
            var built: [PostureTrendBar] = []
            var keys = Set<String>()
            for offset in 0..<7 {
                guard let date = cal.date(byAdding: .day, value: offset, to: start) else { continue }
                let key = dayKey(for: date, calendar: cal)
                keys.insert(key)
                built.append(
                    bar(id: key, label: Self.weekdayTitles[offset], record: days[key], isCurrent: key == todayKey)
                )
            }
            bars = built
            window = keys

        case .month:
            let start = interval.start
            let dayCount = cal.range(of: .day, in: .month, for: reference)?.count ?? 30
            var built: [PostureTrendBar] = []
            var keys = Set<String>()
            for day in 1...dayCount {
                var components = cal.dateComponents([.year, .month], from: start)
                components.day = day
                guard let date = cal.date(from: components) else { continue }
                let key = dayKey(for: date, calendar: cal)
                keys.insert(key)
                built.append(
                    bar(
                        id: key,
                        label: day % 5 == 1 || day == dayCount ? "\(day)" : "",
                        record: days[key],
                        isCurrent: key == todayKey
                    )
                )
            }
            bars = built
            window = keys

        case .year:
            let prefix = String(format: "%04d-", year)
            let keys = Set(days.keys.filter { $0.hasPrefix(prefix) })
            bars = (1...12).map { month in
                let monthPrefix = String(format: "%04d-%02d", year, month)
                let monthKeys = keys.filter { $0.hasPrefix(monthPrefix) }
                var good = 0.0
                var bad = 0.0
                for key in monthKeys {
                    good += days[key]?.good ?? 0
                    bad += days[key]?.bad ?? 0
                }
                return PostureTrendBar(
                    id: "m\(month)",
                    title: monthPrefix,
                    label: "\(month)",
                    good: good,
                    bad: bad,
                    isCurrent: year == cal.component(.year, from: now) && month == currentMonth
                )
            }
            window = keys
        }

        let inWindow = days.filter { window.contains($0.key) }
        let slots = slotSummary(from: inWindow.values.map(\.hourly))

        return PostureTrend(
            range: range,
            start: interval.start,
            end: interval.end,
            bars: bars,
            best: slots.best,
            worst: slots.worst,
            good: bars.reduce(0) { $0 + $1.good },
            bad: bars.reduce(0) { $0 + $1.bad }
        )
    }

    // MARK: - Helpers

    private static func bar(
        id: String,
        label: String,
        record: PostureDayRecord?,
        isCurrent: Bool
    ) -> PostureTrendBar {
        PostureTrendBar(
            id: id,
            title: id,
            label: label,
            good: record?.good ?? 0,
            bad: record?.bad ?? 0,
            isCurrent: isCurrent
        )
    }

    private static func dayMap(
        records: [PostureDayRecord],
        today: PostureStats,
        now: Date,
        calendar: Calendar
    ) -> [String: PostureDayRecord] {
        let key = dayKey(for: now, calendar: calendar)
        var map: [String: PostureDayRecord] = [:]
        for record in records where record.day <= key { map[record.day] = record }
        guard today.dayKey.isEmpty || today.dayKey == key else { return map }
        // Today is still live, so it always wins over an archived copy.
        map[key] = PostureDayRecord(
            day: key,
            good: today.goodSeconds,
            bad: today.badSeconds,
            met: false,
            hourly: today.hourly
        )
        return map
    }

    /// Best and worst hour-of-day across the given days, ignoring hours that saw
    /// less than `slotMinimumSeconds` of detection.
    static func slotSummary(
        from hourlySets: [[PostureHourBucket]],
        minimum: Double = slotMinimumSeconds
    ) -> (best: PostureSlotSummary?, worst: PostureSlotSummary?) {
        var totals = Array(repeating: PostureHourBucket(), count: 24)
        for hourly in hourlySets where hourly.count == 24 {
            for hour in 0..<24 {
                totals[hour].good += hourly[hour].good
                totals[hour].bad += hourly[hour].bad
            }
        }

        let candidates = totals.enumerated().compactMap { hour, bucket -> PostureSlotSummary? in
            guard bucket.total >= minimum else { return nil }
            return PostureSlotSummary(hour: hour, good: bucket.good, bad: bucket.bad)
        }
        let best = candidates.sorted {
            if $0.goodFraction != $1.goodFraction { return $0.goodFraction > $1.goodFraction }
            if $0.total != $1.total { return $0.total > $1.total }
            return $0.hour < $1.hour
        }.first
        let worst = candidates.sorted {
            if $0.goodFraction != $1.goodFraction { return $0.goodFraction < $1.goodFraction }
            if $0.total != $1.total { return $0.total > $1.total }
            return $0.hour < $1.hour
        }.first
        return (best, worst)
    }

    private static func dayKey(for date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }
}
