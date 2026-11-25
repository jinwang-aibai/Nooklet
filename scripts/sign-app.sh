#!/bin/bash
set -euo pipefail

app="$1"
staging_dir="$2"
finder_extension="$3"
finder_entitlements="$4"

sign_bundles() {
  /usr/bin/codesign --force "$@" --entitlements "$finder_entitlements" "$finder_extension"
  /usr/bin/codesign --force "$@" "$app"
}

if [ -n "${NOOKLET_SIGNING_IDENTITY:-}" ]; then
  sign_bundles --sign "$NOOKLET_SIGNING_IDENTITY"
  exit 0
fi

# Reuse a certificate across builds so macOS can match an existing permission.
umask 077
signing_dir="$HOME/Library/Application Support/Nooklet Development/Signing"
mkdir -p "$signing_dir"
identity="$signing_dir/identity.pem"
if [ ! -s "$identity" ]; then
  new_identity="$(mktemp -d "$signing_dir/.identity.XXXXXX")"
  trap 'rm -rf "$new_identity"' EXIT
  /usr/bin/openssl req -new -x509 -newkey rsa:2048 -nodes -days 3650 \
    -config /dev/stdin -keyout "$new_identity/key.pem" -out "$new_identity/cert.pem" <<'CONFIG'
[req]
prompt = no
distinguished_name = subject
x509_extensions = signing
[subject]
CN = Nooklet Local Development
[signing]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CONFIG
  cat "$new_identity/cert.pem" "$new_identity/key.pem" > "$new_identity/identity.pem"
  if ! ln "$new_identity/identity.pem" "$identity" 2>/dev/null && [ ! -s "$identity" ]; then
    printf 'Could not save the development signing identity at %s\n' "$identity" >&2
    exit 1
  fi
  rm -rf "$new_identity"
  trap - EXIT
fi

# Import only into this build's temporary keychain. No trust settings are needed.
keychain="$staging_dir/signing.keychain-db"
password="$(/usr/bin/openssl rand -hex 24)"
trap '/usr/bin/security delete-keychain "$keychain" >/dev/null 2>&1 || true' EXIT
/usr/bin/openssl pkcs12 -export -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
  -in "$identity" -out "$staging_dir/signing.p12" -passout "pass:$password"
/usr/bin/security create-keychain -p "$password" "$keychain"
/usr/bin/security unlock-keychain -p "$password" "$keychain"
/usr/bin/security import "$staging_dir/signing.p12" -k "$keychain" -P "$password" -T /usr/bin/codesign >/dev/null
/usr/bin/security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$password" "$keychain" >/dev/null
sign_bundles --keychain "$keychain" --sign "Nooklet Local Development"
