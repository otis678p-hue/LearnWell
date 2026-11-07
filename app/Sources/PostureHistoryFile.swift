import Foundation

/// `history.json` — one compact entry per day, including today's checkpoint.
///
/// The file sits next to the app's other support data and is rewritten
/// atomically when a day is archived, once a minute, and on shutdown. An entry keeps the day's totals and
/// only the hours that actually saw detection, so the trend bars, the best /
/// worst time slot and the week × hour heatmap can all be rebuilt later without
/// storing anything per second. 400 days is a few hundred kilobytes at worst.
struct PostureHistoryFile {
    struct Payload: Codable {
        var version: Int = 1
        var days: [PostureDayRecord] = []
    }

    /// Roughly a year of history; the year trend needs 366 entries.
    static let maximumDays = 400

    let url: URL

    init(url: URL = PostureHistoryFile.defaultURL()) {
        self.url = url
    }

    static func defaultURL() -> URL {
        // Lets the logic checks and the screenshot harness run against a
        // throwaway file instead of the user's real history.
        if let override = ProcessInfo.processInfo.environment["POSTURE_HISTORY_PATH"],
           !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("INT4154 Posture Detecion", isDirectory: true)
            .appendingPathComponent("history.json", isDirectory: false)
    }

    /// Oldest → newest, trimmed to `maximumDays`.
    func load() -> [PostureDayRecord] {
        loadIfPresent() ?? []
    }

    /// Distinguishes a valid empty file from a missing/unreadable file during migration.
    func loadIfPresent() -> [PostureDayRecord]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        guard let payload = try? decoder.decode(Payload.self, from: data), payload.version == 1 else { return nil }
        return Self.trimmed(payload.days)
    }

    /// Writes the file, creating the folder if needed. Failure is silent: the
    /// in-memory history stays usable for the session either way.
    @discardableResult
    func save(_ records: [PostureDayRecord]) -> Bool {
        let payload = Payload(days: Self.trimmed(records))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(payload) else { return false }
        let folder = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: folder.path) {
            do { try FileManager.default.createDirectory(
                at: folder,
                withIntermediateDirectories: true
            ) } catch { return false }
        }
        do {
            try data.write(to: url, options: [.atomic])
            return true
        } catch { return false }
    }

    static func trimmed(_ records: [PostureDayRecord]) -> [PostureDayRecord] {
        var unique: [String: PostureDayRecord] = [:]
        for record in records { unique[record.day] = record }
        let sorted = unique.values.sorted { $0.day < $1.day }
        guard sorted.count > maximumDays else { return sorted }
        return Array(sorted.suffix(maximumDays))
    }
}
