# Security Policy

## Privacy by Design

- **All processing is local.** Text recognition, translation, summaries, naming files by content, scanning and every other feature run on your Mac.
- **No network calls.** Toolchest opens no connections. Translation and summaries use Apple's on-device frameworks.
- **No keystroke or clipboard recording.** Clipboard auto-clear reads only the pasteboard change count. The event tap matches only the combinations of the features you turned on and passes everything else through.
- **No telemetry, no analytics, no accounts, no cloud.**
- **Nothing stays that should not.** Everything Toolchest changes on the system (the Caps Lock mapping, power assertions, overlays, the extension secrets) is put back when Toolchest quits or the feature is turned off.

## Permissions

| Permission | Why | Scope |
|------------|-----|-------|
| **Accessibility** | Event taps for Finder keys, the quit guard, Dock clicks and Cleaning Mode; reading the Dock, menus and Notification Center | Only while a feature that needs it is on |
| **Input Monitoring** | Listening for key presses for the Hyper key and mute while typing | Only while those features are on |
| **Screen & System Audio Recording** | Capture Text, Capture and Translate, code scanning | The region you select, one frame per capture |
| **Automation** (Finder, System Events, Mail) | Current folder and selection, Dark Mode, Mail message links | Asked at first use, per app |
| **Finder extension** | Right-click menu in Finder | Sandboxed |

Toolchest asks macOS for each permission through the system request API and never flips a privacy switch itself. A missing permission pauses the feature.

## Stored Data

| Data | Location |
|------|----------|
| Settings | `~/Library/Preferences/info.gabrimatic.toolchest.plist` |
| New File templates | `~/Library/Application Support/Toolchest/Templates` |
| Extension secrets | `~/Library/Application Support/Toolchest/IPC`, rewritten at every start and deleted on quit |

`defaults delete info.gabrimatic.toolchest` resets everything.

## Trust Boundaries

| Boundary | Trust Level | Notes |
|----------|-------------|-------|
| Toolchest app | Trusted | Built from this repository; runs with your user's rights |
| Finder extension and widget extension | Sandboxed | Each may look up one Mach port and read one secret file, nothing else |
| Messages from the extensions | Authenticated, then validated | Each carries a fresh 256-bit secret from an owner-only file in `~/Library/Application Support/Toolchest/IPC`, rewritten at every start and deleted on quit. Toolchest then re-checks that the module and feature are on, Finder is in front, and every path exists, is in Finder's selection or shown folder, and is a real folder (symlinks resolved) |
| File writes | Never overwrite | `O_CREAT\|O_EXCL\|O_NOFOLLOW`; the photo copy is staged privately and moved with `renamex_np(RENAME_EXCL)` |
| Captured text | Untrusted input | Tidying uses plain rules, so text in a screenshot cannot steer it. Summaries are labelled as model output and never replace the exact text |
| Apple frameworks | System | Vision, Translation, Apple Intelligence run on device |
| Release downloads | Ad hoc signed | Not notarized; checksums are in `SHA256SUMS.txt` on each release page, and `install.sh` verifies them |

## Verifying a Download

```bash
shasum -a 256 -c SHA256SUMS.txt --ignore-missing
codesign --verify --strict --verbose=2 /Applications/Toolchest.app
```

`install.sh` runs the same checks before it installs anything.

## Supported Versions

Only the latest release receives fixes.

## Vulnerability Reporting

Report vulnerabilities responsibly:

1. **Do not open a public issue.**
2. Use [GitHub's private vulnerability reporting](https://github.com/gabrimatic/toolchest/security/advisories/new) to submit.
3. Include:
   - Steps to reproduce
   - Demonstrated impact
   - Affected version and macOS version
   - Suggested fix (if any)

Expect acknowledgment within 48 hours.
