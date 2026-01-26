import AppKit
import CoreGraphics

// MARK: - Private API Loading
// Private CoreGraphics APIs for enhanced blur effect (not available in App Store builds)

#if !APP_STORE
let cgsMainConnectionID: (@convention(c) () -> UInt32)? = {
    guard let handle = dlopen(nil, RTLD_LAZY) else { return nil }
    guard let sym = dlsym(handle, "CGSMainConnectionID") else { return nil }
    return unsafeBitCast(sym, to: (@convention(c) () -> UInt32).self)
}()

let cgsSetWindowBackgroundBlurRadius: (@convention(c) (UInt32, UInt32, Int32) -> Int32)? = {
    guard let handle = dlopen(nil, RTLD_LAZY) else { return nil }
    guard let sym = dlsym(handle, "CGSSetWindowBackgroundBlurRadius") else { return nil }
    return unsafeBitCast(sym, to: (@convention(c) (UInt32, UInt32, Int32) -> Int32).self)
}()

var privateAPIsAvailable: Bool {
    return cgsMainConnectionID != nil && cgsSetWindowBackgroundBlurRadius != nil
}
#else
// App Store build: no private APIs available
var privateAPIsAvailable: Bool { return false }
#endif

// MARK: - Blur Overlay Manager

class BlurOverlayManager {
    var windows: [NSWindow] = []
    var blurViews: [NSVisualEffectView] = []
    var currentBlurRadius: Int32 = 0
    var targetBlurRadius: Int32 = 0
    var useCompatibilityMode = false

    func setupOverlayWindows() {
        for screen in NSScreen.screens {
            // Use visibleFrame to exclude the menu bar area
            let frame = screen.visibleFrame
            let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isOpaque = false
            window.backgroundColor = .clear
            // Use a level below popUpMenu so menu bar dropdowns appear above the blur
            window.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue - 1)
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.ignoresMouseEvents = true
            window.hasShadow = false

            // Use NSVisualEffectView - supports both private API mode and compatibility mode
            let blurView = NSVisualEffectView(frame: NSRect(origin: .zero, size: frame.size))
            blurView.blendingMode = .behindWindow
            blurView.material = .fullScreenUI
            blurView.state = .active
            blurView.alphaValue = 0  // Start invisible

            window.contentView = blurView
            window.orderFrontRegardless()
            windows.append(window)
            blurViews.append(blurView)
        }
    }

    func rebuildOverlayWindows() {
        // Remove old windows
        for window in windows {
            window.orderOut(nil)
        }
        windows.removeAll()
        blurViews.removeAll()

        // Create new windows for current screens
        setupOverlayWindows()
    }

    func updateBlur() {
        // Smooth transition - ease in slowly, ease out smoothly
        if currentBlurRadius < targetBlurRadius {
            // Slow ease-in: +1 per frame
            currentBlurRadius = min(currentBlurRadius + 1, targetBlurRadius)
        } else if currentBlurRadius > targetBlurRadius {
            // Near-instant ease-out: clear immediately when posture is good
            currentBlurRadius = max(currentBlurRadius - 32, targetBlurRadius)
        }

        // Calculate alpha for NSVisualEffectView modes
        // Square root curve for faster initial ramp, smooth fade
        let normalizedBlur = CGFloat(currentBlurRadius) / 64.0
        let visualEffectAlpha = min(1.0, sqrt(normalizedBlur) * 1.2)

        #if APP_STORE
        // App Store build: always use NSVisualEffectView (public API)
        for blurView in blurViews {
            blurView.alphaValue = visualEffectAlpha
        }
        #else
        if useCompatibilityMode {
            // Compatibility mode: use NSVisualEffectView alphaValue (public API)
            for blurView in blurViews {
                blurView.alphaValue = visualEffectAlpha
            }
        } else if let getConnectionID = cgsMainConnectionID,
                  let setBlurRadius = cgsSetWindowBackgroundBlurRadius {
            // Default: use private CoreGraphics API for blur
            let cid = getConnectionID()
            for window in windows {
                _ = setBlurRadius(cid, UInt32(window.windowNumber), currentBlurRadius)
            }
        } else {
            // Fallback if private APIs unavailable: use NSVisualEffectView
            for blurView in blurViews {
                blurView.alphaValue = visualEffectAlpha
            }
        }
        #endif
    }
}
