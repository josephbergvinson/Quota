# Quota

Quota is a small, local-first macOS dashboard for monitoring multiple ChatGPT Pro and OpenAI API accounts. It answers four practical questions: how much capacity is left, when it resets, which account to use next, and how usage has changed over time.

Quota is built with SwiftUI, AppKit, Charts, Security, and Foundation. It has no third-party runtime libraries. The dashboard is deliberately conservative: a provider value is either reported or visibly unavailable. Quota does not infer message counts, scrape private web endpoints, reuse browser cookies, or send billable probe requests.

## Install

### Download the app

The easiest option is the [latest GitHub Release](https://github.com/josephbergvinson/Quota/releases/latest):

1. Download `Quota-<version>-macOS-universal.zip`.
2. Expand the ZIP.
3. Drag `Quota.app` into the system **Applications** folder. You can instead use `~/Applications` for a per-user install that does not require an administrator password.
4. Follow the first-launch Gatekeeper step below.

The release is a universal app for both Apple silicon and Intel Macs. It is ad-hoc signed, not Developer ID signed or notarized, so macOS will not treat it like an App Store download.

The downloaded app requires macOS 14 or later.

### Build from source

You need:

- macOS 15.6 or later to run Xcode 26;
- the full Xcode 26 app with Swift 6.2 or later (open Xcode once after installing it); and
- for ChatGPT Pro accounts, a local Codex executable supplied by the [ChatGPT macOS app](https://openai.com/chatgpt/desktop/), the Codex app, or the [Codex CLI](https://developers.openai.com/codex/cli/). This last requirement is not needed for OpenAI API organization accounts.

In Terminal, run:

```sh
git clone https://github.com/josephbergvinson/Quota.git
cd Quota
make install
```

`make install` checks the prerequisites, builds a release version, creates an ad-hoc signed application at `~/Applications/Quota.app`, and opens it. It does not change the machine-wide `xcode-select` setting. Updating is the same process after pulling the latest source:

```sh
git pull
make install
```

Quota looks for Codex in the installed ChatGPT or Codex app first, then in the environment's `PATH` and common CLI install locations such as `~/.local/bin`, Homebrew, Volta, and NVM. It does not execute shell startup files. If Codex is not found, the installer warns rather than failing because OpenAI API organization accounts still work.

## Run and develop

The packaged app is the recommended way to use Quota because it has a stable bundle identifier:

```sh
open ~/Applications/Quota.app       # open the installed app
make run                            # rebuild a debug app and open it
make app CONFIGURATION=release      # rebuild without opening it
make build                          # compile a debug build
make test                           # run the core test suite
make dev                            # run the executable from Terminal
```

You can also open `Package.swift` in Xcode and select the `Quota` executable. `make dev` is convenient for development but keeps running in that Terminal window; use Control-C there to stop it.

### Gatekeeper and signing

Both the release download and the source-built app are ad-hoc signed rather than Developer ID signed or notarized by Apple. The downloaded release carries internet quarantine metadata, so on its first launch Control-click `Quota.app` and choose **Open**. If macOS still blocks it, try once, then use **System Settings → Privacy & Security → Open Anyway**. Confirm that the app came from this repository before allowing it, and do not disable Gatekeeper.

Building from source is the more transparent path and usually avoids the downloaded-app quarantine prompt because the application is compiled and signed locally on your Mac.

Running `make install` again replaces only `~/Applications/Quota.app`; it does not erase account history. Because each build has a new local signature, macOS may ask again for Keychain access after rebuilding.

## Provider support

| Account type | Connection | Data shown |
| --- | --- | --- |
| ChatGPT Pro | Browser sign-in handled by a locally installed Codex service | Signed-in identity and plan, reported Codex quota windows, used/remaining percentages, reset times, and daily aggregate token activity |
| OpenAI API organization | Admin API key from an organization owner | 30-day completions token/request history, model breakdown, and organization costs |

ChatGPT telemetry is the supported ChatGPT-backed **Codex** surface. It is not a general API for every quota in ChatGPT web, voice, images, deep research, or other products. Quota preserves the window names returned by Codex and leaves unsupported account-wide model breakdowns unavailable.

The Overview uses one common 7-day, 30-day, or all-reported-history range for its headline totals and chart. Total tokens include every account with daily provider data. Cached input, uncached input, and output cards and chart categories appear only when at least one connected provider reports those splits; otherwise the chart is total-only. The usage chart can switch between daily activity and a cumulative running total for the selected range.

OpenAI API organization usage and ChatGPT subscription usage are separate account types. An API organization key does not reveal a ChatGPT Pro subscription allowance.

Provider documentation:

- [OpenAI Codex app-server account, rate-limit, and usage methods](https://developers.openai.com/codex/app-server/)
- [OpenAI Codex authentication and Keychain-backed credential storage](https://developers.openai.com/codex/auth/)
- [OpenAI organization usage endpoints](https://developers.openai.com/api/reference/typescript/resources/admin/subresources/organization/subresources/usage)
- [OpenAI organization costs endpoint](https://developers.openai.com/api/reference/typescript/resources/admin/subresources/organization/subresources/usage/methods/costs)

## Reset planner

The Reset Planner is a compact rolling one-week-ahead calendar in the Mac's current time zone. It starts today and includes the same weekday next week; past dates are not included. It shows:

- each reported reset time;
- the account and provider;
- the provider window name;
- remaining capacity from the reading that supplied the event; and
- when that reading was captured.

Historical snapshots preserve past reset events. Quota does not project a repeating schedule from a single reset, so an empty day means “no reset was reported for this day,” not “no reset can occur.”

If a future reset is changed or removed by a newer reading before it occurs, the planner drops the superseded event. Completed resets remain in local history.

Codex can report unused placeholder windows whose reset time moves on every refresh. Quota omits those placeholders from capacity and calendar views while retaining real unused and active windows.

Quota's ChatGPT capacity and reset views are intentionally scoped to the regular Codex one-week window. Codex's separate GPT-5.3-Codex-Spark buckets and shorter-duration buckets are not part of regular account rotation planning.

## Local data and credentials

- Account metadata and usage history live at `~/Library/Application Support/Quota/quota-data.json`.
- The signed-in ChatGPT identity and plan are shown after a successful refresh, used to warn about duplicate connections, and kept only in memory rather than written to the history file.
- OpenAI Admin API keys are generic-password items in macOS Keychain and never enter the JSON data file.
- ChatGPT managed credentials are stored by Codex in macOS Keychain. Quota keeps each account's local Codex profile separate.
- Removing an Admin API account deletes its Quota Keychain item. Removing a ChatGPT account asks Codex to log out before deleting its local account directory and history.
- Quota does not collect analytics or upload your account history. Refreshing an account still contacts its provider.

The installer and rebuild commands replace the application bundle only. They do not delete the JSON history file, Codex account directories, or Keychain items.

## Architecture

The Swift package is split into a reusable core and a macOS UI:

```text
QuotaCore
  Models          typed availability, accounts, snapshots, quota windows
  Providers       ChatGPT, OpenAI Admin
  Networking      bounded URLSession client
  Persistence     atomic local JSON and Keychain credentials
  Analytics       aggregate capacity, recommendation, reset events
  Services        refresh registry and serialized repository mutations

Quota
  App             lifecycle and app state
  Features        overview, accounts, reset planner, settings
  Components      native reusable SwiftUI/AppKit presentation
```

Provider code depends on core models, never on SwiftUI or AppKit. The weekly planner consumes normalized `QuotaWindow` values and does not know which provider produced them. Adding a future provider therefore requires a connector plus mapping into `UsageSnapshot`, rather than restructuring the dashboard.

## Known limitations

- OpenAI API activity currently covers the completions usage resource plus total organization cost; other service-specific usage resources can be added independently.
- API rate-limit endpoints generally expose configured ceilings, not an exact live remaining token bucket, so Quota does not present them as live capacity.
- The ChatGPT integration uses Codex's documented app-server interface, which Codex currently labels experimental. Read-only refreshes retry one transient timeout or internal service error in a fresh process; persistent connection failures are shown and never replaced by guessed values.
- Readings older than six hours remain visible as historical values but are marked stale and excluded from “best account” recommendations until refreshed or recorded again.
- Account history stays on the current Mac; there is no built-in device sync.
- Public downloads are ad-hoc signed rather than Developer ID signed or notarized, so first launch requires the Gatekeeper step described above.
