import SwiftUI

/// The report sheet. Collects kind, title, description and optional contact,
/// shows what context will be attached, and posts through ``IssueReporter``.
///
/// Usually presented by ``ReportIssueRow``. Apps with their own trigger (a shake
/// gesture, a debug menu) present it directly:
///
/// ```swift
/// .sheet(isPresented: $showReport) {
///     ReportIssueView(channel: channel, attachments: [.png(screenshotData)])
/// }
/// ```
///
/// Needs a ``FeedbackConfiguration`` in the environment; without one it shows a
/// short "not configured" message so a misconfiguration is visible in testing.
public struct ReportIssueView: View {
    @Environment(\.portfolioFeedback) private var configuration
    @Environment(\.dismiss) private var dismiss

    private let channel: BuildChannel
    private let initialAttachments: [IssueAttachment]
    private let loader: HTTPDataLoader

    @State private var kind: IssueKind = .bug
    @State private var title = ""
    @State private var details = ""
    @State private var reporter = ""
    @State private var includeLog: Bool
    @State private var logPreview: String?
    @State private var phase: Phase = .editing
    @State private var errorMessage: String?

    private enum Phase: Equatable {
        case editing
        case sending
        case sent(number: Int)
    }

    public init(channel: BuildChannel, attachments: [IssueAttachment] = [], loader: HTTPDataLoader = URLSession.shared) {
        self.channel = channel
        self.initialAttachments = attachments
        self.loader = loader
        _includeLog = State(initialValue: true)
    }

    public var body: some View {
        NavigationStack {
            Group {
                if let configuration {
                    switch phase {
                    case .sent(let number):
                        sentView(number: number)
                    case .editing, .sending:
                        form(configuration)
                    }
                } else {
                    ContentUnavailableView(
                        String(localized: "Issue reporting is not configured", bundle: .module),
                        systemImage: "exclamationmark.triangle",
                        description: Text("Add a FeedbackConfiguration with .portfolioFeedback(_:) above this view.", bundle: .module)
                    )
                }
            }
            .navigationTitle(Text("Report an issue", bundle: .module))
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .cancel) { dismiss() } label: { Text("Cancel", bundle: .module) }
                        .disabled(phase == .sending)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if case .sent = phase {
                        // Nothing to confirm once filed; "Done" lives in the body.
                    } else {
                        Button { Task { await send() } } label: {
                            if phase == .sending {
                                ProgressView()
                            } else {
                                Text("Send", bundle: .module)
                            }
                        }
                        .disabled(!canSend)
                    }
                }
            }
            .alert(
                Text("Could not send the report", bundle: .module),
                isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
            ) {
                Button { errorMessage = nil } label: { Text("OK", bundle: .module) }
            } message: {
                Text(errorMessage ?? "")
            }
            .task {
                guard let configuration else { return }
                includeLog = configuration.log.includeByDefault
                let options = configuration.log
                logPreview = await Task.detached(priority: .utility) { LogCollector.recent(options) }.value
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 520)
        #endif
    }

    private var canSend: Bool {
        phase == .editing && configuration != nil &&
            !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @ViewBuilder
    private func form(_ configuration: FeedbackConfiguration) -> some View {
        Form {
            Section {
                Picker(selection: $kind) {
                    ForEach(IssueKind.allCases) { kind in
                        Text(kind.label).tag(kind)
                    }
                } label: {
                    Text("Report type", bundle: .module)
                }
                .pickerStyle(.segmented)

                TextField(text: $title, prompt: Text("Short summary", bundle: .module)) {
                    Text("Title", bundle: .module)
                }
                #if !os(macOS)
                .textInputAutocapitalization(.sentences)
                #endif

                TextField(
                    text: $details,
                    prompt: Text("What happened, and what did you expect?", bundle: .module),
                    axis: .vertical
                ) {
                    Text("Description", bundle: .module)
                }
                .lineLimit(4...12)
            }

            Section {
                TextField(text: $reporter, prompt: Text("Name or email (optional)", bundle: .module)) {
                    Text("Contact", bundle: .module)
                }
                #if !os(macOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.emailAddress)
                #endif
                .autocorrectionDisabled()
            } footer: {
                Text("Only so we can follow up on this report.", bundle: .module)
            }

            Section {
                Toggle(isOn: $includeLog) {
                    Text("Include recent logs", bundle: .module)
                }
                .disabled(logPreview == nil)
                if !initialAttachments.isEmpty {
                    Label {
                        Text("\(initialAttachments.count) attachment(s)", bundle: .module)
                    } icon: {
                        Image(systemName: "paperclip")
                    }
                }
            } header: {
                Text("Attached automatically", bundle: .module)
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(contextSummary)
                    if logPreview == nil {
                        Text("No recent log entries for this app.", bundle: .module)
                    } else {
                        let minutes = Int(configuration.log.window / 60)
                        Text("The last \(minutes) minutes of this app's own log. Private values are redacted by the system.", bundle: .module)
                    }
                }
            }
        }
        .disabled(phase == .sending)
        #if os(macOS)
        .formStyle(.grouped)
        #endif
    }

    private var contextSummary: String {
        let context = DeviceContext.current(channel: channel)
        return String(
            localized: "App \(context.appVersion) (\(context.build)) · \(channel.label) · \(context.systemName) \(context.systemVersion) · \(context.deviceModel) · \(context.locale)",
            bundle: .module
        )
    }

    @ViewBuilder
    private func sentView(number: Int) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)
            Text("Issue #\(number) filed. Thank you!", bundle: .module)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
            Text("The team can see your report in the project's issue tracker.", bundle: .module)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button { dismiss() } label: {
                Text("Done", bundle: .module)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 8)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @MainActor
    private func send() async {
        guard let configuration, canSend else { return }
        phase = .sending
        let context = DeviceContext.current(channel: channel)
        let trimmedReporter = reporter.trimmingCharacters(in: .whitespacesAndNewlines)
        let report = IssueReport(
            kind: kind,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            body: details.trimmingCharacters(in: .whitespacesAndNewlines),
            reporter: trimmedReporter.isEmpty ? nil : trimmedReporter,
            context: context,
            extra: configuration.extraContext(),
            log: includeLog ? logPreview : nil,
            attachments: initialAttachments
        )
        do {
            let receipt = try await IssueReporter(configuration: configuration, loader: loader).submit(report)
            phase = .sent(number: receipt.number)
        } catch {
            phase = .editing
            errorMessage = error.localizedDescription
        }
    }
}

extension IssueKind {
    /// Localized, from the package catalog.
    public var label: String {
        switch self {
        case .bug: String(localized: "Bug", bundle: .module)
        case .idea: String(localized: "Idea", bundle: .module)
        case .question: String(localized: "Question", bundle: .module)
        }
    }
}

extension BuildChannel {
    /// Localized, from the package catalog.
    public var label: String {
        switch self {
        case .xcode: String(localized: "Xcode", bundle: .module)
        case .adHoc: String(localized: "Ad hoc", bundle: .module)
        case .testFlight: String(localized: "TestFlight", bundle: .module)
        case .appStore: String(localized: "App Store", bundle: .module)
        case .unknown: String(localized: "Unknown", bundle: .module)
        }
    }
}
