#!/bin/zsh
#
# package.sh
#
# Builds DualCast and DualCastSwitcher, bundles the audio driver, and produces
# three installer packages in dist/:
#
#   DualCast-Installer.pkg  - installs everything (sender + receiver)
#   DualCast-Sender.pkg     - installs DualCast.app only
#   DualCast-Receiver.pkg   - installs DualCastSwitcher.app + audio driver
#
# Defaults to Debug configuration because Release builds require provisioning
# profiles with the System Extension and App Group capabilities. Pass --release
# to attempt a Release build (will fail unless profiles are configured in the
# Apple Developer portal).
#
# Must be run on a Mac with the Apple Development certificate for team
# 3BMZ2ULZ54 in the keychain.
#

set -e

SCRIPT_DIR="${0:A:h}"
PROJECT_ROOT="${SCRIPT_DIR:h}"
CONFIG="Debug"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --release)
            CONFIG="Release"
            shift
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--release]"
            exit 1
            ;;
    esac
done

DERIVED_DATA="${PROJECT_ROOT}/build-${CONFIG:l}"
OUTPUT_DIR="${PROJECT_ROOT}/dist"
STAGING_DIR="${OUTPUT_DIR}/pkg-staging"

cd "$PROJECT_ROOT"

echo "==> Generating Xcode project..."
xcodegen generate

echo "==> Patching camera extension embed phase..."
python3 scripts/fix-camera-extension-embed.py

echo "==> Building ${CONFIG} binaries..."
xcodebuild -scheme DualCast -configuration "$CONFIG" -derivedDataPath "$DERIVED_DATA" -allowProvisioningUpdates -allowProvisioningDeviceRegistration build
xcodebuild -scheme DualCastSwitcher -configuration "$CONFIG" -derivedDataPath "$DERIVED_DATA" -allowProvisioningUpdates -allowProvisioningDeviceRegistration build
xcodebuild -scheme DualCastAudioDriver -configuration "$CONFIG" -derivedDataPath "$DERIVED_DATA" -allowProvisioningUpdates -allowProvisioningDeviceRegistration build

BUILT_PRODUCTS="${DERIVED_DATA}/Build/Products/${CONFIG}"
DUALCAST_APP="${BUILT_PRODUCTS}/DualCast.app"
SWITCHER_APP="${BUILT_PRODUCTS}/DualCastSwitcher.app"
AUDIO_DRIVER="${BUILT_PRODUCTS}/DualCastAudioDriver.driver"

if [[ ! -d "$DUALCAST_APP" || ! -d "$SWITCHER_APP" || ! -d "$AUDIO_DRIVER" ]]; then
    echo "ERROR: Built products not found."
    echo "Expected:"
    echo "  $DUALCAST_APP"
    echo "  $SWITCHER_APP"
    echo "  $AUDIO_DRIVER"
    exit 1
fi

echo "==> Staging package payloads..."
rm -rf "$STAGING_DIR"

STAGING_COMBINED="${STAGING_DIR}/combined"
STAGING_SENDER="${STAGING_DIR}/sender"
STAGING_RECEIVER="${STAGING_DIR}/receiver"

mkdir -p "${STAGING_COMBINED}/Applications"
mkdir -p "${STAGING_COMBINED}/Library/Audio/Plug-Ins/HAL"
cp -R "$DUALCAST_APP" "${STAGING_COMBINED}/Applications/"
cp -R "$SWITCHER_APP" "${STAGING_COMBINED}/Applications/"
cp -R "$AUDIO_DRIVER" "${STAGING_COMBINED}/Library/Audio/Plug-Ins/HAL/"

mkdir -p "${STAGING_SENDER}/Applications"
cp -R "$DUALCAST_APP" "${STAGING_SENDER}/Applications/"

mkdir -p "${STAGING_RECEIVER}/Applications"
mkdir -p "${STAGING_RECEIVER}/Library/Audio/Plug-Ins/HAL"
cp -R "$SWITCHER_APP" "${STAGING_RECEIVER}/Applications/"
cp -R "$AUDIO_DRIVER" "${STAGING_RECEIVER}/Library/Audio/Plug-Ins/HAL/"

INSTALLER_PKG="${OUTPUT_DIR}/DualCast-Installer.pkg"
SENDER_PKG="${OUTPUT_DIR}/DualCast-Sender.pkg"
RECEIVER_PKG="${OUTPUT_DIR}/DualCast-Receiver.pkg"
rm -f "$INSTALLER_PKG" "$SENDER_PKG" "$RECEIVER_PKG"

echo "==> Building combined installer package..."
pkgbuild \
    --root "$STAGING_COMBINED" \
    --scripts "${PROJECT_ROOT}/scripts/pkg-scripts" \
    --identifier "com.woodseedigi.DualCast.Installer" \
    --version "1.0.0" \
    --install-location "/" \
    "$INSTALLER_PKG"

echo "==> Building sender package..."
pkgbuild \
    --root "$STAGING_SENDER" \
    --identifier "com.woodseedigi.DualCast.Sender" \
    --version "1.0.0" \
    --install-location "/" \
    "$SENDER_PKG"

echo "==> Building receiver package..."
pkgbuild \
    --root "$STAGING_RECEIVER" \
    --scripts "${PROJECT_ROOT}/scripts/pkg-scripts" \
    --identifier "com.woodseedigi.DualCast.Receiver" \
    --version "1.0.0" \
    --install-location "/" \
    "$RECEIVER_PKG"

rm -rf "$STAGING_DIR"

echo ""
echo "==> Packages created:"
echo "  Combined:  ${INSTALLER_PKG}"
echo "  Sender:    ${SENDER_PKG}"
echo "  Receiver:  ${RECEIVER_PKG}"
echo ""
echo "Install with:"
echo "  sudo installer -pkg '${INSTALLER_PKG}' -target /"
echo "  sudo installer -pkg '${SENDER_PKG}' -target /"
echo "  sudo installer -pkg '${RECEIVER_PKG}' -target /"
echo ""
echo "Or double-click in Finder. After installing the receiver, open System"
echo "Settings and approve the DualCast Camera Extension when prompted by"
echo "DualCast Switcher."

echo ""
./scripts/create-dmg.sh
