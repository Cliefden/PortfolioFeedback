import Foundation
import SwiftUI

/// Where reports go and when the UI is shown. Put one in the SwiftUI
/// environment with ``SwiftUICore/View/portfolioFeedback(_:)`` and
/// ``ReportIssueRow`` picks it up.
///
/// ```swift
/// SettingsView()
///     .portfolioFeedback(FeedbackConfiguration(
///         endpoint: URL(string: "https://vivum.crawik.com/functions/v1/report-issue")!,
///         appKey: "otta",                       // the key in the function's ISSUE_APPS map
///         anonKey: Secrets.supabaseAnonKey,     // Kong / edge-runtime JWT gate, not a secret
///         extraContext: { ["plan": store.plan.rawValue] }
///     ))
/// ```
public struct FeedbackConfiguration: Sendable {
    /// When the report row is visible.
    public enum Visibility: Sendable, Equatable {
        /// Only on testing channels (``BuildChannel/isTesting``). The default.
        case automatic
        /// Always, including App Store builds. For development only.
        case always
        /// Never (keeps the configuration in place but hides the UI).
        case never

        public func allows(_ channel: BuildChannel) -> Bool {
            switch self {
            case .automatic: channel.isTesting
            case .always: true
            case .never: false
            }
        }
    }

    /// The `report-issue` edge function URL.
    public var endpoint: URL
    /// Identifies the app to the function (`ISSUE_APPS` key → repo). Not a secret:
    /// it only lets a caller file an issue in this app's own repo, rate limited.
    public var appKey: String
    /// Sent as `apikey` and `Authorization: Bearer` so the self-hosted gateway and
    /// edge runtime accept the call. `nil` when the function is reached without one.
    public var anonKey: String?
    public var visibility: Visibility
    /// Recent-log capture settings.
    public var log: LogOptions
    /// App-specific key/values appended to the report (feature flags, plan, counts).
    /// Called on the main actor when the report is built. Never put user data here.
    public var extraContext: @MainActor @Sendable () -> [String: String]
    /// Request timeout.
    public var timeout: TimeInterval

    public init(
        endpoint: URL,
        appKey: String,
        anonKey: String? = nil,
        visibility: Visibility = .automatic,
        log: LogOptions = LogOptions(),
        timeout: TimeInterval = 20,
        extraContext: @MainActor @Sendable @escaping () -> [String: String] = { [:] }
    ) {
        self.endpoint = endpoint
        self.appKey = appKey
        self.anonKey = anonKey
        self.visibility = visibility
        self.log = log
        self.timeout = timeout
        self.extraContext = extraContext
    }
}

public extension EnvironmentValues {
    /// The app's feedback configuration, or `nil` when the app hasn't set one
    /// (``ReportIssueRow`` then renders nothing).
    @Entry var portfolioFeedback: FeedbackConfiguration?
}

public extension View {
    /// Install the feedback configuration for this view tree.
    func portfolioFeedback(_ configuration: FeedbackConfiguration?) -> some View {
        environment(\.portfolioFeedback, configuration)
    }
}
