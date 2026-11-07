// Logic checks for the posture pipeline that need no camera and no XCTest.
// Run with tools/run_posture_logic_check.sh

import CoreML
import Foundation

var failures = 0
func check(_ condition: Bool, _ message: String) {
    if !condition { failures += 1; print("FAIL:", message) }
}

// Row layout: cx, cy, w, h, bad, good (YOLO26 has no objectness channel)
func row(_ cx: Float, _ cy: Float, _ w: Float, _ h: Float, _ bad: Float, _ good: Float) -> [Float] {
    [cx, cy, w, h, bad, good]
}

let columns = PostureDetectionDecoder.columns

// 1. Single confident good detection
var rows = [Float](repeating: 0, count: columns * 5)
rows.replaceSubrange(0..<columns, with: row(320, 320, 200, 300, 0.05, 0.8))
var detections = PostureDetectionDecoder.decode(rows: rows)
check(detections.count == 1, "one good detection, got \(detections.count)")
check(detections.first?.label == .good, "label good")
check(abs((detections.first?.confidence ?? 0) - 0.8) < 0.0001, "confidence is the class score")
if case .good(let value) = PostureDetectionDecoder.outcome(for: detections) {
    check(abs(value - 0.8) < 0.0001, "outcome confidence")
} else { check(false, "outcome should be good") }

// 2. Below the 0.50 standard threshold is ignored
rows.replaceSubrange(0..<columns, with: row(320, 320, 200, 300, 0.35, 0.05))
check(PostureDetectionDecoder.decode(rows: rows).isEmpty, "below threshold ignored")

// 3. Bad posture
rows.replaceSubrange(0..<columns, with: row(320, 320, 200, 300, 0.7, 0.02))
detections = PostureDetectionDecoder.decode(rows: rows)
check(detections.count == 1 && detections[0].label == .bad, "bad detection")
if case .bad = PostureDetectionDecoder.outcome(for: detections) {} else { check(false, "outcome should be bad") }

// 4. Two people -> no confirmed posture
var pair = [Float](repeating: 0, count: columns * 5)
pair.replaceSubrange(0..<columns, with: row(120, 320, 120, 280, 0.02, 0.75))
pair.replaceSubrange(columns..<(columns * 2), with: row(520, 320, 120, 280, 0.02, 0.72))
detections = PostureDetectionDecoder.decode(rows: pair)
check(detections.count == 2, "two detections, got \(detections.count)")
if case .none(let count) = PostureDetectionDecoder.outcome(for: detections) {
    check(count == 2, "people count 2")
} else { check(false, "two people should not confirm a posture") }

// 4b. Classification preserves unknown without a confident single posture
check(PostureOutcome.none(peopleCount: 0).posture == .unknown, "empty frame is unknown")
check(PostureOutcome.none(peopleCount: 2).posture == .unknown, "two people are unknown")
check(PostureOutcome.bad(0.9).posture == .bad, "bad stays bad")

// 5. Overlapping boxes collapse through NMS
var overlap = [Float](repeating: 0, count: columns * 5)
overlap.replaceSubrange(0..<columns, with: row(320, 320, 200, 300, 0.01, 0.90))
overlap.replaceSubrange(columns..<(columns * 2), with: row(322, 322, 200, 300, 0.01, 0.85))
detections = PostureDetectionDecoder.decode(rows: overlap)
check(detections.count == 1, "overlapping boxes collapse, got \(detections.count)")

// 5b. The exported head is [1, 6, 8400]: channels first, read with its own strides
if let first = try? MLMultiArray(shape: [1, 6, 3], dataType: .float32) {
    // Channels first: index = channel * anchors + anchor.
    let values: [Float] = [320, 320, 200, 300, 0.05, 0.9]
    for (channel, value) in values.enumerated() { first[channel * 3] = NSNumber(value: value) }
    if let tensor = PostureHeadTensor(array: first) {
        let summary = PostureDetectionDecoder.summarize(tensor, threshold: PostureSensitivity.standard.threshold)
        check(summary.detections.count == 1, "channels-first head decodes, got \(summary.detections.count)")
        check(summary.detections.first?.label == .good, "channels-first label good")
        check(abs(summary.bestScore - 0.9) < 0.0001, "channels-first best score")
        check(summary.scoredAnchors == 1, "only the confident anchor counts, got \(summary.scoredAnchors)")
    } else { check(false, "channels-first head should be readable") }
} else { check(false, "could not build a test tensor") }

// 5c. A row-major [1, anchors, 6] head is read too
if let second = try? MLMultiArray(shape: [1, 3, 6], dataType: .float32) {
    let values: [Float] = [320, 320, 200, 300, 0.65, 0.10] + [Float](repeating: 0, count: 12)
    for index in 0..<values.count { second[index] = NSNumber(value: values[index]) }
    if let tensor = PostureHeadTensor(array: second) {
        let summary = PostureDetectionDecoder.summarize(tensor, threshold: PostureSensitivity.standard.threshold)
        check(summary.detections.count == 1, "row-major head decodes, got \(summary.detections.count)")
        check(summary.detections.first?.label == .bad, "row-major label bad")
    } else { check(false, "row-major head should be readable") }
} else { check(false, "could not build a test tensor") }

// 5d. CoreML pads the head buffer: the reader follows the reported strides
let paddedAnchors = 4
let paddedChannels = 8
let paddedCount = columns * paddedChannels
let paddedPointer = UnsafeMutablePointer<Float>.allocate(capacity: paddedCount)
paddedPointer.initialize(repeating: 0, count: paddedCount)
defer { paddedPointer.deallocate() }
let paddedRow: [Float] = [320, 320, 200, 300, 0.02, 0.75]
for (channel, value) in paddedRow.enumerated() { paddedPointer[channel * paddedChannels] = value }
if let paddedArray = try? MLMultiArray(
    dataPointer: UnsafeMutableRawPointer(paddedPointer),
    shape: [NSNumber(value: 1), NSNumber(value: columns), NSNumber(value: paddedAnchors)],
    dataType: .float32,
    strides: [NSNumber(value: paddedCount), NSNumber(value: paddedChannels), 1]
), let tensor = PostureHeadTensor(array: paddedArray) {
    let summary = PostureDetectionDecoder.summarize(tensor, threshold: PostureSensitivity.standard.threshold)
    check(summary.detections.count == 1, "padded strides decode one detection, got \(summary.detections.count)")
    check(summary.detections.first?.label == .good, "padded strides label good")
    check(abs(summary.bestScore - 0.75) < 0.0001, "padded strides best score")
} else { check(false, "padded head should be readable") }

// 5e. Decoded boxes carry a top-left origin, not the head's centre form
rows.replaceSubrange(0..<columns, with: row(320, 320, 200, 300, 0.01, 0.90))
if let detection = PostureDetectionDecoder.decode(rows: rows).first {
    check(abs(detection.box.minX - 220.0 / 640) < 0.0001, "box x is the left edge, got \(detection.box.minX)")
    check(abs(detection.box.minY - 170.0 / 640) < 0.0001, "box y is the top edge, got \(detection.box.minY)")
    check(abs(detection.box.width - 200.0 / 640) < 0.0001, "box keeps the head's width")
    check(abs(detection.box.midX - 320.0 / 640) < 0.0001, "box centre matches the head's cx")
} else { check(false, "expected one detection for the geometry check") }

// 5f. The ultrasonic sensor drives the progressive blur as a severity ramp
check(PostureDistanceResponse.severity(distanceCM: 80) == 0, "far away has no severity")
check(PostureDistanceResponse.severity(distanceCM: 50) == 0, "the too-close line itself has no severity")
check(abs(PostureDistanceResponse.severity(distanceCM: 37.5) - 0.5) < 0.0001, "halfway down the ramp is half strength")
check(PostureDistanceResponse.severity(distanceCM: 25) == 1, "25 cm is full strength")
check(PostureDistanceResponse.severity(distanceCM: 10) == 1, "closer than the ramp stays at full strength")
check(PostureDistanceResponse.severity(distanceCM: -1) == 0, "a missing echo has no severity")
check(PostureDistanceResponse.severity(distanceCM: .nan) == 0, "nan has no severity")

let blurStart = Date(timeIntervalSince1970: 12_000)
check(PostureDistanceResponse.blurIntensity(distanceCM: 40, badSince: blurStart, delay: 3,
                                            now: blurStart.addingTimeInterval(2)) == 0,
      "blur waits out the reminder delay")
check(abs(PostureDistanceResponse.blurIntensity(distanceCM: 40, badSince: blurStart, delay: 3,
                                                now: blurStart.addingTimeInterval(4)) - 0.4) < 0.0001,
      "blur ramps once the delay has passed")
check(PostureDistanceResponse.blurIntensity(distanceCM: 40, badSince: nil, delay: 0, now: blurStart) == 0,
      "no streak means no blur")
check(PostureDistanceResponse.blurIntensity(distanceCM: 80, badSince: blurStart, delay: 0,
                                            now: blurStart.addingTimeInterval(9)) == 0,
      "sitting back clears it immediately")

// 6. Letterbox mapping back to the frame
let transform = PostureLetterboxTransform(scale: 0.5, offset: CGPoint(x: 0, y: 12), modelWidth: 640, modelHeight: 640)
let frame = transform.frameRect(for: CGRect(x: 0.25, y: 0.5, width: 0.1, height: 0.1))
check(abs(frame.minX - 320) < 0.001, "frame x, got \(frame.minX)")
check(abs(frame.minY - 616) < 0.001, "frame y, got \(frame.minY)")
check(abs(frame.width - 128) < 0.001, "frame width, got \(frame.width)")

// 7. Telemetry parsing
let telemetry = PostureSerialTelemetry.parse("D,48.5,C\r")
check(telemetry?.zone == .tooClose && telemetry?.distanceCM == 48.5, "telemetry parse")
check(PostureSerialTelemetry.parse("D,-1,N")?.distanceCM == nil, "no echo has no distance")
check(PostureSerialTelemetry.parse("D,-1,C") == nil, "invalid no-echo zone rejected")
check(PostureSerialTelemetry.parse("D,900,G") == nil, "out of range rejected")
check(PostureSerialTelemetry.parse("D,50,X") == nil, "unknown zone rejected")
check(PostureSerialTelemetry.parse("hello") == nil, "garbage rejected")
check(PostureSerialTelemetry.parse(String(repeating: "D", count: 80)) == nil, "long line rejected")

// 7b. Bad-posture alert policy
var policy = PostureAlertPolicy(repeatInterval: 45)
let t0 = Date(timeIntervalSince1970: 1_000)
check(policy.evaluate(active: true, enabled: true, now: t0), "first bad episode alerts")
check(!policy.evaluate(active: true, enabled: true, now: t0.addingTimeInterval(10)), "no repeat inside cooldown")
check(!policy.evaluate(active: true, enabled: true, now: t0.addingTimeInterval(44)), "still quiet before cooldown")
check(policy.evaluate(active: true, enabled: true, now: t0.addingTimeInterval(46)), "reminds after cooldown")
check(!policy.evaluate(active: false, enabled: true, now: t0.addingTimeInterval(50)), "good posture is silent")
check(policy.evaluate(active: true, enabled: true, now: t0.addingTimeInterval(51)), "new episode alerts immediately")
var muted = PostureAlertPolicy(repeatInterval: 45)
check(!muted.evaluate(active: true, enabled: false, now: t0), "disabled alerts stay silent")
check(muted.evaluate(active: true, enabled: true, now: t0.addingTimeInterval(1)), "enabling alerts mid-episode alerts once")

var once = PostureAlertPolicy(repeatInterval: nil)
check(once.evaluate(active: true, enabled: true, now: t0), "once mode alerts on a new episode")
check(!once.evaluate(active: true, enabled: true, now: t0.addingTimeInterval(600)), "once mode stays quiet afterwards")
check(!once.evaluate(active: false, enabled: true, now: t0.addingTimeInterval(601)), "good posture is silent in once mode")
check(!once.evaluate(active: true, enabled: false, now: t0.addingTimeInterval(602)), "disabled stays silent")
check(once.evaluate(active: true, enabled: true, now: t0.addingTimeInterval(603)), "once mode arms again after recovery")

var continuous = PostureAlertPolicy(repeatInterval: PostureAlertRepeat.continuous.interval)
check(continuous.evaluate(active: true, enabled: true, now: t0), "continuous alerts immediately")
check(!continuous.evaluate(active: true, enabled: true, now: t0.addingTimeInterval(3.9)), "continuous waits its interval")
check(continuous.evaluate(active: true, enabled: true, now: t0.addingTimeInterval(4.1)), "continuous repeats after 4 s")
check(continuous.evaluate(active: true, enabled: true, now: t0.addingTimeInterval(8.2)), "continuous keeps repeating")
check(PostureAlertRepeat.continuous.interval == 4 && PostureAlertRepeat.once.interval == nil, "repeat intervals")

let climate = PostureEnvironmentTelemetry.parse("E,23.4,56.7\r")
check(climate?.temperatureC == 23.4 && climate?.humidityPercent == 56.7, "climate values")
check(PostureEnvironmentTelemetry.parse("E,0,0")?.temperatureC == 0, "zero climate values")
check(PostureEnvironmentTelemetry.parse("E,-40,100")?.humidityPercent == 100, "climate boundaries")
check(PostureEnvironmentTelemetry.parse("E,ERR") == .init(temperatureC: nil, humidityPercent: nil), "explicit sensor failure")
for invalid in ["E,nan,50", "E,20,inf", "E,81,50", "E,-41,50", "E,20,101", "E,20,-1", "E,,50", "E,20", "E,ERR,50", "D,20,50"] {
    check(PostureEnvironmentTelemetry.parse(invalid) == nil, "invalid climate frame: \(invalid)")
}

// 7c. Good-posture announcement
var goodPolicy = PostureGoodAlertPolicy()
check(goodPolicy.evaluate(confirmedGood: true, bad: false, enabled: true), "first good announcement")
check(!goodPolicy.evaluate(confirmedGood: true, bad: false, enabled: true), "no repeat while good")
check(!goodPolicy.evaluate(confirmedGood: false, bad: true, enabled: true), "bad arm is silent")
check(goodPolicy.evaluate(confirmedGood: true, bad: false, enabled: true), "correction announces again")
check(!goodPolicy.evaluate(confirmedGood: false, bad: false, enabled: true), "no detection is silent")
check(!goodPolicy.evaluate(confirmedGood: true, bad: false, enabled: true), "only once per correction")
check(PostureAlert(kind: .good).isPositive && !PostureAlert(tooClose: true).isPositive, "alert tones")

// 7c2. Seconds-based hysteresis: slower entry, faster recovery, neutral loss.
var stab = PostureStabilizer()
let stabStart = Date(timeIntervalSince1970: 9_000)
func stabStep(_ outcome: PostureOutcome, _ offset: TimeInterval) -> PostureState {
    stab.update(outcome, now: stabStart.addingTimeInterval(offset)).posture
}
check(stabStep(.good(0.9), 0) == .unknown, "one frame is not enough")
check(stabStep(.good(0.9), 0.1) == .unknown, "a burst cannot confirm a duration")
check(stabStep(.good(0.9), 0.59) == .unknown, "good waits the entire 0.6 seconds")
check(stabStep(.good(0.9), 0.6) == .good, "0.6 seconds confirms good")
for time in [0.7, 1.2, 1.7, 2.2, 2.69] {
    check(stabStep(.bad(0.9), time) == .good, "a short bad run retains the confirmed state")
}
check(stabStep(.bad(0.9), 2.7) == .bad, "two seconds confirms bad")
check(stab.badSince == stabStart.addingTimeInterval(0.7), "the episode starts with the first bad sample")
for time in [2.8, 3.0, 3.39] {
    check(stabStep(.good(0.9), time) == .bad, "brief good flickers do not clear a bad episode")
}
check(stabStep(.good(0.9), 3.4) == .good && stab.badSince == nil, "stable recovery clears the episode")
check(stabStep(.none(peopleCount: 2), 3.5) == .unknown, "ambiguous input is immediately neutral")
check(stab.stable.peopleCount == 2 && stab.stable.confidence == nil && !stab.stable.isConfirmed,
      "unknown preserves people metadata without confidence")
check(stabStep(.good(0.9), 3.6) == .unknown, "reacquisition starts a new timer")
check(stabStep(.good(0.9), 3.8) == .unknown, "reacquisition does not reuse old good evidence")
check(stabStep(.good(0.9), 4.2) == .good, "fresh evidence restores good")
check(stabStep(.bad(0.9), 4.1) == .good && stab.pendingState == nil,
      "out-of-order frames cannot change state or start a candidate")
check(stabStep(.bad(0.9), 4.2) == .good && stab.pendingState == nil,
      "duplicate timestamps cannot accumulate evidence")
check(stabStep(.good(0.9), 5.3) == .unknown, "a gap over one second clears the old confirmed state")

for fps in [5, 10, 30] {
    var timed = PostureStabilizer()
    for frame in 0...(fps * 2) {
        let result = timed.update(.bad(0.9), now: stabStart.addingTimeInterval(Double(frame) / Double(fps)))
        check(result.posture == (frame < fps * 2 ? .unknown : .bad),
              "Bad confirmation is two seconds at \(fps) fps")
    }
    let recoveryAt = stabStart.addingTimeInterval(2.1)
    for frame in 0...Int(ceil(0.6 * Double(fps))) {
        let duration = Double(frame) / Double(fps)
        let result = timed.update(.good(0.9), now: recoveryAt.addingTimeInterval(duration))
        check(result.posture == (duration + 0.000001 < 0.6 ? .bad : .good),
              "recovery is 0.6 seconds at \(fps) fps")
    }
}
var burst = PostureStabilizer()
for frame in 0..<100 {
    _ = burst.update(.bad(0.9), now: stabStart.addingTimeInterval(Double(frame) / 1000))
}
check(burst.stable.posture == .unknown, "one hundred rapid frames cannot turn 0.1 seconds into two seconds")

// 7d. Sensitivity maps to the reference thresholds
check(PostureSensitivity.strict.threshold == 0.60, "strict matches the reference")
check(PostureSensitivity.standard.threshold == 0.50, "standard threshold")
check(PostureSensitivity.relaxed.threshold == 0.40, "relaxed threshold")
check(PostureSensitivity.sensitive.threshold == 0.30, "sensitive threshold")
var tuned = [Float](repeating: 0, count: columns)
tuned.replaceSubrange(0..<columns, with: row(320, 320, 200, 190, 0.45, 0.05))  // 0.45 score
check(PostureDetectionDecoder.decode(rows: tuned).isEmpty, "0.45 is rejected at 0.50")
check(PostureDetectionDecoder.decode(rows: tuned, threshold: 0.40).count == 1, "0.45 passes at 0.40")

// 8. Snapshot presentation rules
var snapshot = PostureSnapshot.offline
check(snapshot.title == "Posture detection is not running", "offline title")
snapshot = PostureSnapshot(posture: .good, arduino: .disconnected, distanceCM: nil,
                           tooClose: false, isRunning: true, confirmed: false, source: nil,
                           confidence: nil, peopleCount: 0, zone: nil)
check(snapshot.title == "Unknown posture", "unconfirmed posture is labelled unknown")
snapshot.posture = .unknown
check(snapshot.title == "Unknown posture", "unknown label")
snapshot.posture = .good
snapshot.confirmed = true
snapshot.source = .camera
snapshot.confidence = 0.87
check(snapshot.title == "Good posture", "confirmed good title")
check(snapshot.detail == .confidence(0.87), "confidence detail, got \(snapshot.detail)")
snapshot.peopleCount = 3
snapshot.confirmed = false
check(snapshot.detail == .people(3), "people count detail, got \(snapshot.detail)")
snapshot = PostureSnapshot(posture: .bad, arduino: .connected, distanceCM: 44,
                           tooClose: true, isRunning: true)
check(snapshot.title == "Too close — move back", "too close wins over posture")


// 9. Lock and sleep really stop detection: the policy is what the service obeys
var gate = BackgroundDetectionPolicy(userEnabled: true)
check(gate.shouldRun, "detection runs when the switch is on and the system is awake")
check(gate.setUserEnabled(true) == .none, "re-asserting the switch is a no-op")

check(gate.setSuspended(true) == .stop, "locking must stop the capture session")
check(!gate.shouldRun, "camera stays off while locked")
check(gate.userEnabled, "the master switch survives the lock and is not rewritten")
check(gate.setSuspended(true) == .none, "repeated lock notifications do nothing")
check(gate.setSuspended(false) == .start, "waking starts detection again")
check(gate.shouldRun, "detection runs after the wake")

// 9b. A monitor the user turned off does not come back on its own after a lock
var idle = BackgroundDetectionPolicy(userEnabled: false)
check(idle.setSuspended(true) == .none, "locking an idle service does nothing")
check(idle.setSuspended(false) == .none, "waking must not start a monitor the user turned off")
check(!idle.shouldRun, "still off after the wake")

// 9c. Turning the switch on while locked waits for the wake
var lockedOut = BackgroundDetectionPolicy(userEnabled: false, isSuspended: true)
check(lockedOut.setUserEnabled(true) == .none, "enabling while locked keeps the camera off")
check(lockedOut.userEnabled && !lockedOut.shouldRun, "intent recorded, camera still dark")
check(lockedOut.setSuspended(false) == .start, "wake honours the switch just turned on")

// 9d. Turning the switch off mid-run releases the camera
var hot = BackgroundDetectionPolicy(userEnabled: true)
check(hot.setUserEnabled(false) == .stop, "disabling stops detection")
check(hot.setUserEnabled(false) == .none, "disabling twice is a no-op")
check(hot.setUserEnabled(true) == .start, "re-enabling starts it again")

// 9e. Service state is exactly the switch AND the wake state
for userEnabled in [true, false] {
    for suspended in [true, false] {
        let policy = BackgroundDetectionPolicy(userEnabled: userEnabled, isSuspended: suspended)
        check(policy.shouldRun == (userEnabled && !suspended),
              "shouldRun == enabled && !suspended (\(userEnabled), \(suspended))")
    }
}

// 9f. A lock/sleep/wake/unlock cycle produces exactly one stop and one start
var cycle = BackgroundDetectionPolicy(userEnabled: true)
var cycleActions: [BackgroundDetectionPolicy.Action] = []
for suspended in [true, true, false, false] {   // screen sleep, system sleep, both wakes
    let action = cycle.setSuspended(suspended)
    if action != .none { cycleActions.append(action) }
}
check(cycleActions == [.stop, .start], "cycle yields one stop and one start, got \(cycleActions)")
check(cycle.shouldRun, "running again after the cycle")


// 10. Day / week / month / year trends and the day history behind them
var trendCal = Calendar(identifier: .gregorian)
trendCal.timeZone = TimeZone(identifier: "Asia/Taipei") ?? .current
trendCal.firstWeekday = 2

func trendDate(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
    trendCal.date(from: DateComponents(year: year, month: month, day: day, hour: hour)) ?? Date()
}

func hours(_ pairs: [Int: (Double, Double)]) -> [PostureHourBucket] {
    var buckets = PostureDayRecord.emptyHourly
    for (hour, value) in pairs {
        buckets[hour] = PostureHourBucket(good: value.0, bad: value.1)
    }
    return buckets
}

let trendNow = trendDate(2026, 10, 21, 14)
let todayStats = PostureStats(
    dayKey: "2026-10-21",
    goodSeconds: 900,
    badSeconds: 300,
    hourly: hours([9: (900, 0), 15: (0, 300)])
)
let mondayRecord = PostureDayRecord(
    day: "2026-10-19", good: 1800, bad: 600, met: true,
    hourly: hours([9: (1800, 0), 15: (0, 600)])
)
let tuesdayRecord = PostureDayRecord(
    day: "2026-10-20", good: 1800, bad: 1200, met: false,
    hourly: hours([9: (1800, 0), 15: (0, 1200)])
)
let history = [mondayRecord, tuesdayRecord]

// 10a. Day: 24 hourly bars, the current hour marked, live stats included
let dayTrend = PostureTrendBuilder.trend(
    range: .day, records: history, today: todayStats, now: trendNow, calendar: trendCal
)
check(dayTrend.bars.count == 24, "day range has 24 bars, got \(dayTrend.bars.count)")
check(dayTrend.bars[14].isCurrent, "the current hour is flagged")
check(dayTrend.bars[9].good == 900 && dayTrend.bars[9].bad == 0, "day bar carries today's good time")
check(dayTrend.best?.hour == 9, "day best slot is 09:00, got \(String(describing: dayTrend.best?.hour))")
check(dayTrend.worst?.hour == 15, "day worst slot is 15:00")

// 10b. Week: seven bars, Monday first, today included
let weekTrend = PostureTrendBuilder.trend(
    range: .week, records: history, today: todayStats, now: trendNow, calendar: trendCal
)
check(weekTrend.bars.count == 7, "week has 7 bars, got \(weekTrend.bars.count)")
check(weekTrend.bars.map(\.label) == ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"],
      "week is Monday first, got \(weekTrend.bars.map(\.label))")
let todayBar = weekTrend.bars.first { $0.id == "2026-10-21" }
check(todayBar?.good == 900, "week bar for today comes from the live stats")
let emptyBar = weekTrend.bars.first { $0.id == "2026-10-25" }
check(emptyBar?.hasData == false, "a future day has no data")
check(weekTrend.best?.hour == 9, "week best slot is 09:00")
check(weekTrend.worst?.hour == 15, "week worst slot is 15:00")
check(weekTrend.good == 4500 && weekTrend.bad == 2100,
      "week totals add up, got \(weekTrend.good)/\(weekTrend.bad)")

// 10c. Month: one bar per day of the current month
let monthTrend = PostureTrendBuilder.trend(
    range: .month, records: history, today: todayStats, now: trendNow, calendar: trendCal
)
let octoberDays = trendCal.range(of: .day, in: .month, for: trendNow)?.count ?? 0
check(monthTrend.bars.count == octoberDays, "month has \(octoberDays) bars, got \(monthTrend.bars.count)")
check(monthTrend.bars[18].good == 1800, "the 19th keeps its good time")

// 10d. Year: twelve monthly bars aggregating the stored days
let yearTrend = PostureTrendBuilder.trend(
    range: .year, records: history, today: todayStats, now: trendNow, calendar: trendCal
)
check(yearTrend.bars.count == 12, "year has 12 bars, got \(yearTrend.bars.count)")
check(yearTrend.bars[9].good == 4500 && yearTrend.bars[9].bad == 2100,
      "October aggregates three days, got \(yearTrend.bars[9].good)/\(yearTrend.bars[9].bad)")
check(yearTrend.bars[0].hasData == false, "January has no data")

// 10e. Hours under the floor never win best / worst
let floored = PostureTrendBuilder.slotSummary(from: [
    hours([7: (120, 0), 9: (300, 300), 15: (0, 600)])
])
check(floored.best?.hour == 9, "a 2 minute hour is ignored, got \(String(describing: floored.best?.hour))")
check(floored.worst?.hour == 15, "worst slot is the slouched hour")
let unfloored = PostureTrendBuilder.slotSummary(
    from: [hours([7: (120, 0), 9: (300, 300)])], minimum: 60
)
check(unfloored.best?.hour == 7, "lowering the floor admits the short hour")
let noSlots = PostureTrendBuilder.slotSummary(from: [])
check(noSlots.best == nil && noSlots.worst == nil, "no data means no slots")

// 10f. history.json round trip, size and retention
let historyURL = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("posture-history-\(UUID().uuidString).json")
let historyFile = PostureHistoryFile(url: historyURL)
historyFile.save(history)
let reloaded = historyFile.load()
check(reloaded.count == 2, "two days round trip, got \(reloaded.count)")
check(reloaded[0] == mondayRecord, "a record survives encode + decode unchanged")
check(reloaded[0].hourly[9].good == 1800, "the hourly split survives the round trip")
let historyBytes = (try? Data(contentsOf: historyURL).count) ?? 0
check(historyBytes > 0 && historyBytes < 600, "a few days stay tiny, got \(historyBytes) bytes")

let manyDays = (0..<450).map { index in
    PostureDayRecord(day: String(format: "2025-%03d", index), good: 60, bad: 0, met: true)
}
historyFile.save(manyDays)
let capped = historyFile.load()
check(capped.count == PostureHistoryFile.maximumDays,
      "history is capped at \(PostureHistoryFile.maximumDays), got \(capped.count)")
check(capped.first?.day == manyDays[50].day, "the oldest days are dropped first")

// 10g. A day that ended while the app was closed still reaches the history
let staleDefaults = UserDefaults(suiteName: "posture-logic-check-\(UUID().uuidString)")!
staleDefaults.set("2026-10-20", forKey: "notch.posture.stats.day")
staleDefaults.set(1800.0, forKey: "notch.posture.stats.good")
staleDefaults.set(600.0, forKey: "notch.posture.stats.bad")
let staleURL = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("posture-stale-\(UUID().uuidString).json")
let staleStore = PostureHistoryFile(url: staleURL)
_ = MainActor.assumeIsolated {
    PostureSessionTracker(defaults: staleDefaults, historyFile: staleStore)
}
let adopted = staleStore.load()
check(adopted.count == 1 && adopted[0].day == "2026-10-20",
      "yesterday is archived on launch, got \(adopted.map(\.day))")
check(adopted.first?.good == 1800, "the archived day keeps its totals")

try? FileManager.default.removeItem(at: historyURL)
try? FileManager.default.removeItem(at: staleURL)
staleDefaults.removePersistentDomain(forName: staleDefaults.volatileDomainNames.first ?? "")

// 11. Focus/rest rhythm, deterministic clocks and isolated preferences/history.
MainActor.assumeIsolated {
    let suite = "posture-cycle-check-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("\(suite).json")
    defer {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: url)
    }
    let start = Calendar.current.startOfDay(for: Date()).addingTimeInterval(3600)
    @MainActor func tracker(_ now: Date) -> PostureSessionTracker {
        PostureSessionTracker(defaults: defaults, historyFile: PostureHistoryFile(url: url), now: now)
    }
    let session = tracker(start)
    check(!session.settings.enabled && session.cycle.remaining == 3000,
          "rhythm is opt-in with a 50 minute focus default")
    check(session.settings.breakMinutes == 10, "default break is 10 minutes")
    session.setCycleEnabled(true, now: start)
    var now = start
    session.tick(now: now, state: .good, isRunning: true)
    @MainActor func sit(_ seconds: Int) {
        for _ in 0..<(seconds / 5) {
            now = now.addingTimeInterval(5)
            session.tick(now: now, state: .good, isRunning: true)
        }
    }
    var events: [PostureCyclePhase] = []
    session.onCycleEvent = { events.append($0.phase) }
    sit(2250)
    check(session.cycle.countdownText == "12:30", "HUD focus countdown reaches 12:30")
    let restoredFocus = tracker(now)
    check(restoredFocus.cycle.remaining == 750, "short relaunch preserves focus progress")
    sit(750)
    check(session.cycle.phase == .rest && session.cycle.remaining == 600,
          "50 minutes of detected sitting starts a 10 minute break")
    check(events == [.rest], "focus boundary announces exactly once")
    now = now.addingTimeInterval(120)
    session.tick(now: now, state: nil, isRunning: false)
    check(session.cycle.countdownText == "08:00", "break uses actual elapsed time after suspension")
    let restoredRest = tracker(now.addingTimeInterval(60))
    check(restoredRest.cycle.phase == .rest && restoredRest.cycle.remaining == 420,
          "relaunch resumes the remaining break")
    now = now.addingTimeInterval(480)
    session.tick(now: now, state: nil, isRunning: false)
    check(session.cycle.phase == .focus && session.cycle.remaining == 3000,
          "break ends at its deadline with a fresh focus phase")
    check(session.cycle.completedToday == 1 && events == [.rest, .focus],
          "full focus and break count as one cycle")
    session.tick(now: now.addingTimeInterval(1), state: nil, isRunning: false)
    check(session.cycle.completedToday == 1, "break completion does not repeat")
    now = now.addingTimeInterval(1)
    sit(60)
    now = now.addingTimeInterval(30)
    session.tick(now: now, state: .unknown, isRunning: true)
    check(session.cycle.remaining == 2940, "unknown posture pauses focus")
    now = now.addingTimeInterval(90)
    session.tick(now: now, state: nil, isRunning: false)
    check(session.cycle.remaining == 3000, "two minutes away resets focus")
    session.startBreakNow(now: now)
    session.setCycleDurations(focus: 25, breakLength: nil, now: now)
    check(session.cycle.phase == .rest && session.cycle.remaining == 600,
          "editing the next focus duration preserves the current break")
    session.skipRest(now: now)
    check(session.cycle.phase == .focus && session.cycle.remaining == 1500,
          "skip break starts focus with the selected duration")
    check(session.cycle.completedToday == 1, "skipping a break never earns a cycle")
    session.startBreakNow(now: now)
    now = now.addingTimeInterval(600)
    session.tick(now: now, state: nil, isRunning: false)
    check(session.cycle.completedToday == 1, "early rest never earns a full cycle")
    session.setCycleDurations(focus: .nan, breakLength: .infinity, now: now)
    check(session.settings.focusMinutes == 25 && session.settings.breakMinutes == 10,
          "nonfinite duration settings are rejected")
    session.setCycleEnabled(false, now: now)
    sit(60)
    check(session.cycle.remaining == 1500, "disabled rhythm does not count down")
    session.setCycleEnabled(true, now: now)
    sit(60)
    check(tracker(now.addingTimeInterval(121)).cycle.remaining == 1500,
          "returning after two minutes offline resets focus")
    let midnight = Calendar.current.startOfDay(for: start).addingTimeInterval(24 * 3600)
    session.tick(now: midnight, state: nil, isRunning: false)
    check(session.cycle.completedToday == 0, "daily count resets at midnight")
    session.setCycleDurations(focus: 1, breakLength: 1, now: midnight)
    now = midnight
    sit(60)
    check(session.cycle.phase == .rest, "short focus preset enters rest")
    let expired = tracker(now.addingTimeInterval(65))
    check(expired.cycle.phase == .focus && expired.cycle.completedToday == 1,
          "expired break completes once when reopening")
    check(tracker(now.addingTimeInterval(66)).cycle.completedToday == 1,
          "repeated reopening never double counts an expired break")
    let fraction = PostureCycle(remaining: 0.2, duration: 60)
    check(fraction.countdownText == "00:01", "countdown never shows zero before the boundary")

    // Custom values use the same saved settings and preserve elapsed time.
    session.setCycleEnabled(false, now: now)
    session.setCycleDurations(focus: 37, breakLength: 7, now: now)
    session.setCycleEnabled(true, now: now)
    sit(60)
    check(session.cycle.remaining == 2160, "custom 37 minute focus counts down normally")
    let customReload = tracker(now)
    check(customReload.settings.focusMinutes == 37 && customReload.settings.breakMinutes == 7,
          "custom focus and break durations survive relaunch")
    session.setCycleDurations(focus: 42, breakLength: nil, now: now)
    check(session.cycle.remaining == 2460, "applying a custom focus keeps elapsed focus time")
    session.startBreakNow(now: now)
    now = now.addingTimeInterval(60)
    session.tick(now: now, state: nil, isRunning: false)
    session.setCycleDurations(focus: nil, breakLength: 9, now: now)
    check(session.cycle.remaining == 480, "applying a custom break keeps elapsed break time")
    session.setCycleDurations(focus: 0, breakLength: 601, now: now)
    check(session.settings.focusMinutes == 42 && session.settings.breakMinutes == 9,
          "out of range custom durations leave settings unchanged")
    session.setCycleDurations(focus: 1, breakLength: 600, now: now)
    let limits = tracker(now)
    check(limits.settings.focusMinutes == 1 && limits.settings.breakMinutes == 600,
          "both custom duration boundaries are accepted and saved")

}


// MARK: - Dorso posture response function (PostureResponse.swift)

let responseStart = Date(timeIntervalSince1970: 2_000)

// 19. Dorso's intensity curve: severity raised to 1 / intensity.
let severityReading = PostureResponseReading(isBadPosture: true, severity: 0.25)
func responseIntensity(_ intensity: Double) -> Double {
    PostureResponse.process(
        severityReading,
        state: PostureResponseState(),
        config: PostureResponseConfig(
            badSampleThreshold: 1,
            goodSampleThreshold: 1,
            warningOnsetDelay: 0,
            intensity: intensity
        )
    ).warningIntensity
}
check(abs(responseIntensity(1) - 0.25) < 0.0001, "intensity 1 keeps the severity")
check(abs(responseIntensity(0.5) - 0.0625) < 0.0001, "half intensity flattens the ramp")
check(abs(responseIntensity(2) - 0.5) < 0.0001, "double intensity sharpens the ramp")
check(abs(responseIntensity(0) - 0.25) < 0.0001, "a non-positive intensity falls back to 1")

// 20. One slouch episode records once, and again when it comes back.
var episodeState = PostureResponseState()
let episodeConfig = PostureResponseConfig(
    badSampleThreshold: 2,
    goodSampleThreshold: 2,
    warningOnsetDelay: 0,
    intensity: 1
)
let badReading = PostureResponseReading(isBadPosture: true, severity: 0.6)
let goodReading = PostureResponseReading(isBadPosture: false, severity: 0)
func episodeStep(_ reading: PostureResponseReading) -> [PostureResponseEffect] {
    let result = PostureResponse.process(
        reading,
        state: episodeState,
        config: episodeConfig,
        now: responseStart
    )
    episodeState = result.state
    return result.effects
}
check(episodeStep(badReading).isEmpty, "the first bad sample is silent")
check(episodeStep(badReading).contains(.recordSlouchEvent), "the episode records when it opens")
check(episodeStep(badReading).contains(.recordSlouchEvent) == false, "staying slouched never records twice")
check(episodeStep(goodReading).isEmpty, "one good sample does not close the episode")
check(episodeStep(goodReading).contains(.updatePresentation), "closing the episode refreshes presentation")
check(episodeStep(badReading).isEmpty, "a later bad sample starts a new run")
check(episodeStep(badReading).contains(.recordSlouchEvent), "the next episode records again")

// MARK: - Pose fallback: geometry thresholds, baseline drift and the fusion policy

func poseFeatures(
    headTilt: Double = 0,
    headForward: Double = 0.02,
    headAbove: Double = 0.65,
    shoulderTilt: Double = 0,
    torsoLean: Double? = nil,
    view: PosturePoseView = .frontal
) -> PosturePoseFeatures {
    PosturePoseFeatures(
        headTiltDegrees: headTilt,
        headForward: headForward,
        headAbove: headAbove,
        shoulderTiltDegrees: shoulderTilt,
        torsoLeanDegrees: torsoLean,
        view: view,
        confidence: 0.6,
        box: CGRect(x: 0.3, y: 0.2, width: 0.4, height: 0.5),
        weakestJointConfidence: 0.6, headTiltMeasured: true
    )
}

// 21. The judge passes a measured upright frame and rejects the slouches it can see.
let poseJudge = PosturePoseJudge()
check(poseJudge.verdict(for: poseFeatures()).state == .good, "an upright pose is good")

// 22. A head tilted hard against the shoulder line is a slouch on its own.
check(poseJudge.verdict(for: poseFeatures(headTilt: 45)).state == .bad,
      "a 45 degree head tilt is bad")
// 23. So is a head pushed well past the shoulder line, or one that has sunk onto the chest.
check(poseJudge.verdict(for: poseFeatures(headForward: 0.36)).state == .bad,
      "a 0.36-span forward head is bad")
check(poseJudge.verdict(for: poseFeatures(headAbove: 0.3)).state == .bad,
      "a head sunk to 0.3 spans is bad")
// 24. A torso leaning off vertical is bad, but only when the hips survived to measure it.
check(poseJudge.verdict(for: poseFeatures(torsoLean: 33)).state == .bad,
      "a 33 degree torso lean is bad")
check(poseJudge.verdict(for: poseFeatures(torsoLean: nil)).state == .good,
      "no measurable torso is not a torso verdict")
// 25. Two moderate deviations are a slouch even though neither alone crosses the limit.
// 26 deg of tilt and 0.29 spans of forward offset: each about a third of the way into
// its band, so neither alone is a confident slouch.
let moderate = poseFeatures(headTilt: 26, headForward: 0.29)
check(poseJudge.verdict(for: moderate).state == .bad,
      "two moderate deviations make a bad")
// 26. A borderline single deviation stays unknown rather than guessing.
check(poseJudge.verdict(for: poseFeatures(headTilt: 24)).state == .unknown,
      "one borderline deviation stays unknown")

// 27. Per-view calibration: a profile frame is not judged against a frontal reference.
var poseBaseline = PosturePoseBaseline()
for _ in 0..<PosturePoseBaseline.minimumSamples {
    poseBaseline.observe(poseFeatures())
}
check(poseBaseline.isReady(for: .frontal), "frontal view calibrates")
check(!poseBaseline.isReady(for: .profile), "profile view stays uncalibrated")
var viewJudge = PosturePoseJudge(baseline: poseBaseline)
check(viewJudge.relativeScores(poseFeatures(view: .profile)).isEmpty,
      "an uncalibrated view gets no relative rules")
// 28. A clear drift away from the calibrated reference is caught, inside the limits.
let drifted = poseJudge.verdict(for: poseFeatures(headTilt: 0))
check(drifted.state == .good, "the calibrated reference still reads good")
let driftVerdict = viewJudge.verdict(for: poseFeatures(headForward: 0.30))
check(driftVerdict.state == .bad, "drift from the baseline is bad")
check(driftVerdict.reasons.contains { $0.contains("drift") }, "the drift is reported")

// 29. The fusion policy: the four paths and their priorities.
let uprightVerdict = PosturePoseVerdict(state: .good, score: 0, confidence: 0.6, reasons: [])
let slouchVerdict = PosturePoseVerdict(state: .bad, score: 0.9, confidence: 0.95, reasons: [])
let hesitantVerdict = PosturePoseVerdict(state: .unknown, score: 0.4, confidence: 0, reasons: [])

var decision = PostureHybridPolicy.decide(
    model: .good(0.8), singleBody: true, poseState: .bad, verdict: hesitantVerdict,
    crop: .notAttempted)
check(decision.source == .model && decision.outcome.posture == .good,
      "a hesitant pose never overturns a model answer")

decision = PostureHybridPolicy.decide(
    model: .none(peopleCount: 0), singleBody: true, poseState: .unknown,
    verdict: hesitantVerdict, crop: .answered(.bad(0.61), 0.61))
check(decision.source == .poseCrop && decision.outcome.posture == .bad,
      "the crop retry answers before geometry does")

decision = PostureHybridPolicy.decide(
    model: .none(peopleCount: 0), singleBody: true, poseState: .bad,
    verdict: slouchVerdict, crop: .abstained)
check(decision.source == .pose && decision.outcome.posture == .bad,
      "geometry decides when the head abstains twice")

// 30. The veto: a confident GOOD the geometry strongly contradicts becomes UNKNOWN.
decision = PostureHybridPolicy.decide(
    model: .good(0.72), singleBody: true, poseState: .bad, verdict: slouchVerdict,
    crop: .notAttempted)
check(decision.source == .poseVeto, "a strong pose objection vetoes a model GOOD")
check(decision.outcome.posture == .unknown, "a vetoed frame is unknown, not bad")

// 31. An uncalibrated pose cannot soften BAD; a weak objection is ignored.
decision = PostureHybridPolicy.decide(
    model: .bad(0.7), singleBody: true, poseState: .good, verdict: uprightVerdict,
    crop: .notAttempted)
check(decision.outcome.posture == .bad && decision.source == .model,
      "upright pose alone cannot overturn a model BAD")
check(!PostureHybridPolicy.decide(
    model: .good(0.72), singleBody: true, poseState: .bad,
    verdict: PosturePoseVerdict(state: .bad, score: 0.5, confidence: 0.7, reasons: []),
    crop: .notAttempted).source.isVeto, "a 0.5 objection is not enough to veto")

// 32. Multi-person frames stay unknown even when geometry would have spoken.
decision = PostureHybridPolicy.decide(
    model: .none(peopleCount: 2), singleBody: false, poseState: .bad,
    verdict: slouchVerdict, crop: .abstained)
check(decision.outcome.posture == .unknown, "two people never get a pose verdict")

// 33. The smoother damps the verdict and needs its warm-up frames.
var smoother = PosturePoseSmoother()
check(smoother.update(slouchVerdict) == .unknown, "the first pose frame is not trusted")
check(smoother.update(slouchVerdict) == .unknown, "the second is still warming up")
check(smoother.update(slouchVerdict) == .bad, "the third confirms bad")
check(smoother.update(hesitantVerdict) == .bad, "a hesitant frame does not clear bad")
smoother.reset()
check(smoother.state == .unknown, "a reset forgets the run")

// 34. The view classifier separates a square-on body from a profile one.
check(PosturePoseView(shoulderSpan: 0.25, headHeight: 0.18) == .frontal, "wide shoulders are frontal")
check(PosturePoseView(shoulderSpan: 0.08, headHeight: 0.18) == .profile, "narrow shoulders are profile")

// 35. Explicit calibration needs preparation, continuous capture and enough usable frames.
let calibrationStart = Date(timeIntervalSince1970: 1_800_000_000)
var calibration = PostureCalibrationSession()
calibration.start(at: calibrationStart)
calibration.update(poseFeatures(), bodyCount: 1, at: calibrationStart.addingTimeInterval(2))
check(calibration.state == .preparing(1) && calibration.candidate.samples == 0,
      "the preparation countdown never learns a baseline")
for frame in 0...60 {
    calibration.update(poseFeatures(), bodyCount: 1,
                       at: calibrationStart.addingTimeInterval(3 + Double(frame) / 10))
}
check(calibration.state == .complete && calibration.candidate.isReady(for: .frontal),
      "six seconds of upright samples completes explicit calibration")
let manualReference = calibration.candidate
var manualTracker = PosturePoseTracker()
manualTracker.installManualBaseline(manualReference)
manualTracker.learn(poseFeatures(headForward: 0.1), verdict: uprightVerdict, outcomeIsGood: true)
check(manualTracker.baseline == manualReference, "a manual reference never drifts through automatic learning")

calibration.start(at: calibrationStart)
for frame in 0...30 {
    calibration.update(poseFeatures(), bodyCount: 1,
                       at: calibrationStart.addingTimeInterval(3 + Double(frame) / 10))
}
let partialProgress = calibration.state.progress ?? 0
calibration.update(nil, bodyCount: 0, at: calibrationStart.addingTimeInterval(6.1))
check(calibration.state == .waiting(.noPerson, partialProgress) && calibration.candidate.samples > 0,
      "a brief landmark dropout pauses progress instead of erasing the capture")
calibration.update(poseFeatures(), bodyCount: 2, at: calibrationStart.addingTimeInterval(6.2))
check(calibration.candidate.samples == 0, "multiple people cannot calibrate a reference")
calibration.update(poseFeatures(headTilt: 45), bodyCount: 1, at: calibrationStart.addingTimeInterval(6.3))
check(calibration.candidate.samples == 0, "a grossly tilted pose cannot become the upright reference")
calibration.update(poseFeatures(), bodyCount: 1, at: calibrationStart.addingTimeInterval(7))
calibration.update(poseFeatures(view: .profile), bodyCount: 1, at: calibrationStart.addingTimeInterval(7.1))
check(calibration.candidate.samples == 1 && !calibration.candidate.isCalibrated,
      "changing views starts a separate continuous capture")
calibration.update(poseFeatures(view: .profile), bodyCount: 1, at: calibrationStart.addingTimeInterval(9))
check(calibration.candidate.samples == 1, "a camera gap cannot count as captured posture")
calibration.update(nil, bodyCount: 0, at: calibrationStart.addingTimeInterval(25))
check(calibration.state == .failedWithReason(.insufficientSamples), "an unusable capture times out with a reason")

let calibrationDomain = "com.posture.calibration-check.\(UUID().uuidString)"
let calibrationDefaults = UserDefaults(suiteName: calibrationDomain)!
calibrationDefaults.set(try! JSONEncoder().encode(manualReference), forKey: "notch.posture.manualReference.v1")
check(PostureManualReference.load(defaults: calibrationDefaults) == nil,
      "MediaPipe must not load a Vision calibration")
PostureManualReference.save(manualReference, defaults: calibrationDefaults)
check(PostureManualReference.load(defaults: calibrationDefaults) == manualReference,
      "the saved manual reference survives encoding and loading")
PostureManualReference.save(calibration.candidate, defaults: calibrationDefaults)
check(PostureManualReference.load(defaults: calibrationDefaults) == manualReference,
      "an incomplete replacement cannot overwrite the saved reference")
calibrationDefaults.set(Data([0, 1, 2]), forKey: PostureManualReference.key)
check(PostureManualReference.load(defaults: calibrationDefaults) == nil, "corrupt reference data is ignored")
calibrationDefaults.removePersistentDomain(forName: calibrationDomain)

// Calibration regressions: framing bias, brief landmark loss and actionable feedback.
var framingCalibration = PostureCalibrationSession()
let cameraBiasedUpright = poseFeatures(headAbove: 0.35)
check(PosturePoseJudge().grossViolation(cameraBiasedUpright),
      "the old circular Good gate rejects this otherwise stable reference")
framingCalibration.start(at: calibrationStart)
for frame in 0...65 {
    let frameTime = calibrationStart.addingTimeInterval(3 + Double(frame) / 10)
    if frame == 30 {
        framingCalibration.update(nil, bodyCount: 1, at: frameTime)
        check(framingCalibration.state == .waiting(.missingJoints, framingCalibration.state.progress ?? 0),
              "missing shoulders give an actionable waiting state")
    } else {
        framingCalibration.update(cameraBiasedUpright, bodyCount: 1, at: frameTime)
    }
}
check(framingCalibration.state == .complete,
      "a stable personal reference outside the generic framing limits can finish despite one dropout")
var calibratedJudgeTracker = PosturePoseTracker()
calibratedJudgeTracker.installManualBaseline(framingCalibration.candidate)
check(calibratedJudgeTracker.update(cameraBiasedUpright).verdict.state == .good,
      "a successful manual reference is actually used instead of being vetoed by the old generic threshold")
check(calibratedJudgeTracker.update(poseFeatures(headAbove: 0.15)).verdict.state == .bad,
      "meaningful drift away from the personalized reference remains bad")
check(PosturePoseJudge(baseline: framingCalibration.candidate).verdict(for: cameraBiasedUpright).state == .bad,
      "automatic calibration cannot bypass generic limits")

var interruptedCalibration = PostureCalibrationSession()
interruptedCalibration.start(at: calibrationStart)
for frame in 0...20 {
    interruptedCalibration.update(poseFeatures(), bodyCount: 1,
        at: calibrationStart.addingTimeInterval(3 + Double(frame) / 10))
}
let beforeDropout = interruptedCalibration.state.progress
interruptedCalibration.update(nil, bodyCount: 1, at: calibrationStart.addingTimeInterval(5.1))
check(interruptedCalibration.state.progress == beforeDropout, "a missing frame cannot advance the progress bar")
interruptedCalibration.update(nil, bodyCount: 1, at: calibrationStart.addingTimeInterval(6.1))
check(interruptedCalibration.candidate.samples == 0 && interruptedCalibration.state.progress == 0,
      "a long loss clears the stale capture rather than joining unrelated poses")
var blockedCalibration = PostureCalibrationSession()
blockedCalibration.start(at: calibrationStart)
blockedCalibration.update(nil, bodyCount: 1, at: calibrationStart.addingTimeInterval(3))
blockedCalibration.update(nil, bodyCount: 1, at: calibrationStart.addingTimeInterval(25))
check(blockedCalibration.state == .failedWithReason(.missingJoints),
      "the actual blocking reason remains visible after timeout")
var noEars = poseFeatures()
noEars.headTiltMeasured = false
var partialReference = PosturePoseBaseline()
for _ in 0..<PosturePoseBaseline.minimumSamples { partialReference.observe(noEars) }
check(partialReference.center("headTilt", view: .frontal) == nil,
      "invisible ears cannot silently calibrate a fake zero head angle")
partialReference.observe(poseFeatures(torsoLean: 0))
partialReference.discardSparseMeasurements()
check(partialReference.center("torsoLean", view: .frontal) == nil && partialReference.isCalibrated,
      "sporadic hips do not invalidate the usable head-and-shoulder reference")

// 36. A calibrated, reliable upright conflict must last two continuous seconds.
let arbitrationStart = Date(timeIntervalSince1970: 1_800_000_100)
var arbiter = PostureHybridArbiter()
func arbitrate(_ time: Double, model: PostureOutcome = .bad(0.95),
               sample: PosturePoseFeatures? = poseFeatures(), singleBody: Bool = true,
               baseline: PosturePoseBaseline? = poseBaseline,
               verdict: PosturePoseVerdict = uprightVerdict, state: PostureState = .good,
               crop: PostureHybridPolicy.CropAnswer = .notAttempted,
               enabled: Bool = true) -> PostureHybridPolicy.Decision {
    arbiter.decide(model: model, singleBody: singleBody, poseState: state,
                   verdict: verdict, crop: crop, features: sample,
                   manualBaseline: baseline, now: arbitrationStart.addingTimeInterval(time),
                   poseVeto: enabled)
}
for frame in 0..<20 {
    check(arbitrate(Double(frame) / 10).outcome.posture == .bad,
          "a short upright disagreement does not override Bad")
}
let corrected = arbitrate(2)
check(corrected.outcome == .none(peopleCount: 1) && corrected.source == .poseConflict,
      "sustained calibrated disagreement becomes Unknown even at high model confidence")
check(corrected.bestScore == 0.95, "a conflict preserves the model score for diagnostics")
check(arbitrate(2.1, sample: nil).outcome.posture == .bad, "lost pose cannot contradict model Bad")
check(arbitrate(2.2).outcome.posture == .bad, "lost pose resets the conflict timer")
check(arbitrate(5).outcome.posture == .bad, "a long frame gap cannot complete the conflict timer")

arbiter.reset()
for frame in 0...25 {
    check(arbitrate(Double(frame) / 10, baseline: nil).outcome.posture == .bad,
          "without an explicit manual baseline the model Bad remains")
}
var lowQuality = poseFeatures()
lowQuality.weakestJointConfidence = 0.15
arbiter.reset()
for frame in 0...25 {
    check(arbitrate(Double(frame) / 10, sample: lowQuality).outcome.posture == .bad,
          "a weak joint cannot hide behind a high average confidence")
}
var missingTilt = poseFeatures()
missingTilt.headTiltMeasured = false
check(arbitrate(3, sample: missingTilt).outcome.posture == .bad,
      "a missing head angle is not an upright zero angle")
check(arbitrate(3.1, sample: poseFeatures(view: .profile)).outcome.posture == .bad,
      "a reference from a different view cannot contradict Bad")
check(arbitrate(3.2, singleBody: false).outcome.posture == .bad,
      "an ambiguous body count cannot establish upright evidence")
check(arbitrate(3.3, verdict: hesitantVerdict).outcome.posture == .bad,
      "a smoothed Good cannot conceal a raw ambiguous pose")
check(arbitrate(3.4, model: .none(peopleCount: 0), verdict: hesitantVerdict).outcome.posture == .unknown,
      "the geometry fallback abstains when raw and smoothed verdicts disagree")
check(arbitrate(3.5, model: .good(0.9), verdict: slouchVerdict, state: .bad).source == .poseVeto,
      "a strong reliable slouch still vetoes a model Good")
check(arbitrate(3.6, model: .good(0.9), sample: lowQuality,
                verdict: slouchVerdict, state: .bad).outcome.posture == .good,
      "unreliable pose evidence does not veto the model")
check(arbitrate(3.7, model: .none(peopleCount: 2),
                crop: .answered(.good(0.9), 0.9)).outcome == .none(peopleCount: 2),
      "a crop cannot convert multiple model detections into one good person")

arbiter.reset()
for frame in 0...25 {
    let cropDecision = arbitrate(Double(frame) / 10, model: .none(peopleCount: 0),
                                 crop: .answered(.bad(0.85), 0.85))
    if frame >= 20 {
        check(cropDecision.source == .poseConflict && cropDecision.outcome.posture == .unknown,
              "the cropped model uses the same conflict rule")
    }
}
check(arbitrate(2.6, enabled: false).outcome.posture == .bad,
      "disabling pose arbitration restores the model verdict")
check(arbitrate(2.7).outcome.posture == .bad, "disabling arbitration clears accumulated evidence")

var torsoReference = PosturePoseBaseline()
for _ in 0..<PosturePoseBaseline.minimumSamples { torsoReference.observe(poseFeatures(torsoLean: 0)) }
check(!torsoReference.matchesUpright(poseFeatures()), "losing calibrated hips cannot prove upright posture")
check(!poseBaseline.matchesUpright(poseFeatures(headForward: 0.20)),
      "a pose inside absolute limits still has to match the personal reference")
var lifecycleTracker = PosturePoseTracker()
lifecycleTracker.installManualBaseline(poseBaseline)
for _ in 0..<PosturePoseTracker.warmup { _ = lifecycleTracker.update(poseFeatures()) }
lifecycleTracker.resetTemporalEvidence()
check(lifecycleTracker.hasManualBaseline && lifecycleTracker.baseline == poseBaseline,
      "pausing resets temporal evidence without discarding the manual reference")
check(lifecycleTracker.update(poseFeatures()).state == .unknown,
      "resuming requires fresh pose warm-up instead of reusing a stale verdict")
print("CHECKED: sustained manual-reference conflicts, quality gates, missing joints, gaps, views, crops and ambiguous poses")

print(failures == 0 ? "ALL LOGIC CHECKS PASSED" : "FAILURES: \(failures)")
exit(failures == 0 ? 0 : 1)
