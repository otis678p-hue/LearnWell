import Foundation

/// Exercise the real AppLanguage lookup against the resources shipped in an app.
/// Source-table coverage alone cannot catch an outdated installed bundle.
@main
enum LocalizationBundleCheck {
    static func main() throws {
        var failures: [String] = []
        let tableURL = Bundle.main.resourceURL!
            .appendingPathComponent("zh-Hant.lproj/Localizable.strings")
        let data = try Data(contentsOf: tableURL)
        let table = try PropertyListSerialization.propertyList(from: data, format: nil) as! [String: String]
        for (key, expected) in table {
            let chinese = AppLanguage.traditionalChinese.localized(key)
            if chinese != expected {
                failures.append("Chinese lookup failed: \(key) → \(chinese)")
            }
            // English is the source text itself; it must never pick up Chinese.
            let english = AppLanguage.english.localized(key)
            if english != key {
                failures.append("English lookup changed the source: \(key) → \(english)")
            }
        }

        // Reuse the same process to catch language caching across a switch.
        let key = "No single person detected; posture unknown"
        if !containsHanzi(AppLanguage.traditionalChinese.localized(key)) {
            failures.append("Traditional Chinese lookup failed")
        }
        if AppLanguage.english.localized(key) != key {
            failures.append("Switching back to English retained Chinese text")
        }

        guard failures.isEmpty else {
            for failure in failures { fputs(failure + "\n", stderr) }
            exit(1)
        }
        print("bundle localization ok: \(table.count) zh-Hant entries, language switching")
    }

    private static func containsHanzi(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x3400...0x9FFF).contains($0.value) }
    }
}
