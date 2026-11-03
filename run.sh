#!/bin/bash
# Build LidIA and package it as a proper .app bundle so macOS TCC
# permissions (Calendar, Reminders, Microphone, etc.) work correctly.
#
# Usage:
#   ./run.sh          # build + run
#   ./run.sh build    # build only (creates .build/LidIA.app)
#   ./run.sh install  # build, install to /Applications/LidIA.app, launch it
#   ./run.sh clean    # remove .app bundle

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN_PATH="$(swift build --show-bin-path 2>/dev/null)"
APP_DIR="${ROOT_DIR}/.build/LidIA.app"
CONTENTS="${APP_DIR}/Contents"
MACOS="${CONTENTS}/MacOS"
RESOURCES="${CONTENTS}/Resources"

PLIST_SRC="${ROOT_DIR}/Sources/LidIA/Resources/Info.plist"
ENTITLEMENTS="${ROOT_DIR}/Sources/LidIA/Resources/LidIA.entitlements"
ASSETS_BUNDLE="${BIN_PATH}/LidIA_LidIA.bundle"

case "${1:-run}" in
    clean)
        rm -rf "${APP_DIR}"
        echo "Cleaned ${APP_DIR}"
        exit 0
        ;;
    build|run|install)
        ;;
    *)
        echo "Usage: $0 [build|run|install|clean]"
        exit 1
        ;;
esac

# 1. Build
echo "==> Building LidIA..."
swift build

# 2. Create .app bundle structure
echo "==> Packaging .app bundle..."
mkdir -p "${MACOS}" "${RESOURCES}"

# 3. Copy executable
# Replace (new inode) rather than overwrite: copying over a binary that is
# running (the app, or LidiaMCP launched by Claude/Cursor) invalidates its
# code signature and macOS kills it.
rm -f "${MACOS}/LidIA"
cp "${BIN_PATH}/LidIA" "${MACOS}/LidIA"

# 4. Copy Info.plist
cp "${PLIST_SRC}" "${CONTENTS}/Info.plist"

# 4b. Optional built-in Google OAuth client, so it needn't be committed.
# See docs/google-oauth.md.
if [ -n "${LIDIA_GOOGLE_CLIENT_ID:-}" ]; then
    /usr/libexec/PlistBuddy -c "Set :LidIAGoogleClientID ${LIDIA_GOOGLE_CLIENT_ID}" "${CONTENTS}/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :LidIAGoogleClientSecret ${LIDIA_GOOGLE_CLIENT_SECRET:-}" "${CONTENTS}/Info.plist"
fi

# 5. Compile asset catalog (SPM doesn't process xcassets)
# This produces Assets.car + AppIcon.icns in Resources/, which macOS needs
# for app icon in Dock, notifications, and other system surfaces.
XCASSETS_SRC="${ROOT_DIR}/Sources/LidIA/Resources/Assets.xcassets"
if [ -d "${XCASSETS_SRC}" ]; then
    echo "==> Compiling asset catalog..."
    xcrun actool "${XCASSETS_SRC}" \
        --compile "${RESOURCES}" \
        --platform macosx \
        --minimum-deployment-target 15.0 \
        --app-icon AppIcon \
        --output-partial-info-plist /dev/null \
        2>/dev/null || echo "Warning: actool failed, falling back to .icns copy"
fi

# 5b. Always copy the hand-crafted .icns (higher quality than actool output)
ICNS_SRC="${ROOT_DIR}/Sources/LidIA/Resources/AppIcon.icns"
if [ -f "${ICNS_SRC}" ]; then
    cp "${ICNS_SRC}" "${RESOURCES}/AppIcon.icns"
fi

# 5c. Copy SPM resource bundle (for any non-icon resources)
if [ -d "${ASSETS_BUNDLE}" ]; then
    cp -R "${ASSETS_BUNDLE}" "${RESOURCES}/"
fi

# 5d. Compile MLX Metal shaders into metallib and bundle them
# MLX requires a pre-compiled default.metallib in mlx-swift_Cmlx.bundle/
MLX_METAL_DIR="${ROOT_DIR}/.build/checkouts/mlx-swift/Source/Cmlx/mlx-generated/metal"
MLX_BUNDLE="${RESOURCES}/mlx-swift_Cmlx.bundle"
MLX_METALLIB="${MLX_BUNDLE}/default.metallib"
if [ -d "${MLX_METAL_DIR}" ] && [ ! -f "${MLX_METALLIB}" ]; then
    mkdir -p "${MLX_BUNDLE}"
    # Probe Metal toolchain — on macOS 26+ it requires `xcodebuild -downloadComponent MetalToolchain`
    if xcrun -sdk macosx metal --version >/dev/null 2>&1; then
        echo "==> Compiling MLX Metal shaders..."
        AIR_DIR=$(mktemp -d)
        find "${MLX_METAL_DIR}" -name "*.metal" -print0 | while IFS= read -r -d '' f; do
            name=$(basename "$f" .metal)
            xcrun -sdk macosx metal -c -I "${MLX_METAL_DIR}" "$f" -o "${AIR_DIR}/${name}.air" 2>/dev/null || true
        done
        if compgen -G "${AIR_DIR}/*.air" >/dev/null; then
            xcrun -sdk macosx metallib "${AIR_DIR}"/*.air -o "${MLX_METALLIB}" 2>/dev/null || true
        fi
        rm -rf "${AIR_DIR}"
    fi
    # Fallback: reuse the previously-installed app's metallib if compile was skipped/failed
    if [ ! -s "${MLX_METALLIB}" ] && [ -f "/Applications/LidIA.app/Contents/Resources/mlx-swift_Cmlx.bundle/default.metallib" ]; then
        echo "==> MLX metallib: Metal toolchain unavailable, reusing /Applications/LidIA.app metallib"
        cp "/Applications/LidIA.app/Contents/Resources/mlx-swift_Cmlx.bundle/default.metallib" "${MLX_METALLIB}"
    fi
    if [ -f "${MLX_METALLIB}" ]; then
        echo "==> MLX metallib ready: $(du -h "${MLX_METALLIB}" | cut -f1)"
    else
        echo "    Warning: no MLX metallib available. Install Metal toolchain: xcodebuild -downloadComponent MetalToolchain"
    fi
fi

# 6. Embed Sparkle.framework (dynamic framework must be in Contents/Frameworks/)
FRAMEWORKS="${CONTENTS}/Frameworks"
# The native build system puts package frameworks in PackageFrameworks/.
SPARKLE_FW="${BIN_PATH}/Sparkle.framework"
[ -d "${SPARKLE_FW}" ] || SPARKLE_FW="${BIN_PATH}/PackageFrameworks/Sparkle.framework"
if [ -d "${SPARKLE_FW}" ]; then
    echo "==> Embedding Sparkle.framework..."
    mkdir -p "${FRAMEWORKS}"
    cp -R "${SPARKLE_FW}" "${FRAMEWORKS}/"
    # Add @executable_path/../Frameworks to rpath so dyld can find it
    if ! otool -l "${MACOS}/LidIA" | grep -q "@executable_path/../Frameworks"; then
        install_name_tool -add_rpath "@executable_path/../Frameworks" "${MACOS}/LidIA"
    fi
elif otool -L "${MACOS}/LidIA" | grep -q Sparkle.framework; then
    echo "Error: LidIA links Sparkle.framework but it was not found under ${BIN_PATH}" >&2
    exit 1
fi

# 6b. Copy LidiaMCP binary alongside the main executable
if [ -f "${BIN_PATH}/LidiaMCP" ]; then
    rm -f "${MACOS}/LidiaMCP"
    cp "${BIN_PATH}/LidiaMCP" "${MACOS}/LidiaMCP"
fi

# 6c. App Intents metadata (Siri, Shortcuts, App Shortcuts). swift build doesn't
# produce Metadata.appintents, and without it macOS sees none of LidIA's intents.
# shellcheck source=scripts/lib/appintents-metadata.sh
source "${ROOT_DIR}/scripts/lib/appintents-metadata.sh"
if ! build_appintents_metadata Debug "${APP_DIR}"; then
    echo "Error: App Intents metadata failed; LidIA would have no Siri or Shortcuts actions." >&2
    exit 1
fi

# 7. Code sign with entitlements
# Use the Apple Development identity for stable signing (preserves TCC permissions across
# rebuilds, and it's the certificate the development provisioning profile covers).
# LIDIA_SIGN_IDENTITY overrides; otherwise the first Apple Development identity, else the
# first identity of any kind. Falls back to ad-hoc if there is none.
# Only lines with a quoted identity count; "0 valid identities found" must not be read as a name.
IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null || true)"
SIGN_IDENTITY="${LIDIA_SIGN_IDENTITY:-$(echo "${IDENTITIES}" | grep '"Apple Development' | head -1 | sed 's/.*"\(.*\)"/\1/' || true)}"
[ -n "${SIGN_IDENTITY}" ] || SIGN_IDENTITY=$(echo "${IDENTITIES}" | grep -m1 '"' | sed 's/.*"\(.*\)"/\1/' || true)

# 7a. iCloud sync needs a provisioning profile with the iCloud capability embedded in the
# bundle, and the iCloud entitlements; macOS refuses to launch an app that claims them
# without one. scripts/fetch-icloud-profile.sh gets it through Xcode's automatic signing.
# Without a profile (or with LIDIA_ICLOUD=0) the app is signed without iCloud and
# simply doesn't sync. See docs/icloud-sync.md.
SIGN_ENTITLEMENTS="${ENTITLEMENTS}"
rm -f "${CONTENTS}/embedded.provisionprofile"
if [ "${LIDIA_ICLOUD:-1}" != "0" ] && [[ "${SIGN_IDENTITY}" == "Apple Development"* ]]; then
    if PROFILE="$("${ROOT_DIR}/scripts/fetch-icloud-profile.sh" development)"; then
        # shellcheck source=scripts/lib/icloud-entitlements.sh
        source "${ROOT_DIR}/scripts/lib/icloud-entitlements.sh"
        cp "${PROFILE}" "${CONTENTS}/embedded.provisionprofile"
        SIGN_ENTITLEMENTS="${ROOT_DIR}/.build/provisioning/LidIA-development.entitlements"
        compose_icloud_entitlements "${ENTITLEMENTS}" "${PROFILE}" Development "${SIGN_ENTITLEMENTS}"
        echo "==> iCloud sync: on (development profile, CloudKit Development environment)"
    else
        echo "==> iCloud sync: off in this build (no provisioning profile; see docs/icloud-sync.md)"
    fi
else
    echo "==> iCloud sync: off in this build (needs an Apple Development identity and LIDIA_ICLOUD unset)"
fi

if [ -n "${SIGN_IDENTITY}" ] && [ "${SIGN_IDENTITY}" != "" ]; then
    echo "==> Code signing with: ${SIGN_IDENTITY}"
    # Sign embedded frameworks first
    if [ -d "${FRAMEWORKS}" ]; then
        find "${FRAMEWORKS}" -name "*.framework" -exec codesign --force --sign "${SIGN_IDENTITY}" {} \; 2>/dev/null || true
    fi
    codesign --force --sign "${SIGN_IDENTITY}" --entitlements "${SIGN_ENTITLEMENTS}" --generate-entitlement-der "${APP_DIR}"
else
    echo "==> Code signing (ad-hoc — permissions may reset on rebuild)..."
    if [ -d "${FRAMEWORKS}" ]; then
        find "${FRAMEWORKS}" -name "*.framework" -exec codesign --force --sign - {} \; 2>/dev/null || true
    fi
    codesign --force --sign - --entitlements "${ENTITLEMENTS}" "${APP_DIR}"
fi

echo "==> Built: ${APP_DIR}"

# Force macOS to re-read the app icon from the bundle (clears icon cache)
/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -f "${APP_DIR}" 2>/dev/null || true

if [ "${1:-run}" = "run" ]; then
    echo "==> Launching LidIA..."
    open "${APP_DIR}"
fi

# install: the copy Spotlight, Launchpad, the Dock and Siri find. Builds under
# .build/ are hidden from Spotlight, so without this an older copy elsewhere wins.
if [ "${1:-run}" = "install" ]; then
    INSTALLED="/Applications/LidIA.app"
    if pgrep -f "^${INSTALLED}/Contents/MacOS/LidIA$" >/dev/null; then
        echo "Error: LidIA is running from ${INSTALLED}. Quit it, then run ./run.sh install again." >&2
        exit 1
    fi
    echo "==> Installing to ${INSTALLED}..."
    rm -rf "${INSTALLED}.new"
    ditto "${APP_DIR}" "${INSTALLED}.new"
    rm -rf "${INSTALLED}"
    mv "${INSTALLED}.new" "${INSTALLED}"
    LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister
    # One registered copy, so "open LidIA", Siri and Spotlight all mean this one.
    "${LSREGISTER}" -u "${APP_DIR}" 2>/dev/null || true
    "${LSREGISTER}" -f "${INSTALLED}" 2>/dev/null || true
    echo "==> Launching ${INSTALLED}..."
    open "${INSTALLED}"
fi
