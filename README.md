# Quota

Quota is a small, local-first macOS dashboard for monitoring multiple ChatGPT Plus/Pro, Claude Pro/Max, OpenAI API, and Anthropic API accounts. It answers four practical questions: how much capacity is left, when it resets, which account to use next, and how usage has changed over time.

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
- for ChatGPT Plus or Pro accounts, a local Codex executable supplied by the [ChatGPT macOS app](https://openai.com/chatgpt/desktop/), the Codex app, or the [Codex CLI](https://developers.openai.com/codex/cli/); and
- for Claude Pro or Max accounts, a current, Anthropic-signed Claude Code executable supplied by [Claude Desktop](https://claude.ai/download) or the [Claude Code installer](https://code.claude.com/docs/en/quickstart).

The local provider clients are needed only for their respective subscription account types. OpenAI and Anthropic API organization accounts do not require either one.

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

Quota looks for Codex and Claude Code in their installed apps first, then in the environment's `PATH` and their standard native CLI locations. It does not execute shell startup files. A missing local client affects only that provider's subscription connection; the rest of Quota remains usable.

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
| ChatGPT Plus or Pro | Browser sign-in handled by a locally installed Codex service | Signed-in identity and provider-reported plan when available, reported Codex quota windows, used/remaining percentages, reset times, banked resets and their reported expiries, and daily aggregate token activity |
| Claude Pro or Max | Browser sign-in handled by a locally installed, Anthropic-signed Claude Code client | Signed-in identity and provider-reported plan when available, reported 5-hour and all-model weekly windows, optional reported model-specific windows, remaining percentages, and reset times |
| OpenAI API organization | Admin API key from an organization owner | 30-day completions token/request history, model breakdown, and organization costs |
| Anthropic API organization | Anthropic Admin API key for a Claude Console organization | 30-day message token history, model breakdown, and reported costs (excluding Priority Tier) |

ChatGPT telemetry is the supported ChatGPT-backed **Codex** surface. It is not a general API for every quota in ChatGPT web, voice, images, deep research, or other products. Quota preserves the window names returned by Codex and leaves unsupported account-wide model breakdowns unavailable.

When Codex reports earned banked resets, Quota shows the provider's authoritative available count on the account. Credit details can be unavailable or capped, and individual credits may not expire, so Quota labels missing expiry details instead of deriving them from the count.

The Overview uses one common 7-day, 30-day, or all-reported-history range for its headline totals and chart. Total tokens include every account with daily provider data. Cached input, uncached input, and output cards and chart categories appear only when at least one connected provider reports those splits; otherwise the chart is total-only. The usage chart can switch between daily activity and a cumulative running total for the selected range.

API organization usage and consumer subscription usage are separate account types. An OpenAI organization key does not reveal a ChatGPT Plus/Pro allowance, and an Anthropic key for a Claude Console organization does not reveal a Claude Pro/Max allowance.

Claude subscription accounts use the same Claude.ai sign-in as Claude Code—never an Anthropic API key. Quota creates a separate Claude Code configuration directory for every account. Claude Code normally stores that profile's OAuth session in macOS Keychain and can use its documented permission-restricted credentials-file fallback; Quota does not read or copy either credential. If the automatic browser return fails, the in-progress account view exposes Claude Code's official code-based fallback and submits that code only to the same running sign-in process. Anthropic currently marks the machine-readable usage control as experimental, so Quota detects support at runtime, accepts additive response changes, and leaves values unavailable if Claude Code stops reporting them.

Claude Code does not currently provide Quota with daily subscription token history, costs, requests, or banked resets. Those sections stay hidden or explicitly say that token history was not reported—Quota does not derive them from utilization percentages. When optional usage credits are enabled and reported, Quota shows that allowance separately and does not invent a reset date.

Provider documentation:

- [OpenAI Codex app-server account, rate-limit, and usage methods](https://developers.openai.com/codex/app-server/)
- [OpenAI Codex authentication and Keychain-backed credential storage](https://developers.openai.com/codex/auth/)
- [OpenAI organization usage endpoints](https://developers.openai.com/api/reference/typescript/resources/admin/subresources/organization/subresources/usage)
- [OpenAI organization costs endpoint](https://developers.openai.com/api/reference/typescript/resources/admin/subresources/organization/subresources/usage/methods/costs)
- [Claude Code authentication](https://code.claude.com/docs/en/authentication)
- [Claude Code environment isolation with `CLAUDE_CONFIG_DIR`](https://code.claude.com/docs/en/env-vars)
- [Using Claude Code with a Claude Pro or Max plan](https://support.claude.com/en/articles/11145838-use-claude-code-with-your-pro-or-max-plan)
- [Anthropic Admin API](https://platform.claude.com/docs/en/manage-claude/admin-api)
- [Anthropic Usage and Cost API](https://platform.claude.com/docs/en/manage-claude/usage-cost-api)

## Reset planner

The Reset Planner is a compact rolling one-week-ahead calendar in the Mac's current time zone. It starts today and includes the same weekday next week; past dates are not included. It shows:

- each reported reset time;
- the account and provider;
- the provider window name;
- remaining capacity from the reading that supplied the event; and
- when that reading was captured.

Historical snapshots preserve past reset events. Quota does not project a repeating schedule from a single reset, so an empty day means “no reset was reported for this day,” not “no reset can occur.”

Banked-reset expiries stay on the Overview and account detail views. They are not placed on this calendar because an expiry removes a saved reset; it does not reset quota capacity.

If a future reset is changed or removed by a newer reading before it occurs, the planner drops the superseded event. Completed resets remain in local history.

Codex can report unused placeholder windows whose reset time moves on every refresh. Quota omits those placeholders from capacity and calendar views while retaining real unused and active windows.

Quota shows the regular Codex one-week window for ChatGPT Pro. For ChatGPT Plus, it also shows the regular five-hour window when Codex reports it. GPT-5.3-Codex-Spark and unrelated buckets remain outside regular account rotation planning.

## Local data and credentials

- Account metadata and usage history live at `~/Library/Application Support/Quota/quota-data.json`.
- Signed-in provider identities and raw plan labels are shown after a successful refresh and used to warn about duplicate connections; those raw values stay in memory. Quota persists the normalized account type (for example, ChatGPT Plus or Claude Max) with local account metadata so it remains accurate after relaunch.
- OpenAI and Anthropic Admin API keys are generic-password items in macOS Keychain and never enter the JSON data file.
- When an Admin API account is added, Quota saves its reconnectable account record before writing the Keychain item. If Keychain rejects the key, Quota rolls that record back; if rollback is also unavailable, the keyless account remains visible so it can be repaired or removed.
- ChatGPT managed credentials are stored by Codex in macOS Keychain. Quota keeps each account's local Codex profile separate.
- Claude managed credentials are owned by Claude Code, normally in macOS Keychain with its documented permission-restricted file fallback. Quota gives each account a stable, separate profile and never writes those credentials to its history.
- Removal is fail-closed: Quota deletes an Admin API account's Keychain item, or signs a managed ChatGPT/Claude profile out and deletes it, before removing the account and its history. If secure cleanup cannot be confirmed, the account and history stay visible so Remove Account can safely be tried again. A failure while saving the final metadata removal can leave a visible account whose credential or managed profile has already been cleared; it can be reconnected or removed again. Removing a managed account does not cancel the underlying subscription.
- Quota does not collect analytics or upload your account history. Refreshing an account still contacts its provider.

The installer and rebuild commands replace the application bundle only. They do not delete the JSON history file, Codex or Claude Code account directories, or Keychain items.

## Architecture

The Swift package is split into a reusable core and a macOS UI:

```text
QuotaCore
  Models          typed availability, accounts, snapshots, quota windows
  Providers       ChatGPT, Claude Code, OpenAI Admin, Anthropic Admin
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
- Anthropic API organization activity covers the Claude Console Messages Usage and Cost reports. Anthropic does not expose those organization reports for individual consumer accounts, does not include Priority Tier charges in the cost report, and does not report an exact live remaining allowance or fixed reset through those endpoints.
- API rate-limit endpoints generally expose configured ceilings, not an exact live remaining token bucket, so Quota does not present them as live capacity.
- The ChatGPT integration uses Codex's documented app-server interface, which Codex currently labels experimental. Read-only refreshes retry one transient timeout or internal service error in a fresh process; persistent connection failures are shown and never replaced by guessed values.
- The Claude integration uses an experimental structured usage control exposed by current Claude Code and the official Agent SDK. Quota capability-checks the response and preserves the last successful reading when the control is unavailable or changes, but an Anthropic update can temporarily require a Quota update.
- Claude subscription usage exposes current rate-limit windows, not a complete historical token feed. Quota stores successful capacity readings locally but does not present those readings as provider-reported token history.
- Readings older than six hours remain visible as historical values but are marked stale and excluded from “best account” recommendations until refreshed or recorded again.
- Account history stays on the current Mac; there is no built-in device sync.
- Public downloads are ad-hoc signed rather than Developer ID signed or notarized, so first launch requires the Gatekeeper step described above.
