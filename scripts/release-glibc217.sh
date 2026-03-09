#!/usr/bin/env bash
# release-glibc217.sh - Release patched Bun (GLIBC ≤2.17 compatible) to GitHub
#
# Usage:
#   ./scripts/release-glibc217.sh              # auto-increment version
#   ./scripts/release-glibc217.sh v0.0.5       # specify version explicitly
#   ./scripts/release-glibc217.sh --dry-run    # dry run, no actual release
#
# Prerequisites:
#   - GITHUB_TOKEN env var set
#   - Built binary at build/release/bun (run: bun run build:release first)
#   - git, curl, jq (or python3) installed

set -euo pipefail

REPO="YuunqiLiu/bun"
BINARY="build/release/bun"
UPSTREAM_BUN_VERSION="1.3.10"
DRY_RUN=false
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ---------- helpers ----------

info()  { echo "[INFO]  $*"; }
ok()    { echo "[OK]    $*"; }
err()   { echo "[ERROR] $*" >&2; exit 1; }

require_cmd() {
    for cmd in "$@"; do
        command -v "$cmd" &>/dev/null || err "Required command not found: $cmd"
    done
}

api_get() {
    curl -fsSL \
        -H "Authorization: token ${GITHUB_TOKEN}" \
        -H "Accept: application/vnd.github.v3+json" \
        "$@"
}

api_post() {
    curl -fsSL \
        -X POST \
        -H "Authorization: token ${GITHUB_TOKEN}" \
        -H "Accept: application/vnd.github.v3+json" \
        -H "Content-Type: application/json" \
        "$@"
}

# ---------- parse args ----------

EXPLICIT_VERSION=""
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        v[0-9]*) EXPLICIT_VERSION="$arg" ;;
        *) err "Unknown argument: $arg" ;;
    esac
done

# ---------- preflight checks ----------

require_cmd git curl python3
cd "$ROOT_DIR"

[[ -n "${GITHUB_TOKEN:-}" ]] || err "GITHUB_TOKEN is not set"

[[ -f "$BINARY" ]] || err "Binary not found: $BINARY  (run 'bun run build:release' first)"

info "Binary: $(ls -lh $BINARY | awk '{print $5, $9}')"
info "Bun version: $($BINARY --version 2>/dev/null || echo 'unknown')"

# ---------- determine next version ----------

get_latest_release_version() {
    api_get "https://api.github.com/repos/${REPO}/releases?per_page=10" 2>/dev/null \
        | python3 -c "
import sys, json, re
releases = json.load(sys.stdin)
versions = []
for r in releases:
    m = re.match(r'v(\d+)\.(\d+)\.(\d+)', r.get('tag_name',''))
    if m:
        versions.append((int(m.group(1)), int(m.group(2)), int(m.group(3))))
if not versions:
    print('none')
else:
    latest = sorted(versions)[-1]
    print('v{}.{}.{}'.format(*latest))
" 2>/dev/null || echo "none"
}

if [[ -n "$EXPLICIT_VERSION" ]]; then
    NEXT_VERSION="$EXPLICIT_VERSION"
    info "Using explicit version: $NEXT_VERSION"
else
    LATEST=$(get_latest_release_version)
    info "Latest release on GitHub: $LATEST"

    if [[ "$LATEST" == "none" ]]; then
        NEXT_VERSION="v0.0.1"
    else
        # Increment patch version
        NEXT_VERSION=$(python3 -c "
v = '${LATEST}'.lstrip('v').split('.')
v[2] = str(int(v[2]) + 1)
print('v' + '.'.join(v))
")
    fi
    info "Next version: $NEXT_VERSION"
fi

# Check tag doesn't already exist
EXISTING_TAG=$(api_get "https://api.github.com/repos/${REPO}/releases/tags/${NEXT_VERSION}" 2>/dev/null \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('tag_name',''))" 2>/dev/null || echo "")
if [[ -n "$EXISTING_TAG" ]]; then
    err "Release $NEXT_VERSION already exists on GitHub"
fi

# ---------- get current commit SHA ----------

COMMIT_SHA=$(git rev-parse HEAD)
BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "glibc217-compat")
info "Commit: $COMMIT_SHA (branch: $BRANCH)"

# ---------- build release notes ----------

RELEASE_NOTES="## Bun ${UPSTREAM_BUN_VERSION} — GLIBC ≤2.17 Compatible Build

This is a patched build of [Bun ${UPSTREAM_BUN_VERSION}](https://github.com/oven-sh/bun/releases/tag/bun-v${UPSTREAM_BUN_VERSION}) compatible with **CentOS 7 / RHEL 7** and other systems running **glibc 2.17**.

### What's patched

Upstream Bun v${UPSTREAM_BUN_VERSION} requires GLIBC 2.25. This build adds workarounds for 3 missing symbols:

| Symbol | Upstream requirement | This build |
|--------|---------------------|------------|
| \`getrandom\` | GLIBC_2.25 | → \`syscall(SYS_getrandom)\` |
| \`quick_exit\` | GLIBC_2.24 | → \`_exit()\` |
| \`__cxa_thread_atexit_impl\` | GLIBC_2.18 | → \`__cxa_atexit()\` |

**Max GLIBC required: 2.17** (\`clock_getres\`)

### Verification

\`\`\`
objdump -T bun-linux-x64 | grep -oP 'GLIBC_[\\d.]+' | sort -t. -k2,2n -u | tail -1
# → GLIBC_2.17
\`\`\`

### Download & use

\`\`\`bash
curl -LO https://github.com/${REPO}/releases/download/${NEXT_VERSION}/bun-linux-x64
chmod +x bun-linux-x64
./bun-linux-x64 --version
\`\`\`

### Dynamic dependencies

Only standard glibc sub-libraries: \`libc\`, \`libpthread\`, \`libdl\`, \`libm\`

---
Built from commit: \`${COMMIT_SHA:0:7}\` | Branch: \`${BRANCH}\`"

# ---------- dry run ----------

if [[ "$DRY_RUN" == "true" ]]; then
    echo ""
    echo "=== DRY RUN - no changes made ==="
    echo "Would create release: $NEXT_VERSION"
    echo "Would upload: $BINARY ($(ls -lh $BINARY | awk '{print $5}'))"
    echo ""
    echo "Release notes:"
    echo "$RELEASE_NOTES"
    exit 0
fi

# ---------- create git tag ----------

info "Creating git tag $NEXT_VERSION on commit $COMMIT_SHA ..."
git tag -a "$NEXT_VERSION" -m "Release $NEXT_VERSION — Bun ${UPSTREAM_BUN_VERSION} GLIBC 2.17 compat" "$COMMIT_SHA"
git push origin "$NEXT_VERSION"
ok "Tag pushed: $NEXT_VERSION"

# ---------- create GitHub release ----------

info "Creating GitHub release $NEXT_VERSION ..."
# Build the JSON payload and call the API; save response to temp file
TMP_RESP=$(mktemp)
TMP_PAYLOAD=$(mktemp)
python3 - <<PYEOF > "$TMP_PAYLOAD"
import json, sys
payload = {
    'tag_name': '${NEXT_VERSION}',
    'target_commitish': '${COMMIT_SHA}',
    'name': 'Bun ${UPSTREAM_BUN_VERSION} GLIBC-2.17 compat ${NEXT_VERSION}',
    'body': """${RELEASE_NOTES}""",
    'draft': False,
    'prerelease': False
}
print(json.dumps(payload))
PYEOF
curl -fsSL \
    -X POST \
    -H "Authorization: token ${GITHUB_TOKEN}" \
    -H "Accept: application/vnd.github.v3+json" \
    -H "Content-Type: application/json" \
    --data @"$TMP_PAYLOAD" \
    "https://api.github.com/repos/${REPO}/releases" > "$TMP_RESP"
rm -f "$TMP_PAYLOAD"

RELEASE_ID=$(python3 -c "import json; d=json.load(open('$TMP_RESP')); print(d.get('id',''))" 2>/dev/null || echo "")
RELEASE_URL=$(python3 -c "import json; d=json.load(open('$TMP_RESP')); print(d.get('html_url',''))" 2>/dev/null || echo "")
rm -f "$TMP_RESP"

[[ -n "$RELEASE_ID" ]] || err "Failed to create release (no id in response)"
ok "Release created: $RELEASE_URL (id=$RELEASE_ID)"

# ---------- upload binary ----------

info "Uploading binary ($(ls -lh $BINARY | awk '{print $5}')) ..."
UPLOAD_URL="https://uploads.github.com/repos/${REPO}/releases/${RELEASE_ID}/assets?name=bun-linux-x64"

TMP_UPLOAD=$(mktemp)
curl -fsSL \
    -X POST \
    -H "Authorization: token ${GITHUB_TOKEN}" \
    -H "Content-Type: application/octet-stream" \
    --data-binary "@${BINARY}" \
    "$UPLOAD_URL" > "$TMP_UPLOAD"

ASSET_URL=$(python3 -c "import json; d=json.load(open('$TMP_UPLOAD')); print(d.get('browser_download_url',''))" 2>/dev/null || echo "")
rm -f "$TMP_UPLOAD"
[[ -n "$ASSET_URL" ]] || err "Failed to upload asset"
ok "Binary uploaded: $ASSET_URL"

# ---------- done ----------

echo ""
echo "========================================"
echo "Release $NEXT_VERSION published!"
echo "URL: $RELEASE_URL"
echo "Binary: $ASSET_URL"
echo "========================================"
