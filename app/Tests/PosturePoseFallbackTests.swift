import XCTest
@testable import NotchTriage

/// Pose fallback: geometry thresholds, per-view calibration and the fusion policy.
/// The Vision estimator itself is exercised off-line by tools/run_posture_pose_check.sh,
/// which needs no test bundle.
final class PosturePoseFallbackTests: XCTestCase {
    private func features(
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

    private var slouch: PosturePoseVerdict {
        PosturePoseVerdict(state: .bad, score: 0.9, confidence: 0.95, reasons: [])
    }

    func testUprightPoseIsGoodAndSlouchesAreBad() {
        let judge = PosturePoseJudge()
        XCTAssertEqual(judge.verdict(for: features()).state, .good)
        XCTAssertEqual(judge.verdict(for: features(headTilt: 45)).state, .bad)
        XCTAssertEqual(judge.verdict(for: features(headForward: 0.36)).state, .bad)
        XCTAssertEqual(judge.verdict(for: features(headAbove: 0.30)).state, .bad)
        XCTAssertEqual(judge.verdict(for: features(torsoLean: 33)).state, .bad)
    }

    func testTorsoRulesStaySilentWithoutVisibleHips() {
        let judge = PosturePoseJudge()
        XCTAssertEqual(judge.verdict(for: features(torsoLean: nil)).state, .good)
    }

    func testTwoModerateDeviationsMakeASlouchButOneDoesNot() {
        let judge = PosturePoseJudge()
        XCTAssertEqual(judge.verdict(for: features(headTilt: 26, headForward: 0.29)).state, .bad)
        XCTAssertEqual(judge.verdict(for: features(headTilt: 24)).state, .unknown)
    }

    func testBaselineCalibratesPerViewAndCatchesDrift() {
        var baseline = PosturePoseBaseline()
        for _ in 0..<PosturePoseBaseline.minimumSamples { baseline.observe(features()) }
        XCTAssertTrue(baseline.isReady(for: .frontal))
        XCTAssertFalse(baseline.isReady(for: .profile))

        let judge = PosturePoseJudge(baseline: baseline)
        XCTAssertTrue(judge.relativeScores(features(view: .profile)).isEmpty)
        XCTAssertEqual(judge.verdict(for: features()).state, .good)
        let drifted = judge.verdict(for: features(headForward: 0.30))
        XCTAssertEqual(drifted.state, .bad)
        XCTAssertTrue(drifted.reasons.contains { $0.contains("drift") })
    }

    func testSlouchNeverTeachesTheBaselineWhatStraightLooksLike() {
        var tracker = PosturePoseTracker()
        let bad = PosturePoseJudge().verdict(for: features(headTilt: 45))
        tracker.learn(features(headTilt: 45), verdict: bad, outcomeIsGood: true)
        XCTAssertEqual(tracker.baseline.samples, 0)
        tracker.learn(features(), verdict: .unknown, outcomeIsGood: true)
        XCTAssertEqual(tracker.baseline.samples, 1)
    }

    func testPolicyPrefersModelConversationOrder() {
        // A hesitant pose never overturns a model answer.
        var decision = PostureHybridPolicy.decide(
            model: .good(0.8), singleBody: true, poseState: .bad,
            verdict: PosturePoseVerdict(state: .unknown, score: 0.4, confidence: 0, reasons: []),
            crop: .notAttempted
        )
        XCTAssertEqual(decision.source, .model)
        XCTAssertEqual(decision.outcome.posture, .good)

        // The crop retry answers before the geometry does.
        decision = PostureHybridPolicy.decide(
            model: .none(peopleCount: 0), singleBody: true, poseState: .unknown,
            verdict: PosturePoseVerdict.unknown, crop: .answered(.bad(0.61), 0.61)
        )
        XCTAssertEqual(decision.source, .poseCrop)
        XCTAssertEqual(decision.outcome.posture, .bad)

        // Geometry decides when the head abstains twice.
        decision = PostureHybridPolicy.decide(
            model: .none(peopleCount: 0), singleBody: true, poseState: .bad,
            verdict: slouch, crop: .abstained
        )
        XCTAssertEqual(decision.source, .pose)
        XCTAssertEqual(decision.outcome.posture, .bad)
    }

    func testVetoTurnsAWrongGoodIntoUnknownButNeedsEvidenceToSoftenBad() {
        var decision = PostureHybridPolicy.decide(
            model: .good(0.72), singleBody: true, poseState: .bad, verdict: slouch,
            crop: .notAttempted
        )
        XCTAssertEqual(decision.source, .poseVeto)
        XCTAssertEqual(decision.outcome.posture, .unknown)

        decision = PostureHybridPolicy.decide(
            model: .bad(0.7), singleBody: true, poseState: .good,
            verdict: PosturePoseVerdict(state: .good, score: 0, confidence: 0.6, reasons: []),
            crop: .notAttempted
        )
        XCTAssertEqual(decision.outcome.posture, .bad)
        XCTAssertEqual(decision.source, .model)
    }

    func testTwoPeopleNeverGetAPoseVerdict() {
        let decision = PostureHybridPolicy.decide(
            model: .none(peopleCount: 2), singleBody: false, poseState: .bad,
            verdict: slouch, crop: .abstained
        )
        XCTAssertEqual(decision.outcome.posture, .unknown)
    }

    func testSmootherNeedsWarmupAndHoldsBadUntilRecovery() {
        var smoother = PosturePoseSmoother()
        let good = PosturePoseVerdict(state: .good, score: 0, confidence: 0.6, reasons: [])
        XCTAssertEqual(smoother.update(slouch), .unknown)
        XCTAssertEqual(smoother.update(slouch), .unknown)
        XCTAssertEqual(smoother.update(slouch), .bad)
        XCTAssertEqual(
            smoother.update(PosturePoseVerdict(state: .unknown, score: 0.30, confidence: 0, reasons: [])),
            .bad
        )
        for _ in 0..<6 { _ = smoother.update(good) }
        XCTAssertEqual(smoother.state, .good)
        smoother.reset()
        XCTAssertEqual(smoother.state, .unknown)
    }

    func testViewClassifierSeparatesSquareOnFromProfile() {
        XCTAssertEqual(PosturePoseView(shoulderSpan: 0.25, headHeight: 0.18), .frontal)
        XCTAssertEqual(PosturePoseView(shoulderSpan: 0.08, headHeight: 0.18), .profile)
    }

    func testVisionRectangleIsConvertedToTopLeftOrigin() {
        let converted = PosturePoseEstimator.normalizedBox(CGRect(x: 0.2, y: 0.3, width: 0.4, height: 0.5))
        XCTAssertEqual(converted.minX, 0.2, accuracy: 0.0001)
        XCTAssertEqual(converted.minY, 0.2, accuracy: 0.0001)
        XCTAssertEqual(converted.width, 0.4, accuracy: 0.0001)
        XCTAssertEqual(converted.height, 0.5, accuracy: 0.0001)
    }

    func testFaceFallbackExpandsIntoHeadAndShoulderCrop() {
        let face = CGRect(x: 0.40, y: 0.10, width: 0.20, height: 0.25)
        let expanded = PosturePoseEstimator.expandedHeadShoulderBox(face)
        XCTAssertEqual(expanded.midX, face.midX, accuracy: 0.0001)
        XCTAssertGreaterThan(expanded.width, face.width)
        XCTAssertGreaterThan(expanded.height, face.height)
        XCTAssertLessThan(expanded.minY, face.minY)
    }

    func testLocatingThresholdsStaySeparateFromMeasurementThresholds() {
        XCTAssertLessThan(PosturePoseEstimator.minimumLocatingJointConfidence,
                          PosturePoseEstimator.minimumJointConfidence)
        XCTAssertEqual(PosturePoseEstimator.minimumLocatingJointCount, 2)
        XCTAssertGreaterThan(PosturePoseEstimator.minimumShoulderSpan, 0)
    }
}
