import Foundation

/// One hour of the day, split by posture.
struct PostureHourBucket: Equatable, Sendable, Codable {
    var good: Double = 0
    var bad: Double = 0

    var total: Double { good + bad }
}

/// Everything the UI needs to describe posture time: today totals, the hourly
/// profile, and how long the user has been sitting without a break.
struct PostureStats: Equatable, Sendable {
    var dayKey: String
    var goodSeconds: Double = 0
    var badSeconds: Double = 0
    /// How long the user has been sitting since the last break / reminder.
    var sittingSeconds: Double = 0
    var hourly: [PostureHourBucket] = Array(repeating: .init(), count: 24)

    static let empty = PostureStats(dayKey: "")

    var trackedSeconds: Double { goodSeconds + badSeconds }

    var goodFraction: Double {
        let total = trackedSeconds
        guard total > 1 else { return 0 }
        return goodSeconds / total
    }

    func minutes(_ seconds: Double) -> String {
        let total = Int((seconds / 60).rounded())
        if total < 60 { return "\(total)m" }
        let hours = total / 60
        let rest = total % 60
        return rest == 0 ? "\(hours)h" : "\(hours)h \(rest)m"
    }

    var goodText: String { minutes(goodSeconds) }
    var badText: String { minutes(badSeconds) }

    var sittingText: String { minutes(sittingSeconds) }

    /// Remaining time before the next rest reminder, in seconds.
    func remaining(until reminderMinutes: Double) -> Double {
        max(0, reminderMinutes * 60 - sittingSeconds)
    }

    func countdownText(until reminderMinutes: Double) -> String {
        let remaining = Int(remaining(until: reminderMinutes).rounded())
        let minutes = remaining / 60
        let seconds = remaining % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
    /// Whether today already satisfies the goal.
    func meets(_ goal: PostureGoal) -> Bool {
        guard trackedSeconds >= goal.minimumMinutes * 60 else { return false }
        return goodFraction >= goal.targetShare
    }

    var goalProgressShare: Double {
        min(max(goodFraction, 0), 1)
    }

    static func dayKey(offsetDaysBack days: Int, from key: String) -> String? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.calendar = Calendar(identifier: .gregorian)
        guard let date = formatter.date(from: key) else { return nil }
        guard let shifted = Calendar.current.date(byAdding: .day, value: -days, to: date) else {
            return nil
        }
        return formatter.string(from: shifted)
    }
}

/// Focus / rest rhythm settings.
struct PostureCycleSettings: Equatable, Sendable {
    var enabled: Bool = false
    var focusMinutes: Double = 50
    var breakMinutes: Double = 10

    static let minuteRange = 1...600
    static let focusPresets: [Int] = [25, 50, 90]
    static let breakPresets: [Int] = [5, 10, 15]
}

enum PostureCyclePhase: String, Equatable, Sendable, Codable {
    case focus
    case rest

    var title: String {
        switch self {
        case .focus: return "Focusing"
        case .rest: return "Break"
        }
    }
}

/// Live state of one focus/rest cycle.
struct PostureCycle: Equatable, Sendable, Codable {
    var phase: PostureCyclePhase = .focus
    /// Seconds left in the current phase.
    var remaining: Double = 0
    /// Length of the current phase, used for the progress bar.
    var duration: Double = 0
    var completedToday: Int = 0

    static let idle = PostureCycle()

    var progress: Double {
        guard duration > 0 else { return 0 }
        return min(max(1 - remaining / duration, 0), 1)
    }

    var countdownText: String {
        let total = Int(max(remaining, 0).rounded(.up))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

/// A daily target: the share of tracked time that should be good posture.
struct PostureGoal: Equatable, Sendable {
    var targetShare: Double = 0.8
    /// A day only counts once enough time has been tracked, so a one minute
    /// 100 % reading cannot mark the goal as met.
    var minimumMinutes: Double = 20

    var targetPercent: Int { Int((targetShare * 100).rounded()) }

    static let presets: [Int] = [60, 70, 80, 90]
}

/// One finished day, kept so streaks and trends survive restarts.
struct PostureDayRecord: Codable, Equatable, Sendable {
    var day: String
    var good: Double
    var bad: Double
    var met: Bool
    /// The day's hourly split, kept so the heatmap and the best/worst slot can
    /// be rebuilt from `history.json`. Only hours with detected time are stored.
    var hourly: [PostureHourBucket]

    static var emptyHourly: [PostureHourBucket] {
        Array(repeating: PostureHourBucket(), count: 24)
    }

    init(
        day: String,
        good: Double,
        bad: Double,
        met: Bool,
        hourly: [PostureHourBucket] = PostureDayRecord.emptyHourly
    ) {
        self.day = day
        self.good = good
        self.bad = bad
        self.met = met
        self.hourly = hourly.count == 24 ? hourly : PostureDayRecord.emptyHourly
    }

    /// Compact JSON: `"hours": {"9": [320, 41]}` — hour → [good, bad] seconds.
    private enum CodingKeys: String, CodingKey {
        case day
        case good
        case bad
        case met
        case hours
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        day = try container.decode(String.self, forKey: .day)
        good = try container.decode(Double.self, forKey: .good)
        bad = try container.decode(Double.self, forKey: .bad)
        met = try container.decode(Bool.self, forKey: .met)
        var buckets = PostureDayRecord.emptyHourly
        if let hours = try container.decodeIfPresent([String: [Double]].self, forKey: .hours) {
            for (key, values) in hours {
                guard let hour = Int(key), buckets.indices.contains(hour) else { continue }
                buckets[hour].good = values.first ?? 0
                buckets[hour].bad = values.count > 1 ? values[1] : 0
            }
        }
        hourly = buckets
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(day, forKey: .day)
        try container.encode(good, forKey: .good)
        try container.encode(bad, forKey: .bad)
        try container.encode(met, forKey: .met)
        var hours: [String: [Double]] = [:]
        for (hour, bucket) in hourly.enumerated() where bucket.total > 0 {
            // Tenths of a second is plenty for a whole day of sitting.
            hours[String(hour)] = [
                (bucket.good * 10).rounded() / 10,
                (bucket.bad * 10).rounded() / 10
            ]
        }
        if !hours.isEmpty {
            try container.encode(hours, forKey: .hours)
        }
    }
}

/// A single cell of the recent-days strip.
struct PostureDayCell: Identifiable, Equatable, Sendable {
    var day: String
    var met: Bool
    var isToday: Bool

    var id: String { day + (isToday ? "-today" : "") }
}

/// History of finished days plus helpers for the streak.
struct PostureHistory: Equatable, Sendable {
    var records: [PostureDayRecord] = []

    func record(for day: String) -> PostureDayRecord? {
        records.first { $0.day == day }
    }

    /// Consecutive days that met the goal, counting today when it is already met.
    func streak(todayKey: String, todayMet: Bool) -> Int {
        var count = todayMet ? 1 : 0
        var offset = 1
        while offset <= 400 {
            guard let key = PostureStats.dayKey(offsetDaysBack: offset, from: todayKey),
                  let record = record(for: key),
                  record.met else {
                return count
            }
            count += 1
            offset += 1
        }
        return count
    }

    /// Most recent `count` days, oldest first, ending with today.
    func recentDays(
        _ count: Int,
        todayKey: String,
        todayMet: Bool
    ) -> [PostureDayCell] {
        var cells: [PostureDayCell] = []
        for offset in stride(from: count - 1, through: 0, by: -1) {
            guard let key = PostureStats.dayKey(offsetDaysBack: offset, from: todayKey) else {
                continue
            }
            if offset == 0 {
                cells.append(PostureDayCell(day: key, met: todayMet, isToday: true))
            } else {
                cells.append(PostureDayCell(
                    day: key,
                    met: record(for: key)?.met ?? false,
                    isToday: false
                ))
            }
        }
        return cells
    }
}

/// Accumulates posture time while detection runs and decides when the user has
/// been sitting long enough to deserve a break reminder.
@MainActor
final class PostureSessionTracker {
    private enum Key {
        static let day = "notch.posture.stats.day"
        static let good = "notch.posture.stats.good"
        static let bad = "notch.posture.stats.bad"
        static let hourly = "notch.posture.stats.hourly"
        static let sitting = "notch.posture.stats.sitting"
        static let history = "notch.posture.history"
        static let goalTarget = "notch.posture.goalTarget"
        static let cycleEnabled = "notch.posture.cycleEnabled"
        static let cycleFocus = "notch.posture.cycleFocus"
        static let cycleBreak = "notch.posture.cycleBreak"
        static let cycleState = "notch.posture.cycleState"
        static let cycleCompleted = "notch.posture.cycleCompleted"
        static let cycleDay = "notch.posture.cycleDay"
    }

    /// A gap this long without a detected person counts as standing up.
    private static let breakThreshold: TimeInterval = 120

    private let defaults: UserDefaults
    private let historyFile: PostureHistoryFile
    private var lastTick: Date?
    private var lastHistoryWriteAt: Date?
    private var idleSeconds: Double = 0
    private var lastReminderAt: Date?
    private var restEndsAt: Date?
    private var completedFocus = false

    private struct SavedCycle: Codable {
        var cycle: PostureCycle
        var restEndsAt: Date?
        var completedFocus: Bool
        var savedAt: Date
    }

    private(set) var stats: PostureStats
    private(set) var history = PostureHistory()
    private(set) var goal = PostureGoal()
    private(set) var cycle = PostureCycle()
    private(set) var settings = PostureCycleSettings()
    /// Fired when a phase boundary is crossed so the HUD can announce it.
    var onCycleEvent: ((PostureCycle) -> Void)?
    /// Fired every tick so the UI countdown stays live.
    var onCycleTick: ((PostureCycle) -> Void)?
    var onChange: ((PostureStats) -> Void)?
    var onHistoryChange: ((PostureHistory) -> Void)?
    var onGoalChange: ((PostureGoal) -> Void)?
    /// Called when the sit streak crosses the reminder interval.
    var onRestReminder: ((Double) -> Void)?

    init(
        defaults: UserDefaults = .standard,
        historyFile: PostureHistoryFile = PostureHistoryFile(),
        now: Date = Date()
    ) {
        self.defaults = defaults
        self.historyFile = historyFile
        stats = PostureStats(dayKey: Self.dayKey(for: now))
        if let stored = defaults.object(forKey: Key.goalTarget) as? Double, stored > 0 {
            goal.targetShare = min(max(stored, 0.1), 1)
        }
        load()
        settings.enabled = defaults.bool(forKey: Key.cycleEnabled)
        settings.focusMinutes = Self.validMinutes(defaults.double(forKey: Key.cycleFocus)) ?? 50
        settings.breakMinutes = Self.validMinutes(defaults.double(forKey: Key.cycleBreak)) ?? 10
        cycle.duration = settings.focusMinutes * 60
        cycle.remaining = cycle.duration
        if settings.enabled,
           let data = defaults.data(forKey: Key.cycleState),
           let saved = try? JSONDecoder().decode(SavedCycle.self, from: data),
           saved.cycle.duration.isFinite, saved.cycle.duration > 0,
           saved.cycle.remaining.isFinite, saved.cycle.remaining >= 0 {
            cycle = saved.cycle
            restEndsAt = saved.restEndsAt
            completedFocus = saved.completedFocus
            if cycle.phase == .focus, now.timeIntervalSince(saved.savedAt) >= Self.breakThreshold {
                cycle.remaining = cycle.duration
                completedFocus = false
            }
        }
        cycle.completedToday = defaults.string(forKey: Key.cycleDay) == stats.dayKey
            ? defaults.integer(forKey: Key.cycleCompleted) : 0
        if settings.enabled, cycle.phase == .rest {
            // A break continues through sleep and relaunch; focus never accrues offline.
            cycle.remaining = max(0, (restEndsAt ?? now).timeIntervalSince(now))
            if cycle.remaining == 0 { finishBreak(now: now) }
        }
        flushHistory(now: now)
    }

    // MARK: ticking

    /// Adds the elapsed time to the right bucket. `state` is nil when detection
    /// is stopped, so time only accrues while the camera is actually analysing.
    func tick(now: Date = Date(), state: PostureState?, isRunning: Bool) {
        defer { lastTick = now }
        rollOverIfNeeded(now: now)

        guard let lastTick else { return }
        let elapsed = max(now.timeIntervalSince(lastTick), 0)
        let delta = min(elapsed, 5)
        guard delta > 0 else { return }

        var updated = stats
        var changed = false

        if isRunning, let state {
            switch state {
            case .good: updated.goodSeconds += delta
            case .bad: updated.badSeconds += delta
            case .unknown: break
            }
            if state != .unknown {
                let hour = Calendar.current.component(.hour, from: now)
                if updated.hourly.indices.contains(hour) {
                    if state == .good {
                        updated.hourly[hour].good += delta
                    } else {
                        updated.hourly[hour].bad += delta
                    }
                }
                updated.sittingSeconds += delta
                idleSeconds = 0
                changed = true
            }
        }

        if !changed {
            // no person on screen: count towards the "stood up" threshold
            idleSeconds += elapsed
            if idleSeconds >= Self.breakThreshold, updated.sittingSeconds > 0 {
                updated.sittingSeconds = 0
                changed = true
            }
        }

        if changed, updated != stats {
            stats = updated
            persist()
            if lastHistoryWriteAt == nil || now.timeIntervalSince(lastHistoryWriteAt!) >= 60 {
                flushHistory(now: now)
            }
            onChange?(updated)
        }
        advanceCycle(
            now: now, delta: delta,
            isSitting: isRunning && state != nil && state != .unknown,
            resetFocus: idleSeconds >= Self.breakThreshold || elapsed >= Self.breakThreshold
        )
    }

    // MARK: - focus / rest rhythm

    func setCycleEnabled(_ enabled: Bool, now: Date = Date()) {
        guard settings.enabled != enabled else { return }
        settings.enabled = enabled
        defaults.set(enabled, forKey: Key.cycleEnabled)
        startPhase(.focus)
        publishCycle(now: now)
    }

    private static func validMinutes(_ value: Double) -> Double? {
        guard value.isFinite,
              value >= Double(PostureCycleSettings.minuteRange.lowerBound),
              value <= Double(PostureCycleSettings.minuteRange.upperBound) else { return nil }
        return value
    }

    func setCycleDurations(focus: Double?, breakLength: Double?, now: Date = Date()) {
        let elapsed = cycle.duration - cycle.remaining
        if let focus, let valid = Self.validMinutes(focus) {
            settings.focusMinutes = valid
            defaults.set(valid, forKey: Key.cycleFocus)
        }
        if let breakLength, let valid = Self.validMinutes(breakLength) {
            settings.breakMinutes = valid
            defaults.set(valid, forKey: Key.cycleBreak)
        }
        cycle.duration = (cycle.phase == .focus ? settings.focusMinutes : settings.breakMinutes) * 60
        cycle.remaining = settings.enabled ? max(0, cycle.duration - elapsed) : cycle.duration
        if cycle.phase == .rest { restEndsAt = now.addingTimeInterval(cycle.remaining) }
        publishCycle(now: now)
    }

    /// An early break does not count as a completed full focus/rest cycle.
    func startBreakNow(now: Date = Date()) {
        guard settings.enabled, cycle.phase == .focus else { return }
        completedFocus = false
        startPhase(.rest, now: now)
        publishCycle(now: now)
        onCycleEvent?(cycle)
    }

    func skipRest(now: Date = Date()) {
        guard settings.enabled, cycle.phase == .rest else { return }
        completedFocus = false
        finishBreak(now: now)
    }

    private func startPhase(_ phase: PostureCyclePhase, now: Date = Date()) {
        cycle.phase = phase
        cycle.duration = (phase == .focus ? settings.focusMinutes : settings.breakMinutes) * 60
        cycle.remaining = cycle.duration
        restEndsAt = phase == .rest ? now.addingTimeInterval(cycle.duration) : nil
        if phase == .focus { completedFocus = false }
        stats.sittingSeconds = 0
        idleSeconds = 0
        lastReminderAt = nil
        persist()
    }

    private func finishBreak(now: Date) {
        if completedFocus { cycle.completedToday += 1 }
        startPhase(.focus, now: now)
        publishCycle(now: now)
        onCycleEvent?(cycle)
    }

    private func advanceCycle(now: Date, delta: Double, isSitting: Bool, resetFocus: Bool) {
        guard settings.enabled else { return }
        switch cycle.phase {
        case .focus:
            if resetFocus { cycle.remaining = cycle.duration }
            if isSitting { cycle.remaining = max(0, cycle.remaining - delta) }
            if cycle.remaining <= 0 {
                completedFocus = true
                startPhase(.rest, now: now)
                onCycleEvent?(cycle)
            }
        case .rest:
            cycle.remaining = max(0, (restEndsAt ?? now).timeIntervalSince(now))
            if cycle.remaining <= 0 {
                finishBreak(now: now)
                return
            }
        }
        publishCycle(now: now)
    }

    private func publishCycle(now: Date) {
        defaults.set(cycle.completedToday, forKey: Key.cycleCompleted)
        defaults.set(stats.dayKey, forKey: Key.cycleDay)
        let saved = SavedCycle(cycle: cycle, restEndsAt: restEndsAt,
                               completedFocus: completedFocus, savedAt: now)
        if let data = try? JSONEncoder().encode(saved) {
            defaults.set(data, forKey: Key.cycleState)
        }
        onCycleTick?(cycle)
        onChange?(stats)
    }

    /// Manual "I stood up" reset, also used by the settings button.
    func takeBreak() {
        idleSeconds = 0
        lastReminderAt = nil
        if settings.enabled, cycle.phase == .focus {
            cycle.remaining = cycle.duration
            publishCycle(now: Date())
        }
        guard stats.sittingSeconds > 0 else { return }
        stats.sittingSeconds = 0
        persist()
        onChange?(stats)
    }

    /// Re-arms the reminder without clearing the streak.
    func acknowledgeReminder() {
        lastReminderAt = Date()
    }

    func resetToday() {
        let dayKey = Self.dayKey(for: Date())
        stats = PostureStats(dayKey: dayKey)
        cycle.completedToday = 0
        if settings.enabled { startPhase(.focus) }
        publishCycle(now: Date())
        idleSeconds = 0
        lastReminderAt = nil
        persist()
        flushHistory()
        onChange?(stats)
    }

    /// Called by the reminder scheduler: true when a new reminder is due.
    func reminderDue(now: Date = Date(), interval: Double?) -> Bool {
        guard let interval, interval > 0 else { return false }
        guard stats.sittingSeconds >= interval * 60 else { return false }
        if let lastReminderAt, now.timeIntervalSince(lastReminderAt) < 60 {
            return false
        }
        return true
    }

    // MARK: persistence

    private func rollOverIfNeeded(now: Date) {
        let today = Self.dayKey(for: now)
        guard stats.dayKey != today else { return }
        archiveFinishedDay()
        stats = PostureStats(dayKey: today)
        cycle.completedToday = 0
        // Keep an in-progress focus or break when the calendar day changes.
        publishCycle(now: now)
        idleSeconds = 0
        lastReminderAt = nil
        persist()
        onChange?(stats)
    }

    /// Stores the day that just ended so streaks and trends survive restarts.
    private func archiveFinishedDay() {
        guard !stats.dayKey.isEmpty else { return }
        guard stats.trackedSeconds > 0 else {
            onHistoryChange?(history)
            return
        }
        upsert(
            day: stats.dayKey,
            good: stats.goodSeconds,
            bad: stats.badSeconds,
            met: stats.meets(goal),
            hourly: stats.hourly
        )
        onHistoryChange?(history)
    }

    /// A day that ended while the app was closed still belongs in the history;
    /// without this the trends lose every day the Mac was shut down overnight.
    private func adoptStaleDay(
        day: String,
        good: Double,
        bad: Double,
        hourly: [PostureHourBucket]
    ) {
        guard !day.isEmpty, day != stats.dayKey, good + bad > 0 else { return }
        let finished = PostureStats(dayKey: day, goodSeconds: good, badSeconds: bad)
        upsert(day: day, good: good, bad: bad, met: finished.meets(goal), hourly: hourly)
        onHistoryChange?(history)
    }

    /// Replaces the record for `day` and writes `history.json`.
    private func upsert(
        day: String,
        good: Double,
        bad: Double,
        met: Bool,
        hourly: [PostureHourBucket]
    ) {
        history.records.removeAll { $0.day == day }
        history.records.append(
            PostureDayRecord(day: day, good: good, bad: bad, met: met, hourly: hourly)
        )
        history.records = PostureHistoryFile.trimmed(history.records)
        persistHistory()
    }

    func setGoalTarget(share: Double) {
        let clamped = min(max(share, 0.1), 1)
        guard clamped != goal.targetShare else { return }
        goal.targetShare = clamped
        defaults.set(clamped, forKey: Key.goalTarget)
        onGoalChange?(goal)
    }

    /// Today's verdict, used by the goal card and the streak.
    var todayMet: Bool {
        stats.meets(goal)
    }

    var streak: Int {
        history.streak(todayKey: stats.dayKey, todayMet: todayMet)
    }

    private static func dayKey(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private func load() {
        let storedDay = defaults.string(forKey: Key.day) ?? ""
        let storedGood = defaults.double(forKey: Key.good)
        let storedBad = defaults.double(forKey: Key.bad)
        var storedHourly = PostureDayRecord.emptyHourly
        if let data = defaults.data(forKey: Key.hourly),
           let decoded = try? JSONDecoder().decode([PostureHourBucket].self, from: data),
           decoded.count == 24 {
            storedHourly = decoded
        }

        history.records = loadHistory()

        guard storedDay == stats.dayKey else {
            adoptStaleDay(day: storedDay, good: storedGood, bad: storedBad, hourly: storedHourly)
            if let checkpoint = history.record(for: stats.dayKey) {
                stats.goodSeconds = checkpoint.good
                stats.badSeconds = checkpoint.bad
                stats.hourly = checkpoint.hourly
            }
            return
        }
        stats.goodSeconds = storedGood
        stats.badSeconds = storedBad
        stats.sittingSeconds = defaults.double(forKey: Key.sitting)
        stats.hourly = storedHourly
    }

    /// `history.json` first; the older UserDefaults blob is migrated once and
    /// then removed.
    private func loadHistory() -> [PostureDayRecord] {
        if let fromFile = historyFile.loadIfPresent() { return fromFile }
        guard let data = defaults.data(forKey: Key.history),
              let decoded = try? JSONDecoder().decode([PostureDayRecord].self, from: data) else {
            return []
        }
        let migrated = PostureHistoryFile.trimmed(decoded)
        if historyFile.save(migrated) { defaults.removeObject(forKey: Key.history) }
        return migrated
    }

    private func persist() {
        defaults.set(stats.dayKey, forKey: Key.day)
        defaults.set(stats.goodSeconds, forKey: Key.good)
        defaults.set(stats.badSeconds, forKey: Key.bad)
        defaults.set(stats.sittingSeconds, forKey: Key.sitting)
        if let data = try? JSONEncoder().encode(stats.hourly) {
            defaults.set(data, forKey: Key.hourly)
        }
    }

    private func persistHistory() {
        historyFile.save(history.records)
    }

    /// Checkpoint once a minute and on app shutdown; repeated writes replace
    /// today's record rather than appending another entry.
    func flushHistory(now: Date = Date()) {
        history.records.removeAll { $0.day == stats.dayKey }
        if stats.trackedSeconds > 0 {
            history.records.append(PostureDayRecord(
                day: stats.dayKey, good: stats.goodSeconds, bad: stats.badSeconds,
                met: stats.meets(goal), hourly: stats.hourly
            ))
        }
        history.records = PostureHistoryFile.trimmed(history.records)
        if historyFile.save(history.records) { lastHistoryWriteAt = now }
        onHistoryChange?(history)
    }
}
