<p align="center">
  <img src="docs/patina-mark-brass.svg" alt="Patina" width="96" />
</p>

# Patina

A macOS app that watches how you work, learns your patterns, and tells you when it can do a task for you.

<img src="docs/screenshot.png" alt="Patina menu bar" width="200">

Patina reads the accessibility tree to observe which apps you use, what you click, and what you repeat. It sends structured metadata to a cloud LLM to detect patterns. When it is confident it can perform a step, it asks. You say yes or no — and then it does it. The human never prompts. The AI volunteers.

## What it observes

- Which app is active (bundle ID and name)
- Window titles (credentials redacted, file paths collapsed before transmission)
- Focused UI element role and label (e.g. "button: Save", "text_field: Invoice Number")
- Timestamps and app switch events
- **Browser URL of the focused tab** — off by default. When you turn on "Capture Browser URLs" in the Data Capture menu, Patina reads the URL of the focused tab in Safari, Safari Technology Preview, Chrome, Chrome Canary, Brave, Edge, Arc, and Firefox via the macOS accessibility API. Query strings, usernames, and passwords are stripped at capture; path and fragment are kept.

## What it does not observe

- Screenshots or screen recordings — never
- Password fields — `AXSecureTextField` and heuristic detection for Electron apps
- Password manager apps — 1Password, Bitwarden, LastPass, Dashlane, KeePassXC, Enpass excluded by default
- File contents, audio, or camera
- Raw field values are not sent to the LLM — only element roles and labels

## What leaves your Mac

Nothing, until you configure analysis. With a trial, license, or your own API key, the analyzer sends a sanitized observation summary to a cloud LLM (Together AI by default). The summary contains:

- App names, element roles, element labels, sanitized window titles, event types, and timestamps
- No screenshots, no raw text field values, no clipboard content, no passwords, no credentials (scanned and redacted; see `src/CredentialDetector.swift`)
- No file paths from window titles

**Browser URLs only if you opt in.** With "Capture Browser URLs" off (the default), no URL data is collected or transmitted. With it on, Patina runs a local pass before sending anything to the LLM. URLs from six known hosts are replaced with opaque IDs and the raw URL never leaves your Mac:

- `mail.google.com` → `thread:<id>` (from fragment)
- `docs.google.com` → `doc:<id>` or `sheet:<id>[/gid:<tab>]`
- `github.com` → `gh:<owner>/<repo>/pr/<n>` or `.../issue/<n>`
- `gist.github.com` → `gist:redacted` (the gist ID is an access credential — never emitted)
- `app.slack.com` → `slack:<team>/<channel>`
- `notion.so` → `notion:page/<32hex>` (slug dropped)

For URLs from any other host, the sanitized URL (path + fragment kept, query + userinfo dropped) is wrapped in `<url>...</url>` tags in the prompt. The prompt header tells the LLM to treat content inside those tags as untrusted data. See `src/URLEntityExtractor.swift` for the six host rules and `src/Analyzer.swift` for the fence.

macOS exposes the URL bar to accessibility clients regardless of the browser's privacy mode. With URL capture on, Safari Private and Chrome Incognito tabs are read the same as normal tabs.

See `src/Analyzer.swift` `buildPrompt()` for the full payload.

Without any analysis mode configured, Patina observes and stores locally. Nothing is sent anywhere.

The app requests `com.apple.security.network.client` (see `Patina.entitlements`) for the LLM connection. No other network access.

## Build from source

Requires macOS 14+ and Xcode Command Line Tools (`xcode-select --install`). Builds on Apple Silicon. Intel not tested.

```bash
git clone https://github.com/MariusAure/patina.work.git
cd patina.work
./build.sh        # Compiles src/*.swift → ./patina binary
./bundle.sh       # Wraps binary in Patina.app bundle
open Patina.app   # Launch — grant Accessibility access when prompted
```

The build uses `swiftc` directly. No Xcode project, no SPM fetch, no dependencies beyond system frameworks and SQLite.

## Install from release

Download from [patina.work](https://patina.work). The page publishes the current binary and a SHA-256 file next to it.

Verify the download before you open it:

```bash
cd ~/Downloads
shasum -a 256 -c patina-0.1.0-arm64.zip.sha256
# expect: patina-0.1.0-arm64.zip: OK
```

The app is currently unsigned. Code-signing and notarization are in progress. Until they land, the SHA-256 file is the only proof that the binary you downloaded is the binary the site served — it does **not** prove the binary matches the source in this repo. Reproducible builds are not wired up yet.

After download:

1. `unzip patina-0.1.0-arm64.zip`
2. Move `Patina.app` to `/Applications`
3. Right-click the app → Open (first launch only, because it is unsigned)
4. Grant Accessibility access when prompted
5. Look for the dot in your menu bar

If you want to avoid the unsigned binary entirely, build from source (section above).

## Architecture

| File | What it does |
|------|-------------|
| `Observer.swift` | Reads accessibility tree via AX APIs. Writes observations to SQLite. |
| `Database.swift` | SQLite storage. Observations, patterns, settings, coverage log. |
| `Sanitize.swift` | Strips file paths, URLs, emails from text before logging or LLM. |
| `CredentialDetector.swift` | Detects API keys, JWTs, credit cards, connection strings. Defense in depth. |
| `URLEntityExtractor.swift` | Pure function: 6 host rules that reduce Gmail/Docs/Sheets/GitHub/Gist/Slack/Notion URLs to opaque IDs before prompt build. |
| `Analyzer.swift` | Sends batched observations to Together AI. Parses pattern responses. URL rows are fenced in `<url>...</url>` with a prompt-header instruction to treat the content as untrusted data. |
| `Notifier.swift` | macOS notifications for detected patterns. Rate-limited to 2/day. |
| `MenuBar.swift` | Menu bar UI. Stats, pause/resume, patterns, activity log. |
| `LogViewer.swift` | Activity log window. Search, filter, delete observations. |
| `Onboarding.swift` | First-run flow. Explains what Patina does, requests AX permission. |
| `PatternExporter.swift` | Exports patterns as markdown with credential redaction. |
| `License.swift` | Local license key validation. `pat_` + 32 hex chars. |
| `main.swift` | App entry point. Sets up DB, observer, analyzer, menu bar. |

## Data storage

All data is in `~/Library/Application Support/Patina/patina.db` (SQLite). You can query it directly:

```bash
sqlite3 ~/Library/Application\ Support/Patina/patina.db \
  'SELECT app_name, COUNT(*) c FROM observations GROUP BY app_name ORDER BY c DESC LIMIT 10;'
```

Delete everything from the Activity Log (menu bar > View Activity Log > Delete All), or:

```bash
sqlite3 ~/Library/Application\ Support/Patina/patina.db 'DELETE FROM observations;'
```

## License

MIT. See [LICENSE](LICENSE).

Built by [Trout Technologies AS](https://patina.work). Security issues: see [SECURITY.md](SECURITY.md).
