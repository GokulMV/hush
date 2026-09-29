#!/usr/bin/env bash
# One-time: creates a self-signed code-signing certificate, "Over&Out Self-Signed", in your login
# keychain. build-app.sh / release.sh sign every build with it, so macOS recognises each update as
# the same app and keeps its Camera and Accessibility permissions (with the default ad-hoc signature
# it asks again after every update). No Apple Developer account needed.
set -euo pipefail

NAME="Over&Out Self-Signed"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "✅ Signing certificate already set up: $NAME"
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF

# macOS's own openssl (LibreSSL) writes a .p12 that `security import` understands.
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/cert.cnf" \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" \
    -out "$TMP/identity.p12" -passout pass:overandout

security import "$TMP/identity.p12" -k "$KEYCHAIN" -P overandout -T /usr/bin/codesign
echo "macOS may ask for your login password to trust the certificate for code signing…"
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem"

echo
echo "✅ Created \"$NAME\". Keep it: every future release must be signed with this same certificate"
echo "   (back it up from Keychain Access if you'll release from another Mac)."
