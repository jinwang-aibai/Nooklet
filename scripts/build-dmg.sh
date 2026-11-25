#!/bin/bash
set -euo pipefail

if [ "$#" -gt 1 ]; then
  printf 'Usage: %s [output-directory]\n' "$0" >&2
  exit 2
fi

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
output_dir="$project_dir/.build/distribution"
if [ "$#" -eq 1 ]; then output_dir="$1"; fi
mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd)"

"$project_dir/scripts/build-app.sh"
app="$project_dir/.build/app/Nooklet.app"
version="$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$app/Contents/Info.plist")"
if beta="$(/usr/bin/plutil -extract NookletBetaNumber raw "$app/Contents/Info.plist" 2>/dev/null)"; then
  version="$version-beta.$beta"
fi
architectures="$(/usr/bin/lipo -archs "$app/Contents/MacOS/Nooklet" | tr ' ' '-')"
filename="Nooklet-$version-$architectures.dmg"

staging="$(mktemp -d "$project_dir/.build/dmg.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
mkdir "$staging/volume"
/usr/bin/ditto "$app" "$staging/volume/Nooklet.app"
ln -s /Applications "$staging/volume/Applications"

/usr/bin/hdiutil create -quiet -volname Nooklet -fs HFS+ -format UDZO \
  -srcfolder "$staging/volume" "$staging/$filename"
/usr/bin/hdiutil verify "$staging/$filename"
mv "$staging/$filename" "$output_dir/$filename"
printf 'Built %s\n' "$output_dir/$filename"
