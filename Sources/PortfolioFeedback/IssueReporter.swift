import Foundation

/// The network seam, so tests never touch the network. `URLSession` conforms.
public protocol HTTPDataLoader: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: HTTPDataLoader {}

/// What the function answers on success: the issue number and its GitHub URL.
/// The URL is for the developer (the repos are private); the UI shows the number.
public struct IssueReceipt: Sendable, Decodable, Equatable {
    public var number: Int
    public var url: URL

    public init(number: Int, url: URL) {
        self.number = number
        self.url = url
    }
}

public enum IssueReporterError: Error, LocalizedError, Equatable {
    /// The function rejected the report (`{error: code}` with this status).
    case rejected(status: Int, code: String)
    /// Rate limited; retry after the given number of seconds when known.
    case rateLimited(retryAfter: Int?)
    /// A transport failure (offline, timeout, TLS).
    case transport(String)
    /// A 2xx without a decodable `{number, url}` body.
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .rejected(let status, let code):
            String(localized: "The server rejected the report (\(code), HTTP \(status)).", bundle: .module)
        case .rateLimited:
            String(localized: "Too many reports in a short time. Please try again in a minute.", bundle: .module)
        case .transport:
            String(localized: "Could not reach the server. Check your connection and try again.", bundle: .module)
        case .invalidResponse:
            String(localized: "The server sent an unexpected reply.", bundle: .module)
        }
    }
}

/// Posts an ``IssueReport`` to the `report-issue` function.
///
/// ```swift
/// let receipt = try await IssueReporter(configuration: config).submit(report)
/// print("filed #\(receipt.number)")
/// ```
public struct IssueReporter: Sendable {
    public var configuration: FeedbackConfiguration
    private let loader: HTTPDataLoader

    public init(configuration: FeedbackConfiguration, loader: HTTPDataLoader = URLSession.shared) {
        self.configuration = configuration
        self.loader = loader
    }

    /// The request that ``submit(_:)`` sends (exposed for tests and debugging).
    public func makeRequest(for report: IssueReport) throws -> URLRequest {
        var request = URLRequest(url: configuration.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = configuration.timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(configuration.appKey, forHTTPHeaderField: "X-App-Key")
        if let anonKey = configuration.anonKey {
            request.setValue(anonKey, forHTTPHeaderField: "apikey")
            request.setValue("Bearer \(anonKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try IssueReport.makeEncoder().encode(report)
        return request
    }

    public func submit(_ report: IssueReport) async throws -> IssueReceipt {
        let request = try makeRequest(for: report)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await loader.data(for: request)
        } catch {
            throw IssueReporterError.transport(String(describing: error))
        }
        guard let http = response as? HTTPURLResponse else { throw IssueReporterError.invalidResponse }
        switch http.statusCode {
        case 200..<300:
            guard let receipt = try? JSONDecoder().decode(IssueReceipt.self, from: data) else {
                throw IssueReporterError.invalidResponse
            }
            return receipt
        case 429:
            let retry = http.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init)
            throw IssueReporterError.rateLimited(retryAfter: retry)
        default:
            let code = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error ?? "http_\(http.statusCode)"
            throw IssueReporterError.rejected(status: http.statusCode, code: code)
        }
    }

    private struct ErrorBody: Decodable {
        var error: String
    }
}
