#!/bin/bash
# =============================================================================
# mirc install — tests
# =============================================================================
#
# `mirc install` is the only command that writes outside the repo, and it writes
# into $HOME/.claude/skills/. On 2026-10-06 the owner deliberately deleted
# $HOME/.claude/skills/mimiry-softlaunch (everything in it but mirc was long out
# of date), which is what exposed the defect these tests hold down: install
# created the canonical copy BEFORE checking the symlink, and the symlink check
# `die`s without --force. So a refused install still put the directory back.
#
# 🚨 EVERY CASE RUNS WITH HOME POINTED AT A TEMPORARY DIRECTORY. The command
# under test writes to $HOME/.claude/skills/... by construction, so a test that
# did not override HOME would recreate on the developer's machine exactly the
# thing this defect is about.
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
MIRC="$(dirname "$SCRIPT_DIR")/mirc.sh"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ✓ %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  ✗ %s\n     %s\n' "$1" "$2"; }

# Each case gets a fresh fake HOME and a fresh prefix directory.
FAKE_HOME=""
PREFIX=""
CANON=""
OUT=""
RC=0

new_sandbox() {
    FAKE_HOME="$(mktemp -d)"
    PREFIX="$FAKE_HOME/bin"
    CANON="$FAKE_HOME/.claude/skills/mimiry-softlaunch/scripts/mirc.sh"
    mkdir -p "$PREFIX"
}
cleanup_sandbox() { [ -n "$FAKE_HOME" ] && rm -rf "$FAKE_HOME"; }
trap cleanup_sandbox EXIT

install_in_sandbox() { # extra args...
    RC=0
    OUT="$(HOME="$FAKE_HOME" bash "$MIRC" install --prefix "$PREFIX" "$@" 2>&1)" || RC=$?
}

echo "mirc install"
echo "============"

# ── The regression ───────────────────────────────────────────────────
echo
echo "A refused install writes nothing"

# This is the owner's exact situation: ~/.local/bin/mirc is a symlink to the
# REPO file, not to the canonical copy, so install refuses without --force.
new_sandbox
ln -s /some/other/path/mirc.sh "$PREFIX/mirc"
install_in_sandbox
if [ "$RC" -eq 0 ]; then
    bad "it refuses a foreign symlink without --force" "exited 0: $OUT"
else
    ok "it refuses a foreign symlink without --force"
fi
# 🚨 THE ASSERTION THAT MATTERS. Before the preflight, this file existed after
# a refusal, and the directory holding it was created too — silently undoing a
# deliberate removal.
if [ -e "$CANON" ]; then
    bad "...and leaves no canonical copy behind" "created $CANON"
else
    ok "...and leaves no canonical copy behind"
fi
if [ -d "$FAKE_HOME/.claude/skills/mimiry-softlaunch" ]; then
    bad "...and does not recreate the skill directory" "created the directory"
else
    ok "...and does not recreate the skill directory"
fi
# The refusal has to say that nothing happened, or the user cannot tell whether
# to go and clean up after it.
case "$OUT" in *"Nothing was written"*) ok "...and says nothing was written" ;;
    *) bad "...and says nothing was written" "message does not say so: $OUT" ;;
esac
cleanup_sandbox

echo
new_sandbox
printf '#!/bin/sh\n' > "$PREFIX/mirc"   # a regular file, not a symlink
install_in_sandbox
if [ "$RC" -eq 0 ]; then bad "it refuses a regular file without --force" "exited 0"; else ok "it refuses a regular file without --force"; fi
if [ -e "$CANON" ]; then bad "...writing nothing" "created $CANON"; else ok "...writing nothing"; fi
cleanup_sandbox

# ── The happy path ───────────────────────────────────────────────────
echo
echo "A clean install does the whole job"

new_sandbox
install_in_sandbox
if [ "$RC" -eq 0 ]; then ok "it installs into an empty prefix"; else bad "it installs into an empty prefix" "rc=$RC: $OUT"; fi
if [ -f "$CANON" ]; then ok "...creating the canonical copy"; else bad "...creating the canonical copy" "missing $CANON"; fi
if [ -L "$PREFIX/mirc" ]; then ok "...and a symlink"; else bad "...and a symlink" "not a symlink"; fi
if [ "$(readlink "$PREFIX/mirc")" = "$CANON" ]; then
    ok "...pointing at the canonical copy"
else
    bad "...pointing at the canonical copy" "points at $(readlink "$PREFIX/mirc")"
fi
if [ -x "$CANON" ]; then ok "...which is executable"; else bad "...which is executable" "not executable"; fi

# 🚨 Installing CHANGES THE DEFAULT HOST, because the canonical copy lives
# outside the skills repo so _default_subdomain returns LIVE_SUBDOMAIN. That is
# the consequence nobody predicts, and install_help explaining it is not the
# same as saying it while doing it.
case "$OUT" in *"A bare \`mirc\` now defaults to"*) ok "...and announces the resulting default host" ;;
    *) bad "...and announces the resulting default host" "not in output: $OUT" ;;
esac
case "$OUT" in *"or pass --host"*) ok "...naming the flag that overrides it" ;;
    *) bad "...naming the flag that overrides it" "not in output: $OUT" ;;
esac

# The installed copy must actually be the running script, or `mirc install`
# ships a version nobody tested.
if cmp -s "$CANON" "$MIRC"; then ok "...and the copy is byte-identical to the source"; else bad "...and the copy is byte-identical to the source" "differs"; fi
cleanup_sandbox

# ── Idempotence ──────────────────────────────────────────────────────
echo
echo "Re-running is safe"

new_sandbox
install_in_sandbox
install_in_sandbox
if [ "$RC" -eq 0 ]; then ok "a second install succeeds"; else bad "a second install succeeds" "rc=$RC: $OUT"; fi
case "$OUT" in *"Already installed"*) ok "...and says it was already installed" ;;
    *) bad "...and says it was already installed" "not in output: $OUT" ;;
esac
cleanup_sandbox

# ── Result ───────────────────────────────────────────────────────────
echo
echo "============"
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
