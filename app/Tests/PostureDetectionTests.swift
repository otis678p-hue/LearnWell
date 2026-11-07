import CoreML
import XCTest
@testable import NotchTriage

final class PostureDetectionTests: XCTestCase {
    private func rows(_ values: [[Float]]) -> [Float] {
        values.flatMap { $0 }
    }

    /// One YOLO26 anchor row: centre-form box plus the two class scores.
    private func row(
        _ cx: Float, _ cy: Float, _ width: Float, _ height: Float,
        _ bad: Float, _ good: Float
    ) -> [Float] {
        [cx, cy, width, height, bad, good]
    }

    func testConfidentGoodAndBadDetectionsKeepTheDetectorThreshold() {
        let good = PostureDetectionDecoder.decode(
            rows: rows([row(320, 320, 200, 300, 0.05, 0.80)])
        )
        XCTAssertEqual(good.count, 1)
        XCTAssertEqual(good.first?.label, .good)
        XCTAssertEqual(good.first?.confidence ?? 0, 0.80, accuracy: 0.0001)
        guard case .good(let confidence) = PostureDetectionDecoder.outcome(for: good) else {
            return XCTFail("Expected a good outcome")
        }
        XCTAssertEqual(confidence, 0.80, accuracy: 0.0001)

        let bad = PostureDetectionDecoder.decode(
            rows: rows([row(320, 320, 200, 300, 0.70, 0.02)])
        )
        XCTAssertEqual(bad.first?.label, .bad)
        guard case .bad = PostureDetectionDecoder.outcome(for: bad) else {
            return XCTFail("Expected a bad outcome")
        }
    }

    func testClassificationPreservesGoodBadAndUnknown() {
        XCTAssertEqual(PostureOutcome.none(peopleCount: 0).posture, .unknown)
        XCTAssertEqual(PostureOutcome.none(peopleCount: 2).posture, .unknown)
        XCTAssertEqual(PostureOutcome.bad(0.9).posture, .bad)
        XCTAssertEqual(PostureOutcome.good(0.9).posture, .good)
    }

    func testStabilizerIgnoresSingleFrameFlaps() {
        var stabilizer = PostureStabilizer()
        let start = Date(timeIntervalSince1970: 5_000)
        func step(_ outcome: PostureOutcome, _ offset: TimeInterval) -> PostureState {
            stabilizer.update(outcome, now: start.addingTimeInterval(offset)).posture
        }
        XCTAssertEqual(step(.good(0.9), 0.0), .unknown)
        XCTAssertEqual(step(.good(0.9), 0.3), .unknown)
        XCTAssertEqual(step(.good(0.9), 0.6), .good)
        XCTAssertEqual(step(.bad(0.9), 0.7), .good)
        XCTAssertEqual(step(.bad(0.9), 1.2), .good)
        XCTAssertEqual(step(.bad(0.9), 1.7), .good)
        XCTAssertEqual(step(.bad(0.9), 2.2), .good)
        XCTAssertEqual(step(.bad(0.9), 2.7), .bad)
        XCTAssertEqual(step(.good(0.9), 2.8), .bad)
        XCTAssertEqual(step(.good(0.9), 3.1), .bad)
        XCTAssertEqual(step(.good(0.9), 3.4), .good)
        XCTAssertEqual(step(.none(peopleCount: 0), 3.5), .unknown)
        XCTAssertEqual(step(.good(0.9), 3.6), .unknown)
        XCTAssertEqual(step(.good(0.9), 3.9), .unknown)
        XCTAssertEqual(step(.good(0.9), 4.2), .good)
        XCTAssertEqual(step(.none(peopleCount: 2), 4.3), .unknown)
        XCTAssertEqual(stabilizer.stable.peopleCount, 2)
        XCTAssertNil(stabilizer.stable.confidence)
        XCTAssertFalse(stabilizer.stable.isConfirmed)
    }

    func testSensitivityLowersTheRequiredConfidence() {
        let rows = self.rows([row(320, 320, 200, 190, 0.45, 0.05)])  // score 0.45
        XCTAssertTrue(PostureDetectionDecoder.decode(rows: rows).isEmpty)
        XCTAssertEqual(PostureDetectionDecoder.decode(rows: rows, threshold: 0.40).count, 1)
        XCTAssertEqual(PostureSensitivity.strict.threshold, 0.60)
        XCTAssertEqual(PostureSensitivity.sensitive.threshold, 0.30)
    }

    func testScoresBelowThresholdAreIgnored() {
        let detections = PostureDetectionDecoder.decode(
            rows: rows([row(320, 320, 200, 300, 0.05, 0.35)])
        )
        XCTAssertTrue(detections.isEmpty)
        XCTAssertEqual(PostureDetectionDecoder.outcome(for: detections), .none(peopleCount: 0))
    }

    func testSeveralPeopleDoNotConfirmAPosture() {
        let detections = PostureDetectionDecoder.decode(
            rows: rows([
                row(120, 320, 120, 280, 0.02, 0.75),
                row(520, 320, 120, 280, 0.02, 0.72)
            ])
        )
        XCTAssertEqual(detections.count, 2)
        XCTAssertEqual(PostureDetectionDecoder.outcome(for: detections), .none(peopleCount: 2))
    }

    func testOverlappingBoxesCollapseThroughNonMaximumSuppression() {
        let detections = PostureDetectionDecoder.decode(
            rows: rows([
                row(320, 320, 200, 300, 0.01, 0.90),
                row(322, 322, 200, 300, 0.01, 0.85)
            ])
        )
        XCTAssertEqual(detections.count, 1)
        XCTAssertEqual(detections.first?.confidence ?? 0, 0.90, accuracy: 0.001)
    }

    func testIntersectionOverUnionMatchesBoxGeometry() {
        let lhs = CGRect(x: 0, y: 0, width: 10, height: 10)
        let rhs = CGRect(x: 5, y: 0, width: 10, height: 10)
        XCTAssertEqual(PostureDetectionDecoder.intersectionOverUnion(lhs, rhs), 50.0 / 150.0, accuracy: 0.0001)
        XCTAssertEqual(PostureDetectionDecoder.intersectionOverUnion(lhs, lhs), 1, accuracy: 0.0001)
    }

    func testLetterboxMapsDetectionsBackOntoTheCameraFrame() {
        let transform = PostureLetterboxTransform(
            scale: 0.5, offset: CGPoint(x: 0, y: 12), modelWidth: 640, modelHeight: 640
        )
        let rect = transform.frameRect(for: CGRect(x: 0.25, y: 0.5, width: 0.1, height: 0.1))
        XCTAssertEqual(rect.minX, 320, accuracy: 0.001)
        XCTAssertEqual(rect.minY, 616, accuracy: 0.001)
        XCTAssertEqual(rect.width, 128, accuracy: 0.001)
    }

    func testChannelsFirstHeadIsReadWithItsOwnStrides() throws {
        // Ultralytics exports the YOLO26 head as [1, 6, 8400]: channels first.
        let array = try MLMultiArray(shape: [1, 6, 4], dataType: .float32)
        // Channels first: index = channel * anchors + anchor.
        let values: [Float] = [320, 320, 200, 300, 0.05, 0.90]
        for (channel, value) in values.enumerated() {
            array[channel * 4] = NSNumber(value: value)
        }
        let tensor = try XCTUnwrap(PostureHeadTensor(array: array))
        XCTAssertEqual(tensor.anchors, 4)
        let summary = PostureDetectionDecoder.summarize(tensor, threshold: 0.50)
        XCTAssertEqual(summary.detections.count, 1)
        XCTAssertEqual(summary.detections.first?.label, .good)
        XCTAssertEqual(summary.bestScore, 0.90, accuracy: 0.0001)
        XCTAssertEqual(summary.scoredAnchors, 1)
    }

    func testRowMajorHeadIsReadToo() throws {
        let array = try MLMultiArray(shape: [1, 4, 6], dataType: .float32)
        let values: [Float] = [320, 320, 200, 300, 0.65, 0.10] + [Float](repeating: 0, count: 18)
        for (index, value) in values.enumerated() {
            array[index] = NSNumber(value: value)
        }
        let tensor = try XCTUnwrap(PostureHeadTensor(array: array))
        let summary = PostureDetectionDecoder.summarize(tensor, threshold: 0.50)
        XCTAssertEqual(summary.detections.count, 1)
        XCTAssertEqual(summary.detections.first?.label, .bad)
    }

    func testPaddedHeadStridesAreHonoured() throws {
        // CoreML pads the head buffer, so the reader must follow the reported strides.
        let anchors = 4
        let padded = 8
        let count = 6 * padded
        let pointer = UnsafeMutablePointer<Float>.allocate(capacity: count)
        pointer.initialize(repeating: 0, count: count)
        defer { pointer.deallocate() }
        let row: [Float] = [320, 320, 200, 300, 0.02, 0.75]
        for (channel, value) in row.enumerated() {
            pointer[channel * padded] = value
        }
        let array = try MLMultiArray(
            dataPointer: UnsafeMutableRawPointer(pointer),
            shape: [1, 6, NSNumber(value: anchors)],
            dataType: .float32,
            strides: [NSNumber(value: 6 * padded), NSNumber(value: padded), 1]
        )
        let tensor = try XCTUnwrap(PostureHeadTensor(array: array))
        XCTAssertEqual(tensor.anchors, anchors)
        let summary = PostureDetectionDecoder.summarize(tensor, threshold: 0.50)
        // Only anchor 0 carries a score; the padded tail stays at zero.
        XCTAssertEqual(summary.detections.count, 1)
        XCTAssertEqual(summary.detections.first?.label, .good)
        XCTAssertEqual(summary.bestScore, 0.75, accuracy: 0.0001)
    }

    func testAlertPolicyRemindsOnceThenRepeatsOnCooldown() {
        var policy = PostureAlertPolicy(repeatInterval: 45)
        let start = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(policy.evaluate(active: true, enabled: true, now: start))
        XCTAssertFalse(policy.evaluate(active: true, enabled: true, now: start.addingTimeInterval(10)))
        XCTAssertFalse(policy.evaluate(active: true, enabled: true, now: start.addingTimeInterval(44)))
        XCTAssertTrue(policy.evaluate(active: true, enabled: true, now: start.addingTimeInterval(46)))
        XCTAssertFalse(policy.evaluate(active: false, enabled: true, now: start.addingTimeInterval(50)))
        XCTAssertTrue(policy.evaluate(active: true, enabled: true, now: start.addingTimeInterval(51)))
    }

    func testAlertPolicyStaysSilentWhenDisabled() {
        var policy = PostureAlertPolicy(repeatInterval: 45)
        let start = Date(timeIntervalSince1970: 2_000)
        XCTAssertFalse(policy.evaluate(active: true, enabled: false, now: start))
        XCTAssertFalse(policy.evaluate(active: true, enabled: false, now: start.addingTimeInterval(60)))
        XCTAssertTrue(policy.evaluate(active: true, enabled: true, now: start.addingTimeInterval(61)))
    }

    func testAlertPolicySupportsOnceAndContinuousModes() {
        let start = Date(timeIntervalSince1970: 3_000)
        var once = PostureAlertPolicy(repeatInterval: PostureAlertRepeat.once.interval)
        XCTAssertTrue(once.evaluate(active: true, enabled: true, now: start))
        XCTAssertFalse(once.evaluate(active: true, enabled: true, now: start.addingTimeInterval(600)))
        XCTAssertTrue(once.evaluate(active: true, enabled: true, now: start.addingTimeInterval(601)))

        var continuous = PostureAlertPolicy(repeatInterval: PostureAlertRepeat.continuous.interval)
        XCTAssertEqual(PostureAlertRepeat.continuous.interval, 4)
        XCTAssertNil(PostureAlertRepeat.once.interval)
        XCTAssertTrue(continuous.evaluate(active: true, enabled: true, now: start))
        XCTAssertFalse(continuous.evaluate(active: true, enabled: true, now: start.addingTimeInterval(3)))
        XCTAssertTrue(continuous.evaluate(active: true, enabled: true, now: start.addingTimeInterval(5)))
        XCTAssertTrue(continuous.evaluate(active: true, enabled: true, now: start.addingTimeInterval(9.5)))
    }

    func testPostureAlertCopyDistinguishesDistancePostureAndRecovery() {
        XCTAssertEqual(PostureAlert(tooClose: false).subtitle, "Sit up straight and relax your shoulders")
        XCTAssertEqual(PostureAlert(tooClose: true).subtitle, "Too close - sit back")
        XCTAssertEqual(PostureAlert(kind: .good).title, "Good posture")
        XCTAssertEqual(PostureAlert(kind: .good).subtitle, "Keep it up")
        XCTAssertTrue(PostureAlert(kind: .good).isPositive)
        XCTAssertFalse(PostureAlert(kind: .badPosture).isPositive)
    }

    func testGoodPosturePolicyAnnouncesCorrectionsOnlyOnce() {
        var policy = PostureGoodAlertPolicy()
        XCTAssertTrue(policy.evaluate(confirmedGood: true, bad: false, enabled: true), "first good of the session")
        XCTAssertFalse(policy.evaluate(confirmedGood: true, bad: false, enabled: true), "no repeat while good")
        XCTAssertFalse(policy.evaluate(confirmedGood: false, bad: true, enabled: true), "bad is silent here")
        XCTAssertTrue(policy.evaluate(confirmedGood: true, bad: false, enabled: true), "correction announces")
        XCTAssertFalse(policy.evaluate(confirmedGood: false, bad: false, enabled: true), "no detection is silent")
        XCTAssertFalse(policy.evaluate(confirmedGood: true, bad: false, enabled: true), "already announced")

        var muted = PostureGoodAlertPolicy()
        XCTAssertFalse(muted.evaluate(confirmedGood: true, bad: false, enabled: false), "disabled stays silent")
        XCTAssertFalse(muted.evaluate(confirmedGood: true, bad: false, enabled: false), "disabled stays silent")
        XCTAssertFalse(muted.evaluate(confirmedGood: false, bad: true, enabled: true), "bad arms it")
        XCTAssertTrue(muted.evaluate(confirmedGood: true, bad: false, enabled: true), "correction announces once enabled")
    }

    func testUltrasonicTelemetryParsing() {
        XCTAssertEqual(
            PostureSerialTelemetry.parse("D,48.5,C\r"),
            PostureSerialTelemetry(distanceCM: 48.5, zone: .tooClose)
        )
        XCTAssertNil(PostureSerialTelemetry.parse("D,-1,N")?.distanceCM)
        XCTAssertEqual(PostureSerialTelemetry.parse("D,-1,N")?.zone, .none)
        XCTAssertNil(PostureSerialTelemetry.parse("D,-1,C"))
        XCTAssertNil(PostureSerialTelemetry.parse("D,900,G"))
        XCTAssertNil(PostureSerialTelemetry.parse("D,50,X"))
        XCTAssertNil(PostureSerialTelemetry.parse("hello"))
        XCTAssertNil(PostureSerialTelemetry.parse(String(repeating: "D", count: 80)))
    }

    func testBoardSelectionPrefersTheRememberedBoardThenALoneUno() {
        let remembered = PostureSerialBoard(
            path: "/dev/cu.usbmodem-old", serialNumber: "SN1", vendorID: 0x2341, productID: 0x0043
        )
        let moved = PostureSerialBoard(
            path: "/dev/cu.usbmodem-new", serialNumber: "SN1", vendorID: 0x2341, productID: 0x0043
        )
        let other = PostureSerialBoard(
            path: "/dev/cu.usbserial-9", serialNumber: "SN2", vendorID: 0x10C4, productID: 0xEA60
        )
        XCTAssertEqual(
            PostureSerialDiscovery.select(from: [other, moved], remembered: remembered),
            moved
        )
        XCTAssertEqual(
            PostureSerialDiscovery.select(from: [other, moved], remembered: nil),
            moved
        )
        let adapter = PostureSerialBoard(
            path: "/dev/cu.usbserial-10", serialNumber: "SN3", vendorID: 0x0403, productID: 0x6001
        )
        XCTAssertNil(PostureSerialDiscovery.select(from: [other, adapter], remembered: nil))
    }
}
