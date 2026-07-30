#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGURATION="${1:-debug}"
APP_INFO="$ROOT_DIR/BundleSupport/RequirementTracker-Info.plist"
APP_ENTITLEMENTS="$ROOT_DIR/BundleSupport/RequirementTracker.entitlements"
WIDGET_ENTITLEMENTS="$ROOT_DIR/BundleSupport/RequirementCalendarWidget.entitlements"
WIDGET_PROJECT="$ROOT_DIR/WidgetExtension/RequirementCalendarWidget.xcodeproj"
WIDGET_DERIVED_DATA="$ROOT_DIR/.build/widget-xcode"

if [[ -z "${DEVELOPER_DIR:-}" && -d "/Applications/Xcode.app/Contents/Developer" ]]; then
    export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi
export CLANG_MODULE_CACHE_PATH="$ROOT_DIR/.build/module-cache"
export SWIFT_MODULE_CACHE_PATH="$ROOT_DIR/.build/module-cache"
mkdir -p "$CLANG_MODULE_CACHE_PATH"

case "$CONFIGURATION" in
    debug)
        OUTPUT_APP="$ROOT_DIR/.build/widget-preview/需求记录 Dev.app"
        XCODE_CONFIGURATION="Debug"
        ;;
    release)
        CURRENT_BRANCH="$(git -C "$ROOT_DIR" branch --show-current)"
        if [[ "$CURRENT_BRANCH" != "main" ]]; then
            echo "Release bundles must be built from main; current branch is $CURRENT_BRANCH." >&2
            exit 1
        fi
        OUTPUT_APP="$ROOT_DIR/dist/需求记录.app"
        XCODE_CONFIGURATION="Release"
        ;;
    *)
        echo "Usage: $0 [debug|release]" >&2
        exit 1
        ;;
esac

swift build \
    --disable-sandbox \
    --package-path "$ROOT_DIR" \
    -c "$CONFIGURATION" \
    --product RequirementTracker
swift build \
    --disable-sandbox \
    --package-path "$ROOT_DIR" \
    -c "$CONFIGURATION" \
    --product JiraRequirementNativeHost
xcodebuild \
    -project "$WIDGET_PROJECT" \
    -scheme RequirementCalendarWidget \
    -configuration "$XCODE_CONFIGURATION" \
    -destination "platform=macOS" \
    -derivedDataPath "$WIDGET_DERIVED_DATA" \
    CODE_SIGNING_ALLOWED=NO \
    build

BIN_DIR="$(
    swift build \
        --disable-sandbox \
        --package-path "$ROOT_DIR" \
        -c "$CONFIGURATION" \
        --show-bin-path
)"
STAGING_ROOT="$ROOT_DIR/.build/app-bundle-staging/$CONFIGURATION"
STAGING_APP="$STAGING_ROOT/需求记录.app"
WIDGET_BUNDLE="$STAGING_APP/Contents/PlugIns/RequirementCalendarWidget.appex"
WIDGET_PRODUCT="$WIDGET_DERIVED_DATA/Build/Products/$XCODE_CONFIGURATION/RequirementCalendarWidget.appex"

rm -rf "$STAGING_ROOT"
mkdir -p \
    "$STAGING_APP/Contents/MacOS" \
    "$STAGING_APP/Contents/Resources" \
    "$STAGING_APP/Contents/PlugIns"

cp "$APP_INFO" "$STAGING_APP/Contents/Info.plist"
cp "$ROOT_DIR/BundleSupport/PkgInfo" "$STAGING_APP/Contents/PkgInfo"
install -m 755 "$BIN_DIR/RequirementTracker" "$STAGING_APP/Contents/MacOS/RequirementTracker"
install -m 755 \
    "$BIN_DIR/JiraRequirementNativeHost" \
    "$STAGING_APP/Contents/Resources/JiraRequirementNativeHost"
ditto \
    "$ROOT_DIR/Integrations/JiraRequirementCapture/extension" \
    "$STAGING_APP/Contents/Resources/JiraRequirementCaptureExtension"

ICON_SOURCE="$ROOT_DIR/dist/需求记录.app/Contents/Resources/AppIcon.icns"
if [[ -f "$ICON_SOURCE" ]]; then
    cp "$ICON_SOURCE" "$STAGING_APP/Contents/Resources/AppIcon.icns"
else
    /usr/libexec/PlistBuddy -c "Delete :CFBundleIconFile" "$STAGING_APP/Contents/Info.plist"
fi

ditto "$WIDGET_PRODUCT" "$WIDGET_BUNDLE"

if [[ "$CONFIGURATION" == "debug" ]]; then
    /usr/libexec/PlistBuddy \
        -c "Set :CFBundleDisplayName 需求记录 Dev" \
        -c "Set :CFBundleName 需求记录 Dev" \
        -c "Set :CFBundleIdentifier com.xfu-work.RequirementTracker.dev" \
        -c "Set :CFBundleURLTypes:0:CFBundleURLSchemes:0 requirementtracker-dev" \
        "$STAGING_APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy \
        -c "Set :CFBundleDisplayName 需求记录日历 Dev" \
        -c "Set :CFBundleIdentifier com.xfu-work.RequirementTracker.dev.CalendarWidget" \
        "$WIDGET_BUNDLE/Contents/Info.plist"
fi

codesign --force --sign - "$STAGING_APP/Contents/Resources/JiraRequirementNativeHost"
codesign \
    --force \
    --sign - \
    --entitlements "$WIDGET_ENTITLEMENTS" \
    "$WIDGET_BUNDLE"
codesign \
    --force \
    --sign - \
    --entitlements "$APP_ENTITLEMENTS" \
    "$STAGING_APP"

rm -rf "$OUTPUT_APP"
mkdir -p "$(dirname "$OUTPUT_APP")"
ditto "$STAGING_APP" "$OUTPUT_APP"
codesign --verify --deep --strict --verbose=2 "$OUTPUT_APP"

if [[ "$CONFIGURATION" == "release" ]]; then
    "$ROOT_DIR/Scripts/cleanup-development-app.sh"
fi

echo "$OUTPUT_APP"
