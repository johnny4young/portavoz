#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
umask 077

fixture_pid=""
test_pid=""
scratch_root=""

# Reached through the EXIT/signal cleanup trap.
# shellcheck disable=SC2329
stop_test() {
  [[ -n "$test_pid" ]] || return 0
  if kill -0 "$test_pid" 2>/dev/null; then
    kill -TERM "$test_pid" 2>/dev/null || true
    for _attempt in {1..250}; do
      kill -0 "$test_pid" 2>/dev/null || break
      sleep 0.02
    done
    if kill -0 "$test_pid" 2>/dev/null; then
      kill -KILL "$test_pid" 2>/dev/null || true
    fi
  fi
  wait "$test_pid" 2>/dev/null || true
  test_pid=""
}

# Reached through the EXIT/signal cleanup trap.
# shellcheck disable=SC2329
stop_fixture() {
  [[ -n "$fixture_pid" ]] || return 0
  if kill -0 "$fixture_pid" 2>/dev/null; then
    kill -TERM "$fixture_pid" 2>/dev/null || true
    for _attempt in {1..250}; do
      kill -0 "$fixture_pid" 2>/dev/null || break
      sleep 0.02
    done
    if kill -0 "$fixture_pid" 2>/dev/null; then
      kill -INT "$fixture_pid" 2>/dev/null || true
      for _attempt in {1..50}; do
        kill -0 "$fixture_pid" 2>/dev/null || break
        sleep 0.02
      done
    fi
    if kill -0 "$fixture_pid" 2>/dev/null; then
      kill -KILL "$fixture_pid" 2>/dev/null || true
    fi
  fi
  wait "$fixture_pid" 2>/dev/null || true
}

# Registered as the process cleanup trap below.
# shellcheck disable=SC2329
cleanup() {
  stop_test
  stop_fixture
  if [[ -n "$scratch_root" && -d "$scratch_root" ]]; then
    rm -rf -- "$scratch_root"
  fi
}

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

startup_attempts="${PORTAVOZ_TEST_WEB_FIXTURE_STARTUP_ATTEMPTS:-1500}"
case "$startup_attempts" in
  ''|*[!0-9]*)
    echo "PORTAVOZ_TEST_WEB_FIXTURE_STARTUP_ATTEMPTS must be an integer." >&2
    exit 64
    ;;
esac
if (( startup_attempts < 1 || startup_attempts > 1500 )); then
  echo "PORTAVOZ_TEST_WEB_FIXTURE_STARTUP_ATTEMPTS must be within 1...1500." >&2
  exit 64
fi

scratch_root="$(mktemp -d "${TMPDIR:-/tmp}/portavoz-swift-tests.XXXXXX")"
fixture_ready="$scratch_root/apuntador-web-fixture.json"
fixture_log="$scratch_root/apuntador-web-fixture.log"
unset PORTAVOZ_TEST_WEB_FIXTURE_DESCRIPTOR

# GitHub-hosted XCTest runners have proven unable to launch this Python child
# reliably from inside the test process. Own it in the invoking shell instead,
# then pass only its atomic, content-free descriptor to the package tests.
python3 scripts/apuntador_web_fixture.py serve \
  --fixture Fixtures/ApuntadorWeb/public-local-v1.json \
  --ready-file "$fixture_ready" \
  >"$fixture_log" 2>&1 &
fixture_pid=$!

for ((_attempt = 0; _attempt < startup_attempts; _attempt += 1)); do
  [[ -f "$fixture_ready" ]] && break
  kill -0 "$fixture_pid" 2>/dev/null || break
  sleep 0.02
done
if [[ ! -f "$fixture_ready" ]] \
    || ! kill -0 "$fixture_pid" 2>/dev/null; then
  echo "Deterministic Apuntador Web fixture did not start." >&2
  cat "$fixture_log" >&2 || true
  exit 2
fi

export PORTAVOZ_TEST_WEB_FIXTURE_DESCRIPTOR="$fixture_ready"

set +e
swift test "$@" &
test_pid=$!
wait "$test_pid"
test_status=$?
test_pid=""
set -e
exit "$test_status"
