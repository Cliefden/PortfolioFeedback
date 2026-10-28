import Foundation
import Testing
@testable import PortfolioFeedback

@Suite("BuildChannel.resolve")
struct BuildChannelTests {
    @Test("simulator wins over everything")
    func simulator() {
        let signals = BuildSignals(isSimulator: true, receiptName: "receipt", storeEnvironment: .production)
        #expect(BuildChannel.resolve(signals) == .xcode)
    }

    @Test("development profile → xcode, distribution profile → adHoc")
    func embeddedProfiles() {
        let dev = BuildSignals(embeddedProfile: ProvisioningProfile(getTaskAllow: true), receiptName: "sandboxReceipt")
        #expect(BuildChannel.resolve(dev) == .xcode)
        let adHoc = BuildSignals(embeddedProfile: ProvisioningProfile(getTaskAllow: false), receiptName: "sandboxReceipt", storeEnvironment: .sandbox)
        #expect(BuildChannel.resolve(adHoc) == .adHoc)
    }

    @Test("StoreKit environment decides TestFlight vs App Store when there is no profile")
    func storeEnvironment() {
        #expect(BuildChannel.resolve(BuildSignals(storeEnvironment: .sandbox)) == .testFlight)
        #expect(BuildChannel.resolve(BuildSignals(storeEnvironment: .production)) == .appStore)
        #expect(BuildChannel.resolve(BuildSignals(storeEnvironment: .xcode)) == .xcode)
        // StoreKit beats a disagreeing receipt name.
        #expect(BuildChannel.resolve(BuildSignals(receiptName: "sandboxReceipt", storeEnvironment: .production)) == .appStore)
    }

    @Test("receipt name is the last resort; nothing → unknown (not testing)")
    func receiptFallback() {
        #expect(BuildChannel.resolve(BuildSignals(receiptName: "sandboxReceipt")) == .testFlight)
        #expect(BuildChannel.resolve(BuildSignals(receiptName: "receipt")) == .appStore)
        #expect(BuildChannel.resolve(BuildSignals()) == .unknown)
        #expect(BuildChannel.unknown.isTesting == false)
    }

    @Test("isTesting")
    func isTesting() {
        #expect(BuildChannel.xcode.isTesting)
        #expect(BuildChannel.adHoc.isTesting)
        #expect(BuildChannel.testFlight.isTesting)
        #expect(!BuildChannel.appStore.isTesting)
    }

    @Test("visibility")
    func visibility() {
        #expect(FeedbackConfiguration.Visibility.automatic.allows(.testFlight))
        #expect(!FeedbackConfiguration.Visibility.automatic.allows(.appStore))
        #expect(!FeedbackConfiguration.Visibility.automatic.allows(.unknown))
        #expect(FeedbackConfiguration.Visibility.always.allows(.appStore))
        #expect(!FeedbackConfiguration.Visibility.never.allows(.xcode))
    }

    @Test("environment override forces the channel")
    func environmentOverride() async {
        let detector = BuildChannelDetector()
        let channel = await detector.channel(environment: [BuildChannelDetector.environmentOverrideKey: "testFlight"])
        #expect(channel == .testFlight)
        // Cached: a later call with a different environment returns the same value.
        let again = await detector.channel(environment: [:])
        #expect(again == .testFlight)
        await detector.reset()
        let afterReset = await detector.channel(environment: [BuildChannelDetector.environmentOverrideKey: "adHoc"])
        #expect(afterReset == .adHoc)
    }
}

@Suite("ProvisioningProfile")
struct ProvisioningProfileTests {
    private func profileData(entitlements: String, extra: String = "") -> Data {
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Name</key><string>Otta Dev</string>
            <key>Entitlements</key>
            <dict>\(entitlements)</dict>
            \(extra)
        </dict>
        </plist>
        """
        // Surround with junk bytes the way the CMS envelope does.
        var data = Data([0x30, 0x82, 0x1a, 0x2b, 0x06, 0x09])
        data.append(Data(plist.utf8))
        data.append(Data([0x00, 0xff, 0x31, 0x82]))
        return data
    }

    @Test("development profile")
    func development() {
        let data = profileData(entitlements: """
            <key>get-task-allow</key><true/>
            <key>aps-environment</key><string>development</string>
        """)
        let profile = ProvisioningProfile(data: data)
        #expect(profile == ProvisioningProfile(getTaskAllow: true, apsEnvironment: "development", provisionsAllDevices: false, name: "Otta Dev"))
    }

    @Test("enterprise / ad hoc profile")
    func distribution() {
        let data = profileData(
            entitlements: "<key>get-task-allow</key><false/><key>aps-environment</key><string>production</string>",
            extra: "<key>ProvisionsAllDevices</key><true/>"
        )
        let profile = ProvisioningProfile(data: data)
        #expect(profile?.getTaskAllow == false)
        #expect(profile?.apsEnvironment == "production")
        #expect(profile?.provisionsAllDevices == true)
    }

    @Test("garbage is nil")
    func garbage() {
        #expect(ProvisioningProfile(data: Data([1, 2, 3])) == nil)
        #expect(ProvisioningProfile(data: Data("<?xml version='1.0'?><plist".utf8)) == nil)
    }
}
