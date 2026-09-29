#!/usr/bin/env bash
# One-time, on the Mac that has the "Over&Out Self-Signed" certificate (scripts/setup-signing.sh):
# lets the "release" GitHub Actions workflow publish releases, so you can release from anywhere
# (GitHub → Actions → release → Run workflow), signed with the same certificate as before.
#
# Stores three repository secrets with the GitHub CLI:
#   SIGNING_CERT_P12, SIGNING_CERT_PASSWORD  the certificate and its private key (only this one)
#   RELEASE_TOKEN                            a token allowed to push to this repo and the tap
#                                            (default: your GitHub CLI login; pass a fine-grained
#                                            token as $1 to limit it to the two repos)
set -euo pipefail
cd "$(dirname "$0")/.."

NAME="Over&Out Self-Signed"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
command -v gh >/dev/null || { echo "Install the GitHub CLI first: brew install gh && gh auth login"; exit 1; }
security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1 \
    || { echo "No \"$NAME\" certificate here. Run this on the Mac you release from."; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS="$(uuidgen)"

# `security` can only export every identity at once; keep just ours (cert + its key) from that.
echo "macOS may ask for your login password (once per key) to export the certificate…"
security export -k "$KEYCHAIN" -t identities -f pkcs12 -P "$PASS" -o "$TMP/all.p12"
/usr/bin/openssl pkcs12 -in "$TMP/all.p12" -passin pass:"$PASS" -nodes -out "$TMP/all.pem" 2>/dev/null
security find-certificate -c "$NAME" -p "$KEYCHAIN" > "$TMP/cert.pem"
# The key whose public half matches our certificate.
WANT="$(/usr/bin/openssl x509 -in "$TMP/cert.pem" -noout -pubkey | /usr/bin/openssl md5)"
awk -v dir="$TMP" '/-----BEGIN .*PRIVATE KEY-----/ { n++; out = dir "/key" n ".pem" } out { print > out } /-----END .*PRIVATE KEY-----/ { out = "" }' "$TMP/all.pem"
KEY=""
for candidate in "$TMP"/key*.pem; do
    [ -e "$candidate" ] || continue
    if [ "$(/usr/bin/openssl pkey -in "$candidate" -pubout 2>/dev/null | /usr/bin/openssl md5)" = "$WANT" ]; then
        KEY="$candidate"; break
    fi
done
[ -n "$KEY" ] || { echo "Couldn't find the private key for \"$NAME\"."; exit 1; }
/usr/bin/openssl pkcs12 -export -inkey "$KEY" -in "$TMP/cert.pem" -name "$NAME" \
    -out "$TMP/identity.p12" -passout pass:"$PASS"

base64 -i "$TMP/identity.p12" | gh secret set SIGNING_CERT_P12
printf '%s' "$PASS" | gh secret set SIGNING_CERT_PASSWORD
if [ -n "${1:-}" ]; then
    printf '%s' "$1" | gh secret set RELEASE_TOKEN
else
    gh auth token | gh secret set RELEASE_TOKEN
fi

echo
echo "✅ Done. To release from anywhere: GitHub → $(gh repo view --json nameWithOwner -q .nameWithOwner)"
echo "   → Actions → release → Run workflow → enter the version."
