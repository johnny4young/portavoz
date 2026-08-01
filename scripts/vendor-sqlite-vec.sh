#!/bin/bash

set -euo pipefail

readonly VERSION="0.1.9"
readonly ARCHIVE_NAME="sqlite-vec-${VERSION}-amalgamation.zip"
readonly ARCHIVE_URL="https://github.com/asg017/sqlite-vec/releases/download/v${VERSION}/${ARCHIVE_NAME}"
readonly ARCHIVE_SHA256="b87cdda12112657ba5ab8842f0088a4090982eaf41f22b2bd6d495b81765a8c9"
readonly LICENSE_SHA256="e49d7859a0fd8d3f8a2a7b81ca1dbddf61bd4f9e981d12908ead721a78c42f32"

usage() {
    cat <<'EOF'
Usage: scripts/vendor-sqlite-vec.sh [--archive PATH] [--destination PATH]

Fetches or reads the pinned sqlite-vec amalgamation, verifies its SHA-256, and
stages only source, headers, and the reviewed upstream MIT license. It never
loads or installs a dynamic SQLite extension.
EOF
}

fail() {
    echo "vendor-sqlite-vec: $*" >&2
    exit 1
}

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
license_source="$repository_root/scripts/vendor-metadata/sqlite-vec/LICENSE-MIT"
archive_path=""
destination="$repository_root/Vendor/sqlite-vec"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --archive)
            [[ $# -ge 2 ]] || fail "--archive requires a path"
            archive_path="$2"
            shift 2
            ;;
        --destination)
            [[ $# -ge 2 ]] || fail "--destination requires a path"
            destination="$2"
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            fail "unknown option: $1"
            ;;
    esac
done

[[ ! -e "$destination" ]] || fail "destination already exists: $destination"
[[ -f "$license_source" ]] || fail "reviewed MIT license is missing: $license_source"
actual_license_sha256="$(shasum -a 256 "$license_source" | awk '{print $1}')"
[[ "$actual_license_sha256" == "$LICENSE_SHA256" ]] \
    || fail "reviewed MIT license SHA-256 mismatch"

work_directory="$(mktemp -d "${TMPDIR:-/tmp}/portavoz-sqlite-vec.XXXXXX")"
trap 'rm -rf "$work_directory"' EXIT

verified_archive="$work_directory/$ARCHIVE_NAME"
if [[ -n "$archive_path" ]]; then
    [[ -f "$archive_path" ]] || fail "archive does not exist: $archive_path"
    cp "$archive_path" "$verified_archive"
else
    curl --fail --location --silent --show-error \
        "$ARCHIVE_URL" \
        --output "$verified_archive"
fi

actual_sha256="$(shasum -a 256 "$verified_archive" | awk '{print $1}')"
[[ "$actual_sha256" == "$ARCHIVE_SHA256" ]] \
    || fail "archive SHA-256 mismatch: expected $ARCHIVE_SHA256, got $actual_sha256"

expanded="$work_directory/expanded"
mkdir "$expanded"
unzip -q "$verified_archive" -d "$expanded"

find_exactly_one() {
    local name="$1"
    local matches=()
    while IFS= read -r path; do
        matches+=("$path")
    done < <(find "$expanded" -type f -name "$name" -print)
    [[ ${#matches[@]} -eq 1 ]] \
        || fail "expected exactly one $name in the verified archive"
    printf '%s\n' "${matches[0]}"
}

sqlite_vec_c="$(find_exactly_one sqlite-vec.c)"
sqlite_vec_h="$(find_exactly_one sqlite-vec.h)"

staged="$work_directory/staged"
mkdir "$staged"
cp "$sqlite_vec_c" "$staged/sqlite-vec.c"
cp "$sqlite_vec_h" "$staged/sqlite-vec.h"
cp "$license_source" "$staged/LICENSE-MIT"
cat > "$staged/PROVENANCE.md" <<EOF
# sqlite-vec provenance

- Upstream: https://github.com/asg017/sqlite-vec
- Version: v$VERSION
- Source archive: $ARCHIVE_URL
- Archive SHA-256: $ARCHIVE_SHA256
- License: MIT selected from upstream's MIT OR Apache-2.0 terms
- License source: scripts/vendor-metadata/sqlite-vec/LICENSE-MIT
- License SHA-256: $LICENSE_SHA256
- Integration policy: static source only; dynamic extension loading is forbidden
EOF

mkdir -p "$(dirname "$destination")"
mv "$staged" "$destination"
echo "Vendored sqlite-vec v$VERSION at $destination"
