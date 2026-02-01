import AppKit
#if SWIFT_PACKAGE
import PosturrCore
#endif

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
