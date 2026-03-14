#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="SpotifyPlay"
DIST_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)/dist"
APP_BUNDLE="${DIST_DIR}/${APP_NAME}.app"
BUILD_DIR="${SCRIPT_DIR}/build"

echo "=== Building ${APP_NAME} ==="

# Clean previous build
rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"

# Compile universal binary (ARM + Intel)
echo "Compiling (arm64)..."
swiftc \
    -O \
    -whole-module-optimization \
    -target arm64-apple-macosx11.0 \
    -o "${BUILD_DIR}/${APP_NAME}-arm64" \
    "${SCRIPT_DIR}/${APP_NAME}.swift"

echo "Compiling (x86_64)..."
swiftc \
    -O \
    -whole-module-optimization \
    -target x86_64-apple-macosx11.0 \
    -o "${BUILD_DIR}/${APP_NAME}-x86_64" \
    "${SCRIPT_DIR}/${APP_NAME}.swift"

echo "Creating universal binary..."
lipo -create \
    "${BUILD_DIR}/${APP_NAME}-arm64" \
    "${BUILD_DIR}/${APP_NAME}-x86_64" \
    -output "${BUILD_DIR}/${APP_NAME}"

# Generate AppIcon.icns from icon.png
echo "Generating app icon..."
ICONSET_DIR="${BUILD_DIR}/AppIcon.iconset"
mkdir -p "${ICONSET_DIR}"
for size in 16 32 64 128 256 512; do
    sips -z ${size} ${size} "${SCRIPT_DIR}/icon.png" --out "${ICONSET_DIR}/icon_${size}x${size}.png" >/dev/null 2>&1
done
for size in 16 32 128 256; do
    double=$((size * 2))
    cp "${ICONSET_DIR}/icon_${double}x${double}.png" "${ICONSET_DIR}/icon_${size}x${size}@2x.png" 2>/dev/null || true
done
iconutil -c icns "${ICONSET_DIR}" -o "${BUILD_DIR}/AppIcon.icns" 2>/dev/null || echo "Warning: iconutil failed, using fallback icon"

# Create .app bundle
echo "Creating app bundle..."
mkdir -p "${DIST_DIR}"
rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

cp "${BUILD_DIR}/${APP_NAME}" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
cp "${SCRIPT_DIR}/Info.plist" "${APP_BUNDLE}/Contents/"
if [ -f "${BUILD_DIR}/AppIcon.icns" ]; then
    cp "${BUILD_DIR}/AppIcon.icns" "${APP_BUNDLE}/Contents/Resources/"
fi
cp "${SCRIPT_DIR}/icon.png" "${APP_BUNDLE}/Contents/Resources/"

# Ad-hoc code sign (required for event tap on modern macOS)
echo "Code signing..."
codesign --force --sign - "${APP_BUNDLE}"

# Clean build artifacts
rm -rf "${BUILD_DIR}"

echo ""
echo "=== Built to ${APP_BUNDLE} ==="
echo ""
echo "To install:"
echo "  cp -r '${APP_BUNDLE}' /Applications/"
echo ""
echo "First launch:"
echo "  1. Right-click the app and choose Open (to bypass Gatekeeper)"
echo "  2. Grant Accessibility permission when prompted"
echo "  3. Relaunch the app after granting permission"
