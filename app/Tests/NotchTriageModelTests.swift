import XCTest
@testable import NotchTriage

/// Model coverage for the posture alert surface and sensor wing options.
final class NotchTriageModelTests: XCTestCase {
    func testWingOptionsIncludeClimate() {
        XCTAssertEqual(
            NotchWingContent.allCases.map(\.rawValue),
            ["posture", "temperature", "humidity", "temperatureHumidity", "hidden"]
        )
        XCTAssertEqual(NotchWingContent.posture.symbol, "figure.seated.side")
        XCTAssertEqual(NotchWingContent.hidden.symbol, "eye.slash")
        XCTAssertEqual(NotchWingContent.temperature.symbol, "thermometer.medium")
        XCTAssertEqual(NotchWingContent.humidity.symbol, "humidity")
    }

    func testPostureHUDCarriesTitleSubtitleAndAccent() {
        let bad = SystemHUDSnapshot.posture(PostureAlert(kind: .badPosture))
        XCTAssertEqual(bad.kind, .posture)
        XCTAssertEqual(bad.title, "Bad posture")
        XCTAssertEqual(bad.accent, .negative)

        let good = SystemHUDSnapshot.posture(PostureAlert(kind: .good))
        XCTAssertEqual(good.title, "Good posture")
        XCTAssertEqual(good.accent, .positive)
    }

    func testPostureAlertKindsResolveTitles() {
        XCTAssertEqual(PostureAlert(tooClose: true).kind, .tooClose)
        XCTAssertEqual(PostureAlert(tooClose: false).kind, .badPosture)
        XCTAssertTrue(PostureAlert(kind: .good).isPositive)
        XCTAssertFalse(PostureAlert(kind: .badPosture).isPositive)
    }
}
