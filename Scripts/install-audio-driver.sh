#!/bin/zsh
#
# install-audio-driver.sh
#
# Builds and installs the DualCast audio driver into /Library/Audio/Plug-Ins/HAL
# and restarts coreaudiod so the "DualCast Audio" device appears. Must be run
# as root (e.g. sudo ./scripts/install-audio-driver.sh).
#

set -e

SCRIPT_DIR="${0:A:h}"
PROJECT_ROOT="${SCRIPT_DIR:h}"
DERIVED_DATA="${PROJECT_ROOT}/build-driver"
BUILT_DRIVER="${DERIVED_DATA}/Build/Products/Debug/DualCastAudioDriver.driver"
HAL_DIR="/Library/Audio/Plug-Ins/HAL"

if [[ $(id -u) -ne 0 ]]; then
    echo "This script must be run as root. Try: sudo $0"
    exit 1
fi

echo "Building DualCastAudioDriver..."
cd "$PROJECT_ROOT"
xcodebuild -target DualCastAudioDriver -configuration Debug -derivedDataPath "$DERIVED_DATA" -allowProvisioningUpdates -allowProvisioningDeviceRegistration build >/tmp/dualcast-audio-driver-build.log 2>&1

if [[ ! -d "$BUILT_DRIVER" ]]; then
    echo "Driver not found at $BUILT_DRIVER"
    echo "Build log: /tmp/dualcast-audio-driver-build.log"
    exit 1
fi

echo "Installing DualCastAudioDriver.driver to $HAL_DIR..."
rm -rf "$HAL_DIR/DualCastAudioDriver.driver"
cp -R "$BUILT_DRIVER" "$HAL_DIR/"
chown -R root:wheel "$HAL_DIR/DualCastAudioDriver.driver"
chmod -R 755 "$HAL_DIR/DualCastAudioDriver.driver"

echo "Restarting coreaudiod..."
killall coreaudiod 2>/dev/null || true

echo "Done. DualCast Audio should appear in System Settings > Sound and in Ecamm."
