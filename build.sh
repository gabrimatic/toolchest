#!/bin/zsh
# Builds Toolchest.app (with its Finder and widget extensions) into ./build.
#   ./build.sh            build only
#   ./build.sh --install  replace /Applications/Toolchest.app and launch it
set -euo pipefail
cd "${0:A:h}"

TARGET=arm64-apple-macos26.0
FRAMEWORKS=(-framework AppKit -framework SwiftUI -framework ServiceManagement -framework Carbon -framework CoreAudio
  -framework AudioToolbox -framework IOKit -framework ScreenCaptureKit -framework Vision -framework Translation
  -framework NaturalLanguage -framework FinderSync -framework CryptoKit -framework ImageIO -framework ApplicationServices
  -framework AppIntents -framework WidgetKit -framework FoundationModels -framework PDFKit)
SOURCES=(Sources/Toolchest/*.swift Sources/Shared/*.swift Sources/SharedUI/*.swift)

APP=build/Toolchest.app
APPEX=$APP/Contents/PlugIns/ToolchestFinder.appex
WIDGETS=$APP/Contents/PlugIns/ToolchestWidgets.appex
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APPEX/Contents/MacOS" "$WIDGETS/Contents/MacOS" "$WIDGETS/Contents/Resources"

# The app, plus the App Intents metadata Shortcuts, Spotlight and Siri read (what Xcode's
# "Extract App Intents Metadata" step makes): the compiler emits constant values for the intent
# types, and appintentsmetadataprocessor turns them into Metadata.appintents.
cat > build/intent-protocols.json <<'JSON'
["AppIntent","EntityQuery","AppEntity","TransientEntity","AppEnum","AppShortcutsProvider","AppIntentsPackage",
 "DynamicOptionsProvider","SetFocusFilterIntent","ControlConfigurationIntent","WidgetConfigurationIntent"]
JSON
swiftc -O -wmo -swift-version 6 -target $TARGET $FRAMEWORKS $SOURCES -module-name Toolchest -o "$APP/Contents/MacOS/Toolchest" \
  -emit-const-values-path build/Toolchest.swiftconstvalues \
  -Xfrontend -const-gather-protocols-file -Xfrontend "$PWD/build/intent-protocols.json"
intents_metadata() { # <module> <binary> <const values> <resources dir> <sources...>
  local module=$1 binary=$2 consts=$3 out=$4; shift 4
  print -l ${@:A} > build/$module-sources.txt
  print -l ${consts:A} > build/$module-consts.txt
  xcrun appintentsmetadataprocessor --output "$out" --module-name $module --binary-file "$binary" \
    --toolchain-dir "$(xcrun --find swiftc | sed 's|/usr/bin/swiftc$||')" --sdk-root "$(xcrun --show-sdk-path)" \
    --xcode-version "$(xcodebuild -version | awk '/Build version/ {print $3}')" --platform-family macOS \
    --deployment-target 26.0 --target-triple $TARGET --source-file-list build/$module-sources.txt \
    --swift-const-vals-list build/$module-consts.txt --quiet-warnings 2>&1 | grep -iE "error" || true
  [[ -f "$out/Metadata.appintents/extract.actionsdata" ]] || { echo "error: no App Intents metadata for $module" >&2; exit 1; }
}
intents_metadata Toolchest "$APP/Contents/MacOS/Toolchest" build/Toolchest.swiftconstvalues "$APP/Contents/Resources" $SOURCES

# The Finder Sync extension: an app extension, so its entry point is NSExtensionMain.
swiftc -O -swift-version 6 -target $TARGET -module-name ToolchestFinder -parse-as-library \
  -framework AppKit -framework FinderSync -Xlinker -e -Xlinker _NSExtensionMain \
  Sources/ToolchestFinder/*.swift Sources/Shared/*.swift -o "$APPEX/Contents/MacOS/ToolchestFinder"
cp Resources/FinderSync-Info.plist "$APPEX/Contents/Info.plist"

# The widget extension: Control Center and menu bar controls plus desktop widgets.
WIDGET_SOURCES=(Sources/ToolchestWidgets/*.swift Sources/Shared/*.swift Sources/SharedUI/*.swift)
swiftc -O -wmo -swift-version 6 -target $TARGET -module-name ToolchestWidgets -parse-as-library \
  -framework AppKit -framework SwiftUI -framework WidgetKit -framework AppIntents -Xlinker -e -Xlinker _NSExtensionMain \
  $WIDGET_SOURCES -o "$WIDGETS/Contents/MacOS/ToolchestWidgets" \
  -emit-const-values-path build/ToolchestWidgets.swiftconstvalues \
  -Xfrontend -const-gather-protocols-file -Xfrontend "$PWD/build/intent-protocols.json"
cp Resources/Widgets-Info.plist "$WIDGETS/Contents/Info.plist"
intents_metadata ToolchestWidgets "$WIDGETS/Contents/MacOS/ToolchestWidgets" build/ToolchestWidgets.swiftconstvalues "$WIDGETS/Contents/Resources" $WIDGET_SOURCES

# IBM Plex Sans (SIL Open Font License) with its licence text, in the app and in the widget extension.
# Both register the file at runtime (Sources/SharedUI/Brand.swift).
for resources in "$APP/Contents/Resources" "$WIDGETS/Contents/Resources"; do
  mkdir -p "$resources/Fonts"
  cp Resources/Fonts/IBMPlexSans.ttf Resources/Fonts/OFL.txt "$resources/Fonts/"
done

cp Resources/Info.plist "$APP/Contents/Info.plist"
# The icon tool compiles with the app's own mark, so the icon and the menu bar image share one source.
# It writes an Icon Composer document, and actool turns that into Assets.car and AppIcon.icns. actool needs
# absolute paths: its helper process keeps the working directory of whichever run started it.
swiftc -parse-as-library -target $TARGET Sources/Toolchest/BrandMark.swift scripts/make-icon.swift -o build/make-icon
build/make-icon build/AppIcon.icon
xcrun actool "$PWD/build/AppIcon.icon" --compile "$PWD/$APP/Contents/Resources" --output-format human-readable-text --warnings --errors \
  --output-partial-info-plist "$PWD/build/icon-info.plist" --app-icon AppIcon --include-all-app-icons --enable-on-demand-resources NO \
  --development-region en --target-device mac --minimum-deployment-target 26.0 --platform macosx > build/actool.log \
  || { cat build/actool.log >&2; exit 1; }
[[ -f "$APP/Contents/Resources/Assets.car" ]] || { cat build/actool.log >&2; echo "error: the app icon did not compile" >&2; exit 1; }
rm -rf build/AppIcon.icon build/make-icon build/actool.log build/icon-info.plist

# Signing. TOOLCHEST_SIGN_IDENTITY names a code-signing identity in the keychain, or "-" for ad hoc, which is what
# releases use. A stable identity keeps the privacy grants across rebuilds (the designated requirement names
# the certificate, not the binary hash). Unset, the build uses the identity named below when the keychain has
# it and signs ad hoc otherwise.
IDENTITY="${TOOLCHEST_SIGN_IDENTITY:-Gabrimatic Local Signing}"
if [[ "$IDENTITY" != "-" ]] && ! security find-identity -p codesigning | grep -qF "\"$IDENTITY\""; then
  [[ -n "${TOOLCHEST_SIGN_IDENTITY:-}" ]] && { echo "error: signing identity \"$IDENTITY\" not found in the keychain" >&2; exit 1; }
  IDENTITY="-"
  echo "note: no local signing identity, signing ad hoc (macOS asks for permissions again after a rebuild)" >&2
fi
codesign --force --options runtime --timestamp=none --entitlements Resources/ToolchestFinder.entitlements -s "$IDENTITY" "$APPEX"
codesign --force --options runtime --timestamp=none --entitlements Resources/ToolchestWidgets.entitlements -s "$IDENTITY" "$WIDGETS"
codesign --force --options runtime --timestamp=none --entitlements Resources/Toolchest.entitlements -s "$IDENTITY" "$APP"
codesign --verify --strict --deep "$APP"
echo "Built $APP (signed: ${IDENTITY/#-/ad hoc})"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x Toolchest 2>/dev/null || true
  # Give a running Toolchest time to undo its Caps Lock mapping before it is replaced.
  for _ in {1..20}; do pgrep -x Toolchest >/dev/null || break; sleep 0.1; done
  rm -rf /Applications/Toolchest.app
  ditto "$APP" /Applications/Toolchest.app
  rm -rf build
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/Toolchest.app
  pluginkit -a /Applications/Toolchest.app/Contents/PlugIns/ToolchestFinder.appex 2>/dev/null || true
  pluginkit -a /Applications/Toolchest.app/Contents/PlugIns/ToolchestWidgets.appex 2>/dev/null || true
  open /Applications/Toolchest.app
  echo "Installed and launched /Applications/Toolchest.app"
fi
