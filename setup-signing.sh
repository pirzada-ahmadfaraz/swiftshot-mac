#!/usr/bin/env bash
set -euo pipefail

# Creates a stable self-signed code-signing identity in the login keychain so that
# macOS TCC (Screen Recording permission) remembers the app across rebuilds.
# Run once. Safe to re-run — it no-ops if the identity already exists.

IDENTITY_NAME="CleanShotClone Self-Signed"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

# Check for the CERTIFICATE (not just valid identities) — an imported-but-not-yet
# -trusted cert doesn't show in find-identity, and re-importing creates duplicates
# that make codesign fail with "ambiguous".
if security find-certificate -c "$IDENTITY_NAME" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "Certificate '$IDENTITY_NAME' already exists in the keychain."
    if security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY_NAME"; then
        echo "It is trusted and ready for signing. Nothing to do."
    else
        echo "It is NOT yet trusted for code signing. Trust it with:"
        echo "  security find-certificate -c \"$IDENTITY_NAME\" -p > /tmp/csc.pem"
        echo "  security add-trusted-cert -p codeSign /tmp/csc.pem"
    fi
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/csc.conf" <<EOF
[ req ]
distinguished_name = dn
prompt = no
x509_extensions = ext
[ dn ]
CN = $IDENTITY_NAME
[ ext ]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
EOF

echo "==> Generating self-signed code-signing certificate"
openssl req -x509 -newkey rsa:2048 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
    -days 3650 -nodes -config "$TMP/csc.conf" >/dev/null 2>&1

# -legacy + SHA1 PBE so Apple's `security` tool can read the PKCS12 (OpenSSL 3.x
# defaults to a MAC algorithm that SecKeychainItemImport rejects).
openssl pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -out "$TMP/cert.p12" -passout pass:secret -name "$IDENTITY_NAME" \
    -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 >/dev/null 2>&1

echo "==> Importing into login keychain (allowing codesign to use it without prompts)"
security import "$TMP/cert.p12" -k "$KEYCHAIN" -P "secret" -A -T /usr/bin/codesign

echo "==> Verifying"
if security find-identity -v -p codesigning | grep -q "$IDENTITY_NAME"; then
    echo "Created signing identity '$IDENTITY_NAME'."
else
    echo "WARNING: identity not listed as valid; signing may fall back to ad-hoc."
fi
