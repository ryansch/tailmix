#!/bin/sh
# Build "tailmix.app", the menu bar app, from this Swift package. Run on
# macOS with Xcode or the Command Line Tools installed.
#
#   ./build-app.sh                 # build for this Mac's architecture
#   UNIVERSAL=1 ./build-app.sh     # arm64 + x86_64 (requires Xcode)
#   OUTPUT_DIR=/Applications ./build-app.sh
set -eu

cd "$(dirname "$0")"
output_dir=${OUTPUT_DIR:-build}
app="$output_dir/tailmix.app"
# CFBundleShortVersionString allows only numbers, so drop any prerelease suffix.
version=${VERSION:-$(sed -n '1p' ../../version/VERSION.txt 2>/dev/null || echo 0.0.0)}
version=${version%%-*}

if [ "${UNIVERSAL:-0}" = 1 ]; then
	swift build -c release --arch arm64 --arch x86_64
	bin_dir=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)
else
	swift build -c release
	bin_dir=$(swift build -c release --show-bin-path)
fi

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_dir/TailmixMenu" "$app/Contents/MacOS/TailmixMenu"
sed "s|@VERSION@|$version|g" Resources/Info.plist > "$app/Contents/Info.plist"

# Render the icon and pack it at every size macOS asks for.
iconset=$(mktemp -d "${TMPDIR:-/tmp}/tailmix-icon.XXXXXX")/AppIcon.iconset
mkdir "$iconset"
swift scripts/make-icon.swift "$iconset/icon_512x512@2x.png"
for size in 16 32 128 256 512; do
	sips -z "$size" "$size" "$iconset/icon_512x512@2x.png" --out "$iconset/icon_${size}x${size}.png" >/dev/null
	double=$((size * 2))
	if [ "$double" -lt 1024 ]; then
		sips -z "$double" "$double" "$iconset/icon_512x512@2x.png" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
	fi
done
iconutil -c icns -o "$app/Contents/Resources/AppIcon.icns" "$iconset"
rm -r "$(dirname "$iconset")"
# Ad-hoc signing is enough to run locally and to register as a login item.
codesign --force --sign "${CODESIGN_IDENTITY:--}" "$app"
echo "Built $app"
