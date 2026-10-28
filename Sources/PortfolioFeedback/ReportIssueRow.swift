import SwiftUI

/// A settings row that opens ``ReportIssueView``. Renders **nothing** unless a
/// ``FeedbackConfiguration`` is in the environment and its visibility allows the
/// detected ``BuildChannel`` (by default: TestFlight, Xcode and ad hoc installs).
///
/// ```swift
/// Section("About") {
///     InfoRow("Version", Bundle.main.versionAndBuild)
///     ReportIssueRow()                    // only visible in testing builds
/// }
/// ```
///
/// Pass `attachments` to include a screenshot the app captured before opening
/// settings, or a custom `label`.
public struct ReportIssueRow<Label: View>: View {
    @Environment(\.portfolioFeedback) private var configuration

    @State private var channel: BuildChannel?
    @State private var presenting = false

    private let attachments: @MainActor @Sendable () -> [IssueAttachment]
    private let label: (BuildChannel) -> Label

    /// - Parameters:
    ///   - attachments: Built when the sheet opens (a screenshot, say).
    ///   - label: The row's label, given the detected channel.
    public init(
        attachments: @MainActor @Sendable @escaping () -> [IssueAttachment] = { [] },
        @ViewBuilder label: @escaping (BuildChannel) -> Label
    ) {
        self.attachments = attachments
        self.label = label
    }

    public var body: some View {
        Group {
            if let configuration, let channel, configuration.visibility.allows(channel) {
                Button {
                    presenting = true
                } label: {
                    label(channel)
                }
                .sheet(isPresented: $presenting) {
                    ReportIssueView(channel: channel, attachments: attachments())
                        .portfolioFeedback(configuration)
                }
            }
        }
        .task {
            channel = await BuildChannelDetector.current()
        }
    }
}

public extension ReportIssueRow where Label == DefaultReportIssueLabel {
    /// The standard row: a ladybug icon, "Report an issue", and the channel as a badge.
    init(attachments: @MainActor @Sendable @escaping () -> [IssueAttachment] = { [] }) {
        self.init(attachments: attachments) { channel in
            DefaultReportIssueLabel(channel: channel)
        }
    }
}

/// The default label used by ``ReportIssueRow``.
public struct DefaultReportIssueLabel: View {
    public var channel: BuildChannel

    public init(channel: BuildChannel) {
        self.channel = channel
    }

    public var body: some View {
        HStack {
            SwiftUI.Label {
                Text("Report an issue", bundle: .module)
            } icon: {
                Image(systemName: "ladybug")
            }
            Spacer()
            Text(channel.label)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.quaternary, in: Capsule())
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }
}
