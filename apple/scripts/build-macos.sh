#!/usr/bin/env bash
# Build the macOS release of Paperhue: a universal (arm64 + x86_64) Release build of
# Paperhue.app, signed ad hoc and zipped as Paperhue-macOS.zip for the GitHub release.
#
# Usage: apple/scripts/build-macos.sh [output-dir]     (default: apple/build/release)
# The version shown in About is PAPERHUE_VERSION when set (apple.yml passes the tag's, as
# android.yml does: v0.3.2 -> 0.3.2), else project.yml's MARKETING_VERSION.
# Needs Xcode (xcodebuild). Without a Developer ID the app is signed ad hoc, so macOS asks
# users to confirm it the first time (right-click > Open); see apple/DEVELOPING.md.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
apple="$(cd "$here/.." && pwd)"
out="${1:-$apple/build/release}"
mkdir -p "$out"
out="$(cd "$out" && pwd)"
derived="$out/DerivedData"
app="$derived/Build/Products/Release/Paperhue.app"
zip="$out/Paperhue-macOS.zip"

version="${PAPERHUE_VERSION:-}"
version="${version%%[!0-9.]*}"  # 0.3.2-rc1 -> 0.3.2: the bundle version is numbers only
if [ -n "${PAPERHUE_VERSION:-}" ] && ! [[ "$version" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
  echo "error: PAPERHUE_VERSION is not a version like 0.3.2: $PAPERHUE_VERSION" >&2; exit 1
fi

rm -rf "$derived" "$zip"
xcodebuild -project "$apple/Paperhue/Paperhue.xcodeproj" -scheme Paperhue \
  -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath "$derived" \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO \
  ${version:+"MARKETING_VERSION=$version"} \
  build

archs="$(lipo -archs "$app/Contents/MacOS/Paperhue")"
for arch in arm64 x86_64; do
  case " $archs " in
    *" $arch "*) ;;
    *) echo "error: Paperhue is not universal (has: $archs)" >&2; exit 1 ;;
  esac
done

# Ad hoc signature ("-"), with the app's sandbox entitlements. Nested code is signed first.
if [ -d "$app/Contents/Frameworks" ]; then
  find "$app/Contents/Frameworks" -depth \( -name '*.framework' -o -name '*.dylib' \) \
    -exec codesign --force --sign - --timestamp=none {} \;
fi
codesign --force --sign - --timestamp=none \
  --entitlements "$apple/Paperhue/Paperhue/Paperhue.entitlements" "$app"
codesign --verify --deep --strict "$app"

# Without extended attributes, ACLs or resource forks: ditto would store them as AppleDouble
# "._*" entries, which `unzip` extracts into the bundle and so breaks its signature.
ditto -c -k --norsrc --noextattr --noacl --noqtn --keepParent "$app" "$zip"

# Check what users get: the zip extracted with plain `unzip`.
if zipinfo -1 "$zip" | grep -E -q '(^|/)(\._|__MACOSX/)'; then
  echo "error: $zip holds AppleDouble entries" >&2; exit 1
fi
check="$(mktemp -d "$out/check.XXXXXX")"
trap 'rm -rf "$check"' EXIT
unzip -q "$zip" -d "$check"
codesign --verify --deep --strict "$check/Paperhue.app"
# The app is Paperhue: no file in it (a resource bundle, say) and none of its names or its
# identifier says ULANI. Internal module names in the binary and texts that name the
# hardware may.
named="$(find "$check/Paperhue.app" -iname '*ulani*')"
plist="$check/Paperhue.app/Contents/Info.plist"
for key in CFBundleName CFBundleDisplayName CFBundleIdentifier CFBundleExecutable; do
  value="$(/usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2>/dev/null || true)"
  case "$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')" in
    *ulani*) named="$named"$'\n'"Info.plist $key: $value" ;;
  esac
done
if [ -n "$named" ]; then
  echo "error: Paperhue.app is named ULANI:" >&2
  printf '%s\n' "$named" | grep . >&2
  exit 1
fi
built="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$plist")"
if [ -n "$version" ] && [ "$built" != "$version" ]; then
  echo "error: Paperhue.app says version $built, not $version" >&2; exit 1
fi
echo "built $zip (version $built, $archs, ad hoc signed)"
shasum -a 256 "$zip"
