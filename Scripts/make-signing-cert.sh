#!/bin/bash
# Create a stable, self-signed code-signing identity in the login keychain so
# rebuilds keep the same code identity — which stops macOS from re-prompting for
# microphone / system-audio permissions after every build (ad-hoc signing
# changes identity each time, so TCC treats each build as a new app).
#
# The identity is local to this machine and NOT committed (a private signing key
# must never live in a public repo). Run once; make-app.sh picks it up by name.
set -euo pipefail

NAME="autowhisper Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -p codesigning | grep -q "$NAME"; then
    echo "already present: \"$NAME\""
    security find-identity -p codesigning | grep "$NAME"
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cs.cnf" <<'EOF'
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = autowhisper Local Signing
[v3]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
    -days 3650 -nodes -config "$TMP/cs.cnf" >/dev/null 2>&1

# Apple's Security framework needs legacy PKCS#12 MAC/ciphers (openssl 3.x
# defaults to AES it can't read).
openssl pkcs12 -export -legacy -macalg sha1 \
    -certpbe pbeWithSHA1And40BitRC2-CBC -keypbe pbeWithSHA1And3-KeyTripleDES-CBC \
    -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/id.p12" \
    -passout pass:aw -name "$NAME" >/dev/null 2>&1

security import "$TMP/id.p12" -k "$KEYCHAIN" -P "aw" -T /usr/bin/codesign >/dev/null

echo "created \"$NAME\":"
security find-identity -p codesigning | grep "$NAME"
echo
echo "Rebuild and install with Scripts/make-app.sh --install."
echo "macOS will prompt for permissions ONE more time (identity changed from ad-hoc);"
echo "after that, rebuilds keep the same identity and won't re-prompt."
