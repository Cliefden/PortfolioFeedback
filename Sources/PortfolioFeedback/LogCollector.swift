import Foundation
import OSLog

/// What ``LogCollector`` reads from the unified log.
public struct LogOptions: Sendable, Equatable {
    /// How far back to read. Default 15 minutes.
    public var window: TimeInterval
    /// Subsystems to include. Empty means the app's bundle identifier, which is
    /// what `AppTelemetry.AppLog` uses by default.
    public var subsystems: [String]
    /// The tail of the formatted log is kept up to this many characters.
    public var maxCharacters: Int
    /// Lowest level to include. `.info` includes debug-level entries too when the
    /// system kept them (it usually doesn't in Release).
    public var minimumLevel: OSLogEntryLog.Level
    /// Whether the toggle in ``ReportIssueView`` starts on.
    public var includeByDefault: Bool

    public init(
        window: TimeInterval = 15 * 60,
        subsystems: [String] = [],
        maxCharacters: Int = 24_000,
        minimumLevel: OSLogEntryLog.Level = .info,
        includeByDefault: Bool = true
    ) {
        self.window = window
        self.subsystems = subsystems
        self.maxCharacters = maxCharacters
        self.minimumLevel = minimumLevel
        self.includeByDefault = includeByDefault
    }
}

/// A log entry reduced to what the report needs. ``LogCollector`` maps
/// `OSLogEntryLog` onto it; tests build them directly.
public struct LogRecord: Sendable, Equatable {
    public var date: Date
    public var level: OSLogEntryLog.Level
    public var category: String
    public var message: String

    public init(date: Date, level: OSLogEntryLog.Level, category: String, message: String) {
        self.date = date
        self.level = level
        self.category = category
        self.message = message
    }
}

/// Reads the app's own recent `os.Logger` output through `OSLogStore`.
///
/// Values interpolated with `privacy: .private` arrive already redacted as
/// `<private>`, so the tail is safe to attach as long as the app's loggers
/// follow the AppTelemetry rule of marking user data private.
public enum LogCollector {
    /// The formatted tail of the current process's log, or `nil` when the store
    /// is unavailable or empty. Reading can take a few hundred milliseconds; call
    /// it off the main actor.
    public static func recent(_ options: LogOptions = LogOptions(), bundle: Bundle = .main, now: Date = Date()) -> String? {
        let subsystems = options.subsystems.isEmpty ? [bundle.bundleIdentifier ?? ""] : options.subsystems
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let position = store.position(date: now.addingTimeInterval(-options.window))
            let predicate = NSPredicate(format: "subsystem IN %@", subsystems)
            let entries = try store.getEntries(at: position, matching: predicate)
            let records = entries.compactMap { entry -> LogRecord? in
                guard let log = entry as? OSLogEntryLog else { return nil }
                return LogRecord(date: log.date, level: log.level, category: log.category, message: log.composedMessage)
            }
            return format(records, options: options)
        } catch {
            return nil
        }
    }

    /// One line per record, oldest first, trimmed from the front to
    /// ``LogOptions/maxCharacters``. `nil` when nothing passes the level filter.
    public static func format(_ records: [LogRecord], options: LogOptions = LogOptions()) -> String? {
        let kept = records.filter { $0.level.rank >= options.minimumLevel.rank }
        guard !kept.isEmpty else { return nil }
        var lines = kept.map { record in
            "\(Self.timestamp.string(from: record.date)) \(record.level.tag) [\(record.category)] \(record.message.replacingOccurrences(of: "\n", with: "\\n"))"
        }
        var text = lines.joined(separator: "\n")
        if text.count > options.maxCharacters {
            // Drop whole lines from the front until it fits, then mark the cut.
            while text.count > options.maxCharacters, lines.count > 1 {
                lines.removeFirst()
                text = lines.joined(separator: "\n")
            }
            if text.count > options.maxCharacters {
                text = String(text.suffix(options.maxCharacters))
            }
            text = "… (earlier lines dropped)\n" + text
        }
        return text
    }

    private static let timestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
}

extension OSLogEntryLog.Level {
    /// Severity order for filtering (`undefined` and `debug` lowest).
    var rank: Int {
        switch self {
        case .undefined: 0
        case .debug: 1
        case .info: 2
        case .notice: 3
        case .error: 4
        case .fault: 5
        @unknown default: 0
        }
    }

    var tag: String {
        switch self {
        case .undefined: "?"
        case .debug: "D"
        case .info: "I"
        case .notice: "N"
        case .error: "E"
        case .fault: "F"
        @unknown default: "?"
        }
    }
}
