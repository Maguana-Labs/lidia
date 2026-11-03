#!/bin/bash
# Builds the public LidIA snapshot: the tree of one private commit, minus private
# material, as ONE new commit on top of the public repo's main. It never pushes.
#
# Usage:
#   scripts/public-snapshot.sh [--rev <commit>] [--out <dir>] [--message-file <file>]
#   scripts/public-snapshot.sh --scan <dir>      # only run the denylist and secret scans
#
#   --rev           the private commit to export (default HEAD)
#   --out           where to build it (default: $TMPDIR/lidia-public-snapshot); emptied first
#   --message-file  the commit message (default: a generated summary of the changed areas)
#
# What it does:
#   1. Exports the tree of --rev into <out>/export, minus EXCLUDES below.
#   2. Scans the export: every term in the personal denylist (case-insensitive,
#      whole words) and secret-shaped strings. Any hit stops the script.
#      The denylist is personal, so it is NOT in the repo: it's read from
#      $LIDIA_PUBLIC_DENYLIST, default ~/.config/lidia/public-denylist.txt
#      (one term per line, "#" comments, "re:<regex>" for an extended regex).
#   3. Fetches the public main (read-only), clones it into <out>/public, replaces
#      its tree with the export and commits once, so pushing is a fast-forward.
#      Public-only files are dropped unless listed in KEEP_PUBLIC.
#   4. Checks the commit's file list matches the export and scans it again.
#
# The commit's author and committer come from LIDIA_PUBLIC_NAME and
# LIDIA_PUBLIC_EMAIL, else from ~/.config/lidia/public-identity ("name=…" and
# "email=…" lines). Use your GitHub noreply address, never a personal one.
#
# It prints the push command; pushing is up to you, after review.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REV="HEAD"
OUT_DIR="${TMPDIR:-/tmp}/lidia-public-snapshot"
MESSAGE_FILE=""
SCAN_ONLY=""
DENYLIST="${LIDIA_PUBLIC_DENYLIST:-${HOME}/.config/lidia/public-denylist.txt}"
IDENTITY_FILE="${HOME}/.config/lidia/public-identity"
PUBLIC_REMOTE="${LIDIA_PUBLIC_REMOTE:-origin}"
PUBLIC_BRANCH="main"

# Private-only material, as paths relative to the repo root (a trailing "/" is a folder).
EXCLUDES=(
    "comparison/"                   # real meeting transcripts and summaries (Granola vs LidIA)
    "docs/plans/"                   # internal planning notes
    "docs/analysis/"                # the revamp analysis (internal)
    ".claude/settings.local.json"   # personal tool permissions and local paths
    "Config/Local.xcconfig"         # the owner's signing team (gitignored; listed for safety)
)

# Files that exist only in the public repo and must survive a snapshot. Every
# other public-only file is dropped (it is an old copy of something the private
# repo moved or deleted).
KEEP_PUBLIC=(
)

# Secret-shaped strings (extended regexes). Prefixes alone ("sk-test") don't
# count: real keys are long.
SECRET_PATTERNS=(
    'sk-ant-[A-Za-z0-9_-]{20,}'
    '\bsk-[A-Za-z0-9_-]{20,}'
    'AIza[0-9A-Za-z_-]{30,}'
    'ghp_[A-Za-z0-9]{30,}'
    'github_pat_[A-Za-z0-9_]{30,}'
    'xox[abprs]-[A-Za-z0-9-]{10,}'
    'GOCSPX-[A-Za-z0-9_-]{20,}'
    'lin_api_[A-Za-z0-9]{20,}'
    'AKIA[0-9A-Z]{16}'
    '-----BEGIN [A-Z ]*PRIVATE KEY-----'
)

die() { echo "error: $*" >&2; exit 1; }
log() { echo "==> $*"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --rev) REV="$2"; shift 2 ;;
        --out) OUT_DIR="$2"; shift 2 ;;
        --message-file) MESSAGE_FILE="$2"; shift 2 ;;
        --scan) SCAN_ONLY="$2"; shift 2 ;;
        -h|--help) sed -n '2,32p' "$0"; exit 0 ;;
        *) die "unknown argument: $1 (see --help)" ;;
    esac
done

# --- Scans -------------------------------------------------------------------

# Files under $1 to scan, NUL-separated, without .git.
scan_files() {
    find "$1" -path "$1/.git" -prune -o -type f -print0
}

is_image() {
    case "$1" in
        *.png|*.PNG|*.jpg|*.jpeg|*.gif|*.webp|*.icns|*.ico|*.heic|*.tif|*.tiff) return 0 ;;
        *) return 1 ;;
    esac
}

# Prints "file: term" for every denylist or secret hit under $1; returns 1 on any hit.
scan_tree() {
    local dir="$1" hits=0 words regexes term file
    [ -f "${DENYLIST}" ] || die "no denylist at ${DENYLIST} (one term per line; see the header of $0)"
    words="$(mktemp)"; regexes="$(mktemp)"
    while IFS= read -r term || [ -n "${term}" ]; do
        term="${term%$'\r'}"
        term="$(printf '%s' "${term}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
        [ -z "${term}" ] && continue
        [[ "${term}" == \#* ]] && continue
        if [[ "${term}" == re:* ]]; then echo "${term#re:}" >> "${regexes}"; else echo "${term}" >> "${words}"; fi
    done < "${DENYLIST}"
    printf '%s\n' "${SECRET_PATTERNS[@]}" >> "${regexes}"

    while IFS= read -r -d '' file; do
        local rel="${file#"${dir}"/}" text
        if is_image "${file}"; then
            continue # images are reviewed by eye (listed at the end)
        fi
        if grep -qI . "${file}" 2>/dev/null || [ ! -s "${file}" ]; then
            text="${file}"
        else
            # Binary (e.g. a SQLite fixture): scan its printable strings.
            text="$(mktemp)"; strings -n 4 "${file}" > "${text}" 2>/dev/null || true
        fi
        if [ -s "${words}" ] && grep -i -w -F -o -f "${words}" "${text}" > /dev/null 2>&1; then
            grep -i -w -F -o -f "${words}" "${text}" | sort -u | sed "s|^|  denylist  ${rel}: |"
            hits=1
        fi
        if grep -i -E -o -f "${regexes}" "${text}" > /dev/null 2>&1; then
            grep -i -E -o -f "${regexes}" "${text}" | sort -u | sed "s|^|  pattern   ${rel}: |" | cut -c1-160
            hits=1
        fi
        if [ "${text}" != "${file}" ]; then rm -f "${text}"; fi
    done < <(scan_files "${dir}")
    rm -f "${words}" "${regexes}"
    return "${hits}"
}

list_images() {
    while IFS= read -r -d '' file; do
        if is_image "${file}"; then echo "  ${file#"$1"/}"; fi
    done < <(scan_files "$1") | sort
}

if [ -n "${SCAN_ONLY}" ]; then
    log "Scanning ${SCAN_ONLY}"
    if scan_tree "${SCAN_ONLY}"; then log "Clean: no denylist terms, no secrets"; else die "scan found the hits above"; fi
    log "Images to check by eye:"; list_images "${SCAN_ONLY}"
    exit 0
fi

# --- Export ------------------------------------------------------------------

cd "${ROOT_DIR}"
SHA="$(git rev-parse --verify "${REV}^{commit}")" || die "no such commit: ${REV}"
case "${OUT_DIR}" in
    ""|/|"${HOME}"|"${ROOT_DIR}"|"${ROOT_DIR}"/*) die "refusing --out ${OUT_DIR}: use a scratch folder outside the repo" ;;
esac
EXPORT="${OUT_DIR}/export"
PUBLIC="${OUT_DIR}/public"
rm -rf "${OUT_DIR}"
mkdir -p "${EXPORT}"

log "Exporting ${SHA:0:12} ($(git log -1 --format=%s "${SHA}" | cut -c1-60))"
git archive --format=tar "${SHA}" | tar -x -C "${EXPORT}"
for path in "${EXCLUDES[@]}"; do
    rm -rf "${EXPORT:?}/${path}"
done
# Folders the excludes emptied.
find "${EXPORT}" -type d -empty -delete
(cd "${EXPORT}" && find . \( -type f -o -type l \) | sed 's|^\./||' | sort) > "${OUT_DIR}/export-files.txt"
log "Exported $(wc -l < "${OUT_DIR}/export-files.txt" | tr -d ' ') files; excluded: ${EXCLUDES[*]}"
[ -f "${EXPORT}/Packages/LidIAKit/Package.swift" ] || die "Packages/LidIAKit is missing from the export: a clean clone wouldn't build"

log "Scanning the export (denylist: ${DENYLIST})"
scan_tree "${EXPORT}" || die "the export has personal terms or secrets (above); fix them in the private repo first"

# --- Public commit ------------------------------------------------------------

PUBLIC_URL="$(git remote get-url "${PUBLIC_REMOTE}")" || die "no remote ${PUBLIC_REMOTE}"
log "Fetching ${PUBLIC_REMOTE}/${PUBLIC_BRANCH} (read-only) from ${PUBLIC_URL}"
git fetch --quiet "${PUBLIC_REMOTE}" "${PUBLIC_BRANCH}"
PUBLIC_SHA="$(git rev-parse "FETCH_HEAD^{commit}")"

# A separate clone of the public repo only, so no private history comes along.
git clone --quiet --single-branch --branch "${PUBLIC_BRANCH}" "${PUBLIC_URL}" "${PUBLIC}"
[ "$(git -C "${PUBLIC}" rev-parse HEAD)" = "${PUBLIC_SHA}" ] \
    || die "the clone's ${PUBLIC_BRANCH} isn't the fetched ${PUBLIC_SHA:0:12}; run again"

# Public-only files: keep the listed ones, report the rest.
git -C "${PUBLIC}" ls-files | sort > "${OUT_DIR}/public-before.txt"
comm -23 "${OUT_DIR}/public-before.txt" "${OUT_DIR}/export-files.txt" > "${OUT_DIR}/public-only.txt"
KEEP_TMP="${OUT_DIR}/keep"
mkdir -p "${KEEP_TMP}"
for path in "${KEEP_PUBLIC[@]+"${KEEP_PUBLIC[@]}"}"; do
    if [ -f "${PUBLIC}/${path}" ] && ! [ -e "${EXPORT}/${path}" ]; then
        mkdir -p "${KEEP_TMP}/$(dirname "${path}")"
        cp -p "${PUBLIC}/${path}" "${KEEP_TMP}/${path}"
    fi
done

# Replace the tree: everything but .git goes, then the export (and kept files) come in.
find "${PUBLIC}" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +
(cd "${EXPORT}" && tar -cf - .) | (cd "${PUBLIC}" && tar -xf -)
(cd "${KEEP_TMP}" && tar -cf - .) | (cd "${PUBLIC}" && tar -xf -)
# A file the public .gitignore would hide must still be committed: add by force.
git -C "${PUBLIC}" add --all --force .

if [ -s "${OUT_DIR}/public-only.txt" ]; then
    log "Public-only files dropped (not in KEEP_PUBLIC):"
    sed 's/^/  /' "${OUT_DIR}/public-only.txt"
fi

# Identity: never a personal address.
NAME="${LIDIA_PUBLIC_NAME:-}"; EMAIL="${LIDIA_PUBLIC_EMAIL:-}"
if [ -f "${IDENTITY_FILE}" ]; then
    [ -n "${NAME}" ] || NAME="$(sed -n 's/^name=//p' "${IDENTITY_FILE}" | head -1)"
    [ -n "${EMAIL}" ] || EMAIL="$(sed -n 's/^email=//p' "${IDENTITY_FILE}" | head -1)"
fi
[ -n "${NAME}" ] && [ -n "${EMAIL}" ] \
    || die "set LIDIA_PUBLIC_NAME and LIDIA_PUBLIC_EMAIL, or name=/email= in ${IDENTITY_FILE}"

MESSAGE="${OUT_DIR}/commit-message.txt"
if [ -n "${MESSAGE_FILE}" ]; then
    cp "${MESSAGE_FILE}" "${MESSAGE}"
else
    {
        echo "Sync from the private repo ($(git log -1 --date=short --format=%cd "${SHA}"))"
        echo
        echo "Changed areas since the last public sync:"
        git -C "${PUBLIC}" diff --cached --dirstat=files,3 | sed 's/^ *[0-9.]*% /- /'
    } > "${MESSAGE}"
fi
log "Scanning the commit message"
MSG_DIR="${OUT_DIR}/message-scan"; mkdir -p "${MSG_DIR}"; cp "${MESSAGE}" "${MSG_DIR}/"
scan_tree "${MSG_DIR}" || die "the commit message has personal terms (above)"

git -C "${PUBLIC}" -c user.name="${NAME}" -c user.email="${EMAIL}" -c commit.gpgsign=false \
    commit --quiet --no-verify --file "${MESSAGE}" \
    --author "${NAME} <${EMAIL}>"
NEW_SHA="$(git -C "${PUBLIC}" rev-parse HEAD)"

# --- Checks ------------------------------------------------------------------

[ "$(git -C "${PUBLIC}" rev-parse HEAD^)" = "${PUBLIC_SHA}" ] || die "the snapshot isn't one commit on top of public ${PUBLIC_BRANCH}"
git -C "${PUBLIC}" ls-files | sort > "${OUT_DIR}/public-after.txt"
(cat "${OUT_DIR}/export-files.txt"; for p in "${KEEP_PUBLIC[@]+"${KEEP_PUBLIC[@]}"}"; do [ -f "${KEEP_TMP}/${p}" ] && echo "${p}"; done) \
    | sort -u > "${OUT_DIR}/expected-files.txt"
if ! diff -u "${OUT_DIR}/expected-files.txt" "${OUT_DIR}/public-after.txt" > "${OUT_DIR}/files.diff"; then
    cat "${OUT_DIR}/files.diff" >&2
    die "the commit's tracked files don't match the export"
fi
log "Tracked files match the export ($(wc -l < "${OUT_DIR}/public-after.txt" | tr -d ' ') files)"

log "Scanning the committed tree"
CHECKOUT="${OUT_DIR}/committed"
mkdir -p "${CHECKOUT}"
git -C "${PUBLIC}" archive --format=tar HEAD | tar -x -C "${CHECKOUT}"
scan_tree "${CHECKOUT}" || die "the committed tree has personal terms or secrets (above)"
rm -rf "${CHECKOUT}" "${KEEP_TMP}" "${MSG_DIR}"

log "Images to check by eye before pushing:"
list_images "${PUBLIC}"

echo
log "Snapshot ready: ${PUBLIC}"
echo "    commit ${NEW_SHA} on top of public ${PUBLIC_BRANCH} ${PUBLIC_SHA:0:12}"
echo "    author ${NAME} <${EMAIL}>"
echo
echo "Review it, then push it yourself (a fast-forward):"
echo "    git -C \"${PUBLIC}\" show --stat HEAD | less"
echo "    git -C \"${PUBLIC}\" push origin ${PUBLIC_BRANCH}"
