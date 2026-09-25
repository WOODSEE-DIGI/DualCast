#!/bin/zsh
#
# setup-local.sh
#
# Build and install DualCast directly on the local Mac (intended for ShootyMax).
# This avoids cross-Mac code signing issues because the app is signed with
# the Apple Development certificate installed on this machine.
#
# Must be run as an admin user. The script will prompt for sudo when needed.
#

set -e

SCRIPT_DIR="${0:A:h}"
PROJECT_ROOT="${SCRIPT_DIR:h}"
DERIVED_DATA="${PROJECT_ROOT}/build-debug"
BUILT_PRODUCTS="${DERIVED_DATA}/Build/Products/Debug"

cd "$PROJECT_ROOT"

# Verify full Xcode is installed (Command Line Tools alone are not enough).
if ! xcode-select -p | grep -q "Xcode.app"; then
    echo "ERROR: Full Xcode.app is required, but only Command Line Tools are installed."
    echo "Install Xcode from the App Store or https://developer.apple.com/download/"
    echo "Then run: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
    exit 1
fi

echo "==> Generating Xcode project..."
xcodegen generate

echo "==> Patching camera extension embed phase..."
python3 scripts/fix-camera-extension-embed.py

echo "==> Building Debug binaries..."
xcodebuild -scheme DualCast -configuration Debug -derivedDataPath "$DERIVED_DATA" build
xcodebuild -scheme DualCastSwitcher -configuration Debug -derivedDataPath "$DERIVED_DATA" build
xcodebuild -scheme DualCastAudioDriver -configuration Debug -derivedDataPath "$DERIVED_DATA" build

echo "==> Installing DualCast.app to /Applications..."
sudo rm -rf /Applications/DualCast.app
sudo cp -R "${BUILT_PRODUCTS}/DualCast.app" /Applications/
sudo xattr -d com.apple.quarantine /Applications/DualCast.app 2>/dev/null || true

echo "==> Installing DualCastSwitcher.app to /Applications..."
sudo rm -rf /Applications/DualCastSwitcher.app
sudo cp -R "${BUILT_PRODUCTS}/DualCastSwitcher.app" /Applications/
sudo xattr -d com.apple.quarantine /Applications/DualCastSwitcher.app 2>/dev/null || true

echo "==> Installing DualCastAudioDriver..."
sudo rm -rf /Library/Audio/Plug-Ins/HAL/DualCastAudioDriver.driver
sudo cp -R "${BUILT_PRODUCTS}/DualCastAudioDriver.driver" /Library/Audio/Plug-Ins/HAL/
sudo xattr -d com.apple.quarantine /Library/Audio/Plug-Ins/HAL/DualCastAudioDriver.driver 2>/dev/null || true
sudo chown -R root:wheel /Library/Audio/Plug-Ins/HAL/DualCastAudioDriver.driver
sudo chmod -R 755 /Library/Audio/Plug-Ins/HAL/DualCastAudioDriver.driver

echo "==> Restarting coreaudiod..."
sudo killall coreaudiod 2>/dev/null || true

echo ""
echo "==> Done."
echo "Next steps:"
echo "1. Open System Settings -> Privacy & Security -> Camera Extension"
echo "   and approve DualCastCameraExtension."
echo "2. Launch DualCastSwitcher and click 'Activate Cameras'."
echo "3. Launch DualCast on the sender Mac and grant permissions."
