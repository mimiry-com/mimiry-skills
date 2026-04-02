#!/bin/bash
# Mimiry API Authentication — SSH Signature Exchange
#
# Usage: source mimiry-auth.sh <ssh_key_path> [api_base]
#   Exports: MIMIRY_TOKEN, MIMIRY_API
#
# The auth algorithm:
#   1. Compute SHA256 fingerprint of the public key
#   2. Construct message: {fingerprint}\n{timestamp}\n{nonce}
#   3. Write to file, sign with ssh-keygen -Y sign -n mimiry-auth
#   4. Base64-encode the .sig file, exchange for JWT
set -e

SSH_KEY="${1:?Usage: mimiry-auth.sh <ssh_key_path> [api_base]}"
API_BASE="${2:-https://softlaunch.mimiry.com}"

# Strip .pub extension if provided — we need both the private key and .pub
SSH_KEY="${SSH_KEY%.pub}"

if [ ! -f "$SSH_KEY" ]; then
    echo "Error: SSH private key not found: $SSH_KEY" >&2
    exit 1
fi

if [ ! -f "${SSH_KEY}.pub" ]; then
    echo "Error: Public key not found: ${SSH_KEY}.pub" >&2
    exit 1
fi

FINGERPRINT=$(ssh-keygen -lf "${SSH_KEY}.pub" | awk '{print $2}')
TIMESTAMP=$(date +%s)
NONCE=$(openssl rand -hex 16)

TMPFILE=$(mktemp)
printf '%s\n%s\n%s' "$FINGERPRINT" "$TIMESTAMP" "$NONCE" > "$TMPFILE"
ssh-keygen -Y sign -f "$SSH_KEY" -n mimiry-auth "$TMPFILE" 2>/dev/null
SIGNATURE=$(base64 -w0 "${TMPFILE}.sig")
rm -f "$TMPFILE" "${TMPFILE}.sig"

RESPONSE=$(curl -s -X POST "${API_BASE}/api/v1/auth/token" \
  -H "X-SSH-Fingerprint: $FINGERPRINT" \
  -H "X-SSH-Signature: $SIGNATURE" \
  -H "X-SSH-Timestamp: $TIMESTAMP" \
  -H "X-SSH-Nonce: $NONCE" \
  -H "Content-Type: application/json" \
  -d '{"expires_in": 3600}')

TOKEN=$(echo "$RESPONSE" | jq -r '.access_token // empty')
if [ -z "$TOKEN" ]; then
    echo "Authentication failed:" >&2
    echo "$RESPONSE" | jq '.' 2>/dev/null || echo "$RESPONSE" >&2
    exit 1
fi

export MIMIRY_TOKEN="$TOKEN"
export MIMIRY_API="${API_BASE}/api/compute/v1"
echo "Authenticated (fingerprint: $FINGERPRINT)"
set +e
