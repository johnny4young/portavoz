#!/bin/bash

set -euo pipefail

readonly VERSION="0.1.9"
readonly ARCHIVE_NAME="sqlite-vec-${VERSION}-amalgamation.zip"
readonly ARCHIVE_URL="https://github.com/asg017/sqlite-vec/releases/download/v${VERSION}/${ARCHIVE_NAME}"
readonly ARCHIVE_SHA256="b87cdda12112657ba5ab8842f0088a4090982eaf41f22b2bd6d495b81765a8c9"
readonly C_SHA256="ba081a47fa02eadc3cf6b16c314b695b84081269349aac722b4efa338fe8fd85"
readonly HEADER_SHA256="4f022d5ff3f97e521c7aef473a6991a7819a4d226be4267d3ee03138904d9968"
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

actual_c_sha256="$(shasum -a 256 "$sqlite_vec_c" | awk '{print $1}')"
[[ "$actual_c_sha256" == "$C_SHA256" ]] \
    || fail "sqlite-vec.c SHA-256 mismatch"
grep -Fq '#define SQLITE_VEC_VERSION "v0.1.9"' "$sqlite_vec_h" \
    || fail "archive header does not declare sqlite-vec v0.1.9"
grep -Fq 'sqlite3_vec_init' "$sqlite_vec_h" \
    || fail "archive header does not declare sqlite3_vec_init"

staged="$work_directory/staged"
mkdir "$staged"
cp "$sqlite_vec_c" "$staged/sqlite-vec.c"
cat > "$staged/sqlite-vec.h" <<'EOF'
#ifndef SQLITE_VEC_H
#define SQLITE_VEC_H

#ifndef SQLITE_CORE
#include "sqlite3ext.h"
#else
#include "sqlite3.h"
#endif

#ifdef SQLITE_VEC_STATIC
#define SQLITE_VEC_API
#else
#ifdef _WIN32
#define SQLITE_VEC_API __declspec(dllexport)
#else
#define SQLITE_VEC_API
#endif
#endif

#define SQLITE_VEC_VERSION "v0.1.9"
#define SQLITE_VEC_DATE "2026-03-31T07:59:06Z"
#define SQLITE_VEC_SOURCE "e9f598abfa0c06b328d8fe5da9c3760cce74be10"

#define SQLITE_VEC_VERSION_MAJOR 0
#define SQLITE_VEC_VERSION_MINOR 1
#define SQLITE_VEC_VERSION_PATCH 9

#ifdef __cplusplus
extern "C" {
#endif

SQLITE_VEC_API int sqlite3_vec_init(sqlite3 *db, char **pzErrMsg,
                                    const sqlite3_api_routines *pApi);

#ifdef __cplusplus
} /* end of the 'extern "C"' block */
#endif

#endif /* ifndef SQLITE_VEC_H */
EOF
actual_header_sha256="$(shasum -a 256 "$staged/sqlite-vec.h" | awk '{print $1}')"
[[ "$actual_header_sha256" == "$HEADER_SHA256" ]] \
    || fail "rendered sqlite-vec.h SHA-256 mismatch"
cp "$license_source" "$staged/LICENSE-MIT"
cat > "$staged/PROVENANCE.md" <<EOF
# sqlite-vec provenance

- Upstream: https://github.com/asg017/sqlite-vec
- Version: v$VERSION
- Tag commit: \`e9f598abfa0c06b328d8fe5da9c3760cce74be10\`
- Official amalgamation archive: \`$ARCHIVE_NAME\`
- Official archive SHA-256: \`$ARCHIVE_SHA256\`
- Vendored C Git blob: \`de3176f9ca28a273c5086f1cc995ebf4e3c04c22\`
- Vendored C SHA-256: \`$C_SHA256\`
- Header template Git blob: \`f49f62f6552b45ac612d236af96979aaba5bac8c\`
- Version file Git blob: \`1a030947e832763db761663d9f3e5acb42a7bff8\`
- Rendered header SHA-256: \`$HEADER_SHA256\`
- License: MIT selected from upstream's MIT OR Apache-2.0 terms
- License SHA-256: \`$LICENSE_SHA256\`

The C amalgamation is byte-identical to the official \`v$VERSION\` Git blob. The
header is deterministically rendered from the official tagged template using
the fixed version, tag commit, and tag-commit timestamp shown above. The
checksum-pinned release ZIP remains the canonical offline acquisition route;
the tagged-blob route is an independent fallback when release-asset transport
is unavailable. Git attributes disable text normalization for these two
vendored artifacts and intentionally preserve upstream whitespace byte for
byte.

Portavoz compiles these files only into the \`CSQLiteVecResearch\` test target.
Dynamic extension loading is forbidden. No app, CLI, durable schema, meeting
writer, or user-visible query path depends on this code.
EOF

mkdir -p "$(dirname "$destination")"
mv "$staged" "$destination"
echo "Vendored sqlite-vec v$VERSION at $destination"
