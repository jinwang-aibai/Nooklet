#!/bin/bash
# Local development packaging.
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
configuration="release"

if [ "${1:-}" = "--debug" ]; then
  configuration="debug"
  shift
fi
if [ "$#" -ne 0 ]; then
  echo "Usage: $0 [--debug]" >&2
  exit 2
fi

cd "$project_dir"
swift build --configuration "$configuration" --product Nooklet
swift build --configuration "$configuration" --product NookletFinderExtension
bin_dir="$(swift build --configuration "$configuration" --show-bin-path)"
output_dir="$project_dir/.build/app"
mkdir -p "$output_dir"
staging_dir="$(mktemp -d "$output_dir/.package.XXXXXX")"
trap 'rm -rf "$staging_dir"' EXIT
staging_app="$staging_dir/Nooklet.app"
mkdir -p "$staging_app/Contents/MacOS" "$staging_app/Contents/Resources"

cp "$project_dir/Resources/Info.plist" "$staging_app/Contents/Info.plist"
cp "$project_dir/LICENSE" "$staging_app/Contents/Resources/LICENSE"
cp "$bin_dir/Nooklet" "$staging_app/Contents/MacOS/Nooklet"
chmod 755 "$staging_app/Contents/MacOS/Nooklet"
finder_extension="$staging_app/Contents/PlugIns/NookletFinderExtension.appex"
mkdir -p "$finder_extension/Contents/MacOS"
cp "$project_dir/Resources/FinderExtension-Info.plist" "$finder_extension/Contents/Info.plist"
cp "$bin_dir/NookletFinderExtension" "$finder_extension/Contents/MacOS/NookletFinderExtension"
for key in CFBundleShortVersionString CFBundleVersion LSMinimumSystemVersion; do
  value="$(/usr/bin/plutil -extract "$key" raw "$staging_app/Contents/Info.plist")"
  /usr/bin/plutil -insert "$key" -string "$value" "$finder_extension/Contents/Info.plist"
done
swift "$project_dir/scripts/draw-icon.swift" "$staging_dir/Nooklet.iconset" \
  "$staging_app/Contents/Resources/NookletMenuBar.png"
/usr/bin/iconutil --convert icns --output "$staging_app/Contents/Resources/Nooklet.icns" \
  "$staging_dir/Nooklet.iconset"

# The executable resolves packaged resources from Contents/Resources first;
# Bundle.module remains the fallback when launched directly by SwiftPM.
for resource_bundle in "$bin_dir"/*.bundle; do
  [ -d "$resource_bundle" ] || continue
  /usr/bin/ditto "$resource_bundle" "$staging_app/Contents/Resources/$(basename "$resource_bundle")"
done

/usr/bin/plutil -lint "$staging_app/Contents/Info.plist"
/usr/bin/plutil -lint "$finder_extension/Contents/Info.plist" "$project_dir/Resources/FinderExtension.entitlements"
"$project_dir/scripts/sign-app.sh" "$staging_app" "$staging_dir" "$finder_extension" "$project_dir/Resources/FinderExtension.entitlements"
/usr/bin/codesign --verify --deep --strict "$staging_app"

# Replace only this script's generated application, after packaging succeeds.
destination="$output_dir/Nooklet.app"
if [ -e "$destination" ]; then
  rm -rf "$destination"
fi
mv "$staging_app" "$destination"
printf 'Built %s\n' "$destination"
printf 'Open with: open "%s"\n' "$destination"
