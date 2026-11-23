#!/bin/bash
# ONE-TIME, run by the Mac's owner (it changes the login keychain): creates a self-signed code-signing identity
# "MyPLaMo SnapTrans Dev" so development builds keep the same code identity across rebuilds. macOS privacy permissions
# (Accessibility, Screen Recording) are tied to that identity; with ad hoc signing they are lost on every rebuild.
#   macos/scripts/create-dev-cert.sh
# Asks for the login password once (to trust the certificate for code signing). Nothing leaves this Mac.
# Undo: Keychain Access → login → My Certificates → delete "MyPLaMo SnapTrans Dev" (certificate and key).
set -euo pipefail
NAME="MyPLaMo SnapTrans Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then echo "\"$NAME\" already exists."; exit 0; fi
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CNF
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/cert.cnf" -keyout "$TMP/dev.key" -out "$TMP/dev.crt" 2>/dev/null
PASS=$(/usr/bin/openssl rand -hex 16)
/usr/bin/openssl pkcs12 -export -inkey "$TMP/dev.key" -in "$TMP/dev.crt" -name "$NAME" -out "$TMP/dev.p12" -passout "pass:$PASS"
# -T /usr/bin/codesign: codesign may use the key without a keychain prompt on every build.
security import "$TMP/dev.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign
# Trust for code signing in the user's trust settings (macOS asks for the login password here).
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/dev.crt"
security find-identity -v -p codesigning | grep "$NAME" && echo "Created \"$NAME\"."
