#!/bin/bash
# Packages dist/Kippet.app as a notarized Kippet DMG that opens on other Macs without Gatekeeper warnings.
#
# One-time setup (stores an app-specific password in the keychain):
#   xcrun notarytool store-credentials kippet-notary --apple-id <Apple ID> --team-id <Team ID>
#
# Usage:
#   ./Scripts/build-app.sh --arch arm64 --arch x86_64   # universal: Apple silicon and Intel
#   ./Scripts/package-release.sh            # sign, notarize, staple
#   ./Scripts/package-release.sh --skip-notarize   # local check only; other Macs will block it
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
app="$root/dist/Kippet.app"
profile="${KIPPET_NOTARY_PROFILE:-kippet-notary}"
notarize=1
[[ "${1:-}" == "--skip-notarize" ]] && notarize=0

if [[ ! -d "$app" ]]; then
    printf 'Build the app first: ./Scripts/build-app.sh\n' >&2
    exit 1
fi

identity="$(/usr/bin/printenv KIPPET_SIGN_IDENTITY || /usr/bin/printenv CLIPSHELF_SIGN_IDENTITY || true)"
for file in "$root/.kippet-signing-identity" "$root/.clipshelf-signing-identity"; do
    if [[ -z "$identity" && -f "$file" ]]; then identity="$(<"$file")"; fi
done
if [[ -z "$identity" ]] || ! /usr/bin/security find-identity -v -p codesigning |
    /usr/bin/grep -F "$identity" | /usr/bin/grep -q "Developer ID Application"; then
    printf 'A Developer ID Application identity is required. Run Scripts/configure-signing.sh first.\n' >&2
    exit 1
fi

archs="$(/usr/bin/lipo -archs "$app/Contents/MacOS/Kippet")"
if [[ "$archs" != *arm64* || "$archs" != *x86_64* ]]; then
    printf 'Release builds must run on Apple silicon and Intel. Rebuild with: ./Scripts/build-app.sh --arch arm64 --arch x86_64\n' >&2
    exit 1
fi

version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist")"
release="$root/dist/release"
dmg="$release/Kippet-$version.dmg"
work="$(mktemp -d "${TMPDIR:-/tmp}/kippet-release.XXXXXXXX")"
trap 'rm -rf "$work"' EXIT

mkdir -p "$work/root" "$release"
/usr/bin/ditto "$app" "$work/root/Kippet.app"
# Notarization needs the hardened runtime and a secure timestamp.
/usr/bin/codesign --force --options runtime --timestamp --sign "$identity" \
    --entitlements "$root/Kippet.entitlements" "$work/root/Kippet.app"
/usr/bin/codesign --verify --strict --deep "$work/root/Kippet.app"
ln -s /Applications "$work/root/Applications"

rm -f "$dmg"
/usr/bin/hdiutil create -quiet -volname "Kippet" -srcfolder "$work/root" -fs HFS+ -format UDZO "$dmg"
/usr/bin/codesign --force --timestamp --sign "$identity" "$dmg"

if [[ "$notarize" == 1 ]]; then
    /usr/bin/xcrun notarytool submit "$dmg" --keychain-profile "$profile" --wait
    /usr/bin/xcrun stapler staple "$dmg"
    /usr/sbin/spctl --assess --type open --context context:primary-signature -vv "$dmg"
else
    printf 'Skipped notarization: this DMG is for local checks only.\n' >&2
fi

# The landing page links to site/downloads/Kippet.dmg.
mkdir -p "$root/site/downloads"
cp "$dmg" "$root/site/downloads/Kippet.dmg"
/usr/bin/shasum -a 256 "$dmg"
echo "$dmg"
