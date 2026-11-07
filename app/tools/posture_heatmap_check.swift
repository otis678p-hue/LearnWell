import Foundation

@main
enum PostureHeatmapCheck {
    static func main() throws {
        var failures = 0
        var checks = 0
        func check(_ condition: Bool, _ message: String) {
            checks += 1
            if !condition { failures += 1; print("FAIL: \(message)") }
        }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Chicago")!
        let formatter = ISO8601DateFormatter()
        func date(_ iso: String) -> Date { formatter.date(from: iso)! }
        let now = date("2026-10-23T14:30:00-05:00")
        func record(_ day: String, _ hour: Int, _ good: Double, _ bad: Double) -> PostureDayRecord {
            var hours = PostureDayRecord.emptyHourly
            hours[hour] = .init(good: good, bad: bad)
            return .init(day: day, good: good, bad: bad, met: false, hourly: hours)
        }
        var today = PostureStats(dayKey: "2026-10-23", goodSeconds: 60, badSeconds: 240)
        today.hourly[14] = .init(good: 60, bad: 240)
        let records = [
            record("2026-10-19", 9, 600, 0),
            record("2026-10-20", 9, 120, 480),
            record("2026-10-21", 10, 0, 179),
            record("2026-10-22", 23, 180, 0),
            record("2026-10-23", 14, 0, 900), // live must replace this
            record("2026-10-18", 9, 0, 3600), // previous week
            record("2026-10-24", 9, 0, 3600)  // future
        ]
        let map = PostureHeatmap.build(records: records, today: today, now: now, calendar: cal)
        func cell(_ weekday: Int, _ hour: Int) -> PostureHeatmapCell { map.cells[weekday * 24 + hour] }
        check(map.cells.count == 168 && Set(map.cells.map(\.id)).count == 168, "7 × 24 unique cells")
        check(cell(0, 0).day == "2026-10-19" && cell(6, 23).day == "2026-10-25", "Monday through Sunday")
        check(cell(0, 9).isQualified && cell(0, 9).badPercent == 0, "observed 0% is data")
        check(cell(1, 9).badPercent == 80 && cell(0, 9).bad == 0, "weekdays do not merge")
        check(cell(2, 10).hasData && !cell(2, 10).isQualified, "179 seconds is insufficient")
        check(cell(3, 23).isQualified, "180 seconds qualifies")
        check(cell(4, 14).bad == 240 && cell(4, 14).good == 60, "live totals override archived today")
        check(!cell(4, 14).isFuture && cell(4, 15).isFuture, "current hour versus future hours")
        check(cell(5, 9).isFuture && !cell(5, 9).hasData, "future records cannot color heatmap")
        check(map.worst?.id == "2026-10-20-9", "worst uses ratio, then sample duration; ignores short sample")
        check(cell(3, 23).timeTitle == "23:00–00:00", "last hour ends at midnight")
        check(!cell(0, 8).hasData && !cell(0, 8).isQualified, "no data distinct from good-only")
        let empty = PostureHeatmap.build(records: [], today: .empty, now: now, calendar: cal)
        check(!empty.hasData && empty.worst == nil, "empty state")
        let good = PostureHeatmap.build(records: [records[0]], today: .empty, now: now, calendar: cal)
        check(good.hasData && good.worst == nil, "all-good data has no slouching winner")
        let stale = PostureStats(dayKey: "2026-10-20")
        let staleMap = PostureHeatmap.build(records: records, today: stale, now: now, calendar: cal)
        check(staleMap.cells[24 + 9].bad == 480, "stale live day cannot erase history")
        let duplicate = PostureHeatmap.build(records: records + [records[0]], today: today, now: now, calendar: cal)
        check(duplicate.cells == map.cells, "duplicate days do not crash or double count")
        let legacy = Data("{\"day\":\"2026-10-19\",\"good\":600,\"bad\":100,\"met\":false}".utf8)
        let oldRecord = try JSONDecoder().decode(PostureDayRecord.self, from: legacy)
        let legacyMap = PostureHeatmap.build(records: [oldRecord], today: .empty, now: now, calendar: cal)
        check(!legacyMap.hasData, "legacy daily totals do not fabricate hourly data")
        let restored = try JSONDecoder().decode([PostureDayRecord].self, from: JSONEncoder().encode(records))
        check(PostureHeatmap.build(records: restored, today: today, now: now, calendar: cal) == map,
              "hourly history survives persistence")
        let sunday = PostureHeatmap.build(records: [], today: .empty,
            now: date("2026-11-01T23:30:00-06:00"), calendar: cal)
        check(sunday.cells.first?.day == "2026-10-26" && sunday.cells.last?.day == "2026-11-01",
              "Sunday and DST fallback retain seven calendar days")
        let year = PostureHeatmap.build(records: [], today: .empty,
            now: date("2027-01-01T00:30:00-06:00"), calendar: cal)
        check(year.cells.first?.day == "2026-12-28" && year.cells.last?.day == "2027-01-03", "year boundary")
        print("Heatmap: \(checks) checks, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
