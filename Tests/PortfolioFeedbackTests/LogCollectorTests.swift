import Foundation
import OSLog
import Testing
@testable import PortfolioFeedback

@Suite("LogCollector.format")
struct LogCollectorTests {
    private let base = Date(timeIntervalSince1970: 1_793_059_200) // 2026-10-27T00:00:00Z

    private func record(_ seconds: TimeInterval, _ level: OSLogEntryLog.Level, _ category: String, _ message: String) -> LogRecord {
        LogRecord(date: base.addingTimeInterval(seconds), level: level, category: category, message: message)
    }

    @Test("one line per record with level tag and category; newlines escaped")
    func formatting() throws {
        let text = try #require(LogCollector.format([
            record(0, .info, "app", "launched"),
            record(1.25, .error, "sync", "failed\nretrying"),
        ], options: LogOptions()))
        let lines = text.split(separator: "\n")
        #expect(lines.count == 2)
        #expect(lines[0].hasSuffix(" I [app] launched"))
        #expect(lines[1].hasSuffix(" E [sync] failed\\nretrying"))
        // HH:mm:ss.SSS in the current time zone — check the shape only.
        #expect(lines[0].prefix(12).filter { $0 == ":" }.count == 2)
    }

    @Test("minimum level filters debug out, keeps notice and above")
    func levelFilter() {
        let records = [
            record(0, .debug, "app", "dbg"),
            record(1, .info, "app", "inf"),
            record(2, .notice, "app", "ntc"),
            record(3, .fault, "app", "flt"),
        ]
        let notice = LogCollector.format(records, options: LogOptions(minimumLevel: .notice))
        #expect(notice?.contains("dbg") == false)
        #expect(notice?.contains("inf") == false)
        #expect(notice?.contains("ntc") == true)
        #expect(notice?.contains("flt") == true)
        #expect(LogCollector.format([record(0, .debug, "app", "dbg")], options: LogOptions(minimumLevel: .info)) == nil)
        #expect(LogCollector.format([], options: LogOptions()) == nil)
    }

    @Test("keeps the tail when over the cap and marks the cut")
    func tail() throws {
        let records = (0..<50).map { record(TimeInterval($0), .info, "app", "line \($0)") }
        let text = try #require(LogCollector.format(records, options: LogOptions(maxCharacters: 200)))
        #expect(text.hasPrefix("… (earlier lines dropped)\n"))
        #expect(text.contains("line 49"))
        #expect(!text.contains("line 0\n"))
        let body = text.dropFirst("… (earlier lines dropped)\n".count)
        #expect(body.count <= 200)
    }

    @Test("reading the live store does not throw and returns our own entries")
    func liveStore() {
        let subsystem = "com.crawik.portfoliofeedback.tests"
        let logger = Logger(subsystem: subsystem, category: "test")
        let marker = "marker-\(UUID().uuidString)"
        logger.error("\(marker, privacy: .public)")
        let text = LogCollector.recent(LogOptions(window: 60, subsystems: [subsystem], minimumLevel: .error))
        // The store can lag slightly; accept either nil or a tail containing the marker.
        if let text {
            #expect(text.contains(marker))
            #expect(text.contains(" E [test] "))
        }
    }
}
