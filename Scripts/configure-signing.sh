#!/bin/bash
set -euo pipefail

if [[ "$#" -ne 1 ]]; then
    printf 'Usage: bash Scripts/configure-signing.sh /path/to/developerID_application.cer\n' >&2
    exit 2
fi
certificate="$1"
root="$(cd "$(dirname "$0")/.." && pwd)"
fingerprint="$(/usr/bin/openssl x509 -inform DER -in "$certificate" -noout -fingerprint -sha1 |
    /usr/bin/sed 's/.*=//;s/://g')"
if [[ ! "$fingerprint" =~ ^[[:xdigit:]]{40}$ ]]; then
    printf 'Could not read the signing certificate fingerprint.\n' >&2
    exit 1
fi

/usr/bin/security verify-cert -p codeSign -L -c "$certificate"
if ! /usr/bin/security find-identity -v -p codesigning |
    /usr/bin/grep -Fi "$fingerprint" >/dev/null; then
    login_keychain="$( (/usr/bin/security login-keychain -d user || /usr/bin/security default-keychain -d user) |
        /usr/bin/sed -E 's/^[[:space:]]*"//; s/"$//')"
    if [[ ! -f "$login_keychain" ]]; then
        printf 'Could not locate the login keychain.\n' >&2
        exit 1
    fi
    /usr/bin/security import "$certificate" -k "$login_keychain"
fi
if ! /usr/bin/security find-identity -v -p codesigning |
    /usr/bin/grep -Fi "$fingerprint" >/dev/null; then
    printf 'The certificate is present, but its matching signing identity is unavailable.\n' >&2
    exit 1
fi

config="$(mktemp "$root/.kippet-signing.XXXXXXXX")"
trap 'rm -f "$config"' EXIT
printf '%s\n' "$fingerprint" >"$config"
mv "$config" "$root/.kippet-signing-identity"
printf 'Kippet will reuse this signing identity on subsequent local builds.\n'
