#!/bin/bash
# Get a macOS provisioning profile for io.lidia.app with iCloud (CloudKit) and push,
# so LidIA.app can sync through the iCloud.io.lidia.app container outside the App Store.
# macOS only honors iCloud entitlements on an app that embeds a matching profile
# (Contents/embedded.provisionprofile); without one the app is killed at launch.
#
# Usage:
#   scripts/fetch-icloud-profile.sh development    # for run.sh (Apple Development)
#   scripts/fetch-icloud-profile.sh developer-id   # for create-release.sh (Developer ID)
#
# Prints the path of the profile (copied to .build/provisioning/<kind>.provisionprofile)
# on success; exits non-zero with what to do otherwise.
#
# development:  builds the stub Xcode project in scripts/icloud-provisioning with
#               automatic signing (-allowProvisioningUpdates, and
#               -allowProvisioningDeviceRegistration to register this Mac). Xcode
#               registers the App ID, turns on iCloud + push, and makes a
#               "Mac Team Provisioning Profile: io.lidia.app". Needs Xcode signed in
#               to an account on your team.
#
# The team comes from LIDIA_TEAM_ID, else DEVELOPMENT_TEAM in Config/Local.xcconfig
# (gitignored; see Config/Local.xcconfig.example), else this Mac's signing certificate.
# developer-id: uses a Developer ID profile for io.lidia.app already on this Mac
#               (downloaded from the developer portal, or LIDIA_DEVELOPER_ID_PROFILE),
#               else asks Xcode to make one by exporting the stub with Developer ID.
#               See docs/icloud-sync.md if neither works.

set -euo pipefail

KIND="${1:-development}"
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
STUB_DIR="${ROOT_DIR}/scripts/icloud-provisioning"
OUT_DIR="${ROOT_DIR}/.build/provisioning"
WORK_DIR="${ROOT_DIR}/.build/provisioning-work"
TEAM_ID="${LIDIA_TEAM_ID:-}"
if [ -z "${TEAM_ID}" ] && [ -f "${ROOT_DIR}/Config/Local.xcconfig" ]; then
    TEAM_ID="$(sed -n 's/^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*\([A-Z0-9]*\).*/\1/p' "${ROOT_DIR}/Config/Local.xcconfig" | tail -1)"
fi
if [ -z "${TEAM_ID}" ]; then
    # Else the team (OU) of this Mac's signing certificate for this kind of build.
    CERT_NAME="Apple Development"
    [ "${KIND}" = "developer-id" ] && CERT_NAME="Developer ID Application"
    TEAM_ID="$(security find-certificate -c "${CERT_NAME}" -p 2>/dev/null \
        | openssl x509 -noout -subject 2>/dev/null \
        | sed -n 's/.*OU *= *\([A-Z0-9]\{10\}\).*/\1/p' | head -1 || true)"
fi
if [ -z "${TEAM_ID}" ]; then
    echo "No Apple Developer team: set LIDIA_TEAM_ID or DEVELOPMENT_TEAM in Config/Local.xcconfig." >&2
    exit 1
fi
APP_ID="${TEAM_ID}.io.lidia.app"
CONTAINER="iCloud.io.lidia.app"
mkdir -p "${OUT_DIR}"

log() { echo "$*" >&2; }

# Decodes a profile to a plist file; echoes the plist path.
decode_profile() {
    local plist
    plist="$(mktemp)"
    security cms -D -i "$1" > "${plist}" 2>/dev/null || { rm -f "${plist}"; return 1; }
    echo "${plist}"
}

# True when the profile is for io.lidia.app on macOS, not expired, carries the iCloud
# container, and is the wanted kind (development: lists devices; developer-id: all devices).
profile_matches() {
    local profile="$1" kind="$2" plist
    plist="$(decode_profile "${profile}")" || return 1
    local app_id platform expires all_devices containers now_epoch exp_epoch
    app_id="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.application-identifier' "${plist}" 2>/dev/null || true)"
    platform="$(/usr/libexec/PlistBuddy -c 'Print :Platform:0' "${plist}" 2>/dev/null || true)"
    expires="$(plutil -extract ExpirationDate raw -o - "${plist}" 2>/dev/null || true)"
    all_devices="$(/usr/libexec/PlistBuddy -c 'Print :ProvisionsAllDevices' "${plist}" 2>/dev/null || echo false)"
    containers="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.developer.icloud-container-identifiers' "${plist}" 2>/dev/null || true)"
    rm -f "${plist}"
    [ "${app_id}" = "${APP_ID}" ] || return 1
    [ "${platform}" = "OSX" ] || return 1
    [[ "${containers}" == *"${CONTAINER}"* ]] || return 1
    now_epoch="$(date +%s)"
    exp_epoch="$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "${expires}" +%s 2>/dev/null || echo 0)"
    [ "${exp_epoch}" -gt "$((now_epoch + 86400))" ] || return 1
    if [ "${kind}" = "developer-id" ]; then
        [ "${all_devices}" = "true" ] || return 1
    else
        [ "${all_devices}" != "true" ] || return 1
    fi
    return 0
}

# Newest matching profile among the ones Xcode and the portal download put on this Mac.
find_installed_profile() {
    local kind="$1" best="" best_time=0 f t
    for dir in "${HOME}/Library/Developer/Xcode/UserData/Provisioning Profiles" "${HOME}/Library/MobileDevice/Provisioning Profiles"; do
        [ -d "${dir}" ] || continue
        for f in "${dir}"/*.provisionprofile "${dir}"/*.mobileprovision; do
            [ -f "${f}" ] || continue
            if profile_matches "${f}" "${kind}"; then
                t="$(stat -f %m "${f}")"
                if [ "${t}" -gt "${best_time}" ]; then best="${f}"; best_time="${t}"; fi
            fi
        done
    done
    [ -n "${best}" ] && echo "${best}"
}

install_profile() {
    cp "$1" "${OUT_DIR}/${KIND}.provisionprofile"
    echo "${OUT_DIR}/${KIND}.provisionprofile"
}

# Reuse the last copy while it's still good.
if [ -f "${OUT_DIR}/${KIND}.provisionprofile" ] && profile_matches "${OUT_DIR}/${KIND}.provisionprofile" "${KIND}"; then
    echo "${OUT_DIR}/${KIND}.provisionprofile"
    exit 0
fi

case "${KIND}" in
    development)
        log "==> Getting a development provisioning profile for io.lidia.app (iCloud)…"
        rm -rf "${WORK_DIR}"
        if ! xcodebuild -project "${STUB_DIR}/LidIAProvisioning.xcodeproj" -scheme LidIAProvisioning \
            -destination 'platform=macOS' -configuration Debug \
            -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
            -derivedDataPath "${WORK_DIR}" DEVELOPMENT_TEAM="${TEAM_ID}" build >"${OUT_DIR}/development.log" 2>&1; then
            log "    xcodebuild couldn't get a profile. Last lines of ${OUT_DIR}/development.log:"
            grep -E "error:" "${OUT_DIR}/development.log" | tail -5 >&2 || true
            log "    Is Xcode signed in (Xcode › Settings › Accounts) to an account on team ${TEAM_ID}?"
            exit 1
        fi
        install_profile "${WORK_DIR}/Build/Products/Debug/LidIA.app/Contents/embedded.provisionprofile"
        ;;
    developer-id)
        if [ -n "${LIDIA_DEVELOPER_ID_PROFILE:-}" ]; then
            profile_matches "${LIDIA_DEVELOPER_ID_PROFILE}" developer-id \
                || { log "LIDIA_DEVELOPER_ID_PROFILE isn't a valid Developer ID profile for io.lidia.app with iCloud."; exit 1; }
            install_profile "${LIDIA_DEVELOPER_ID_PROFILE}"
            exit 0
        fi
        if found="$(find_installed_profile developer-id)"; then
            install_profile "${found}"
            exit 0
        fi
        log "==> Asking Xcode for a Developer ID provisioning profile for io.lidia.app (iCloud)…"
        rm -rf "${WORK_DIR}"
        mkdir -p "${WORK_DIR}"
        EXPORT_OPTIONS="${WORK_DIR}/ExportOptions-DeveloperID.plist"
        cp "${STUB_DIR}/ExportOptions-DeveloperID.plist" "${EXPORT_OPTIONS}"
        /usr/libexec/PlistBuddy -c "Set :teamID ${TEAM_ID}" "${EXPORT_OPTIONS}"
        if xcodebuild -project "${STUB_DIR}/LidIAProvisioning.xcodeproj" -scheme LidIAProvisioning \
                -destination 'generic/platform=macOS' -configuration Release -allowProvisioningUpdates \
                -derivedDataPath "${WORK_DIR}/dd" -archivePath "${WORK_DIR}/LidIA.xcarchive" DEVELOPMENT_TEAM="${TEAM_ID}" archive >"${OUT_DIR}/developer-id.log" 2>&1 \
           && xcodebuild -exportArchive -archivePath "${WORK_DIR}/LidIA.xcarchive" \
                -exportOptionsPlist "${EXPORT_OPTIONS}" \
                -exportPath "${WORK_DIR}/export" -allowProvisioningUpdates >>"${OUT_DIR}/developer-id.log" 2>&1 \
           && [ -f "${WORK_DIR}/export/LidIA.app/Contents/embedded.provisionprofile" ]; then
            install_profile "${WORK_DIR}/export/LidIA.app/Contents/embedded.provisionprofile"
            exit 0
        fi
        log "    Xcode couldn't make a Developer ID profile (see ${OUT_DIR}/developer-id.log)."
        log "    Make it once in the developer portal (docs/icloud-sync.md, \"Developer ID profile\"):"
        log "      developer.apple.com/account › Certificates, IDs & Profiles › Profiles › +"
        log "      › Distribution: Developer ID › Profile type: Mac › App ID: io.lidia.app"
        log "      › Certificate: Developer ID Application (${TEAM_ID}) › Name: LidIA Developer ID iCloud"
        log "      › Generate › Download, then put the file in"
        log "      ~/Library/Developer/Xcode/UserData/Provisioning Profiles/ (or set LIDIA_DEVELOPER_ID_PROFILE to it)."
        exit 1
        ;;
    *)
        log "Usage: $0 development|developer-id"
        exit 2
        ;;
esac
