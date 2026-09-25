#!/bin/zsh
#
# create-dmg.sh
#
# Creates a compressed .dmg containing the DualCast installer packages.
# Run after package.sh.
#

set -e

SCRIPT_DIR="${0:A:h}"
PROJECT_ROOT="${SCRIPT_DIR:h}"
DIST_DIR="${PROJECT_ROOT}/dist"
DMG_STAGING="${DIST_DIR}/dmg-staging"
DMG_FILE="${DIST_DIR}/DualCast-Installer.dmg"

cd "$PROJECT_ROOT"

if [[ ! -f "${DIST_DIR}/DualCast-Installer.pkg" ]]; then
    echo "ERROR: Packages not found. Run ./scripts/package.sh first."
    exit 1
fi

echo "==> Staging DMG contents..."
rm -rf "$DMG_STAGING"
mkdir -p "$DMG_STAGING"

cp "${DIST_DIR}/DualCast-Installer.pkg" "${DMG_STAGING}/"
cp "${DIST_DIR}/DualCast-Sender.pkg" "${DMG_STAGING}/"
cp "${DIST_DIR}/DualCast-Receiver.pkg" "${DMG_STAGING}/"

cat > "${DMG_STAGING}/README.txt" <<'EOF'
DualCast Installer
==================

DualCast sends your Mac's displays and cameras as NDI sources.
DualCast Switcher receives them and exposes virtual webcams + audio.

Packages
--------
- DualCast-Installer.pkg    Installs both sender and receiver on this Mac.
- DualCast-Sender.pkg       Installs only DualCast.app (the sender).
- DualCast-Receiver.pkg     Installs DualCastSwitcher.app, the camera
                            extension, and the DualCast Audio driver.

Install
-------
Double-click a package, or run in Terminal:
    sudo installer -pkg DualCast-Receiver.pkg -target /
    sudo installer -pkg DualCast-Sender.pkg -target /

After installing the receiver:
1. Open System Settings → Privacy & Security → Camera Extension.
2. Approve DualCastCameraExtension.
3. Launch DualCast Switcher and click "Activate Cameras".

Permissions
-----------
The first time you run DualCast, grant:
- Screen Recording
- Camera
- Microphone

The first time you run DualCast Switcher, grant:
- Camera Extension activation
EOF

rm -f "$DMG_FILE"

echo "==> Creating DMG..."
hdiutil create \
    -volname "DualCast Installer" \
    -srcfolder "$DMG_STAGING" \
    -ov \
    -format UDZO \
    "$DMG_FILE"

rm -rf "$DMG_STAGING"

echo ""
echo "==> DMG created: $DMG_FILE"
