import Foundation
import Testing
@testable import PortfolioFeedback

let sampleContext = DeviceContext(
    bundleIdentifier: "com.crawik.otta",
    appVersion: "2.2.1",
    build: "57",
    channel: .testFlight,
    systemName: "iOS",
    systemVersion: "27.1.0",
    deviceModel: "iPhone17,1",
    locale: "sv_SE",
    timeZone: "Europe/Stockholm",
    isLowPowerModeEnabled: false
)

@Suite("IssueReport encoding")
struct IssueReportTests {
    @Test("JSON shape matches the function's contract")
    func shape() throws {
        let report = IssueReport(
            kind: .bug,
            title: "Crash on map",
            body: "Tapped the coverage layer.",
            reporter: "erik@example.com",
            reporterId: "11111111-2222-3333-4444-555555555555",
            createdAt: Date(timeIntervalSince1970: 1_793_059_200),
            context: sampleContext,
            extra: ["plan": "pro"],
            log: "12:00:00.000 E [sync] failed",
            attachments: [.png(Data([0x89, 0x50]))]
        )
        let data = try IssueReport.makeEncoder().encode(report)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(json["schema"] as? Int == 1)
        #expect(json["kind"] as? String == "bug")
        #expect(json["title"] as? String == "Crash on map")
        #expect(json["reporter"] as? String == "erik@example.com")
        #expect(json["reporterId"] as? String == "11111111-2222-3333-4444-555555555555")
        #expect(json["createdAt"] as? String == "2026-10-27T00:00:00Z")
        #expect((json["extra"] as? [String: String]) == ["plan": "pro"])
        #expect(json["log"] as? String == "12:00:00.000 E [sync] failed")

        let context = try #require(json["context"] as? [String: Any])
        #expect(context["bundleIdentifier"] as? String == "com.crawik.otta")
        #expect(context["channel"] as? String == "testFlight")
        #expect(context["isLowPowerModeEnabled"] as? Bool == false)

        let attachments = try #require(json["attachments"] as? [[String: Any]])
        #expect(attachments.count == 1)
        #expect(attachments[0]["name"] as? String == "screenshot.png")
        #expect(attachments[0]["contentType"] as? String == "image/png")
        #expect(attachments[0]["data"] as? String == "iVA=")   // base64 of 0x89 0x50
    }

    @Test("round-trips through Codable")
    func roundTrip() throws {
        let report = IssueReport(kind: .idea, title: "Dark map", body: "", reporterId: "r", createdAt: Date(timeIntervalSince1970: 0), context: sampleContext)
        let data = try IssueReport.makeEncoder().encode(report)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(IssueReport.self, from: data)
        #expect(decoded == report)
    }

    @Test("DeviceContext.current reads the bundle and the given channel")
    func currentContext() {
        let context = DeviceContext.current(bundle: .main, channel: .adHoc)
        #expect(context.channel == .adHoc)
        #expect(!context.systemVersion.isEmpty)
        #expect(!context.deviceModel.isEmpty)
        #expect(context.deviceModel != "unknown")
        #expect(context.locale == Locale.current.identifier)
    }

    @Test("ReporterIdentity is stable per defaults suite")
    func reporterIdentity() throws {
        let suite = "PortfolioFeedbackTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = ReporterIdentity.current(defaults: defaults)
        let second = ReporterIdentity.current(defaults: defaults)
        #expect(first == second)
        #expect(UUID(uuidString: first) != nil)
        #expect(first == first.lowercased())
    }
}
