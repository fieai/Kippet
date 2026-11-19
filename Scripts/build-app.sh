#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
configuration=release
app="$root/dist/Kippet.app"
identity_file="$root/.kippet-signing-identity"
# Older checkouts saved the fingerprint under the ClipShelf name.
[[ -f "$identity_file" ]] || identity_file="$root/.clipshelf-signing-identity"
identity="$(/usr/bin/printenv KIPPET_SIGN_IDENTITY || /usr/bin/printenv CLIPSHELF_SIGN_IDENTITY || true)"
if [[ -z "$identity" && -f "$identity_file" ]]; then
    identity="$(<"$identity_file")"
    if [[ ! "$identity" =~ ^[[:xdigit:]]{40}$ ]]; then
        printf 'Invalid signing fingerprint in %s\n' "$identity_file" >&2
        exit 1
    fi
fi
if [[ -z "$identity" && -d "$app" ]] &&
    /usr/bin/codesign -d --verbose=2 "$app" 2>&1 | /usr/bin/grep '^Authority=' >/dev/null; then
    printf 'Kippet already uses certificate signing. Configure its identity before rebuilding.\n' >&2
    exit 1
fi
if [[ -z "$identity" ]]; then
    identity=-
fi

swift build --package-path "$root" -c "$configuration" "$@"
binary_dir="$(swift build --package-path "$root" -c "$configuration" --show-bin-path "$@")"

mkdir -p "$root/dist"
staging="$(mktemp -d "$root/dist/.kippet-build.XXXXXXXX")"
cleanup() {
    if [[ -d "$staging/Previous.app" && ! -e "$app" ]]; then
        if ! mv "$staging/Previous.app" "$app"; then
            printf 'Previous app is available at %s/Previous.app\n' "$staging" >&2
            return
        fi
    fi
    rm -rf "$staging"
}
trap cleanup EXIT

new_app="$staging/Kippet.app"
mkdir -p "$new_app/Contents/MacOS" "$new_app/Contents/Resources"
install -m 644 "$root/Info.plist" "$new_app/Contents/Info.plist"
install -m 644 "$root/Resources/Kippet.icns" "$new_app/Contents/Resources/Kippet.icns"
install -m 755 "$binary_dir/Kippet" "$new_app/Contents/MacOS/Kippet"
/usr/bin/codesign --force --sign "$identity" --timestamp=none --entitlements "$root/Kippet.entitlements" "$new_app"
/usr/bin/codesign --verify --strict "$new_app"
if [[ -d "$app" ]]; then
    mv "$app" "$staging/Previous.app"
fi
mv "$new_app" "$app"
echo "$app"
