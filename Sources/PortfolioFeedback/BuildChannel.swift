import Foundation
import StoreKit

/// How the running binary was installed. Decides whether the issue reporter is
/// shown at all: everything except ``appStore`` counts as a testing install.
///
/// Detection is done at runtime, not by build configuration, because a
/// TestFlight build *is* a Release build. The inputs are gathered in
/// ``BuildSignals`` and combined by ``resolve(_:)``, which is pure and tested;
/// ``BuildChannelDetector`` does the gathering (including the async StoreKit
/// lookup) and caches the answer for the process.
public enum BuildChannel: String, Sendable, Codable, CaseIterable, Hashable {
    /// Run from Xcode, the simulator, or a development-signed install.
    case xcode
    /// Ad hoc or enterprise distribution (an embedded profile without `get-task-allow`).
    case adHoc
    /// Installed through TestFlight (sandbox App Store environment, no embedded profile).
    case testFlight
    /// Installed from the App Store.
    case appStore
    /// Nothing conclusive. Treated as **not** testing so the row never leaks into
    /// a production install by accident.
    case unknown

    /// `true` for ``xcode``, ``adHoc`` and ``testFlight``.
    public var isTesting: Bool {
        switch self {
        case .xcode, .adHoc, .testFlight: true
        case .appStore, .unknown: false
        }
    }

    /// Combine the signals. Order matters: the simulator and an embedded profile
    /// are definitive, the App Store environment is next, the receipt file name
    /// is the last resort.
    public static func resolve(_ signals: BuildSignals) -> BuildChannel {
        if signals.isSimulator { return .xcode }
        if signals.storeEnvironment == .xcode { return .xcode }
        if let profile = signals.embeddedProfile {
            // TestFlight and App Store installs are re-signed by Apple and carry no
            // embedded.mobileprovision, so any profile means a developer install.
            return profile.getTaskAllow ? .xcode : .adHoc
        }
        switch signals.storeEnvironment {
        case .sandbox: return .testFlight
        case .production: return .appStore
        default: break
        }
        switch signals.receiptName {
        case "sandboxReceipt": return .testFlight
        case "receipt": return .appStore
        default: return .unknown
        }
    }
}

/// The raw facts ``BuildChannel/resolve(_:)`` works from. Built by
/// ``BuildSignals/local(bundle:)``; tests construct them directly.
public struct BuildSignals: Sendable, Equatable {
    public var isSimulator: Bool
    /// Parsed `embedded.mobileprovision`, present only on developer installs.
    public var embeddedProfile: ProvisioningProfile?
    /// Last path component of the App Store receipt URL (`receipt` or
    /// `sandboxReceipt`), when the bundle reports one.
    public var receiptName: String?
    /// From StoreKit 2's `AppTransaction`, when it has been consulted.
    public var storeEnvironment: StoreEnvironment?

    public init(
        isSimulator: Bool = false,
        embeddedProfile: ProvisioningProfile? = nil,
        receiptName: String? = nil,
        storeEnvironment: StoreEnvironment? = nil
    ) {
        self.isSimulator = isSimulator
        self.embeddedProfile = embeddedProfile
        self.receiptName = receiptName
        self.storeEnvironment = storeEnvironment
    }

    /// Everything that can be read synchronously from the bundle. Does not touch
    /// StoreKit; ``BuildChannelDetector`` adds that when the local facts are
    /// inconclusive.
    public static func local(bundle: Bundle = .main) -> BuildSignals {
        #if targetEnvironment(simulator)
        let simulator = true
        #else
        let simulator = false
        #endif
        var profile: ProvisioningProfile?
        if let url = bundle.url(forResource: "embedded", withExtension: "mobileprovision") ??
            bundle.url(forResource: "embedded", withExtension: "provisionprofile"),
           let data = try? Data(contentsOf: url) {
            profile = ProvisioningProfile(data: data)
        }
        // Deprecated since iOS 18 in favour of AppTransaction, but still populated
        // and the only synchronous signal that separates TestFlight from the store.
        let receiptName = bundle.appStoreReceiptURL?.lastPathComponent
        return BuildSignals(isSimulator: simulator, embeddedProfile: profile, receiptName: receiptName)
    }
}

/// The App Store environment the binary was signed for, as StoreKit 2 reports it.
public enum StoreEnvironment: String, Sendable, Codable, Equatable {
    case xcode, sandbox, production

    /// `AppTransaction.shared`, with a timeout so a slow StoreKit never holds up the UI.
    /// Returns `nil` on failure or timeout. Only call this when the local signals are
    /// inconclusive (no simulator, no embedded profile): on a TestFlight or App Store
    /// install the transaction is already on the device and no sign-in prompt appears.
    public static func fromAppTransaction(timeout: Duration = .seconds(5)) async -> StoreEnvironment? {
        await withTaskGroup(of: StoreEnvironment?.self) { group in
            group.addTask {
                guard let result = try? await AppTransaction.shared else { return nil }
                switch result {
                case .verified(let transaction), .unverified(let transaction, _):
                    return StoreEnvironment(transaction.environment)
                }
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    init?(_ environment: AppStore.Environment) {
        switch environment {
        case .xcode: self = .xcode
        case .sandbox: self = .sandbox
        case .production: self = .production
        default: return nil
        }
    }
}

/// The parts of an `embedded.mobileprovision` that matter for channel detection.
///
/// The profile is a CMS-signed blob with the plist inside as plain XML, so it is
/// cut out between `<?xml` and `</plist>` rather than verifying the signature
/// (the same approach Vivum's `PushEnvironment` uses).
public struct ProvisioningProfile: Sendable, Equatable {
    /// `get-task-allow` entitlement: `true` on development profiles, `false` on ad hoc / enterprise.
    public var getTaskAllow: Bool
    /// `aps-environment` entitlement (`development` / `production`), when present.
    public var apsEnvironment: String?
    /// `ProvisionsAllDevices` (enterprise distribution).
    public var provisionsAllDevices: Bool
    /// Profile name, for diagnostics.
    public var name: String?

    public init(getTaskAllow: Bool, apsEnvironment: String? = nil, provisionsAllDevices: Bool = false, name: String? = nil) {
        self.getTaskAllow = getTaskAllow
        self.apsEnvironment = apsEnvironment
        self.provisionsAllDevices = provisionsAllDevices
        self.name = name
    }

    public init?(data: Data) {
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex) else {
            return nil
        }
        let plistData = data.subdata(in: start.lowerBound..<end.upperBound)
        guard let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any] else {
            return nil
        }
        let entitlements = plist["Entitlements"] as? [String: Any] ?? [:]
        self.init(
            getTaskAllow: entitlements["get-task-allow"] as? Bool ?? false,
            apsEnvironment: entitlements["aps-environment"] as? String,
            provisionsAllDevices: plist["ProvisionsAllDevices"] as? Bool ?? false,
            name: plist["Name"] as? String
        )
    }
}

/// Detects the channel once per process and caches it.
///
/// ```swift
/// let channel = await BuildChannelDetector.current()
/// if channel.isTesting { … }
/// ```
///
/// `PORTFOLIO_FEEDBACK_CHANNEL=testFlight` in the environment (a scheme setting
/// or UI-test launch environment) forces a value for previews and tests.
public actor BuildChannelDetector {
    public static let shared = BuildChannelDetector()

    public static let environmentOverrideKey = "PORTFOLIO_FEEDBACK_CHANNEL"

    private var cached: BuildChannel?
    private var inFlight: Task<BuildChannel, Never>?

    public init() {}

    /// The process's channel (cached after the first call).
    public static func current() async -> BuildChannel {
        await shared.channel()
    }

    public func channel(bundle: Bundle = .main, environment: [String: String] = ProcessInfo.processInfo.environment) async -> BuildChannel {
        if let cached { return cached }
        if let inFlight { return await inFlight.value }
        let task = Task<BuildChannel, Never> {
            if let raw = environment[Self.environmentOverrideKey], let forced = BuildChannel(rawValue: raw) {
                return forced
            }
            var signals = BuildSignals.local(bundle: bundle)
            let inconclusive = !signals.isSimulator && signals.embeddedProfile == nil
            if inconclusive {
                signals.storeEnvironment = await StoreEnvironment.fromAppTransaction()
            }
            return BuildChannel.resolve(signals)
        }
        inFlight = task
        let value = await task.value
        cached = value
        inFlight = nil
        return value
    }

    /// Drop the cached value (tests).
    public func reset() {
        cached = nil
        inFlight = nil
    }
}
