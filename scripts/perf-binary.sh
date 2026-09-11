#!/usr/bin/env bash

# Prepare or validate the one Release CLI used by every performance harness.
# Callers source this file and invoke `portavoz_prepare_perf_binary "$ROOT"`.
portavoz_prepare_perf_binary() {
  local root="$1"
  local binary="${PORTAVOZ_PERF_BINARY:-}"
  local build_wall_ms="${PORTAVOZ_PERF_BUILD_WALL_MS:-}"
  local expected_sha256="${PORTAVOZ_PERF_BINARY_SHA256:-}"
  local source_commit="${PORTAVOZ_PERF_SOURCE_COMMIT:-}"

  if [[ -z "$binary" ]]; then
    local build_start build_end
    build_start="$(python3 -c 'import time; print(time.monotonic_ns())')"
    swift build -c release --product portavoz-cli
    build_end="$(python3 -c 'import time; print(time.monotonic_ns())')"
    build_wall_ms="$(python3 - "$build_start" "$build_end" <<'PY'
import math
import sys

start, end = map(int, sys.argv[1:])
value = (end - start) / 1_000_000
if end < start or not math.isfinite(value):
    raise SystemExit("error: non-monotonic Release build clock")
print(value)
PY
)"
    binary="$root/.build/release/portavoz-cli"
  elif [[ -z "$build_wall_ms" || -z "$expected_sha256" || -z "$source_commit" ]]; then
    echo "error: a prebuilt performance binary requires build duration, SHA-256, and source commit" >&2
    return 64
  fi

  if [[ "$binary" != /* || "$binary" == *$'\n'* || "$binary" == *$'\r'* ]]; then
    echo "error: performance binary must be one absolute single-line path" >&2
    return 64
  fi
  if [[ ! -f "$binary" || ! -x "$binary" || -L "$binary" ]]; then
    echo "error: performance binary must be one executable regular file" >&2
    return 66
  fi
  if ! python3 - "$build_wall_ms" <<'PY'
import math
import sys

try:
    value = float(sys.argv[1])
except ValueError as error:
    raise SystemExit("error: invalid Release build duration") from error
if not math.isfinite(value) or value < 0:
    raise SystemExit("error: invalid Release build duration")
PY
  then
    return 64
  fi

  local actual_sha256 digest_output
  digest_output="$(/usr/bin/shasum -a 256 -- "$binary")"
  actual_sha256="${digest_output%% *}"
  if [[ ! "$actual_sha256" =~ ^[0-9a-f]{64}$ ]]; then
    echo "error: performance binary SHA-256 is invalid" >&2
    return 65
  fi
  if [[ -n "$expected_sha256" && "$actual_sha256" != "$expected_sha256" ]]; then
    echo "error: performance binary changed after the exact Release build" >&2
    return 65
  fi

  local current_commit
  current_commit="$(git -C "$root" rev-parse HEAD)"
  if [[ ! "$current_commit" =~ ^[0-9a-f]{40}$ ]]; then
    echo "error: performance source commit is invalid" >&2
    return 65
  fi
  if [[ -n "$source_commit" && "$current_commit" != "$source_commit" ]]; then
    echo "error: performance source HEAD changed after the exact Release build" >&2
    return 65
  fi

  PORTAVOZ_PERF_BINARY="$binary"
  PORTAVOZ_PERF_BINARY_SHA256="$actual_sha256"
  PORTAVOZ_PERF_BUILD_WALL_MS="$build_wall_ms"
  PORTAVOZ_PERF_SOURCE_COMMIT="$current_commit"
  export PORTAVOZ_PERF_BINARY
  export PORTAVOZ_PERF_BINARY_SHA256
  export PORTAVOZ_PERF_BUILD_WALL_MS
  export PORTAVOZ_PERF_SOURCE_COMMIT
}
