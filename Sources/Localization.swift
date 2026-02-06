import Foundation

private var localizationBundle: Bundle {
    #if SWIFT_PACKAGE
    return Bundle.module
    #else
    return Bundle.main
    #endif
}

private func localizedString(_ key: String) -> String {
    let value = NSLocalizedString(key, bundle: localizationBundle, comment: "")
    #if DEBUG
    if value == key {
        NSLog("Missing localization for key: %@", key)
    }
    #endif
    return value
}

public func L(_ key: String) -> String {
    localizedString(key)
}

public func L(_ key: String, _ args: CVarArg...) -> String {
    let format = localizedString(key)
    return String(format: format, locale: Locale.current, arguments: args)
}
