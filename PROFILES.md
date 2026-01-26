# Profile-Based Posture Monitoring

## Overview

Posturr automatically saves and restores calibration profiles based on display configuration. Each unique monitor setup has its own calibration profile, allowing seamless transitions between workstations.

## Core Concepts

### Profile Key
- Format: `displays:<sorted-uuid1>+<sorted-uuid2>+...`
- Based on connected display UUIDs (not camera)
- Sorted to ensure consistent key regardless of connection order

### Profile Data
```swift
struct ProfileData: Codable {
    let goodPostureY: CGFloat
    let badPostureY: CGFloat
    let neutralY: CGFloat
    let postureRange: CGFloat
    let cameraID: String  // Camera used for this calibration
}
```

### App State Machine
```swift
enum AppState: Equatable {
    case disabled      // User turned off monitoring
    case calibrating   // Currently in calibration flow
    case monitoring    // Actively monitoring posture
    case paused(PauseReason)  // Paused, waiting for action
}

enum PauseReason: Equatable {
    case noProfile          // No calibration for this display config
    case onTheGo            // Laptop-only mode (if enabled)
    case cameraDisconnected // No cameras available
}
```

### Key Design Decisions

1. **State machine with computed property**: All UI and camera state derives from a single `state` variable (backed by `_state`). The setter guards against no-op changes and calls `handleStateTransition()` which automatically syncs camera and UI.

2. **Camera is part of profile data**: Calibration is camera-specific. Changing cameras requires recalibration.

3. **Auto camera selection on disconnect**: When selected camera disconnects, automatically select another available camera. If a profile exists for the current display config that matches the fallback camera, resume monitoring; otherwise prompt for recalibration.

4. **Display config determines profile, not camera**: Plugging in the same monitor should restore the profile, even if a different camera is used (will prompt recalibration if camera doesn't match).

---

## User Stories & Scenarios

### Fresh Install

**Scenario 1: First launch with camera**
- User launches app for the first time
- Camera permission is requested and granted
- Expected: Calibration starts automatically, status shows "Calibrating..."

**Scenario 2: First launch, camera permission denied**
- User launches app and denies camera permission
- Expected: Alert prompts to open Settings, status shows "Camera access denied"

---

### Profile Persistence

**Scenario 3: Quit and relaunch with same setup**
- User calibrates, uses app, quits
- User relaunches app with same monitors/camera
- Expected: Profile loads automatically, no calibration prompt, monitoring starts

**Scenario 4: Quit and relaunch with different monitor**
- User calibrates on laptop + external monitor
- User quits, unplugs monitor, relaunches
- Expected: New display config has no profile, shows "Calibration needed"

**Scenario 5: Return to previously calibrated setup**
- User has profiles for: laptop-only AND laptop+monitor
- User is on laptop-only, plugs in monitor
- Expected: Profile for laptop+monitor loads, monitoring resumes (if camera matches)

---

### Monitor Changes (Hot-plug)

**Scenario 6: Unplug monitor while monitoring**
- User is monitoring with laptop + external monitor
- User unplugs external monitor
- Expected:
  - Overlay windows rebuild for new screen config
  - Look up profile for laptop-only config
  - If profile exists with available camera: resume monitoring
  - If no profile: show "Calibration needed"

**Scenario 7: Plug in monitor while monitoring**
- User is monitoring on laptop-only
- User plugs in external monitor
- Expected:
  - Overlay windows rebuild
  - Look up profile for laptop+monitor config
  - If profile exists with available camera: resume monitoring
  - If no profile: show "Calibration needed"

**Scenario 8: Unplug monitor with attached camera**
- User is monitoring using external monitor's camera
- User unplugs monitor (camera goes with it)
- Expected:
  - Detect camera disconnect (fires before display change due to debounce)
  - If other cameras available AND profile matches fallback camera: auto-select, resume monitoring
  - If other cameras available but no matching profile: auto-select one, show "Calibration needed"
  - If no cameras: show "Camera disconnected"
  - Display change handler runs after debounce, may override state based on new display config

---

### Camera Changes

**Scenario 9: Manual camera selection while monitoring**
- User is monitoring with Camera A
- User selects Camera B from menu
- Expected:
  - Camera switches to B
  - State changes to "Calibration needed" (calibration is camera-specific)
  - Recalibrate menu item enabled

**Scenario 10: Camera disconnect while monitoring**
- User is monitoring with external USB camera
- User unplugs the camera
- Expected:
  - If other cameras exist AND profile matches fallback camera: auto-select, resume monitoring
  - If other cameras exist but no matching profile: auto-select one, show "Calibration needed"
  - If no cameras: show "Camera disconnected", Recalibrate greyed out

**Scenario 11: Camera reconnect after disconnect**
- User unplugged camera, app shows "Camera disconnected"
- User plugs camera back in
- Expected:
  - If camera matches profile for current display config: auto-resume monitoring
  - If camera doesn't match: show "Calibration needed" (camera available for recalibration)

**Scenario 12: Different camera connects**
- User unplugged Camera A, app shows "Calibration needed"
- User plugs in Camera B (different camera)
- Expected: Stay in "Calibration needed", user can recalibrate with Camera B

---

### Pause on the Go

**Scenario 13: Enable "Pause on the Go" while on laptop-only**
- User is on laptop with just built-in display
- User enables "Pause on the Go" setting
- Expected: Immediately pauses with "Paused (on the go)"

**Scenario 14: Unplug monitor with "Pause on the Go" enabled**
- User has "Pause on the Go" enabled
- User is monitoring on laptop + external monitor
- User unplugs external monitor
- Expected: Pauses with "Paused (on the go)" instead of looking up laptop-only profile

**Scenario 15: Plug in monitor while paused on the go**
- User is paused on the go (laptop-only)
- User plugs in external monitor
- Expected: Resumes or prompts calibration based on profile for new config

**Scenario 16: Disable "Pause on the Go" while paused**
- User is paused with "Paused (on the go)"
- User disables the setting
- Expected: Transitions based on current config - resume if profile exists, else "Calibration needed"

---

### Enable/Disable Toggle

**Scenario 17: Disable while monitoring**
- User is actively monitoring
- User clicks "Enabled" to disable
- Expected: Camera stops, blur clears, status shows "Disabled"

**Scenario 18: Re-enable with valid profile**
- User disabled the app while having a valid profile
- User clicks "Enabled" to re-enable
- Expected: Monitoring resumes with existing calibration

**Scenario 19: Re-enable without profile**
- User disabled the app, then changed display config
- User clicks "Enabled" to re-enable
- Expected: Shows "Calibration needed" (not calibrated for new config)

**Scenario 20: Re-enable with no camera**
- User disabled app, then unplugged all cameras
- User clicks "Enabled"
- Expected: Shows "Camera disconnected"

---

### Calibration Flow

**Scenario 21: Complete calibration**
- User clicks Recalibrate or app prompts calibration
- User completes all calibration steps
- Expected:
  - Profile saved for current display config with current camera ID
  - Transitions to monitoring state
  - Future launches with same config will auto-load profile

**Scenario 22: Cancel calibration**
- User starts calibration
- User presses Escape to cancel
- Expected: Uses default calibration values, transitions to monitoring

**Scenario 23: Recalibrate with different camera**
- User has profile with Camera A
- User switches to Camera B, sees "Calibration needed"
- User clicks Recalibrate
- Expected: Calibrates with Camera B, saves profile (overwrites old one for this display config)

---

### Edge Cases

**Scenario 24: No cameras at app launch**
- User launches app with no cameras connected
- Expected: Shows "Camera disconnected", Recalibrate greyed out with "(no camera)"

**Scenario 25: Display change while calibrating**
- User is in middle of calibration
- User unplugs a monitor
- Expected: Calibration should handle gracefully (windows rebuild, may need to restart calibration)

**Scenario 26: Rapid monitor plug/unplug**
- User plugs and unplugs monitors rapidly
- Expected: Debounce timer (0.5s) prevents rapid state changes, settles to final config

**Scenario 27: Multiple external monitors**
- User has laptop + 2 external monitors
- Profile key includes all 3 display UUIDs
- Expected: Unique profile for this 3-monitor setup

**Scenario 28: Same monitor model, different unit**
- User has monitor A at home, monitor B at office (same model)
- Expected: Different UUIDs, different profiles (each monitor has unique UUID)

---

## Settings Persistence

All settings are saved to UserDefaults:
- `sensitivity` - Posture detection sensitivity
- `deadZone` - Movement tolerance before blur activates
- `useCompatibilityMode` - Use public API blur instead of private API
- `blurWhenAway` - Blur screen when user not detected
- `pauseOnTheGo` - Auto-pause on laptop-only config
- `lastCameraID` - Last selected camera
- `profiles` - Dictionary of display config -> ProfileData

---

## State Transition Diagram

```
                    ┌─────────────┐
                    │   disabled  │
                    └──────┬──────┘
                           │ toggle enable
                           ▼
              ┌────────────────────────┐
              │ check profile & camera │
              └───────────┬────────────┘
                          │
         ┌────────────────┼────────────────┐
         │                │                │
         ▼                ▼                ▼
   ┌──────────┐    ┌────────────┐   ┌─────────────────┐
   │monitoring│◄──►│ calibrating│   │ paused(reason)  │
   └────┬─────┘    └────────────┘   └────────┬────────┘
        │                                     │
        │         display/camera change       │
        └─────────────────────────────────────┘
```

---

## Debugging Tips

1. **Check current state**: Menu bar icon indicates state
   - Standing figure = monitoring/calibrating
   - Pause circle = paused
   - Dotted figure = disabled

2. **Check status text**: Menu shows detailed status
   - "Good Posture" / "Slouching" / "Away" = monitoring
   - "Calibrating..." = in calibration
   - "Calibration needed" = paused, needs recalibration
   - "Camera disconnected" = no cameras available
   - "Paused (on the go)" = laptop-only with setting enabled

3. **Camera issues**: If camera won't start
   - Check if Recalibrate is greyed out (no camera)
   - Try selecting camera from menu
   - Check System Preferences for camera permissions

4. **Profile issues**: If wrong calibration loads
   - Different monitor configs have different profiles
   - Changing cameras requires recalibration
   - Profiles are keyed by display UUID, not name
