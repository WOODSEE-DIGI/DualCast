#!/bin/zsh
#
# build-all.sh
#
# Generates the Xcode project, patches the camera extension embed phase, and
# builds all DualCast targets (DualCast, DualCastSwitcher, DualCastCameraExtension,
# DualCastAudioDriver). Run this after pulling changes or editing project.yml.
#

set -e

SCRIPT_DIR="${0:A:h}"
PROJECT_ROOT="${SCRIPT_DIR:h}"

cd "$PROJECT_ROOT"

echo "==> Generating Xcode project with xcodegen..."
xcodegen generate

echo "==> Patching camera extension embed phase..."
python3 scripts/fix-camera-extension-embed.py

echo "==> Building DualCast..."
xcodebuild -target DualCast -configuration Debug -allowProvisioningUpdates -allowProvisioningDeviceRegistration build

echo "==> Building DualCastSwitcher + Camera Extension..."
xcodebuild -target DualCastSwitcher -configuration Debug -allowProvisioningUpdates -allowProvisioningDeviceRegistration build

echo "==> Building DualCastAudioDriver..."
xcodebuild -target DualCastAudioDriver -configuration Debug -allowProvisioningUpdates -allowProvisioningDeviceRegistration build

echo ""
echo "==> Build complete."
echo "    DualCast.app:           $(xcodebuild -target DualCast -configuration Debug -showBuildSettings 2>/dev/null | grep -m1 'BUILT_PRODUCTS_DIR' | sed 's/.*= //')/DualCast.app"
echo "    DualCastSwitcher.app:   $(xcodebuild -target DualCastSwitcher -configuration Debug -showBuildSettings 2>/dev/null | grep -m1 'BUILT_PRODUCTS_DIR' | sed 's/.*= //')/DualCastSwitcher.app"
echo "    DualCastAudioDriver.driver: $(xcodebuild -target DualCastAudioDriver -configuration Debug -showBuildSettings 2>/dev/null | grep -m1 'BUILT_PRODUCTS_DIR' | sed 's/.*= //')/DualCastAudioDriver.driver"
echo ""
echo "Next steps:"
echo "  1. Run DualCast.app on the sending Mac."
echo "  2. Run DualCastSwitcher.app on the receiving Mac and activate cameras."
echo "  3. Install the audio driver with: sudo ./scripts/install-audio-driver.sh"
