#!/usr/bin/env bash
# Checks a built or archived Regatta.app against the shipping config (#107): the A12 device capability,
# the scene manifest and launch screen in Info.plist, no UIRequiresFullScreen, and a privacy manifest.
# With an SDK prefix (e.g. iphoneos27), also checks the SDK the app was built with.
#
#   scripts/check-shipping-config.sh path/to/Regatta.app [sdk-prefix]
set -euo pipefail

app="${1:?usage: check-shipping-config.sh path/to/Regatta.app [sdk-prefix]}"
sdk="${2:-}"
info="$app/Info.plist"
problems=0

fail() {
    echo "check-shipping-config.sh: $1" >&2
    problems=$((problems + 1))
}

plutil -p "$info"

plist="$(plutil -p "$info")"
grep -q '"iphone-ipad-minimum-performance-a12"' <<<"$plist" || fail "no iphone-ipad-minimum-performance-a12 in UIRequiredDeviceCapabilities"
grep -q '"UIApplicationSceneManifest" =>' <<<"$plist" || fail "no UIApplicationSceneManifest"
grep -q '"UISceneDelegateClassName" =>' <<<"$plist" || fail "no scene delegate in the scene manifest"
grep -q '"UILaunchScreen" =>' <<<"$plist" || fail "no UILaunchScreen"
grep -q '"ITSAppUsesNonExemptEncryption" => false' <<<"$plist" || fail "ITSAppUsesNonExemptEncryption isn't false"
if grep -q 'UIRequiresFullScreen' <<<"$plist"; then fail "UIRequiresFullScreen is set"; fi

if [[ -n "$sdk" ]]; then
    built="$(plutil -extract DTSDKName raw "$info")"
    [[ "$built" == "$sdk"* ]] || fail "built with $built, expected $sdk"
fi

if [[ -f "$app/PrivacyInfo.xcprivacy" ]]; then
    plutil -lint "$app/PrivacyInfo.xcprivacy"
else
    fail "no PrivacyInfo.xcprivacy in the bundle"
fi

if ((problems > 0)); then exit 1; fi
echo "Shipping config OK: $app"
