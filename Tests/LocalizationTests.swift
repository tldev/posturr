import XCTest
@testable import PosturrCore

final class LocalizationTests: XCTestCase {
    func testLocalizableKeysMatchAcrossLocales() throws {
        let bundle = Bundle.module
        guard let urls = bundle.urls(forResourcesWithExtension: "strings", subdirectory: nil) else {
            XCTFail("No .strings resources found")
            return
        }

        let localizableUrls = urls.filter { $0.lastPathComponent == "Localizable.strings" }
        XCTAssertFalse(localizableUrls.isEmpty, "No Localizable.strings found in bundle")

        let grouped = Dictionary(grouping: localizableUrls) {
            $0.deletingLastPathComponent().lastPathComponent
        }

        guard let baseUrl = grouped["en.lproj"]?.first else {
            XCTFail("Missing en.lproj Localizable.strings")
            return
        }

        let baseKeys = Set(try loadStrings(from: baseUrl).keys)

        for (locale, urls) in grouped {
            guard let url = urls.first else { continue }
            let keys = Set(try loadStrings(from: url).keys)
            XCTAssertEqual(keys, baseKeys, "Localization keys mismatch for \(locale)")
        }
    }

    private func loadStrings(from url: URL) throws -> [String: String] {
        guard let dict = NSDictionary(contentsOf: url) as? [String: String] else {
            throw NSError(
                domain: "LocalizationTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to load \(url.path)"]
            )
        }
        return dict
    }
}
