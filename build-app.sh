#!/bin/bash
set -euo pipefail

# Builds AgentsMate.app, the dashboard, from the AgentsMateApp executable.
#
#   ./build-app.sh                 release build, version stamped from the clock
#   ./build-app.sh --debug         debug build
#   ./build-app.sh --version 2026.11.25.1530
#
# AGENTSMATE_VERSION sets the version too; --version wins over it.
#
# The bundle is signed ad hoc so it launches on this Mac. Signing with a
# Developer ID and notarising happen downstream.

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

APP_NAME="AgentsMate"
TARGET="AgentsMateApp"
RESOURCES="Sources/$TARGET/Resources"
CONFIG="release"
VERSION="${AGENTSMATE_VERSION:-$(date +%Y.%m.%d.%H%M)}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --debug) CONFIG="debug" ;;
        --version) VERSION="$2"; shift ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

if ! [[ "$VERSION" =~ ^[0-9]{4}\.[0-9]{2}\.[0-9]{2}\.[0-9]{4}$ ]]; then
    echo "Version must be YYYY.MM.DD.HHMM, got: $VERSION" >&2
    exit 2
fi
MARKETING_VERSION="${VERSION%.*}"
BUILD_NUMBER="${VERSION##*.}"

echo "Building $APP_NAME $VERSION ($CONFIG)"
# SwiftPM records the minimum OS as the SDK version in LC_BUILD_VERSION, and AppKit
# picks window chrome from it. Record the real SDK instead.
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
swift build -c "$CONFIG" --product "$TARGET" -Xlinker -platform_version -Xlinker macos -Xlinker 27.0 -Xlinker "$SDK_VERSION"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

APP_BUNDLE="$APP_NAME.app"
CONTENTS="$APP_BUNDLE/Contents"
rm -rf "$APP_BUNDLE"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"

cp "$BIN_DIR/$TARGET" "$CONTENTS/MacOS/$APP_NAME"
cp "$RESOURCES/Info.plist" "$CONTENTS/Info.plist"
echo -n "APPL????" > "$CONTENTS/PkgInfo"

/usr/libexec/PlistBuddy \
    -c "Set :CFBundleShortVersionString $MARKETING_VERSION" \
    -c "Set :CFBundleVersion $BUILD_NUMBER" \
    "$CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Add :AgentsMateCommit string $(git rev-parse HEAD 2>/dev/null || echo unknown)" "$CONTENTS/Info.plist"

# The app icon: Assets.car for Liquid Glass, an .icns for older systems.
ICON_OUT="$(mktemp -d)"
trap 'rm -rf "$ICON_OUT"' EXIT
xcrun actool \
    --compile "$ICON_OUT" \
    --platform macosx \
    --minimum-deployment-target 27.0 \
    --app-icon "$APP_NAME" \
    --output-partial-info-plist "$ICON_OUT/partial-info.plist" \
    --warnings --errors \
    "$PWD/$RESOURCES/$APP_NAME.icon" >/dev/null
cp "$ICON_OUT/Assets.car" "$CONTENTS/Resources/Assets.car"
cp "$ICON_OUT/$APP_NAME.icns" "$CONTENTS/Resources/$APP_NAME.icns"

# SwiftPM resource bundles (AgentsMate's lane icons) sit beside the binary.
for bundle in "$BIN_DIR"/*.bundle; do
    [ -e "$bundle" ] && cp -R "$bundle" "$CONTENTS/Resources/"
done

codesign --force --sign - --entitlements "$RESOURCES/$APP_NAME.entitlements" "$APP_BUNDLE"

echo "Built $APP_BUNDLE $VERSION"
