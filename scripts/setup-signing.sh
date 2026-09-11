#!/usr/bin/env bash
# Creates a local self-signed code-signing identity "go-runner Local" in the login keychain (once).
# Signing every build with the same identity keeps macOS privacy grants (Accessibility for Slack alerts)
# across rebuilds and reinstalls. scripts/uninstall.sh removes the identity again.
#   ./scripts/setup-signing.sh
set -euo pipefail

NAME="${GORUNNER_SIGN_IDENTITY:-go-runner Local}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
  echo "이미 있습니다: $NAME"
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.cnf" <<EOF
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
EOF

# macOS /usr/bin/openssl (LibreSSL) writes PKCS#12 files the keychain can import.
OPENSSL=/usr/bin/openssl
"$OPENSSL" req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.cnf" >/dev/null 2>&1
# No pipes here: with pipefail, `tr | head` exits on SIGPIPE and silently aborts the script.
PASS="$("$OPENSSL" rand -hex 16)"
"$OPENSSL" pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" \
  -out "$TMP/identity.p12" -passout "pass:$PASS" >/dev/null 2>&1

# -T: only codesign may use the private key without asking.
security import "$TMP/identity.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign >/dev/null

echo "만들었습니다: $NAME (로그인 키체인)"
security find-identity -p codesigning "$KEYCHAIN" | grep -F "$NAME" || true
