#!/bin/bash
# Sourced by run.sh and scripts/create-release.sh.
#
# compose_icloud_entitlements <base.entitlements> <profile> <Development|Production> <out.plist>
#
# Writes LidIA's entitlements plus the iCloud ones the provisioning profile allows:
# the app and team identifiers, CloudKit on iCloud.io.lidia.app, the CloudKit
# environment (Development for run.sh builds, Production for Developer ID releases,
# which Apple requires outside the App Store) and push (aps-environment, whatever the
# profile grants). Every key must be allowed by the embedded profile, or macOS refuses
# to launch the app.
compose_icloud_entitlements() {
    local base="$1" profile="$2" environment="$3" out="$4" decoded app_id team aps
    decoded="$(mktemp)"
    security cms -D -i "${profile}" > "${decoded}"
    app_id="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.application-identifier' "${decoded}")"
    team="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.developer.team-identifier' "${decoded}")"
    aps="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.developer.aps-environment' "${decoded}" 2>/dev/null || true)"
    rm -f "${decoded}"

    cp "${base}" "${out}"
    local pb=/usr/libexec/PlistBuddy
    "${pb}" -c "Add :com.apple.application-identifier string ${app_id}" "${out}"
    "${pb}" -c "Add :com.apple.developer.team-identifier string ${team}" "${out}"
    "${pb}" -c "Add :com.apple.developer.icloud-services array" "${out}"
    "${pb}" -c "Add :com.apple.developer.icloud-services:0 string CloudKit" "${out}"
    "${pb}" -c "Add :com.apple.developer.icloud-container-identifiers array" "${out}"
    "${pb}" -c "Add :com.apple.developer.icloud-container-identifiers:0 string iCloud.io.lidia.app" "${out}"
    "${pb}" -c "Add :com.apple.developer.icloud-container-environment string ${environment}" "${out}"
    if [ -n "${aps}" ]; then
        "${pb}" -c "Add :com.apple.developer.aps-environment string ${aps}" "${out}"
    fi
}
