import Foundation
import Testing
@testable import PortfolioFeedback

/// Serves one canned response and records the request.
final class StubLoader: HTTPDataLoader, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [URLRequest] = []
    var status: Int
    var body: Data
    var headers: [String: String]
    var failure: Error?

    init(status: Int = 201, body: String = #"{"number":42,"url":"https://github.com/Cliefden/Otta/issues/42"}"#, headers: [String: String] = [:], failure: Error? = nil) {
        self.status = status
        self.body = Data(body.utf8)
        self.headers = headers
        self.failure = failure
    }

    var requests: [URLRequest] { lock.withLock { _requests } }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        lock.withLock { _requests.append(request) }
        if let failure { throw failure }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        return (body, response)
    }
}

let endpoint = URL(string: "https://vivum.crawik.com/functions/v1/report-issue")!

func sampleReport() -> IssueReport {
    IssueReport(kind: .bug, title: "T", body: "B", reporterId: "rid", createdAt: Date(timeIntervalSince1970: 0), context: sampleContext)
}

@Suite("IssueReporter")
struct IssueReporterTests {
    @Test("request: POST, JSON, app key, anon key as apikey + bearer")
    func request() throws {
        let config = FeedbackConfiguration(endpoint: endpoint, appKey: "otta", anonKey: "anon.jwt", timeout: 7)
        let request = try IssueReporter(configuration: config).makeRequest(for: sampleReport())
        #expect(request.httpMethod == "POST")
        #expect(request.url == endpoint)
        #expect(request.timeoutInterval == 7)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "X-App-Key") == "otta")
        #expect(request.value(forHTTPHeaderField: "apikey") == "anon.jwt")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer anon.jwt")
        let body = try #require(request.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["title"] as? String == "T")
        #expect(json["schema"] as? Int == 1)
    }

    @Test("no anon key → no apikey / Authorization headers")
    func noAnonKey() throws {
        let config = FeedbackConfiguration(endpoint: endpoint, appKey: "otta")
        let request = try IssueReporter(configuration: config).makeRequest(for: sampleReport())
        #expect(request.value(forHTTPHeaderField: "apikey") == nil)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test("201 with {number, url} → receipt")
    func success() async throws {
        let loader = StubLoader()
        let reporter = IssueReporter(configuration: FeedbackConfiguration(endpoint: endpoint, appKey: "otta"), loader: loader)
        let receipt = try await reporter.submit(sampleReport())
        #expect(receipt == IssueReceipt(number: 42, url: URL(string: "https://github.com/Cliefden/Otta/issues/42")!))
        #expect(loader.requests.count == 1)
    }

    @Test("error body code surfaces as rejected")
    func rejected() async {
        let loader = StubLoader(status: 401, body: #"{"error":"unknown_app"}"#)
        let reporter = IssueReporter(configuration: FeedbackConfiguration(endpoint: endpoint, appKey: "nope"), loader: loader)
        await #expect(throws: IssueReporterError.rejected(status: 401, code: "unknown_app")) {
            _ = try await reporter.submit(sampleReport())
        }
    }

    @Test("non-JSON error body → http_<status>")
    func rejectedWithoutBody() async {
        let loader = StubLoader(status: 502, body: "Bad Gateway")
        let reporter = IssueReporter(configuration: FeedbackConfiguration(endpoint: endpoint, appKey: "otta"), loader: loader)
        await #expect(throws: IssueReporterError.rejected(status: 502, code: "http_502")) {
            _ = try await reporter.submit(sampleReport())
        }
    }

    @Test("429 → rateLimited with Retry-After")
    func rateLimited() async {
        let loader = StubLoader(status: 429, body: #"{"error":"rate_limited"}"#, headers: ["Retry-After": "37"])
        let reporter = IssueReporter(configuration: FeedbackConfiguration(endpoint: endpoint, appKey: "otta"), loader: loader)
        await #expect(throws: IssueReporterError.rateLimited(retryAfter: 37)) {
            _ = try await reporter.submit(sampleReport())
        }
    }

    @Test("2xx without a receipt → invalidResponse")
    func invalidResponse() async {
        let loader = StubLoader(status: 200, body: "{}")
        let reporter = IssueReporter(configuration: FeedbackConfiguration(endpoint: endpoint, appKey: "otta"), loader: loader)
        await #expect(throws: IssueReporterError.invalidResponse) {
            _ = try await reporter.submit(sampleReport())
        }
    }

    @Test("transport failure → transport")
    func transport() async {
        let loader = StubLoader(failure: URLError(.notConnectedToInternet))
        let reporter = IssueReporter(configuration: FeedbackConfiguration(endpoint: endpoint, appKey: "otta"), loader: loader)
        do {
            _ = try await reporter.submit(sampleReport())
            Issue.record("expected a throw")
        } catch let error as IssueReporterError {
            guard case .transport = error else {
                Issue.record("wrong error \(error)")
                return
            }
            #expect(error.errorDescription?.isEmpty == false)
        } catch {
            Issue.record("unexpected \(error)")
        }
    }
}
