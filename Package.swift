// swift-tools-version: 6.0
import PackageDescription

// In-app issue reporting for internal testing builds (TestFlight, Xcode, ad hoc).
// A "Report an issue" row that renders nothing in App Store builds, a sheet
// that collects title/description/kind plus app, device and recent-log
// context, and a client that posts the report to the portfolio's
// `report-issue` edge function (supabase-shared `github.ts`), which holds the
// GitHub credential and files the issue in the app's repo. The app never
// carries a GitHub token.
//
// Apple frameworks only (Foundation, SwiftUI, StoreKit, OSLog). No dependencies.
// See _standard/SHARED_PACKAGES_SURVEY.md §1.10 and README.md.
let package = Package(
    name: "PortfolioFeedback",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
        .visionOS(.v1),
    ],
    products: [
        .library(name: "PortfolioFeedback", targets: ["PortfolioFeedback"]),
    ],
    targets: [
        .target(
            name: "PortfolioFeedback",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "PortfolioFeedbackTests",
            dependencies: ["PortfolioFeedback"]
        ),
    ]
)
