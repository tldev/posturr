import XCTest
@testable import PosturrCore

final class PostureUIStateTests: XCTestCase {

    // MARK: - Disabled State

    func testDisabledState() {
        let uiState = PostureUIState.derive(
            from: .disabled,
            isCalibrated: true,
            isCurrentlyAway: false,
            isCurrentlySlouching: false,
            trackingSource: .camera
        )

        XCTAssertEqual(uiState.statusText, "Status: Disabled")
        XCTAssertEqual(uiState.icon, .paused)
        XCTAssertFalse(uiState.isEnabled)
        XCTAssertTrue(uiState.canRecalibrate)
    }

    // MARK: - Calibrating State

    func testCalibratingState() {
        let uiState = PostureUIState.derive(
            from: .calibrating,
            isCalibrated: false,
            isCurrentlyAway: false,
            isCurrentlySlouching: false,
            trackingSource: .camera
        )

        XCTAssertEqual(uiState.statusText, "Status: Calibrating...")
        XCTAssertEqual(uiState.icon, .calibrating)
        XCTAssertTrue(uiState.isEnabled)
        XCTAssertFalse(uiState.canRecalibrate)
    }

    // MARK: - Monitoring State

    func testMonitoringGoodPosture() {
        let uiState = PostureUIState.derive(
            from: .monitoring,
            isCalibrated: true,
            isCurrentlyAway: false,
            isCurrentlySlouching: false,
            trackingSource: .camera
        )

        XCTAssertEqual(uiState.statusText, "Status: Good Posture")
        XCTAssertEqual(uiState.icon, .good)
        XCTAssertTrue(uiState.isEnabled)
    }

    func testMonitoringBadPosture() {
        let uiState = PostureUIState.derive(
            from: .monitoring,
            isCalibrated: true,
            isCurrentlyAway: false,
            isCurrentlySlouching: true,
            trackingSource: .camera
        )

        XCTAssertEqual(uiState.statusText, "Status: Slouching")
        XCTAssertEqual(uiState.icon, .bad)
    }

    func testMonitoringAway() {
        let uiState = PostureUIState.derive(
            from: .monitoring,
            isCalibrated: true,
            isCurrentlyAway: true,
            isCurrentlySlouching: false,
            trackingSource: .camera
        )

        XCTAssertEqual(uiState.statusText, "Status: Away")
        XCTAssertEqual(uiState.icon, .away)
    }

    func testAwayTakesPrecedenceOverSlouching() {
        let uiState = PostureUIState.derive(
            from: .monitoring,
            isCalibrated: true,
            isCurrentlyAway: true,
            isCurrentlySlouching: true,
            trackingSource: .camera
        )

        XCTAssertEqual(uiState.statusText, "Status: Away")
        XCTAssertEqual(uiState.icon, .away)
    }

    func testMonitoringNotCalibrated() {
        let uiState = PostureUIState.derive(
            from: .monitoring,
            isCalibrated: false,
            isCurrentlyAway: false,
            isCurrentlySlouching: false,
            trackingSource: .camera
        )

        XCTAssertEqual(uiState.statusText, "Status: Starting...")
        XCTAssertEqual(uiState.icon, .good)
    }

    // MARK: - Paused States

    func testPausedNoProfile() {
        let uiState = PostureUIState.derive(
            from: .paused(.noProfile),
            isCalibrated: false,
            isCurrentlyAway: false,
            isCurrentlySlouching: false,
            trackingSource: .camera
        )

        XCTAssertEqual(uiState.statusText, "Status: Calibration needed")
        XCTAssertEqual(uiState.icon, .paused)
    }

    func testPausedOnTheGo() {
        let uiState = PostureUIState.derive(
            from: .paused(.onTheGo),
            isCalibrated: true,
            isCurrentlyAway: false,
            isCurrentlySlouching: false,
            trackingSource: .camera
        )

        XCTAssertEqual(uiState.statusText, "Status: Paused (on the go - recalibrate)")
        XCTAssertEqual(uiState.icon, .paused)
    }

    func testPausedCameraDisconnected() {
        let uiState = PostureUIState.derive(
            from: .paused(.cameraDisconnected),
            isCalibrated: true,
            isCurrentlyAway: false,
            isCurrentlySlouching: false,
            trackingSource: .camera
        )

        XCTAssertEqual(uiState.statusText, "Status: Camera disconnected")
        XCTAssertEqual(uiState.icon, .paused)
    }

    func testPausedAirPodsDisconnected() {
        let uiState = PostureUIState.derive(
            from: .paused(.cameraDisconnected),
            isCalibrated: true,
            isCurrentlyAway: false,
            isCurrentlySlouching: false,
            trackingSource: .airpods
        )

        XCTAssertEqual(uiState.statusText, "Status: AirPods disconnected")
        XCTAssertEqual(uiState.icon, .paused)
    }

    func testPausedScreenLocked() {
        let uiState = PostureUIState.derive(
            from: .paused(.screenLocked),
            isCalibrated: true,
            isCurrentlyAway: false,
            isCurrentlySlouching: false,
            trackingSource: .camera
        )

        XCTAssertEqual(uiState.statusText, "Status: Paused (screen locked)")
        XCTAssertEqual(uiState.icon, .paused)
    }

    func testPausedAirPodsRemoved() {
        let uiState = PostureUIState.derive(
            from: .paused(.airPodsRemoved),
            isCalibrated: true,
            isCurrentlyAway: false,
            isCurrentlySlouching: false,
            trackingSource: .airpods
        )

        XCTAssertEqual(uiState.statusText, "Status: Paused (put in AirPods)")
        XCTAssertEqual(uiState.icon, .paused)
    }
}
