#!/bin/sh
# Build "tailmix Menu.app" from this Swift package. Run on macOS with Xcode or
# the Command Line Tools installed.
#
#   ./build-app.sh                 # build for this Mac's architecture
#   UNIVERSAL=1 ./build-app.sh     # arm64 + x86_64 (requires Xcode)
#   OUTPUT_DIR=/Applications ./build-app.sh
set -eu

cd "$(dirname "$0")"
output_dir=${OUTPUT_DIR:-build}
app="$output_dir/tailmix Menu.app"
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
# Ad-hoc signing is enough to run locally and to register as a login item.
codesign --force --sign "${CODESIGN_IDENTITY:--}" "$app"
echo "Built $app"
