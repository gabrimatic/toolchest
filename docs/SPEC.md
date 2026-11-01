# Toolchest specification

Single source of truth. README and PLATFORM describe what ships; this file says what must be true. A change that breaks a line here is a bug; a feature missing here is not in scope.

## 1. Product

A free macOS menu bar app of power tools, each switchable on its own. Requirements: macOS 26 or later, Apple silicon. Build: Xcode 27 or later (Swift 6), `./build.sh` (`--install`, `--debug`). Bundle ids use `info.gabrimatic.*`. `TOOLCHEST_SIGN_IDENTITY` names a keychain signing identity so Accessibility, Input Monitoring, Screen Recording and Automation grants survive rebuilds, and `-` forces ad hoc; release builds are ad hoc signed. MIT, no account, no network, no telemetry.

## 2. Defaults (hard rule)

- Every behavior-changing module ships OFF and no hotkey is registered until its feature is on.
- On a fresh profile only these are on: Keep Awake (Utilities submenu) and Color Picker (Screen menu item). Nothing else changes how the Mac behaves.
- Finder, Windows & Dock, Keyboard, Audio and Mail & Notes ship off with their features on, except Mute while typing. Screen and Utilities ship on with only Color Picker and Keep Awake on.
- Seven hotkeys have suggested combinations, ⌃⌥⌘ plus a letter: Isolate I, Capture Text T, Translate Y, Scan B, Mic mute M, next output O, next input U. The others start empty.
- Launch at login starts on: the first launch registers it through `SMAppService`, and the welcome window and Settings show the real state.
- Settings live in UserDefaults key `settings.v1` (one JSON document, merged over defaults on load; wrong-typed values ignored). Haptics default on (it only acts when a feature fires).

## 3. Modules

Each module has its own switch plus a switch per feature. A feature is active only when module AND feature are on.

### 3.1 Finder
Name by Content (right-click on files, needs Apple Intelligence): the on-device model reads up to 40 selected files and proposes names in a review panel; nothing is renamed until Rename, numbers avoid clashes, Undo reverses the batch. Images and scanned PDFs go to the model as pictures on macOS 27; a picture the guardrails refuse is named from its Vision text. Cut and paste (⌘X/⌘V move files, only in the file list, never in text fields); Return opens and F2 renames; ⇧⌘T reopens the last closed window or tab (up to 20, skips deleted folders); ⌥N creates `untitled.txt` (numbered) in the current folder and starts rename; paste as file (image to `Pasted Image <date>.png`, text to `Pasted Text <date>.txt`); right-click extras in the Finder Sync extension "Toolchest Finder Extras": Copy Path, Open in Warp (Terminal fallback), Open in VS Code, New File from Template (`~/Library/Application Support/Toolchest/Templates`), Move To, Copy To, Color Tag, Copy SHA-256, Remove Photo Location (writes `<name> (no location).<ext>`, never edits the original, verifies no GPS).
Current folder = front Finder window, or Desktop when none; Recents, AirDrop and search windows have no folder and say so. Move/Copy never overwrite.

### 3.2 Windows & Dock
Quit guard (⌘Q needs a hold, default 0.6 s with a ring, or a double press; optional ⌘W guard per app; Finder and Toolchest exempt); Isolate window hotkey; Dock click on the active app (hide, minimize or cycle); middle-click Dock icon quits (hold or double click; Finder and Toolchest exempt); green button fills the visible screen, click again restores, ⌥-click enters full screen. Dock folders and stacks ignored.

### 3.3 Keyboard
Hyper key (Caps Lock to F18 via per-keyboard `UserKeyMapping`, F18 becomes ⌃⌥⇧⌘, lone tap sends Esc if enabled; only Toolchest's own mapping entry is added and removed, on off, quit, `kill`, and next launch after a crash; re-applied on keyboard connect and wake); app hotkeys (open or focus, again hides); drop-down Finder and Warp at a set height (screen share 0.45 default; grows from under the menu bar); Shortcut Inspector (menu items only).

### 3.4 Screen
Capture Text (Vision, accurate, auto language, on device); Capture and Translate (Apple Translation, panel with Copy, system download prompt for missing pairs); Scan codes (QR/barcodes from region or clipboard image, result shown before anything opens, only http/https get Open); Color picker (system sampler, copies Hex, RGB or OKLCH); Tidy captured text (off by default, plain rules, never adds, drops or changes a word); Capture and Summarize (Apple Intelligence, labelled model output beside the exact text, separate Copy Exact Text and Copy Summary, model output never on the clipboard unless Copy Summary). Needs Screen Recording.

### 3.5 Audio
Music stays shut (quit a Music launch that has a media key within 1.5 s or no input in the 2 s before; Dock/Finder/Spotlight/terminal launches stay); mic mute (hotkey, menu bar indicator clickable, follows a new default input, optional mute while typing when the mic is in use, unmute 0.8 s after); device switching (hotkeys cycle outputs and inputs in name order, HUD card); volume cap after wake (default 50%).

### 3.6 Utilities
Keep Awake (15 min, 30 min, 1, 2, 5 h, or until off; power assertion); Cleaning Mode (black overlay on all screens, swallows keyboard, trackpad, mouse, media keys; hold Esc 2 s to exit; always ends after 60 s, enforced by timer and by the input gate; ends on sleep or lock; refuses without Accessibility); quick toggles (Dark Mode via System Events, desktop icons via Finder `CreateDesktop`); clipboard auto-clear (off by default, 30 s to 10 min, also on sleep and lock, never while ⌘ held or right after paste, never something copied later); notification shortcuts (clear all, open top, through the Accessibility tree).
Left out on purpose: Grayscale, Night Shift, True Tone, Low Power Mode (no public API).

### 3.7 Mail & Notes
Copy `message://` link of the selected Mail message; copy a note link via Notes' own Copy Link. Only read from apps already open; never launch them.

## 4. Platform features

- Authenticated Finder channel: Mach message port plus a fresh 256-bit secret in `~/Library/Application Support/Toolchest/IPC/finder.secret` (owner-only), written at every start, deleted when the feature turns off or Toolchest quits. Sandboxed extension may look up only that port and read only that file. Toolchest re-checks: module, Right-click extras and extension on, Finder frontmost, paths exist and are in Finder's selection or shown folder; Terminal and templates need real folders with symlinks resolved. Writes use `O_CREAT|O_EXCL|O_NOFOLLOW`; photo copy via private staging and `renamex_np(RENAME_EXCL)`. No URL scheme.
- App Intents: 25 actions covering every module, 10 with Siri phrases, 1 `AppEntity` (devices); an action behind a module or feature switch refuses with a clear message while that switch is off; headless Recognize Text in Image, Summarize Text, Translate Text need no switch.
- Focus filter (`SetFocusFilterIntent`): per Focus mute mic, guard ⌘Q everywhere, keep awake (while the Keep Awake feature is on); ending the Focus undoes only what the filter changed.
- Controls (Control Center and menu bar): Keep Awake, Mute Microphone, Next Output Device, Cleaning Mode, Hyper Key. Widgets: Keep Awake (countdown, switch) and Audio Devices (output, input, mic mute). They live in a sandboxed extension with its own port and secret; without Toolchest running they show off or "Open Toolchest".
- Haptics (`NSHapticFeedbackManager`): tick on ring start, region pick, module flip; commit on guarded quit or cleaning end; tap on shortcut recorded; Settings > General switch.
- Login item through `SMAppService` only. No launchd agents, no cron.

## 5. Design and accessibility

- The app icon and the menu bar mark are original vector artwork (paths, no SF Symbol: Apple's license forbids system images in icons and logos). SF Symbols are for ordinary interface symbols only.
- docs/DESIGN.md is the look: ink, ice and the accent only, IBM Plex Sans on every surface the app draws itself (native controls keep SF Pro), flat ink or paper cards, Liquid Glass (`.glass` styles) only on what you click or focus, SF Symbols as plain monochrome line symbols, concentric radii, window moves one step per display refresh (120 Hz via display link). No gradients, shaders, sweeps or ambient loops.
- Perfect in light and dark.
- Reduce Motion: no springs and no drop-down animation. Low Power Mode and serious/critical thermal state: no drop-down animation. Increase Contrast: thicker selector border, darker dim, heavier card outline, stronger ring track. Reduce Transparency: glass adapts.
- VoiceOver: label and value on every control, HUD and panel announcements.
- Multiple displays, Spaces, full screen: selector covers all displays; HUD and drop-downs follow the pointer; overlays join all Spaces and show over full-screen apps; cleaning mode re-covers displays plugged in mid-clean.

## 6. Performance

Idle CPU near 0% (target under 0.5% averaged over 60 s), lean RAM (target under 120 MB resident at idle with defaults). No polling timers while idle; hotkeys by `RegisterEventHotKey`; the event tap exists only while a feature that needs it is on.

## 7. Security

- Input is untrusted; fail closed; least privilege. Nothing leaves the Mac. Keystrokes and clipboard contents are never recorded; clipboard clearing reads only the change count.
- Event tap matches only the combinations of features that are on and passes everything else through.
- Summaries and translations are labelled; text in a screenshot cannot steer tidying (no model).
- No secrets in logs. Extension requests without the secret are refused.

## 8. Permissions

Accessibility, Input Monitoring, Screen and System Audio Recording, Automation (Finder, System Events, Mail), Finder extension in Login Items and Extensions. Missing permission pauses the feature (menu says "Needs Accessibility…"), never half-works. Settings > Permissions shows state, asks macOS with "Allow…" and opens the exact pane after a refusal. Toolchest never flips a privacy switch itself.

## 9. Not included

Quitting idle apps, quit all apps, switching the default browser without the macOS prompt, AirDrop auto-accept or auto-move, archiving or renaming Downloads, private trackpad gestures, settings export between Macs, Live Activities, notch UI, iCloud sync.

## 10. Release

1. `./build.sh` signs the app, the Finder extension and the widget extension.
2. README, PLATFORM and this file agree.
3. `scripts/package.sh` writes `Toolchest-<version>.zip`, `Toolchest-<version>.dmg` and `SHA256SUMS.txt` into `dist/`, and the app, Finder extension and widget extension in both verify with `codesign --verify --strict --deep`.

## 11. Mac app behavior

1. **Welcome window:** on first launch, in the design language. It says in one line what the app does, then lists each permission, one row each, with:
   - an "Allow…" button that triggers the real macOS prompt through the proper request API (Accessibility: `AXIsProcessTrustedWithOptions` with prompt; Input Monitoring: `CGRequestListenEventAccess`; Screen Recording: `CGRequestScreenCaptureAccess`; Automation: `AEDeterminePermissionToAutomateTarget`), so macOS itself adds the app to the list and asks. You never press "+" in System Settings.
   - a live status that reads "Allowed" the moment access is granted, with no relaunch.
   - a fallback "Open System Settings" button to the exact pane, only after macOS was already asked.
   Then a "Launch at login" switch showing the real state and a Done button. Done, Esc and the close button end it the same way, and it never returns on its own.
2. **Ask at first need:** if a feature needs a permission that isn't granted, ask with the system prompt at that moment, then show a clear "not allowed yet" card with one button. Never fail silently.
3. **Info.plist:** a usage string for every permission used (`NSAppleEventsUsageDescription`, `NSScreenCaptureUsageDescription`), in plain language. Also `CFBundleDisplayName`, a version and build, `NSHumanReadableCopyright` "© 2026 Soroush Yousefpour", `LSApplicationCategoryType`, `LSUIElement` and the app icon.
4. **No Dock icon:** in any state. Toolchest stays a menu bar app, and its standard menus show while one of its windows is in front.
5. **Menu bar menu:** the app's name first, then the items of what is on, Modules, Settings… ⌘,, About Toolchest and Quit Toolchest ⌘Q.
6. **Reopen behavior:** a second launch, or opening the app from Finder or Spotlight while it runs, shows the welcome window until it is finished and Settings after that (`applicationShouldHandleReopen`). The menu bar icon may be hidden, and everything must stay reachable without it.
7. **Standard menus:** App menu with About Toolchest (a custom About window in the design language with icon, version, one-line description and copyright), Settings… ⌘, and Quit ⌘Q; an Edit menu so copy, paste and undo work in every text field; a Window menu; Help, where Toolchest Help opens Settings > About and its "Using Toolchest" section. There is no bundled README and no Help window. ⌘W closes windows, and Esc closes About, the permission card and result panels.
8. **Settings window:** one flat sidebar of panes with the pane beside it under its title: General, the modules, Permissions, About. It has the same layout in all these apps and remembers its size and position. Permissions shows each permission's live state with "Allow…", and a "Welcome window" row with a "Show Again" button.
9. **Single instance:** a second launch hands over to the running copy and quits. Clean quit: every system change the app made (key remaps, assertions, overlays) is reverted on quit, and SIGTERM is a normal quit.
10. **Polish everywhere:** light and dark mode (ink and ice, one fixed accent), Reduce Motion, Reduce Transparency and Increase Contrast respected, VoiceOver labels, keyboard navigation in every window, and no layout jumps. Copy is short, human and consistent.

## Design language

docs/DESIGN.md is binding for every surface, icon and word in this app.
