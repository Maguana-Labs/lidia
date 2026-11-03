#!/bin/bash
# Build, sign, notarize and (optionally) publish a LidIA release.
#
# Usage:
#   ./scripts/create-release.sh 1.2.0              # Developer ID + notarized DMG and signed appcast in dist/
#   ./scripts/create-release.sh 1.2.0 --publish    # same, then a GitHub release with the DMG and appcast
#   ./scripts/create-release.sh 1.2.0 --adhoc      # local test build: ad-hoc signed, not notarized
#   ./scripts/create-release.sh 1.2.0 --no-icloud  # Developer ID build without iCloud sync
#
# One-time setup (see docs/release-signing.md and docs/icloud-sync.md):
#   1. A "Developer ID Application" certificate in this Mac's Keychain.
#   2. Notary credentials: xcrun notarytool store-credentials "LidIA-notary"
#   3. The Sparkle private key in this Mac's Keychain (generate_keys).
#   4. A Developer ID provisioning profile for io.lidia.app with iCloud
#      (scripts/fetch-icloud-profile.sh developer-id finds or makes it), and the
#      CloudKit schema deployed to Production in the CloudKit Console.
#
# Updates are served from GitHub releases of $LIDIA_RELEASE_REPO (default
# Maguana-Labs/lidia). The app's SUFeedURL points at
# https://github.com/<repo>/releases/latest/download/appcast.xml, so each
# release carries its own signed appcast.

set -euo pipefail

usage() { sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

VERSION="${1:-}"; [ -n "${VERSION}" ] || usage
VERSION="${VERSION#v}"
shift
MODE="sign"
PUBLISH=0
ICLOUD=1
for arg in "$@"; do
    case "$arg" in
        --adhoc) MODE="adhoc" ;;
        --publish) PUBLISH=1 ;;
        --no-icloud) ICLOUD=0 ;;
        *) usage ;;
    esac
done
# Ad-hoc signatures can't carry a provisioning profile, so they never get iCloud.
[ "${MODE}" = "adhoc" ] && ICLOUD=0
if [ "${MODE}" = "adhoc" ] && [ "${PUBLISH}" = 1 ]; then
    echo "ERROR: --publish needs a signed, notarized build (drop --adhoc)." >&2
    exit 1
fi

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="${ROOT_DIR}/dist"
APP_NAME="LidIA"
ENTITLEMENTS="${ROOT_DIR}/Sources/LidIA/Resources/LidIA.entitlements"
PLIST_SRC="${ROOT_DIR}/Sources/LidIA/Resources/Info.plist"
NOTARY_PROFILE="${LIDIA_NOTARY_PROFILE:-LidIA-notary}"
RELEASE_REPO="${LIDIA_RELEASE_REPO:-Maguana-Labs/lidia}"
SPARKLE_BIN="${ROOT_DIR}/.build/artifacts/sparkle/Sparkle/bin"
# Monotonic build number for Sparkle's version comparison.
BUILD_NUMBER="$(git -C "${ROOT_DIR}" rev-list --count HEAD)"

step() { echo ""; echo "==> $*"; }
fail() { echo "ERROR: $*" >&2; exit 1; }

# ---------------------------------------------------------------- preflight
step "Preflight (${MODE}, version ${VERSION}, build ${BUILD_NUMBER})"
SU_KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "${PLIST_SRC}" 2>/dev/null || true)"
if [ -z "${SU_KEY}" ] || [ "${SU_KEY}" = "REPLACE_WITH_SPARKLE_PUBLIC_ED_KEY" ]; then
    [ "${MODE}" = "sign" ] && fail "SUPublicEDKey is missing or the placeholder. See docs/release-signing.md."
    echo "WARNING: SUPublicEDKey is a placeholder; in-app updates are off in this build."
fi

if [ "${MODE}" = "sign" ]; then
    DEV_ID="$(security find-identity -v -p codesigning 2>/dev/null | grep '"Developer ID Application' | head -1 | sed 's/.*"\(.*\)"/\1/' || true)"
    [ -n "${DEV_ID}" ] || fail "No 'Developer ID Application' certificate in the Keychain. See docs/release-signing.md, step 1."
    xcrun notarytool history --keychain-profile "${NOTARY_PROFILE}" >/dev/null 2>&1 \
        || fail "Notary credentials '${NOTARY_PROFILE}' not found. Run: xcrun notarytool store-credentials \"${NOTARY_PROFILE}\""
    [ "$("${SPARKLE_BIN}/generate_keys" -p 2>/dev/null)" = "${SU_KEY}" ] \
        || fail "The Sparkle private key in this Keychain doesn't match SUPublicEDKey in Info.plist."
    if [ "${PUBLISH}" = 1 ]; then
        gh repo view "${RELEASE_REPO}" >/dev/null 2>&1 || fail "Can't reach GitHub repo ${RELEASE_REPO} with gh."
        if gh release view "v${VERSION}" --repo "${RELEASE_REPO}" >/dev/null 2>&1; then
            fail "Release v${VERSION} already exists in ${RELEASE_REPO}."
        fi
    fi
    SIGN_ID="${DEV_ID}"
    echo "    Identity: ${DEV_ID}"
    if [ "${ICLOUD}" = 1 ]; then
        # iCloud outside the App Store needs a Developer ID profile with iCloud embedded.
        ICLOUD_PROFILE="$("${ROOT_DIR}/scripts/fetch-icloud-profile.sh" developer-id)" \
            || fail "No Developer ID provisioning profile with iCloud for io.lidia.app (steps above), or pass --no-icloud."
        echo "    iCloud profile: ${ICLOUD_PROFILE}"
        echo "    Reminder: the CloudKit schema must be deployed to Production (docs/icloud-sync.md) or releases can't sync."
    fi
else
    SIGN_ID="-"
fi

# ---------------------------------------------------------------- build
step "Building release binaries"
cd "${ROOT_DIR}"
swift build -c release --product LidIA
swift build -c release --product LidiaMCP
BIN_PATH="$(swift build -c release --show-bin-path)"

# ---------------------------------------------------------------- package
step "Packaging ${APP_NAME}.app"
mkdir -p "${DIST_DIR}"
RELEASE_APP="${DIST_DIR}/${APP_NAME}.app"
CONTENTS="${RELEASE_APP}/Contents"
MACOS="${CONTENTS}/MacOS"
RESOURCES="${CONTENTS}/Resources"
FRAMEWORKS="${CONTENTS}/Frameworks"
rm -rf "${RELEASE_APP}"
mkdir -p "${MACOS}" "${RESOURCES}" "${FRAMEWORKS}"

cp "${BIN_PATH}/LidIA" "${MACOS}/LidIA"
cp "${BIN_PATH}/LidiaMCP" "${MACOS}/LidiaMCP"

cp "${PLIST_SRC}" "${CONTENTS}/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" "${CONTENTS}/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD_NUMBER}" "${CONTENTS}/Info.plist"
if [ -n "${LIDIA_GOOGLE_CLIENT_ID:-}" ]; then
    /usr/libexec/PlistBuddy -c "Set :LidIAGoogleClientID ${LIDIA_GOOGLE_CLIENT_ID}" "${CONTENTS}/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :LidIAGoogleClientSecret ${LIDIA_GOOGLE_CLIENT_SECRET:-}" "${CONTENTS}/Info.plist"
fi

XCASSETS_SRC="${ROOT_DIR}/Sources/LidIA/Resources/Assets.xcassets"
if [ -d "${XCASSETS_SRC}" ]; then
    xcrun actool "${XCASSETS_SRC}" --compile "${RESOURCES}" --platform macosx \
        --minimum-deployment-target 26.0 --app-icon AppIcon \
        --output-partial-info-plist /dev/null >/dev/null
fi
ICNS_SRC="${ROOT_DIR}/Sources/LidIA/Resources/AppIcon.icns"
[ -f "${ICNS_SRC}" ] && cp "${ICNS_SRC}" "${RESOURCES}/AppIcon.icns"

# SPM resource bundles (LidIA's own and every dependency's).
find "${BIN_PATH}" -maxdepth 1 -name "*.bundle" -exec cp -R {} "${RESOURCES}/" \;

# MLX Metal shaders: SPM doesn't compile them, so build the metallib here.
MLX_METAL_DIR="${ROOT_DIR}/.build/checkouts/mlx-swift/Source/Cmlx/mlx-generated/metal"
if [ -d "${MLX_METAL_DIR}" ]; then
    MLX_BUNDLE="${RESOURCES}/mlx-swift_Cmlx.bundle"
    mkdir -p "${MLX_BUNDLE}"
    AIR_DIR="$(mktemp -d)"
    while IFS= read -r -d '' f; do
        xcrun -sdk macosx metal -c -I "${MLX_METAL_DIR}" "$f" -o "${AIR_DIR}/$(basename "$f" .metal).air"
    done < <(find "${MLX_METAL_DIR}" -name "*.metal" -print0)
    xcrun -sdk macosx metallib "${AIR_DIR}"/*.air -o "${MLX_BUNDLE}/default.metallib"
    rm -rf "${AIR_DIR}"
    echo "    MLX metallib: $(du -h "${MLX_BUNDLE}/default.metallib" | cut -f1)"
fi

# Sparkle: the native build system puts package frameworks in PackageFrameworks/.
SPARKLE_FW="${BIN_PATH}/Sparkle.framework"
[ -d "${SPARKLE_FW}" ] || SPARKLE_FW="${BIN_PATH}/PackageFrameworks/Sparkle.framework"
[ -d "${SPARKLE_FW}" ] || fail "Sparkle.framework not found under ${BIN_PATH}."
cp -R "${SPARKLE_FW}" "${FRAMEWORKS}/"
if ! otool -l "${MACOS}/LidIA" | grep -q "@executable_path/../Frameworks"; then
    install_name_tool -add_rpath "@executable_path/../Frameworks" "${MACOS}/LidIA"
fi

# App Intents metadata: without it macOS sees no Siri or Shortcuts actions.
# shellcheck source=scripts/lib/appintents-metadata.sh
source "${ROOT_DIR}/scripts/lib/appintents-metadata.sh"
build_appintents_metadata Release "${RELEASE_APP}" || fail "App Intents metadata failed (see above)."

# ---------------------------------------------------------------- sign
step "Signing (inside out)"
sign() {
    if [ "${SIGN_ID}" = "-" ]; then
        codesign --force --sign - "$@"
    else
        codesign --force --sign "${SIGN_ID}" --options runtime --timestamp "$@"
    fi
}
SPARKLE_V="${FRAMEWORKS}/Sparkle.framework/Versions/B"
sign "${SPARKLE_V}/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "${SPARKLE_V}/XPCServices/Downloader.xpc"
sign "${SPARKLE_V}/Autoupdate"
sign "${SPARKLE_V}/Updater.app"
sign "${FRAMEWORKS}/Sparkle.framework"
sign "${MACOS}/LidiaMCP"
APP_ENTITLEMENTS="${ENTITLEMENTS}"
if [ "${ICLOUD}" = 1 ]; then
    # shellcheck source=lib/icloud-entitlements.sh
    source "${ROOT_DIR}/scripts/lib/icloud-entitlements.sh"
    cp "${ICLOUD_PROFILE}" "${CONTENTS}/embedded.provisionprofile"
    APP_ENTITLEMENTS="${DIST_DIR}/LidIA-release.entitlements"
    # Developer ID apps must use CloudKit's Production environment.
    compose_icloud_entitlements "${ENTITLEMENTS}" "${ICLOUD_PROFILE}" Production "${APP_ENTITLEMENTS}"
fi
sign --entitlements "${APP_ENTITLEMENTS}" "${RELEASE_APP}"

codesign --verify --deep --strict --verbose=2 "${RELEASE_APP}"
if [ "${MODE}" = "sign" ]; then
    codesign -d --verbose=2 "${RELEASE_APP}" 2>&1 | grep -E "^(Authority|TeamIdentifier|Runtime)" | head -4
fi
if [ "${ICLOUD}" = 1 ]; then
    SIGNED_ENTITLEMENTS="$(codesign -d --entitlements :- "${RELEASE_APP}" 2>/dev/null)"
    echo "${SIGNED_ENTITLEMENTS}" | grep -q "iCloud.io.lidia.app" || fail "The signed app is missing the iCloud container entitlement."
    echo "${SIGNED_ENTITLEMENTS}" | grep -q "<string>Production</string>" || fail "The signed app isn't on CloudKit's Production environment."
    echo "    iCloud: CloudKit Production, profile embedded"
fi

# ---------------------------------------------------------------- DMG
step "Creating DMG"
DMG="${DIST_DIR}/${APP_NAME}-${VERSION}.dmg"
rm -f "${DMG}"
DMG_STAGE="$(mktemp -d)"
cp -R "${RELEASE_APP}" "${DMG_STAGE}/"
ln -s /Applications "${DMG_STAGE}/Applications"
hdiutil create -volname "${APP_NAME} ${VERSION}" -srcfolder "${DMG_STAGE}" -ov -format UDZO "${DMG}" -quiet
rm -rf "${DMG_STAGE}"
[ "${MODE}" = "sign" ] && sign "${DMG}"
echo "    ${DMG} ($(du -h "${DMG}" | cut -f1))"

# ---------------------------------------------------------------- notarize
if [ "${MODE}" = "sign" ]; then
    step "Notarizing (this takes a few minutes)"
    SUBMIT_LOG="$(mktemp)"
    # Capture first, then check: piping into `grep -q` makes the pipeline fail
    # under pipefail (grep exits early, tee gets SIGPIPE) even when accepted.
    xcrun notarytool submit "${DMG}" --keychain-profile "${NOTARY_PROFILE}" --wait > "${SUBMIT_LOG}" 2>&1 || true
    if ! grep -q "status: Accepted" "${SUBMIT_LOG}"; then
        cat "${SUBMIT_LOG}"
        SUB_ID="$(grep -m1 "id:" "${SUBMIT_LOG}" | awk '{print $2}')"
        [ -n "${SUB_ID}" ] && xcrun notarytool log "${SUB_ID}" --keychain-profile "${NOTARY_PROFILE}" || true
        fail "Notarization was not accepted (log above)."
    fi
    xcrun stapler staple "${DMG}"
    xcrun stapler validate "${DMG}"
    spctl --assess --type open --context context:primary-signature --verbose=2 "${DMG}"
fi

# ---------------------------------------------------------------- appcast
APPCAST="${DIST_DIR}/appcast.xml"
if [ "${MODE}" = "sign" ]; then
    step "Writing signed appcast"
    ED_SIGNATURE="$("${SPARKLE_BIN}/sign_update" -p "${DMG}")"
    cat > "${APPCAST}" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>LidIA</title>
    <link>https://github.com/${RELEASE_REPO}/releases</link>
    <language>en</language>
    <item>
      <title>LidIA ${VERSION}</title>
      <pubDate>$(LC_ALL=C date -R)</pubDate>
      <link>https://github.com/${RELEASE_REPO}/releases/tag/v${VERSION}</link>
      <sparkle:version>${BUILD_NUMBER}</sparkle:version>
      <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
      <enclosure
        url="https://github.com/${RELEASE_REPO}/releases/download/v${VERSION}/${APP_NAME}-${VERSION}.dmg"
        length="$(stat -f%z "${DMG}")"
        type="application/octet-stream"
        sparkle:edSignature="${ED_SIGNATURE}"
      />
    </item>
  </channel>
</rss>
EOF
    # SURequireSignedFeed: the feed is signed too. Don't edit it afterwards.
    "${SPARKLE_BIN}/sign_update" "${APPCAST}"
    echo "    ${APPCAST}"
fi

rm -rf "${RELEASE_APP}"

# ---------------------------------------------------------------- publish
if [ "${PUBLISH}" = 1 ]; then
    step "Publishing v${VERSION} to ${RELEASE_REPO}"
    gh release create "v${VERSION}" "${DMG}" "${APPCAST}" \
        --repo "${RELEASE_REPO}" \
        --title "LidIA ${VERSION}" \
        --notes "Download ${APP_NAME}-${VERSION}.dmg, open it and drag LidIA to Applications. Installed copies update themselves."
    echo "    https://github.com/${RELEASE_REPO}/releases/tag/v${VERSION}"
fi

step "Done"
ls -lh "${DMG}"
if [ "${MODE}" = "sign" ] && [ "${PUBLISH}" = 0 ]; then
    echo "Publish with: $0 ${VERSION} --publish   (or upload dist/ files to a GitHub release yourself)"
fi
