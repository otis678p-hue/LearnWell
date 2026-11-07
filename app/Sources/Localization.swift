import Foundation

enum AppLanguage: String, CaseIterable, Codable, Identifiable, Sendable {
    case traditionalChinese = "zh-Hant"
    case english = "en"

    static let defaultLanguage: AppLanguage = .english

    var id: String { rawValue }

    /// Each language is named in itself, so it stays untranslated.
    var title: String {
        switch self {
        case .traditionalChinese: return "繁體中文"
        case .english: return "English"
        }
    }

    var locale: Locale {
        Locale(identifier: rawValue)
    }

    /// The source copy is English and doubles as the key; zh-Hant.lproj maps it to Chinese.
    func localized(_ source: String) -> String {
        Self.lookup(rawValue, source) ?? source
    }

    func localizedFormat(_ source: String, _ arguments: CVarArg...) -> String {
        String(
            format: localized(source),
            locale: locale,
            arguments: arguments
        )
    }

    // MARK: - lookup

    private static let missingSentinel = "\u{0}__missing__"

    private static func lookup(_ language: String, _ source: String) -> String? {
        guard let path = Bundle.main.path(forResource: language, ofType: "lproj"),
              let bundle = Bundle(path: path) else {
            return nil
        }
        let value = bundle.localizedString(
            forKey: source,
            value: missingSentinel,
            table: nil
        )
        guard value != source, value != missingSentinel else { return nil }
        return value
    }
}
