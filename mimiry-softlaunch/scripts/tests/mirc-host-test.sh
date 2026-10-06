#!/bin/bash
# =============================================================================
# mirc host resolution — tests
# =============================================================================
#
# mirc had NO tests. It reached its third instance-vs-subdomain incident on
# 2026-10-06, and the first two had each been "fixed" by changing a name while
# the coupling survived — which is exactly the kind of regression a test holds
# down and a comment does not.
#
# Everything here is black-box through `mirc api-base`, which prints the
# resolved base URL and exits. That subcommand exists because "which host am I
# actually talking to?" was unanswerable during the first two incidents, and it
# makes the resolver testable with no network, no auth and no mocks.
#
# 🚨 STDOUT AND STDERR ARE CAPTURED SEPARATELY, ON PURPOSE. `mimiry-auth.sh:34`
# reads `mirc api-base` through $(...), so anything diagnostic that lands on
# stdout becomes part of the API base URL. A test that merged the streams would
# pass while the host echo silently corrupted the other script.
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
MIRC="$(dirname "$SCRIPT_DIR")/mirc.sh"

PASS=0
FAIL=0
OUT=""
ERR=""
RC=0

# run invokes mirc with the given args, keeping the streams apart.
run() {
    local tmp_out tmp_err
    tmp_out="$(mktemp)"
    tmp_err="$(mktemp)"
    RC=0
    bash "$MIRC" "$@" >"$tmp_out" 2>"$tmp_err" || RC=$?
    OUT="$(cat "$tmp_out")"
    ERR="$(cat "$tmp_err")"
    rm -f "$tmp_out" "$tmp_err"
}

ok()  { PASS=$((PASS + 1)); printf '  ✓ %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  ✗ %s\n     %s\n' "$1" "$2"; }

assert_eq() { # <what> <got> <want>
    if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got [$2], want [$3]"; fi
}
assert_contains() { # <what> <haystack> <needle>
    case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "[$2] does not contain [$3]" ;; esac
}
assert_not_contains() { # <what> <haystack> <needle>
    case "$2" in *"$3"*) bad "$1" "[$2] must not contain [$3]" ;; *) ok "$1" ;; esac
}

echo "mirc host resolution"
echo "===================="

# ── The incident ─────────────────────────────────────────────────────
echo
echo "An environment identifier is refused, not turned into a hostname"

# This is the value the operator passed on 2026-10-06. It used to become
# `https://staging-beta1.mimiry.com` and fail as a DNS error, which blames the
# network for what is a category error: the tool does not map instances to
# hosts and should say so.
run --host staging-beta1 api-base
if [ "$RC" -eq 0 ]; then
    bad "staging-beta1 is refused" "exited 0 with stdout [$OUT]"
else
    ok "staging-beta1 is refused"
fi
assert_eq "...and prints no base URL" "$OUT" ""
assert_contains "...saying it is an identifier" "$ERR" "environment identifier"
# 🚨 The message must offer a way forward. An operator who knows instance names
# and not subdomains is stuck otherwise — and being stuck is what makes someone
# try the other spelling until something works, which is how the wrong live
# instance got reached.
assert_contains "...and naming the flag that works" "$ERR" "--host trunk"
assert_not_contains "...and NOT blaming DNS" "$ERR" "does not resolve"

for ident in dev-sandbox staging-beta prod-eu; do
    run --host "$ident" api-base
    if [ "$RC" -eq 0 ]; then bad "$ident is refused" "exited 0"; else ok "$ident is refused"; fi
done

# ── Hostnames ────────────────────────────────────────────────────────
echo
echo "A hostname is used as-is, not suffixed"

# `--instance beta.mimiry.com` used to produce
# https://beta.mimiry.com.mimiry.com, because .mimiry.com was appended
# unconditionally. The hostname is the one value a user can copy out of their
# browser, so it was the likeliest thing to paste.
run --host beta.mimiry.com api-base
assert_eq "beta.mimiry.com is not double-suffixed" "$OUT" "https://beta.mimiry.com"

run --host staging-api.example.com api-base
assert_eq "a dotted host keeps working despite a refused prefix" \
    "$OUT" "https://staging-api.example.com"

run --host http://localhost:8080 api-base
assert_eq "an explicit URL is verbatim" "$OUT" "http://localhost:8080"

run --host https://trunk.mimiry.com/ api-base
assert_eq "a trailing slash is trimmed" "$OUT" "https://trunk.mimiry.com"

# ── Subdomains ───────────────────────────────────────────────────────
echo
echo "A bare word is a subdomain"

run --host trunk api-base
assert_eq "trunk -> trunk.mimiry.com" "$OUT" "https://trunk.mimiry.com"

# 🚨 `beta` is BOTH a live subdomain (instance beta1's host) and a live
# instance name (trunk's). It must resolve as the HOST, because that is what
# the flag means — and the echo below is what lets a user notice which one
# they got. This assertion is the collision, pinned.
run --host beta api-base
assert_eq "beta -> beta.mimiry.com (the HOST, not trunk)" "$OUT" "https://beta.mimiry.com"

# ── Saying which host ────────────────────────────────────────────────
echo
echo "The resolved host is announced, on stderr"

run --host beta api-base
assert_contains "an override announces the host" "$ERR" "→ host: https://beta.mimiry.com"
# 🚨 THE STREAM IS THE POINT. mimiry-auth.sh captures stdout of this exact
# command; a diagnostic on stdout becomes part of its API base URL.
assert_eq "stdout carries ONLY the URL" "$OUT" "https://beta.mimiry.com"

run api-base
assert_eq "the default host is announced quietly" "$ERR" ""
assert_contains "...and still resolves" "$OUT" ".mimiry.com"

# ── The deprecated spelling ──────────────────────────────────────────
echo
echo "--instance still works, and says it is deprecated"

# Kept working deliberately: docs, PROJECT-STATE and
# plans/beta-demo/demo-ssh-volume.sh all use it.
run --instance beta api-base
assert_eq "--instance resolves identically to --host" "$OUT" "https://beta.mimiry.com"
assert_contains "...warning that it is deprecated" "$ERR" "deprecated"
assert_contains "...naming the replacement" "$ERR" "--host"
# The whole misunderstanding in one line: the user believed the flag took an
# instance name. The warning has to contradict that belief explicitly, or it
# just looks like a rename with no reason to care.
assert_contains "...and saying it never took an instance name" "$ERR" "never took an instance name"

run --instance staging-beta1 api-base
if [ "$RC" -eq 0 ]; then
    bad "the deprecated flag refuses identifiers too" "exited 0"
else
    ok "the deprecated flag refuses identifiers too"
fi

# ── Flag position ────────────────────────────────────────────────────
echo
echo "Both flags work on either side of the command"

# 🚨 FOUND BY A STALE MUTANT, not by thinking. The parser has TWO branches for
# these flags — one before the command is known and one after — and a mutation
# applied to only the first still passed every test, because every test above
# puts the flag first. `mirc ssh register --host beta` is supported and was
# entirely uncovered, so a change to that branch alone was invisible.
run ssh --host beta
assert_contains "--host after the command resolves" "$ERR" "→ host: https://beta.mimiry.com"

run ssh --instance beta
assert_contains "--instance after the command resolves" "$ERR" "→ host: https://beta.mimiry.com"
assert_contains "...and still warns" "$ERR" "deprecated"

run ssh --host staging-beta1
if [ "$RC" -eq 0 ]; then
    bad "an identifier after the command is refused" "exited 0"
else
    ok "an identifier after the command is refused"
fi

# ── Precedence ───────────────────────────────────────────────────────
echo
echo "Precedence and plumbing"

OUT="$(MIMIRY_API_BASE=https://env.example.com bash "$MIRC" --host trunk api-base 2>/dev/null)"
assert_eq "--host beats MIMIRY_API_BASE" "$OUT" "https://trunk.mimiry.com"

OUT="$(MIMIRY_API_BASE=https://env.example.com bash "$MIRC" api-base 2>/dev/null)"
assert_eq "MIMIRY_API_BASE beats the default" "$OUT" "https://env.example.com"

# A missing value must not silently become the next argument. `--host api-base`
# would otherwise resolve to api-base.mimiry.com and swallow the command.
run --host
if [ "$RC" -eq 0 ]; then bad "--host with no value fails" "exited 0"; else ok "--host with no value fails"; fi

# ── The DNS preflight hint ───────────────────────────────────────────
echo
echo "The preflight names the flag that exists"

# Reaching _preflight_host needs a key, because auth is checked first — so a
# throwaway key is generated and the target deliberately does not resolve.
# Preflight dies before any request is attempted, which the error states, so
# nothing is sent anywhere.
_TEST_KEY="$(mktemp -u)"
if ssh-keygen -t ed25519 -N '' -f "$_TEST_KEY" -q -C mirc-host-test 2>/dev/null; then
    run --host nonexistent-xyz.invalid --key "$_TEST_KEY" session list
    assert_contains "preflight fires before any request" "$ERR" "no request was attempted"
    assert_contains "...and the hint names --host" "$ERR" "--host <subdomain|hostname>"
    # 🚨 This is the guard that read OPT_INSTANCE after the rename. With the
    # stale variable the test below becomes "was MIMIRY_API_BASE unset?", so an
    # explicit override is told the released instance "is not live yet" —
    # advice about a choice the user did not make.
    assert_not_contains "...not the 'not live yet' advice, since a host WAS chosen" \
        "$ERR" "is not live yet"
    rm -f "$_TEST_KEY" "$_TEST_KEY.pub"
else
    echo "  ⊘ skipped: ssh-keygen unavailable"
fi

# ── Help ─────────────────────────────────────────────────────────────
echo
echo "Help documents the flag that exists"

run --help
assert_contains "help documents --host" "$OUT" "--host <target>"
assert_contains "help marks --instance deprecated" "$OUT" "DEPRECATED alias"
# Help that restates a resolved value is help that eventually lies — this file
# already learned that when it said "Default: softlaunch" for a year.
assert_contains "help states the current default host" "$OUT" "Current default host:"

# ── Result ───────────────────────────────────────────────────────────
echo
echo "===================="
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
