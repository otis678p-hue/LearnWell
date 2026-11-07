import Foundation

/// Audits the localisation contract: English text in the code is the key, and
/// zh-Hant.lproj/Localizable.strings maps it to Traditional Chinese.
///
/// Fails when Chinese text appears in a Swift string (it belongs in the zh-Hant
/// table), when interface text has no zh-Hant entry, or when a zh-Hant value is
/// not Chinese. Interface text is any literal passed to a SwiftUI view, a
/// `localized`/`t` call or a `title:`-style argument. Deliberate exceptions are
/// listed in tools/localization_allowlist.txt.
@main
enum CheckLocalization {
    static func main() {
        let root = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
        let sourcesDir = URL(fileURLWithPath: root).appendingPathComponent("Sources")
        let allowlist = loadAllowlist(root: root)
        let tableURL = sourcesDir.appendingPathComponent("zh-Hant.lproj/Localizable.strings")
        guard let data = try? Data(contentsOf: tableURL),
              let chinese = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: String]
        else {
            fputs("cannot read zh-Hant strings table\n", stderr)
            exit(1)
        }

        var failures: [String] = []
        for (key, value) in chinese where !containsHanzi(value) {
            failures.append("zh-Hant value is not Chinese: \"\(key)\" = \"\(value)\"")
        }
        let interface = try! NSRegularExpression(pattern:
            #"(?:\b(?:Text|Label|Button|Toggle|Picker|Section|LocalizedStringKey|localized|localizedFormat|help|t)\(\s*|\b(?:title|subtitle|footnote|detail|label|text|message|placeholder):\s*)"((?:[^"\\\n]|\\.)*)""#)
        let literal = try! NSRegularExpression(pattern: #""((?:[^"\\\n]|\\.)*)""#)
        let identifier = try! NSRegularExpression(pattern: #"^[A-Za-z][\w-]*(\.[\w-]+)+$"#)
        var checked = 0

        for file in swiftFiles(in: sourcesDir) {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for (index, line) in text.components(separatedBy: "\n").enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") || trimmed.hasPrefix("*") || trimmed.hasPrefix("/*") { continue }
                let place = "\(file.lastPathComponent):\(index + 1)"
                for raw in captures(literal, in: line) where containsHanzi(raw) && !allowlist.contains(raw) {
                    failures.append("\(place): Chinese text in code, use English and add it to zh-Hant: \"\(raw)\"")
                }
                for raw in captures(interface, in: line) {
                    guard raw.rangeOfCharacter(from: .letters) != nil, !raw.contains("\\("),
                          !containsHanzi(raw), !allowlist.contains(raw),
                          identifier.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)) == nil
                    else { continue }
                    checked += 1
                    if chinese[unescape(raw)] == nil {
                        failures.append("\(place): missing zh-Hant translation: \"\(raw)\"")
                    }
                }
            }
        }

        if failures.isEmpty {
            print("localization ok: \(checked) interface strings, \(chinese.count) zh-Hant entries")
            return
        }
        fputs("localization check failed (\(failures.count) issue(s)):\n", stderr)
        for failure in failures { fputs("  \(failure)\n", stderr) }
        exit(1)
    }

    private static func captures(_ regex: NSRegularExpression, in line: String) -> [String] {
        regex.matches(in: line, range: NSRange(line.startIndex..., in: line)).compactMap {
            Range($0.range(at: 1), in: line).map { String(line[$0]) }
        }
    }

    /// Source escapes that also appear in the table keys after plist parsing.
    private static func unescape(_ raw: String) -> String {
        raw.replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }

    private static func loadAllowlist(root: String) -> Set<String> {
        let url = URL(fileURLWithPath: root).appendingPathComponent("tools/localization_allowlist.txt")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return Set(text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") })
    }

    private static func swiftFiles(in directory: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "swift" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func containsHanzi(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
    }
}
