#!/bin/bash
#
# Creates a stable self-signed code-signing identity and imports it into the
# login keychain, so build.sh can sign lumac with a constant identity.
#
# Why: macOS ties Full Disk Access (and other TCC grants) to an app's Designated
# Requirement. With this identity that requirement is anchored to the certificate,
# not the binary hash, so a granted permission survives every rebuild. Ad-hoc
# signing has no stable identity, so each rebuild looks like a new app and has to
# be re-authorized.
#
# Run once:  ./scripts/make-signing-cert.sh
# The signature is self-signed (free), so first launch after download still needs
# a one-time Gatekeeper bypass — but updates keep their permissions.

set -euo pipefail

NAME="${1:-lumac-selfsign}"

if security find-identity -p codesigning 2>/dev/null | grep -q "\"$NAME\""; then
  echo "'$NAME' already exists in the keychain — nothing to do."
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cs.cnf" <<EOF
[ req ]
distinguished_name = dn
x509_extensions = ext
prompt = no
[ dn ]
CN = $NAME
[ ext ]
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
  -days 3650 -nodes -config "$TMP/cs.cnf" -extensions ext >/dev/null 2>&1

openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -out "$TMP/id.p12" -passout pass:lumac -name "$NAME" >/dev/null 2>&1

# -A lets any tool use the key without a per-use prompt (codesign included).
security import "$TMP/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
  -P lumac -A

echo "created code-signing identity '$NAME'."
echo "now run ./build.sh — it will sign with it automatically."
