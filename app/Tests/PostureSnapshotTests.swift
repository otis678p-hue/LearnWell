import XCTest
@testable import NotchTriage

final class PostureSnapshotTests: XCTestCase {
    private func snapshot(
        posture: PostureState = .good,
        arduino: PostureArduinoState = .connected,
        distance: Double? = 75,
        tooClose: Bool = false,
        running: Bool = true,
        detected: Bool = true,
        confidence: Double? = nil,
        people: Int = 0
    ) -> PostureSnapshot {
        PostureSnapshot(
            posture: posture,
            arduino: arduino,
            distanceCM: distance,
            tooClose: tooClose,
            isRunning: running,
            confirmed: detected,
            source: .camera,
            confidence: confidence,
            peopleCount: people,
            zone: nil
        )
    }

    func testStoppedDetectionNeverReportsAPosture() {
        XCTAssertEqual(PostureSnapshot.offline.title, "Posture detection is not running")
        XCTAssertEqual(snapshot(posture: .bad, running: false).title, "Posture detection is not running")
    }

    func testTooCloseOverridesTheCameraVerdict() {
        let close = snapshot(posture: .good, distance: 44, tooClose: true)
        XCTAssertEqual(close.title, "Too close — move back")
        XCTAssertEqual(close.posture, .good)
        XCTAssertEqual(close.distanceCM, 44)
    }

    func testUnconfirmedPostureIsLabelledUnknown() {
        let unknown = snapshot(posture: .unknown, detected: false)
        XCTAssertEqual(unknown.title, "Unknown posture")
        XCTAssertEqual(snapshot(detected: false).title, "Unknown posture")
        XCTAssertFalse(unknown.confirmed)
        XCTAssertEqual(snapshot(confidence: 0.88).title, "Good posture")
    }

    func testPresentationDetails() {
        XCTAssertEqual(snapshot(confidence: 0.87).detail, .confidence(0.87))
        XCTAssertEqual(snapshot(detected: false, people: 3).detail, .people(3))
        XCTAssertEqual(snapshot(detected: false, confidence: nil).detail, .arduino("Arduino connected"))
        XCTAssertEqual(
            snapshot(posture: .bad, arduino: .disabled, distance: nil, detected: false).detail,
            .arduino("Arduino disabled")
        )
    }

    func testArduinoTitlesAndSymbolsCoverEveryState() {
        for state in [PostureArduinoState.connected, .disconnected, .starting, .unresponsive, .disabled] {
            XCTAssertFalse(state.title.isEmpty)
            XCTAssertFalse(state.symbol.isEmpty)
        }
        XCTAssertEqual(PostureArduinoState.disabled.title, "Arduino disabled")
        XCTAssertEqual(PostureArduinoState.unresponsive.symbol, "exclamationmark")
    }

    func testDistanceZonesDescribeTheFirmwareThresholds() {
        XCTAssertEqual(PostureDistanceZone(rawValue: "C"), .tooClose)
        XCTAssertEqual(PostureDistanceZone(rawValue: "W"), .near)
        XCTAssertEqual(PostureDistanceZone(rawValue: "G"), .good)
        XCTAssertEqual(PostureDistanceZone(rawValue: "N"), .none)
        XCTAssertNil(PostureDistanceZone(rawValue: "X"))
        XCTAssertEqual(PostureDistanceZone.tooClose.title, "Too close - move back")
    }
}
