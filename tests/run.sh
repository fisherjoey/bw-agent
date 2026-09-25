#!/usr/bin/env bash
# shellcheck disable=SC2016 # single quotes are intended: $1/$VAR expand in the child shell
# Runs bw-agent against a mock `bw serve` (tests/mock_bw_serve.py).
# No real vault, no network, no GUI. Needs bash, curl, jq, python3.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
BW="$HERE/../bw-agent"
TMP="$(mktemp -d)"
PIDS=()
cleanup() { for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done; rm -rf "$TMP"; }
trap cleanup EXIT

pass=0; fail=0
check() { # description, then a command that must succeed
  local desc="$1"; shift
  if "$@"; then echo "ok   - $desc"; pass=$((pass + 1)); else echo "FAIL - $desc"; fail=$((fail + 1)); fi
}

start_mock() { # port status
  python3 "$HERE/mock_bw_serve.py" "$1" "$2" &
  PIDS+=("$!")
  for _ in $(seq 50); do curl -fs "http://127.0.0.1:$1/status" >/dev/null && return 0; sleep 0.1; done
  echo "mock server on port $1 did not start" >&2; exit 1
}

pick_port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])'; }

P1="$(pick_port)"; start_mock "$P1" unlocked
P2="$(pick_port)"; start_mock "$P2" locked
export BW_AGENT_API="http://127.0.0.1:$P1"

# --- usage ---------------------------------------------------------------
"$BW" >/dev/null 2>&1; rc=$?
check "no verb prints usage and exits 64" test "$rc" -eq 64

# --- lock state ----------------------------------------------------------
out="$(BW_AGENT_API="http://127.0.0.1:$P2" "$BW" get api-key 2>&1)"; rc=$?
check "locked vault: get fails" test "$rc" -ne 0
check "locked vault: message says how to unlock" grep -q "bw-agent unlock" <<<"$out"

out="$(BW_AGENT_API="http://127.0.0.1:1" "$BW" list 2>&1)"; rc=$?
check "unreachable API: list fails with a clear message" grep -q "cannot reach bw serve" <<<"$out"

# --- scoping -------------------------------------------------------------
out="$("$BW" list 2>&1)"
check "list shows items in the scoped folder" grep -qx "api-key" <<<"$out"
check "list hides items outside the folder" bash -c '! grep -q bank <<<"$1"' _ "$out"

out="$("$BW" get bank 2>&1)"; rc=$?
check "get refuses an item outside the folder" test "$rc" -ne 0
check "out-of-folder secret never printed" bash -c '! grep -q must-never-be-visible <<<"$1"' _ "$out"

out="$(BW_AGENT_FOLDER=Personal "$BW" list 2>&1)"
check "BW_AGENT_FOLDER switches the scoped folder" grep -qx "bank" <<<"$out"

# --- get -----------------------------------------------------------------
out="$("$BW" get api-key 2>&1)"
check "get prints metadata (length + last4)" grep -q "length 17; ends '…WXYZ'" <<<"$out"
check "get does not print the value" bash -c '! grep -q s3cr3t <<<"$1"' _ "$out"

out="$("$BW" get api-key --reveal 2>/dev/null)"
check "get --reveal prints the value on stdout" test "$out" = "s3cr3t-value-WXYZ"
err="$("$BW" get api-key --reveal 2>&1 >/dev/null)"
check "get --reveal warns on stderr" grep -q WARNING <<<"$err"

out="$("$BW" get api-key --field token --reveal 2>/dev/null)"
check "get --field reads a custom field" test "$out" = "field-val-1234"

# --- exec / file ---------------------------------------------------------
check "exec injects the secret into the named env var" \
  "$BW" exec api-key --env MY_TOKEN -- sh -c 'test "$MY_TOKEN" = s3cr3t-value-WXYZ'
check "exec defaults the env var to SECRET" \
  "$BW" exec api-key -- sh -c 'test "$SECRET" = s3cr3t-value-WXYZ'
"$BW" exec api-key -- sh -c 'exit 7'; rc=$?
check "exec passes through the command's exit code" test "$rc" -eq 7

"$BW" file api-key "$TMP/key" >/dev/null
check "file writes the secret" test "$(cat "$TMP/key")" = "s3cr3t-value-WXYZ"
check "file sets mode 0600" test "$(stat -c %a "$TMP/key")" = "600"

# --- put -----------------------------------------------------------------
out="$(printf '%s' 'new-value-9876' | "$BW" put new-item --notes "test")"
check "put stores a new item" grep -q "stored 'new-item'" <<<"$out"
out="$(printf '%s' 'rotated-5555' | "$BW" put new-item)"
check "put on an existing name updates it" grep -q "updated 'new-item'" <<<"$out"
check "updated value is readable" test "$("$BW" get new-item --reveal 2>/dev/null)" = "rotated-5555"
printf '' | "$BW" put empty-item >/dev/null 2>&1; rc=$?
check "put refuses an empty value" test "$rc" -ne 0

# --- request -------------------------------------------------------------
out="$("$BW" request api-key --reason "test")"; rc=$?
check "request on an existing item exits 0 without a dialog" test "$rc" -eq 0
check "request on an existing item says already stored" grep -q "already stored" <<<"$out"

env -u DISPLAY -u WAYLAND_DISPLAY BW_AGENT_SESSION_PROCS=no-such-process-xyz \
  "$BW" request missing-item --reason "test" >/dev/null 2>&1; rc=$?
check "request with no graphical session exits 3" test "$rc" -eq 3

echo
echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
