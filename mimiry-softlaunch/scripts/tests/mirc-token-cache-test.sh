#!/bin/bash
# =============================================================================
# mirc token cache — tests
# =============================================================================
#
# The cache was keyed by host only, so `mirc --key B` within 55 minutes of a
# sign-in with key A reused A's token: the wrong account, with nothing on screen
# to say so (found 2026-11-01 while probing staff routes as a test user). It is
# now keyed by host AND key.
#
# Black-box through `mirc token-path`, which prints the cache file an
# invocation would use, with no network and no sign-in. Every run targets a
# host nobody uses (127.0.0.1:9), so a real host's cache is never touched.
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
MIRC="$(dirname "$SCRIPT_DIR")/mirc.sh"
HOST="http://127.0.0.1:9"
PREFIX="/tmp/mirc-token-$(id -u)-127.0.0.1:9"
KEYFILE="/tmp/mirc-key-$(id -u)-127.0.0.1:9"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ✓ %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  ✗ %s\n     %s\n' "$1" "$2"; }

command -v ssh-keygen >/dev/null || { echo "needs ssh-keygen" >&2; exit 3; }

work="$(mktemp -d)"
cleanup() { rm -rf "$work"; rm -f "$PREFIX" "$PREFIX"-* "$KEYFILE"; }
trap cleanup EXIT
cleanup_state() { rm -f "$PREFIX" "$PREFIX"-* "$KEYFILE"; }
cleanup_state

ssh-keygen -q -t ed25519 -N "" -C "a@test" -f "$work/a"
ssh-keygen -q -t ed25519 -N "" -C "b@test" -f "$work/b"
# The same key under another comment: the same identity.
cp "$work/a" "$work/a2"
awk '{ print $1, $2, "renamed@test" }' "$work/a.pub" > "$work/a2.pub"

path() { bash "$MIRC" --host "$HOST" --key "$1" token-path 2>/dev/null; }

echo "mirc token cache"
echo "================"

pa="$(path "$work/a")"
pb="$(path "$work/b")"
case "$pa" in "$PREFIX"-*) ok "key A's cache is under the host" ;; *) bad "key A's cache is under the host" "got [$pa]" ;; esac
if [ -n "$pa" ] && [ "$pa" != "$pb" ]; then ok "two keys, two caches"; else bad "two keys, two caches" "A [$pa] B [$pb]"; fi
if [ "$(path "$work/a.pub")" = "$pa" ]; then ok "the .pub path names the same key"; else bad "the .pub path names the same key" "got [$(path "$work/a.pub")]"; fi
if [ "$(path "$work/a2")" = "$pa" ]; then ok "a new comment is the same key"; else bad "a new comment is the same key" "got [$(path "$work/a2")]"; fi
if [ "$(path "$work/a")" = "$pa" ]; then ok "stable across runs"; else bad "stable across runs" "changed"; fi

# token-path reports; it changes nothing.
if [ ! -e "$KEYFILE" ]; then ok "token-path does not remember the key"; else bad "token-path does not remember the key" "$KEYFILE was written"; fi
echo "1 legacy" > "$PREFIX"
path "$work/a" >/dev/null
if [ -e "$PREFIX" ]; then ok "token-path leaves the legacy cache alone"; else bad "token-path leaves the legacy cache alone" "it was removed"; fi

# A real command resolves the key the same way, remembers it, and removes the
# host-only cache, whose token belongs to whichever key signed in last.
bash "$MIRC" --host "$HOST" --key "$work/a" auth >/dev/null 2>&1 || true
if [ ! -e "$PREFIX" ]; then ok "a command removes the host-only legacy cache"; else bad "a command removes the host-only legacy cache" "$PREFIX survived"; fi
if [ "$(cat "$KEYFILE" 2>/dev/null)" = "$work/a" ]; then ok "a command remembers the key"; else bad "a command remembers the key" "got [$(cat "$KEYFILE" 2>/dev/null)]"; fi
if [ "$(bash "$MIRC" --host "$HOST" token-path 2>/dev/null)" = "$pa" ]; then
    ok "without --key, the remembered key's cache"
else
    bad "without --key, the remembered key's cache" "got [$(bash "$MIRC" --host "$HOST" token-path 2>/dev/null)]"
fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
