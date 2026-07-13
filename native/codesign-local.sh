#!/bin/sh
# Sign Arco development artifacts with one stable local identity. Apple notes
# that ad-hoc signatures are tied to a specific build, which makes macOS treat
# every rebuild as new code for privacy permissions. This identity is for local
# development only; release builds should set ARCO_CODESIGN_IDENTITY to an
# Apple-issued signing identity.
set -eu

if [ "$#" -ne 2 ]; then
  echo "usage: $0 <code-path> <signing-identifier>" >&2
  exit 2
fi

CODE_PATH=$1
SIGNING_IDENTIFIER=$2

if [ -n "${ARCO_CODESIGN_IDENTITY:-}" ]; then
  codesign --force --sign "$ARCO_CODESIGN_IDENTITY" \
    --identifier "$SIGNING_IDENTIFIER" \
    "$CODE_PATH"
  exit 0
fi

SIGNING_DIR=${ARCO_LOCAL_SIGNING_DIR:-"$HOME/Library/Application Support/Arco/Signing"}
KEYCHAIN="$SIGNING_DIR/arco-local.keychain-db"
PASSWORD_FILE="$SIGNING_DIR/keychain-password"
IDENTITY_NAME="Arco Local Development"

create_identity() {
  umask 077
  mkdir -p "$SIGNING_DIR"
  TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/arco-signing.XXXXXX")
  trap 'rm -rf "$TEMP_DIR"' EXIT HUP INT TERM
  PASSWORD=$(uuidgen)
  printf '%s' "$PASSWORD" > "$PASSWORD_FILE"
  security create-keychain -p "$PASSWORD" "$KEYCHAIN"
  security unlock-keychain -p "$PASSWORD" "$KEYCHAIN"
  /usr/bin/openssl req -x509 -newkey rsa:2048 \
    -keyout "$TEMP_DIR/key.pem" \
    -out "$TEMP_DIR/cert.pem" \
    -days 3650 \
    -nodes \
    -subj "/CN=$IDENTITY_NAME/O=Arco Local Development" \
    -addext "basicConstraints=critical,CA:TRUE" \
    -addext "keyUsage=critical,digitalSignature,keyCertSign" \
    -addext "extendedKeyUsage=codeSigning" >/dev/null 2>&1
  /usr/bin/openssl pkcs12 -export \
    -out "$TEMP_DIR/identity.p12" \
    -inkey "$TEMP_DIR/key.pem" \
    -in "$TEMP_DIR/cert.pem" \
    -passout "pass:$PASSWORD" >/dev/null 2>&1
  security import "$TEMP_DIR/identity.p12" \
    -k "$KEYCHAIN" \
    -P "$PASSWORD" \
    -T /usr/bin/codesign >/dev/null
  rm -rf "$TEMP_DIR"
  trap - EXIT HUP INT TERM
}

if [ ! -f "$KEYCHAIN" ] || [ ! -f "$PASSWORD_FILE" ]; then
  rm -f "$KEYCHAIN" "$PASSWORD_FILE"
  create_identity
fi

PASSWORD=$(cat "$PASSWORD_FILE")
security unlock-keychain -p "$PASSWORD" "$KEYCHAIN"
IDENTITY_SHA=$(security find-certificate -c "$IDENTITY_NAME" -Z "$KEYCHAIN" \
  | awk '/SHA-1 hash:/{print $3; exit}')
if [ -z "$IDENTITY_SHA" ]; then
  echo "Arco local signing identity is missing from $KEYCHAIN" >&2
  exit 1
fi

codesign --force --sign "$IDENTITY_SHA" \
  --keychain "$KEYCHAIN" \
  --identifier "$SIGNING_IDENTIFIER" \
  "$CODE_PATH"
