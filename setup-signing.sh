#!/bin/bash
# One-time: create a stable self-signed code-signing identity in a dedicated
# keychain so macOS remembers Tempo's Music-library permission permanently
# (ad-hoc signatures don't persist TCC grants). Safe to re-run.
set -e
KC="tempo-signing"
PW="tempo"
IDENTITY="Tempo Local Signing"
KEYCHAIN="$HOME/Library/Keychains/$KC.keychain-db"

if security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "$IDENTITY"; then
    echo "✓ Signing identity already present."
    exit 0
fi

cat > /tmp/tempocsr.cnf <<'EOF'
[req]
distinguished_name=dn
x509_extensions=v3
prompt=no
[dn]
CN=Tempo Local Signing
[v3]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -keyout /tmp/tk.pem -out /tmp/tc.pem -days 3650 -nodes -config /tmp/tempocsr.cnf
# Legacy PBE so macOS's importer can read the PKCS#12.
openssl pkcs12 -export -inkey /tmp/tk.pem -in /tmp/tc.pem -out /tmp/tid.p12 \
    -passout pass:$PW -name "$IDENTITY" \
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1

security create-keychain -p "$PW" "$KC.keychain" 2>/dev/null || true
security unlock-keychain -p "$PW" "$KC.keychain"
security set-keychain-settings "$KC.keychain"
EXISTING=$(security list-keychains -d user | sed -e 's/"//g' -e 's/^[[:space:]]*//')
security list-keychains -d user -s "$KC.keychain" $EXISTING >/dev/null 2>&1
security import /tmp/tid.p12 -k "$KC.keychain" -P "$PW" -A -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PW" "$KC.keychain" >/dev/null 2>&1
rm -f /tmp/tk.pem /tmp/tc.pem /tmp/tid.p12 /tmp/tempocsr.cnf
echo "✓ Created signing identity: $IDENTITY"
