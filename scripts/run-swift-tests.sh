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
  # swift test leads its own process group, so parallel workers stop with it.
  # macOS reports EPERM, not ESRCH, once only unreaped members remain; both end the wait.
  if kill -0 -- "-$test_pid" 2>/dev/null; then
    kill -TERM -- "-$test_pid" 2>/dev/null || true
    for _attempt in {1..250}; do
      kill -0 -- "-$test_pid" 2>/dev/null || break
      # A child forked while TERM was in flight never received it.
      (( _attempt % 25 )) || kill -TERM -- "-$test_pid" 2>/dev/null || true
      sleep 0.02
    done
    if kill -0 -- "-$test_pid" 2>/dev/null; then
      kill -KILL -- "-$test_pid" 2>/dev/null || true
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

interrupted=""

# A signal between a fork and its PID assignment would leave that child behind,
# so it is held until the PID is recorded.
defer_signals() {
  trap 'interrupted=129' HUP
  trap 'interrupted=130' INT
  trap 'interrupted=143' TERM
}

honor_signals() {
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  [[ -z "$interrupted" ]] || exit "$interrupted"
}

trap cleanup EXIT
honor_signals

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

workers="${PORTAVOZ_SWIFT_TEST_WORKERS:-3}"
case "$workers" in
  ''|*[!0-9]*)
    echo "PORTAVOZ_SWIFT_TEST_WORKERS must be an integer." >&2
    exit 64
    ;;
esac
if (( workers < 1 || workers > 32 )); then
  echo "PORTAVOZ_SWIFT_TEST_WORKERS must be within 1...32." >&2
  exit 64
fi

scratch_root="$(mktemp -d "${TMPDIR:-/tmp}/portavoz-swift-tests.XXXXXX")"
fixture_ready="$scratch_root/apuntador-web-fixture.json"
fixture_log="$scratch_root/apuntador-web-fixture.log"
unset PORTAVOZ_TEST_WEB_FIXTURE_DESCRIPTOR

# GitHub-hosted XCTest runners have proven unable to launch this Python child
# reliably from inside the test process. Own it in the invoking shell instead,
# then pass only its atomic, content-free descriptor to the package tests.
defer_signals
python3 scripts/apuntador_web_fixture.py serve \
  --fixture Fixtures/ApuntadorWeb/public-local-v1.json \
  --ready-file "$fixture_ready" \
  >"$fixture_log" 2>&1 &
fixture_pid=$!
honor_signals

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

run_tests() {
  # A targeted run keeps the plain swift test semantics it asked for.
  local argument
  for argument in "$@"; do
    case "$argument" in
      --filter|--filter=*|--skip|--skip=*|--specifier|-s|--parallel|--no-parallel|list)
        swift test "$@"
        return
        ;;
    esac
  done
  local build=()
  for argument in "$@"; do
    [[ "$argument" == --skip-build ]] || build+=("$argument")
  done
  if [[ " $* " != *" --skip-build "* ]]; then
    swift build --build-tests ${build[@]+"${build[@]}"} || return
  fi
  local listing="$scratch_root/tests.txt" bin
  swift test list --skip-build ${build[@]+"${build[@]}"} >"$listing" || return
  # A scoped CI run keeps only the listed tests its anchored class pattern names.
  if [[ -n "${PORTAVOZ_SWIFT_TEST_SCOPE:-}" ]]; then
    grep -E "$PORTAVOZ_SWIFT_TEST_SCOPE" "$listing" >"$listing.scoped" || {
      echo "PORTAVOZ_SWIFT_TEST_SCOPE matched no listed test." >&2
      return 2
    }
    mv "$listing.scoped" "$listing"
  fi
  bin="$(swift build --show-bin-path ${build[@]+"${build[@]}"})" || return
  local bundles=("$bin"/*.xctest)
  if [[ ${#bundles[@]} -ne 1 || ! -d "${bundles[0]}" ]]; then
    echo "Expected exactly one XCTest bundle in $bin." >&2
    return 2
  fi
  local xctest_status=0 testing_status=0 suites
  python3 scripts/run_xctest_pool.py --bundle "${bundles[0]}" \
    --listing "$listing" --workers "$workers" || xctest_status=$?
  # Swift Testing suites run in their own concurrent process, as before.
  suites="$(python3 - "$listing" <<'PY'
import re
import sys

names = sorted({line.split("/", 1)[0] for line in open(sys.argv[1]) if "(" in line})
print("^(" + "|".join(re.escape(name) for name in names) + ")/" if names else "")
PY
)" || return
  if [[ -n "$suites" ]]; then
    swift test --skip-build ${build[@]+"${build[@]}"} --filter "$suites" || testing_status=$?
  fi
  (( xctest_status == 0 )) || return "$xctest_status"
  return "$testing_status"
}

set +e
# XCTest classes run in a pool of xctest processes; the group lets cleanup stop them.
defer_signals
set -m
run_tests "$@" &
test_pid=$!
set +m
honor_signals
wait "$test_pid"
test_status=$?
test_pid=""
set -e
exit "$test_status"
