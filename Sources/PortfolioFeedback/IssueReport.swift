import Foundation

/// What kind of report the tester is filing. Becomes a `kind:` label on the issue.
public enum IssueKind: String, Sendable, Codable, CaseIterable, Identifiable {
    case bug
    case idea
    case question

    public var id: String { rawValue }
}

/// A file attached to a report (a screenshot, usually). `data` is base64 in JSON.
/// The function uploads it to storage and links it from the issue; apps should
/// downscale screenshots first (≈ 1 MB is plenty).
public struct IssueAttachment: Sendable, Codable, Equatable {
    public var name: String
    public var contentType: String
    public var data: Data

    public init(name: String, contentType: String, data: Data) {
        self.name = name
        self.contentType = contentType
        self.data = data
    }

    /// A PNG screenshot.
    public static func png(_ data: Data, name: String = "screenshot.png") -> IssueAttachment {
        IssueAttachment(name: name, contentType: "image/png", data: data)
    }

    /// A JPEG screenshot.
    public static func jpeg(_ data: Data, name: String = "screenshot.jpg") -> IssueAttachment {
        IssueAttachment(name: name, contentType: "image/jpeg", data: data)
    }
}

/// App, OS and device facts attached to every report. No identifiers beyond the
/// bundle ID; the device model is the hardware identifier (`iPhone17,1`), not a name.
public struct DeviceContext: Sendable, Codable, Equatable {
    public var bundleIdentifier: String
    public var appVersion: String
    public var build: String
    public var channel: BuildChannel
    public var systemName: String
    public var systemVersion: String
    public var deviceModel: String
    public var locale: String
    public var timeZone: String
    public var isLowPowerModeEnabled: Bool

    public init(
        bundleIdentifier: String,
        appVersion: String,
        build: String,
        channel: BuildChannel,
        systemName: String,
        systemVersion: String,
        deviceModel: String,
        locale: String,
        timeZone: String,
        isLowPowerModeEnabled: Bool
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.appVersion = appVersion
        self.build = build
        self.channel = channel
        self.systemName = systemName
        self.systemVersion = systemVersion
        self.deviceModel = deviceModel
        self.locale = locale
        self.timeZone = timeZone
        self.isLowPowerModeEnabled = isLowPowerModeEnabled
    }

    /// The running app and device.
    public static func current(bundle: Bundle = .main, channel: BuildChannel) -> DeviceContext {
        let info = ProcessInfo.processInfo
        let version = info.operatingSystemVersion
        return DeviceContext(
            bundleIdentifier: bundle.bundleIdentifier ?? "unknown",
            appVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0",
            build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1",
            channel: channel,
            systemName: Self.systemName,
            systemVersion: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
            deviceModel: Self.hardwareModel(),
            locale: Locale.current.identifier,
            timeZone: TimeZone.current.identifier,
            isLowPowerModeEnabled: info.isLowPowerModeEnabled
        )
    }

    static var systemName: String {
        #if os(iOS)
        #if targetEnvironment(macCatalyst)
        return "macCatalyst"
        #else
        return "iOS"
        #endif
        #elseif os(macOS)
        return "macOS"
        #elseif os(visionOS)
        return "visionOS"
        #elseif os(watchOS)
        return "watchOS"
        #elseif os(tvOS)
        return "tvOS"
        #else
        return "unknown"
        #endif
    }

    /// `iPhone17,1`, `Mac16,6`, or the simulator's model identifier.
    static func hardwareModel() -> String {
        #if targetEnvironment(simulator)
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return "\(simulated) (simulator)"
        }
        #endif
        var systemInfo = utsname()
        uname(&systemInfo)
        let machine = withUnsafeBytes(of: &systemInfo.machine) { bytes -> String in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        return machine.isEmpty ? "unknown" : machine
    }
}

/// One report, as posted to the `report-issue` function (`schema` 1). The function
/// composes the issue title and markdown body server-side from these fields.
public struct IssueReport: Sendable, Codable, Equatable {
    public static let currentSchema = 1

    public var schema: Int
    public var kind: IssueKind
    public var title: String
    public var body: String
    /// Free-text contact the tester typed (name or email). Optional, shown in the issue.
    public var reporter: String?
    /// Random per-install UUID. Lets the function rate limit and group a tester's
    /// reports without identifying the person.
    public var reporterId: String
    public var createdAt: Date
    public var context: DeviceContext
    /// App-provided key/values (see ``FeedbackConfiguration/extraContext``).
    public var extra: [String: String]
    /// Recent log tail (see ``LogCollector``), already redacted by the unified log.
    public var log: String?
    public var attachments: [IssueAttachment]

    public init(
        kind: IssueKind,
        title: String,
        body: String,
        reporter: String? = nil,
        reporterId: String = ReporterIdentity.current(),
        createdAt: Date = Date(),
        context: DeviceContext,
        extra: [String: String] = [:],
        log: String? = nil,
        attachments: [IssueAttachment] = []
    ) {
        self.schema = Self.currentSchema
        self.kind = kind
        self.title = title
        self.body = body
        self.reporter = reporter
        self.reporterId = reporterId
        self.createdAt = createdAt
        self.context = context
        self.extra = extra
        self.log = log
        self.attachments = attachments
    }

    /// The JSON encoder the client uses (ISO 8601 dates, stable key order).
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

/// The per-install random identifier sent as ``IssueReport/reporterId``.
public enum ReporterIdentity {
    public static let defaultsKey = "portfolioFeedback.reporterId"

    /// Read or create the identifier in `defaults`.
    public static func current(defaults: UserDefaults = .standard) -> String {
        if let existing = defaults.string(forKey: defaultsKey), !existing.isEmpty {
            return existing
        }
        let fresh = UUID().uuidString.lowercased()
        defaults.set(fresh, forKey: defaultsKey)
        return fresh
    }
}
