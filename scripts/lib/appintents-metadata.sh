#!/bin/bash
# App Intents metadata for the SwiftPM-built Mac app.
#
# Xcode runs `appintentsmetadataprocessor` after linking; without its output
# (Contents/Resources/Metadata.appintents) macOS sees none of LidIA's intents:
# no Siri, no Shortcuts actions, no App Shortcuts. `swift build` doesn't run it,
# but its build system (Swift Build) already compiles with -emit-const-values,
# which is what the processor reads. So this does the rest of Xcode's steps:
#
#   1. LidIAAppIntents (the shared package in LidIAKit): its own metadata,
#      like Xcode's `<Package>.appintents`.
#   2. LidIA (the app): its metadata, merging step 1 as a static dependency.
#   3. App Shortcut phrases per language (Sources/LidIA/Resources/AppShortcuts),
#      validated with `appshortcutstringsprocessor`.
#   4. `appintentsnltrainingprocessor`: Siri's phrase-matching assets.
#
# Usage (sourced): build_appintents_metadata <Debug|Release> <path/to/LidIA.app>
# The app's Info.plist must already be in place (the bundle ID is read from it).
# Needs Xcode (not just the Command Line Tools). Fails loudly: an app without
# metadata builds and runs, but silently has no intents.

build_appintents_metadata() {
    local config="$1"
    local app_dir="$2"
    local root_dir
    root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
    local contents="${app_dir}/Contents"
    local resources="${contents}/Resources"
    local intermediates="${root_dir}/.build/out/Intermediates.noindex"
    local products="${root_dir}/.build/out/Products/${config}"
    local arch
    arch="$(uname -m)"

    if [ ! -d "${intermediates}" ]; then
        echo "    Error: ${intermediates} not found. App Intents metadata needs SwiftPM's default" >&2
        echo "    build system (Swift Build), which emits the const values the processor reads." >&2
        return 1
    fi

    local toolchain sdk xcode_build bundle_id min_os
    toolchain="$(cd "$(dirname "$(xcrun --find swift)")/../.." && pwd)"
    sdk="$(xcrun --sdk macosx --show-sdk-path)"
    xcode_build="$(xcodebuild -version | awk '/Build version/ {print $3}')"
    bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${contents}/Info.plist")"
    min_os="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "${contents}/Info.plist" 2>/dev/null || echo 26.0)"
    local triple="${arch}-apple-macos${min_os}"

    local work="${root_dir}/.build/appintents/${config}"
    rm -rf "${work}"
    mkdir -p "${work}"
    : > "${work}/empty.list"

    # $1 module, $2 build dir suffix ("-t" library, "-p" product), $3 binary,
    # $4 output dir, $5 bundle id, $6 static metadata list.
    _lidia_extract() {
        local module="$1" suffix="$2" binary="$3" output="$4" bid="$5" static_list="$6"
        local objdir
        objdir="$(find "${intermediates}" -type d -path "*/${config}/${module}${suffix}.build/Objects-normal/${arch}" -print -quit)"
        if [ -z "${objdir}" ]; then
            echo "    Error: no build products for ${module} (${config}, ${arch})." >&2
            return 1
        fi
        find "${objdir}" -name '*.swiftconstvalues' > "${work}/${module}.constvalues"
        if [ ! -s "${work}/${module}.constvalues" ]; then
            echo "    Error: ${module} has no .swiftconstvalues; was it built with Swift Build?" >&2
            return 1
        fi
        xcrun appintentsmetadataprocessor \
            --toolchain-dir "${toolchain}" \
            --module-name "${module}" \
            --sdk-root "${sdk}" \
            --xcode-version "${xcode_build}" \
            --platform-family macOS \
            --deployment-target "${min_os}" \
            --bundle-identifier "${bid}" \
            --output "${output}" \
            --target-triple "${triple}" \
            --binary-file "${binary}" \
            --dependency-file "${work}/${module}_dependency_info.dat" \
            --stringsdata-file "${work}/${module}.stringsdata" \
            --source-file-list "${objdir}/${module}.SwiftFileList" \
            --metadata-file-list "${work}/empty.list" \
            --static-metadata-file-list "${static_list}" \
            --swift-const-vals-list "${work}/${module}.constvalues" \
            --force \
            --compile-time-extraction \
            --deployment-aware-processing \
            > "${work}/${module}.log" 2>&1 || {
                cat "${work}/${module}.log" >&2
                return 1
            }
        # The processor prints warnings it doesn't fail on; show them.
        grep -i "warning\|error" "${work}/${module}.log" | grep -v "^$" | sed 's/^/    /' || true
    }

    # 1. The shared package (a static library linked into the app).
    _lidia_extract LidIAAppIntents -t "${products}/LidIAAppIntents.o" \
        "${work}/LidIAAppIntents.appintents" "lidiakit.LidIAAppIntents" "${work}/empty.list" || return 1
    echo "${work}/LidIAAppIntents.appintents/Metadata.appintents/extract.actionsdata" > "${work}/static.list"

    # 2. The app, with the package merged in. Writes Resources/Metadata.appintents.
    rm -rf "${resources}/Metadata.appintents"
    _lidia_extract LidIA -p "${contents}/MacOS/LidIA" "${resources}" "${bundle_id}" "${work}/static.list" || return 1

    # 3. App Shortcut phrases, per language, in the main bundle.
    local strings_args=()
    local lproj
    for lproj in "${root_dir}"/Sources/LidIA/Resources/AppShortcuts/*.lproj; do
        [ -f "${lproj}/AppShortcuts.strings" ] || continue
        mkdir -p "${resources}/$(basename "${lproj}")"
        cp "${lproj}/AppShortcuts.strings" "${resources}/$(basename "${lproj}")/AppShortcuts.strings"
        strings_args+=(--source-file "${resources}/$(basename "${lproj}")/AppShortcuts.strings")
    done
    if [ ${#strings_args[@]} -gt 0 ]; then
        xcrun appshortcutstringsprocessor "${strings_args[@]}" \
            --input-data-path "${resources}/Metadata.appintents" \
            --platform-family macOS --deployment-target "${min_os}" \
            --metadata-file-list "${work}/empty.list" \
            > "${work}/shortcut-strings.log" 2>&1 || {
                cat "${work}/shortcut-strings.log" >&2
                return 1
            }
    fi

    # 4. Siri's phrase-matching (SSU) assets, next to the metadata.
    mkdir -p "${work}/ssu"
    xcrun appintentsnltrainingprocessor \
        --infoplist-path "${contents}/Info.plist" \
        --temp-dir-path "${work}/ssu" \
        --bundle-id "${bundle_id}" \
        --product-path "${resources}" \
        --extracted-metadata-path "${resources}/Metadata.appintents" \
        --metadata-file-list "${work}/empty.list" \
        --archive-ssu-assets \
        > "${work}/nltraining.log" 2>&1 || {
            cat "${work}/nltraining.log" >&2
            return 1
        }

    local actions
    actions="$(/usr/bin/python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); print(len(d.get("actions",{})), len(d.get("entities",{})), len(d.get("autoShortcuts",[])))' "${resources}/Metadata.appintents/extract.actionsdata")"
    set -- ${actions}
    echo "==> App Intents metadata: $1 intents, $2 entities, $3 App Shortcuts"
}
