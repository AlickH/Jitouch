#!/bin/bash
#
# Build Jitouch, signed and packaged, either per architecture or universal.
#
#   ./scripts/build-per-arch.sh arm64
#   ./scripts/build-per-arch.sh x86_64
#   ./scripts/build-per-arch.sh universal
#   ./scripts/build-per-arch.sh all
#
# Signing identities come from the environment so this stays reproducible:
#   DEV_TEAM     - Apple team id, e.g. ABCDE12345
#   APP_ID       - "Developer ID Application: Your Name (ABCDE12345)"
#   INSTALLER_ID - "Developer ID Installer: Your Name (ABCDE12345)"
#
# Outputs land in dist/:
#   Jitouch-<arch>.prefPane(.zip)   drag-and-drop install
#   Install-Jitouch-<arch>.pkg      installer package
#
# Pass NOTARIZE=1 to submit each artifact to Apple and staple the ticket
# (requires a working `asc` login or a notarytool keychain profile).

set -Eeuo pipefail

cd "$(dirname "$0")/.."

: "${DEV_TEAM:?set DEV_TEAM to your Apple team id}"
: "${APP_ID:?set APP_ID to your Developer ID Application identity}"
: "${INSTALLER_ID:?set INSTALLER_ID to your Developer ID Installer identity}"

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" prefpane/Info.plist 2>/dev/null || echo 0.0.0)
VERSION=${VERSION:-0.0.0}
NOTARIZE=${NOTARIZE:-0}
TARGETS=${1:-all}

if [ "$TARGETS" = "all" ]; then
    ARCH_LIST="arm64 x86_64 universal"
elif [ "$TARGETS" = "universal" ]; then
    ARCH_LIST="universal"
else
    ARCH_LIST="$TARGETS"
fi

mkdir -p dist

build_one() {
    local arch=$1
    local out="build-$arch"
    local -a archflags

    if [ "$arch" = "universal" ]; then
        archflags=(ARCHS="arm64 x86_64")
    else
        archflags=(ARCHS="$arch" VALID_ARCHS="$arch")
    fi

    echo "=== $arch: app ==="
    xcodebuild -project jitouch/Jitouch/Jitouch.xcodeproj -scheme Jitouch -configuration Release \
        "${archflags[@]}" ONLY_ACTIVE_ARCH=NO \
        CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="$DEV_TEAM" \
        CODE_SIGN_IDENTITY="$APP_ID" PROVISIONING_PROFILE_SPECIFIER="" \
        OTHER_CODE_SIGN_FLAGS="--timestamp --options runtime" \
        SYMROOT="$PWD/$out" build | tail -1

    echo "=== $arch: preference pane ==="
    rm -rf prefpane/Jitouch.app
    cp -R "$out/Release/Jitouch.app" prefpane/Jitouch.app
    xcodebuild -project prefpane/Jitouch.xcodeproj -target Jitouch -configuration Release \
        "${archflags[@]}" ONLY_ACTIVE_ARCH=NO \
        CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="$DEV_TEAM" \
        CODE_SIGN_IDENTITY="$APP_ID" PROVISIONING_PROFILE_SPECIFIER="" \
        OTHER_CODE_SIGN_FLAGS="--timestamp --options runtime" \
        SYMROOT="$PWD/$out" build | tail -1

    local pane="$out/Release/Jitouch.prefPane"
    rm -rf "dist/Jitouch-$arch.prefPane"
    cp -R "$pane" "dist/Jitouch-$arch.prefPane"
    codesign --verify --deep --strict "dist/Jitouch-$arch.prefPane"

    echo "=== $arch: installer ==="
    local stage="build/pkg-$arch/staging"
    rm -rf "build/pkg-$arch"
    mkdir -p "$stage"
    cp -R "dist/Jitouch-$arch.prefPane" "$stage/Jitouch.prefPane"

    local hostarch
    if [ "$arch" = "universal" ]; then hostarch="arm64,x86_64"; else hostarch="$arch"; fi
    sed "s/hostArchitectures=\"x86_64,arm64\"/hostArchitectures=\"$hostarch\"/" \
        prefpane/distribution.xml > "build/pkg-$arch/distribution.xml"

    pkgbuild --root "$stage" --component-plist prefpane/components.plist \
        --scripts scripts/pkg-scripts \
        --identifier com.jitouch.Jitouch --version "$VERSION" \
        --install-location /Library/PreferencePanes \
        --sign "$INSTALLER_ID" --timestamp \
        "build/pkg-$arch/JitouchPrefpane.pkg" >/dev/null

    productbuild --distribution "build/pkg-$arch/distribution.xml" --package-path "build/pkg-$arch" \
        --identifier com.jitouch.Jitouch --version "$VERSION" \
        --sign "$INSTALLER_ID" --timestamp \
        "dist/Install-Jitouch-$arch.pkg" >/dev/null

    echo "=== $arch: zip ==="
    rm -f "dist/Jitouch-$arch.prefPane.zip"
    ( cd dist && zip -qry "Jitouch-$arch.prefPane.zip" "Jitouch-$arch.prefPane" )

    if [ "$NOTARIZE" = "1" ]; then
        echo "=== $arch: notarize ==="
        asc notarization submit --file "dist/Jitouch-$arch.prefPane.zip" --wait --output json
        xcrun stapler staple "dist/Jitouch-$arch.prefPane"
        rm -f "dist/Jitouch-$arch.prefPane.zip"
        ( cd dist && zip -qry "Jitouch-$arch.prefPane.zip" "Jitouch-$arch.prefPane" )

        asc notarization submit --file "dist/Install-Jitouch-$arch.pkg" --wait --output json
        xcrun stapler staple "dist/Install-Jitouch-$arch.pkg"
    fi

    rm -rf prefpane/Jitouch.app
    echo "=== $arch: done ==="
}

for arch in $ARCH_LIST; do
    build_one "$arch"
done

echo
ls -lh dist
