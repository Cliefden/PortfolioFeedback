# PortfolioFeedback

In-app issue reporting for **testing builds only**. A settings row that is invisible in
App Store installs, a sheet where a tester describes the problem, and a client that
posts the report (with app version, device, OS, locale and the app's recent log tail)
to the portfolio's `report-issue` edge function, which files it as a GitHub issue in
the app's repo. Survey item §1.10 in `Celiador/_standard/SHARED_PACKAGES_SURVEY.md`.

- swift-tools 6.0 (Swift 6 language mode), iOS 17 / macOS 14 / visionOS 1
- Apple frameworks only (Foundation, SwiftUI, StoreKit, OSLog); no dependencies
- One library product, `PortfolioFeedback`
- Resources: `Localizable.xcstrings` (`en` + `sv` draft, `needs_review`)
- Tests use Swift Testing with an injected `HTTPDataLoader`; no test touches the network

```swift
.package(url: "https://github.com/Cliefden/PortfolioFeedback.git", from: "0.1.0")
// or, during adoption: .package(path: "../PortfolioFeedback")
```

**The app never carries a GitHub token.** The server half lives in
[`supabase-shared/src/github.ts`](../supabase-shared/src/github.ts) (`reportIssue`),
deployed once as `report-issue`. The app only knows the function URL, its own *app key*
(the key in the function's `ISSUE_APPS` map) and the stack's anon key. An extracted app
key lets someone file rate-limited, labelled issues in that one repo, nothing else.

## Adoption (two lines per app)

```swift
import PortfolioFeedback

// 1. Put the configuration in the environment, above the settings screen (or at the root).
SettingsView()
    .portfolioFeedback(FeedbackConfiguration(
        endpoint: URL(string: "https://vivum.crawik.com/functions/v1/report-issue")!,
        appKey: "otta",
        anonKey: Secrets.supabaseAnonKey,          // the stack that hosts report-issue
        extraContext: { ["plan": store.plan.rawValue, "locations": "\(locations.count)"] }
    ))

// 2. Add the row where the About / version rows are.
Section("About") {
    InfoRow("Version", Bundle.main.versionAndBuild)
    ReportIssueRow()                               // nothing is rendered in App Store builds
}
```

Then add the app to the function's `ISSUE_APPS` (see the supabase-shared README) and
create the labels `from-app`, `kind:bug`, `kind:idea`, `kind:question`,
`channel:testFlight`, `channel:xcode`, `channel:adHoc` in the repo (GitHub creates
missing labels on the fly when the token has write access, so this is optional).

## Which builds show the row

`BuildChannel` is detected at **runtime**, never from `#if DEBUG`, because a TestFlight
build is a Release build:

| Signal | Channel |
|---|---|
| Simulator | `xcode` |
| `embedded.mobileprovision` with `get-task-allow` | `xcode` |
| `embedded.mobileprovision` without it (ad hoc / enterprise) | `adHoc` |
| No profile, `AppTransaction.environment == .sandbox` | `testFlight` |
| No profile, `.production` | `appStore` |
| StoreKit unavailable → receipt file name `sandboxReceipt` / `receipt` | `testFlight` / `appStore` |
| Nothing conclusive | `unknown` (treated as **not** testing) |

`FeedbackConfiguration.Visibility` is `.automatic` (testing channels only) by default;
`.always` is for development, `.never` keeps the configuration but hides the UI. The
server enforces the app key and an optional bundle-ID allowlist as a second layer.
`PORTFOLIO_FEEDBACK_CHANNEL=testFlight` in the launch environment forces a channel for
previews and UI tests.

The StoreKit lookup is only made when the local signals are inconclusive (no simulator,
no embedded profile), i.e. on TestFlight and App Store installs, where the app
transaction is already on the device and no sign-in prompt can appear. It has a 5 s
timeout and the result is cached for the process (`BuildChannelDetector`).

## What a report contains

`IssueReport` (JSON `schema` 1), composed by `ReportIssueView`:

| Field | Source |
|---|---|
| `kind` | Bug / Idea / Question picker |
| `title`, `body` | the tester |
| `reporter` | optional free-text contact the tester typed |
| `reporterId` | random per-install UUID (`UserDefaults` key `portfolioFeedback.reporterId`); rate limiting and grouping, not identity |
| `context` | bundle ID, version, build, channel, OS, hardware model (`iPhone17,1`), locale, time zone, Low Power Mode |
| `extra` | `FeedbackConfiguration.extraContext()` — app-provided key/values; never user data |
| `log` | `LogCollector.recent` — the last 15 min of the app's own `os.Logger` output (subsystem = bundle ID, the `AppTelemetry.AppLog` default), tail-trimmed to 24 000 chars. Values logged with `privacy: .private` arrive as `<private>`. The tester can switch it off. |
| `attachments` | whatever the app passes (`ReportIssueRow(attachments:)` / `ReportIssueView(attachments:)`), e.g. `.png(screenshotData)`. Downscale first; the server caps 3 × 2 MB. |

The function builds the issue title (`[Bug] …`), a Markdown body with a context table
and the log in a collapsed block, and labels `from-app`, `kind:<kind>`, `channel:<channel>`.

## API

| Area | Types |
|---|---|
| Channel | `BuildChannel`, `BuildSignals`, `StoreEnvironment`, `ProvisioningProfile`, `BuildChannelDetector` |
| Report | `IssueReport`, `IssueKind`, `DeviceContext`, `IssueAttachment`, `ReporterIdentity` |
| Logs | `LogCollector`, `LogOptions`, `LogRecord` |
| Client | `IssueReporter`, `IssueReceipt`, `IssueReporterError`, `HTTPDataLoader` |
| UI | `ReportIssueRow`, `DefaultReportIssueLabel`, `ReportIssueView`, `FeedbackConfiguration`, `View.portfolioFeedback(_:)`, `EnvironmentValues.portfolioFeedback` |

### Own trigger (shake, debug menu, screenshot)

```swift
@State private var report = false

.onShake { report = true }                       // app-provided gesture
.sheet(isPresented: $report) {
    ReportIssueView(channel: channel, attachments: [.png(ImageDownscaler.png(of: snapshot))])
}
```

`ReportIssueView` needs the configuration in the environment and a `BuildChannel`
(`await BuildChannelDetector.current()`); check `channel.isTesting` yourself when you
present it directly.

### Errors shown to the tester

`IssueReporterError` is `LocalizedError`: `rejected(status, code)` for a `{error}` body,
`rateLimited(retryAfter)` for 429, `transport` when offline, `invalidResponse` otherwise.
The sheet shows `errorDescription` in an alert and stays open so nothing typed is lost.

## Tests

```sh
swift test                                  # 26 tests: channel matrix, profile parsing, JSON shape, log formatting, client
xcodebuild -scheme PortfolioFeedback -destination 'generic/platform=iOS Simulator' build
```

## Server setup (once per portfolio)

See `supabase-shared/README.md` → **GitHub issues from the app**. In short: vendor
supabase-shared ≥ 0.2.0 into the hosting stack, copy `examples/report-issue/` to
`supabase/functions/report-issue/`, set `ISSUE_APPS`, a GitHub App (or fine-grained
PAT with Issues read/write) and optionally `ISSUE_ATTACHMENTS_BUCKET`, deploy.

The portfolio's deployment lives in the Vivum repo (`supabase/functions/report-issue`,
`deploy/cliefden/issue-apps.json` for the app keys, `deploy/cliefden/report-issue-deploy.sh`
to deploy) and answers at `https://vivum.crawik.com/functions/v1/report-issue`. To add an
app: `openssl rand -hex 16`, add the key with the repo and bundle IDs to `issue-apps.json`,
re-run the deploy script, and put the key in the app's `FeedbackConfiguration`.
