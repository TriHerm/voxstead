#!/usr/bin/env bash
set -euo pipefail

mode="${1:-run}"
case "$mode" in
  run|--debug|--logs|--telemetry|--verify|--build-only) ;;
  *) printf 'Usage: %s [--build-only|--debug|--logs|--telemetry|--verify]\n' "$0" >&2; exit 2 ;;
esac

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"
if [[ -z "${DEVELOPER_DIR:-}" && "$(xcode-select -p)" == /Library/Developer/CommandLineTools && -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
configuration="${VOXSTEAD_BUILD_CONFIGURATION:-debug}"
xcrun swift build --configuration "$configuration" --product Voxstead
binary="$(xcrun swift build --configuration "$configuration" --show-bin-path)/Voxstead"
destination="$root/dist/Voxstead.app"
mkdir -p "$root/dist"
stage="$(mktemp -d "$root/dist/.app.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
bundle="$stage/Voxstead.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp "$binary" "$bundle/Contents/MacOS/Voxstead"
cp "$root/script/Info.plist" "$bundle/Contents/Info.plist"
cp "$root/Assets/Voxstead.icns" "$bundle/Contents/Resources/"
licenses="$bundle/Contents/Resources/Licenses"
mkdir -p "$licenses"
cp "$root/LICENSE" "$licenses/Voxstead.txt"
for dependency in "$root"/.build/checkouts/*; do
  name="$(basename "$dependency")"
  for notice in "$dependency"/LICENSE* "$dependency"/NOTICE*; do
    [[ -f "$notice" ]] || continue
    mkdir -p "$licenses/$name"
    cp "$notice" "$licenses/$name/"
  done
done
cp -R "$root/.build/checkouts/FluidAudio/ThirdPartyLicenses" "$licenses/FluidAudio/"
if [[ -n "${VOXSTEAD_SIGN_IDENTITY:-}" ]]; then
  /usr/bin/codesign --force --options runtime --timestamp --sign "$VOXSTEAD_SIGN_IDENTITY" "$bundle"
else
  /usr/bin/codesign --force --sign - "$bundle"
fi
/usr/bin/codesign --verify --strict "$bundle"

if pgrep -f "^$destination/Contents/MacOS/Voxstead$" >/dev/null; then
  printf 'Quit the workspace copy of Voxstead before replacing it so it can save the current recording.\n' >&2
  exit 1
fi

rm -rf "$destination"
mv "$bundle" "$destination"

case "$mode" in
  --build-only) printf '%s\n' "$destination" ;;
  --debug) lldb -- "$destination/Contents/MacOS/Voxstead" ;;
  --verify)
    /usr/bin/open -n "$destination"
    for _ in {1..25}; do
      if pgrep -f "^$destination/Contents/MacOS/Voxstead$" >/dev/null; then
        sleep 1
        pgrep -f "^$destination/Contents/MacOS/Voxstead$" >/dev/null && exit 0
      fi
      sleep 0.2
    done
    printf 'Voxstead did not stay running.\n' >&2
    exit 1
    ;;
  --logs|--telemetry)
    /usr/bin/open -n "$destination"
    /usr/bin/log stream --style compact --predicate 'process == "Voxstead"'
    ;;
  run) /usr/bin/open -n "$destination" ;;
esac
