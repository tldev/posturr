import XCTest
@testable import PosturrCore

final class PostureEngineTests: XCTestCase {

    // MARK: - Test Helpers

    func makeReading(bad: Bool, severity: Double = 0.5) -> PostureReading {
        PostureReading(timestamp: Date(), isBadPosture: bad, severity: severity)
    }

    func makeState(
        badFrames: Int = 0,
        goodFrames: Int = 0,
        slouching: Bool = false,
        away: Bool = false,
        badPostureStartTime: Date? = nil
    ) -> PostureMonitoringState {
        var state = PostureMonitoringState()
        state.consecutiveBadFrames = badFrames
        state.consecutiveGoodFrames = goodFrames
        state.isCurrentlySlouching = slouching
        state.isCurrentlyAway = away
        state.badPostureStartTime = badPostureStartTime
        return state
    }

    func makeConfig(
        frameThreshold: Int = 8,
        goodFrameThreshold: Int = 5,
        onsetDelay: TimeInterval = 0,
        intensity: CGFloat = 1.0
    ) -> PostureConfig {
        PostureConfig(
            frameThreshold: frameThreshold,
            goodFrameThreshold: goodFrameThreshold,
            warningOnsetDelay: onsetDelay,
            intensity: intensity
        )
    }

    // MARK: - Good Posture Frame Tests

    func testGoodFrameResetsBadCounter() {
        let state = makeState(badFrames: 5)
        let result = PostureEngine.processReading(
            makeReading(bad: false),
            state: state,
            config: makeConfig()
        )

        XCTAssertEqual(result.newState.consecutiveBadFrames, 0)
        XCTAssertEqual(result.newState.consecutiveGoodFrames, 1)
    }

    func testGoodFrameIncrementsGoodCounter() {
        let state = makeState(goodFrames: 3)
        let result = PostureEngine.processReading(
            makeReading(bad: false),
            state: state,
            config: makeConfig()
        )

        XCTAssertEqual(result.newState.consecutiveGoodFrames, 4)
    }

    func testGoodFrameClearsBadPostureStartTime() {
        let state = makeState(badPostureStartTime: Date())
        let result = PostureEngine.processReading(
            makeReading(bad: false),
            state: state,
            config: makeConfig()
        )

        XCTAssertNil(result.newState.badPostureStartTime)
    }

    func testGoodFrameClearsWarningIntensity() {
        var state = makeState()
        state.postureWarningIntensity = 0.8
        let result = PostureEngine.processReading(
            makeReading(bad: false),
            state: state,
            config: makeConfig()
        )

        XCTAssertEqual(result.newState.postureWarningIntensity, 0)
    }

    // MARK: - Bad Posture Frame Tests

    func testBadFrameIncrementsBadCounter() {
        let state = makeState(badFrames: 3)
        let result = PostureEngine.processReading(
            makeReading(bad: true),
            state: state,
            config: makeConfig()
        )

        XCTAssertEqual(result.newState.consecutiveBadFrames, 4)
        XCTAssertEqual(result.newState.consecutiveGoodFrames, 0)
    }

    func testBadFrameResetsGoodCounter() {
        let state = makeState(goodFrames: 3)
        let result = PostureEngine.processReading(
            makeReading(bad: true),
            state: state,
            config: makeConfig()
        )

        XCTAssertEqual(result.newState.consecutiveGoodFrames, 0)
    }

    func testBadFrameAtThresholdStartsTimer() {
        let now = Date()
        let state = makeState(badFrames: 7) // Will become 8
        let result = PostureEngine.processReading(
            makeReading(bad: true),
            state: state,
            config: makeConfig(frameThreshold: 8),
            currentTime: now
        )

        XCTAssertNotNil(result.newState.badPostureStartTime)
    }

    // MARK: - Slouching Transition Tests

    func testTransitionToSlouchingAtThreshold() {
        let now = Date()
        let state = makeState(badFrames: 7, badPostureStartTime: now.addingTimeInterval(-1))
        let result = PostureEngine.processReading(
            makeReading(bad: true, severity: 0.8),
            state: state,
            config: makeConfig(frameThreshold: 8, onsetDelay: 0),
            currentTime: now
        )

        XCTAssertTrue(result.newState.isCurrentlySlouching)
        XCTAssertTrue(result.effects.contains(.recordSlouchEvent))
        XCTAssertTrue(result.effects.contains(.updateUI))
    }

    func testNoDoubleSlouchEventWhenAlreadySlouching() {
        let now = Date()
        let state = makeState(badFrames: 10, slouching: true, badPostureStartTime: now.addingTimeInterval(-5))
        let result = PostureEngine.processReading(
            makeReading(bad: true),
            state: state,
            config: makeConfig(),
            currentTime: now
        )

        XCTAssertTrue(result.newState.isCurrentlySlouching)
        XCTAssertFalse(result.effects.contains(.recordSlouchEvent))
        XCTAssertFalse(result.effects.contains(.updateUI))
    }

    func testWarningIntensitySetWhenSlouching() {
        let now = Date()
        let state = makeState(badFrames: 10, slouching: true, badPostureStartTime: now.addingTimeInterval(-5))
        let result = PostureEngine.processReading(
            makeReading(bad: true, severity: 0.8),
            state: state,
            config: makeConfig(),
            currentTime: now
        )

        XCTAssertGreaterThan(result.newState.postureWarningIntensity, 0)
    }

    // MARK: - Onset Delay Tests

    func testOnsetDelayPreventsImmediateSlouching() {
        let now = Date()
        let state = makeState(badFrames: 7, badPostureStartTime: now) // Just started
        let result = PostureEngine.processReading(
            makeReading(bad: true),
            state: state,
            config: makeConfig(onsetDelay: 2.0), // 2 second delay
            currentTime: now
        )

        XCTAssertFalse(result.newState.isCurrentlySlouching)
        XCTAssertFalse(result.effects.contains(.recordSlouchEvent))
    }

    func testOnsetDelayAllowsSlouchingAfterWaiting() {
        let now = Date()
        let state = makeState(badFrames: 7, badPostureStartTime: now.addingTimeInterval(-3)) // 3 seconds ago
        let result = PostureEngine.processReading(
            makeReading(bad: true),
            state: state,
            config: makeConfig(onsetDelay: 2.0), // 2 second delay - we're past it
            currentTime: now
        )

        XCTAssertTrue(result.newState.isCurrentlySlouching)
    }

    // MARK: - Recovery Tests

    func testRecoveryAfterGoodFrameThreshold() {
        let state = makeState(goodFrames: 4, slouching: true) // Will become 5
        let result = PostureEngine.processReading(
            makeReading(bad: false),
            state: state,
            config: makeConfig(goodFrameThreshold: 5)
        )

        XCTAssertFalse(result.newState.isCurrentlySlouching)
        XCTAssertTrue(result.effects.contains(.updateUI))
    }

    func testNoRecoveryBeforeThreshold() {
        let state = makeState(goodFrames: 3, slouching: true) // Will become 4
        let result = PostureEngine.processReading(
            makeReading(bad: false),
            state: state,
            config: makeConfig(goodFrameThreshold: 5)
        )

        XCTAssertTrue(result.newState.isCurrentlySlouching)
        XCTAssertFalse(result.effects.contains(.updateUI))
    }

    func testNoRecoveryIfNotSlouching() {
        let state = makeState(goodFrames: 10, slouching: false)
        let result = PostureEngine.processReading(
            makeReading(bad: false),
            state: state,
            config: makeConfig()
        )

        XCTAssertFalse(result.newState.isCurrentlySlouching)
        XCTAssertFalse(result.effects.contains(.updateUI))
    }

    // MARK: - Analytics Tracking Tests

    func testAlwaysTracksAnalytics() {
        let state = makeState()
        let result = PostureEngine.processReading(
            makeReading(bad: false),
            state: state,
            config: makeConfig(),
            frameInterval: 0.25
        )

        XCTAssertTrue(result.effects.contains(.trackAnalytics(interval: 0.25, isSlouching: false)))
    }

    func testAlwaysUpdatesBlur() {
        let state = makeState()
        let result = PostureEngine.processReading(
            makeReading(bad: false),
            state: state,
            config: makeConfig()
        )

        XCTAssertTrue(result.effects.contains(.updateBlur))
    }

    // MARK: - Away State Tests

    func testAwayChangeUpdatesState() {
        let state = makeState(away: false)
        let result = PostureEngine.processAwayChange(isAway: true, state: state)

        XCTAssertTrue(result.newState.isCurrentlyAway)
        XCTAssertTrue(result.shouldUpdateUI)
    }

    func testAwayChangeToSameStateNoUpdate() {
        let state = makeState(away: true)
        let result = PostureEngine.processAwayChange(isAway: true, state: state)

        XCTAssertTrue(result.newState.isCurrentlyAway)
        XCTAssertFalse(result.shouldUpdateUI)
    }

    func testReturnFromAwayUpdatesUI() {
        let state = makeState(away: true)
        let result = PostureEngine.processAwayChange(isAway: false, state: state)

        XCTAssertFalse(result.newState.isCurrentlyAway)
        XCTAssertTrue(result.shouldUpdateUI)
    }

    // MARK: - State Reset Tests

    func testStateReset() {
        var state = makeState(badFrames: 10, goodFrames: 5, slouching: true, away: true)
        state.postureWarningIntensity = 0.9
        state.badPostureStartTime = Date()

        state.reset()

        XCTAssertEqual(state.consecutiveBadFrames, 0)
        XCTAssertEqual(state.consecutiveGoodFrames, 0)
        XCTAssertFalse(state.isCurrentlySlouching)
        XCTAssertFalse(state.isCurrentlyAway)
        XCTAssertNil(state.badPostureStartTime)
        XCTAssertEqual(state.postureWarningIntensity, 0)
    }

    // MARK: - State Machine Tests

    func testDetectorShouldRunWhenMonitoring() {
        XCTAssertTrue(PostureEngine.shouldDetectorRun(for: .monitoring, trackingSource: .camera))
    }

    func testDetectorShouldRunWhenCalibrating() {
        XCTAssertTrue(PostureEngine.shouldDetectorRun(for: .calibrating, trackingSource: .camera))
    }

    func testDetectorShouldNotRunWhenDisabled() {
        XCTAssertFalse(PostureEngine.shouldDetectorRun(for: .disabled, trackingSource: .camera))
    }

    func testDetectorShouldNotRunWhenPaused() {
        XCTAssertFalse(PostureEngine.shouldDetectorRun(for: .paused(.noProfile), trackingSource: .camera))
    }

    func testAirPodsDetectorRunsWhenPausedForRemoval() {
        // AirPods detector should keep running when paused due to removal
        // so it can detect when they're put back in
        XCTAssertTrue(PostureEngine.shouldDetectorRun(for: .paused(.airPodsRemoved), trackingSource: .airpods))
    }

    func testCameraDetectorStopsWhenPausedForRemoval() {
        // Camera doesn't have this behavior
        XCTAssertFalse(PostureEngine.shouldDetectorRun(for: .paused(.airPodsRemoved), trackingSource: .camera))
    }

    func testStateWhenEnablingWithCalibration() {
        let state = PostureEngine.stateWhenEnabling(isCalibrated: true, detectorAvailable: true)
        XCTAssertEqual(state, .monitoring)
    }

    func testStateWhenEnablingWithoutCalibration() {
        let state = PostureEngine.stateWhenEnabling(isCalibrated: false, detectorAvailable: true)
        XCTAssertEqual(state, .paused(.noProfile))
    }

    func testStateWhenEnablingWithoutDetector() {
        let state = PostureEngine.stateWhenEnabling(isCalibrated: true, detectorAvailable: false)
        XCTAssertEqual(state, .paused(.cameraDisconnected))
    }

    // MARK: - Full Cycle Integration Test

    func testFullSlouchAndRecoveryCycle() {
        var state = PostureMonitoringState()
        let config = makeConfig(frameThreshold: 3, goodFrameThreshold: 2, onsetDelay: 0)
        let now = Date()

        // Start with good posture
        XCTAssertFalse(state.isCurrentlySlouching)

        // 3 bad frames to trigger slouching
        for i in 1...3 {
            let result = PostureEngine.processReading(
                makeReading(bad: true, severity: 0.7),
                state: state,
                config: config,
                currentTime: now
            )
            state = result.newState

            if i == 3 {
                XCTAssertTrue(state.isCurrentlySlouching, "Should be slouching after \(i) bad frames")
            }
        }

        XCTAssertTrue(state.isCurrentlySlouching)
        XCTAssertGreaterThan(state.postureWarningIntensity, 0)

        // 2 good frames to recover
        for i in 1...2 {
            let result = PostureEngine.processReading(
                makeReading(bad: false),
                state: state,
                config: config
            )
            state = result.newState

            if i == 2 {
                XCTAssertFalse(state.isCurrentlySlouching, "Should recover after \(i) good frames")
            }
        }

        XCTAssertFalse(state.isCurrentlySlouching)
        XCTAssertEqual(state.postureWarningIntensity, 0)
    }
}
