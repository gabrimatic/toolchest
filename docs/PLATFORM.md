# Platform audit

What macOS 26/27 and this class of Mac (Apple silicon, ProMotion, Force Touch, notch, multiple displays) offer, and what Toolchest does with each. Public APIs only. "Adopted" means it ships; "Not adopted" gives the reason.

## Adopted

| Capability | Framework | Where Toolchest uses it |
| --- | --- | --- |
| Liquid Glass | SwiftUI `glassEffect`, `.glass` button styles | Only what you click or focus: buttons and controls. The HUD, hold ring, hint pill, result panels and cleaning card are flat ink or paper cards (docs/DESIGN.md) |
| SF Symbols | SwiftUI `contentTransition(.symbolEffect)` | Ordinary interface symbols in ice or ink, one symbol swap on the hold ring and the HUD |
| Bundled type | `CTFontManagerRegisterFontsForURL` | IBM Plex Sans (SIL Open Font License) on every surface the app draws itself, in the app and in the widget extension; native controls keep the system font |
| ProMotion 120 Hz | `NSScreen.displayLink` (`CADisplayLink`) | Drop-down windows grow one step per display refresh |
| Force Touch haptics | `NSHapticFeedbackManager` | Tick when a hold ring starts, a region is picked or a module flips; commit when a guarded quit fires or cleaning mode ends; a tap when a shortcut is recorded. Switch in Settings > General |
| App Intents | `AppIntents` | 25 actions covering every module: Keep Awake, Cleaning Mode, Dark Mode, desktop icons, notifications, Capture Text, Translate, Summarize, code scan, color picker, mic mute, device switching, output device (with an `AppEntity` of devices), Isolate, drop-downs, Hyper key, Mail and note links, module switches, Settings, and headless Recognize Text in Image, Summarize Text and Translate Text. Ten have Siri phrases (`AppShortcutsProvider`). An action behind a module or feature switch refuses while that switch is off |
| Permission request APIs | `AXIsProcessTrustedWithOptions`, `CGRequestListenEventAccess`, `CGRequestScreenCaptureAccess`, `AEDeterminePermissionToAutomateTarget` | Welcome window, Settings > Permissions and the "not allowed yet" card ask macOS directly, so Toolchest lands in each Privacy list without pressing "+"; the pane opens only after a refusal |
| Menu item images | `NSMenuItem.preferredImageVisibility` (macOS 27) | The menu bar menu and the Finder extension menu keep their SF Symbols; macOS 27 hides menu images unless an item asks to show them |
| Focus filters | `SetFocusFilterIntent` | Per Focus: mute the mic, guard ⌘Q in every app, keep the Mac awake; undone when the Focus ends (only what the filter itself changed) |
| Control Center and menu bar controls | WidgetKit `ControlWidget` | Keep Awake, Mute Microphone, Next Output Device (shows the device), Cleaning Mode, Hyper Key |
| Desktop widgets | WidgetKit | Keep Awake (live countdown, toggle) and Audio Devices (output, input, mic mute button) |
| On-device Apple Intelligence | `FoundationModels` | Capture and Summarize, the Summarize Text action, and Name by Content, which reads selected files and proposes names in a review panel. Availability is checked first and every unavailable reason is explained. For a summary, one `LanguageModelSession` with short instructions streams plain text into the panel, and text is cut to the model's own context size (`contextSize`, `tokenCount`). Name by Content generates one `@Generable` name per file and sends images and scanned pages as attachments on macOS 27. The summary is labelled as model output and shown beside the exact text; it never replaces copied text. Tidying captured text is plain code (TextReflow), so nothing in a screenshot can steer it |
| Translation | `Translation` | Capture and Translate and the Translate Text action share one route (detect, same-language check, `LanguageAvailability`): installed pairs translate headless, others go through the system download sheet (the action asks for the download instead) |
| Vision | `Vision` (`RecognizeTextRequest`, `DetectBarcodesRequest`) | Capture Text, code scanning, Recognize Text in Image, naming a picture the model refuses |
| ScreenCaptureKit | `SCScreenshotManager.captureImage(in:)` | Region capture across displays |
| Natural Language | `NLLanguageRecognizer` | Source language for translation |
| PDFKit | `PDFDocument` | Name by Content reads the first pages' text, or the first page as a picture for a scan |
| ImageIO | `CGImageSource`, `CGImageDestination` | Remove Photo Location copies the image without GPS and keeps the other tags |
| CryptoKit | `SHA256` | Copy SHA-256 |
| Core Audio | HAL properties and listeners | Mute, device switching, volume cap, mic-in-use detection |
| Power and heat | `ProcessInfo.isLowPowerModeEnabled`, `thermalState`, their notifications | Low Power Mode or a serious/critical thermal state turn off the drop-down animation |
| Accessibility | `NSWorkspace` display options, VoiceOver | Reduce Motion: no springs and no drop-down animation. Increase Contrast: thicker selector border, darker dim, heavier card outline, stronger ring track. Reduce Transparency: the glass buttons adapt on their own; the flat cards are already opaque. VoiceOver: labels and values on every control, HUD and panel announcements |
| Multiple displays, Spaces, full screen | AppKit | Selector covers every display; HUD and drop-downs follow the pointer's display; the green button fills the display holding most of the window; overlays join all Spaces and show over full-screen apps; cleaning mode re-covers displays plugged in mid-clean |
| Global hotkeys | Carbon `RegisterEventHotKey` | All hotkeys, no permission, no idle cost |
| Event taps, Accessibility | `CGEventTap`, AX | Interception features only while on |
| HID key mapping | `IOHIDEventSystemClient`, `IOHIDManager` | Hyper key per keyboard, re-applied when a keyboard connects |
| Login item | `SMAppService` | Launch at login, registered on the first launch |
| Finder Sync | `FinderSync` | Right-click extras over an authenticated channel |

## Not adopted

| Capability | Why not |
| --- | --- |
| Grayscale, Night Shift, True Tone, Low Power Mode switches | No public API; they live in private frameworks or need root. |
| Live Activities on the Mac | No Mac surface for third-party apps. |
| Touch Bar | Not on current Macs. |
| Notch-area UI | Toolchest's surfaces are the menu bar item, HUDs and panels; nothing gains from sitting around the notch. |
| Camera, Continuity Camera, Handoff | Nothing in Toolchest's modules needs them. |
| iCloud sync of settings | Settings export between Macs is excluded on purpose. |
| Spotlight indexing of content (`CSSearchableIndex`) | Toolchest keeps no user content to index; its actions already appear in Spotlight through App Intents. |
| Image Playground, Writing Tools hooks | Toolchest's text tools act on captured screen text, in panels that keep the exact text beside the model's output. |
| App groups for extension data | Needs a provisioning profile on macOS 15 and later; the extensions use owner-only secret files and private Mach ports instead. |

## Limits worth knowing

- Widgets and controls talk to the running app. Without Toolchest running they show "off" or "Open Toolchest".
- Springs and the drop-down animation turn off under Reduce Motion, and the drop-down animation under Low Power Mode or high heat; everything still works without them.
- Haptics play only while a finger rests on a Force Touch trackpad.
- Apple Intelligence features need Apple Intelligence turned on; Toolchest says why when it's unavailable, and Capture and Summarize still shows the exact text.
