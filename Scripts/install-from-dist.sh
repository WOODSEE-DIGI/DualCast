#!/bin/zsh
#
# install-from-dist.sh
#
# Installs the pre-built packages from dist/ and clears quarantine flags.
# This is a fallback when full Xcode is not available on the target Mac.
#
# WARNING: The camera extension may still fail to activate without a valid
# provisioning profile. If that happens, install full Xcode on this Mac and
# run setup-local.sh instead.
#

set -e

SCRIPT_DIR="${0:A:h}"
PROJECT_ROOT="${SCRIPT_DIR:h}"
DIST_DIR="${PROJECT_ROOT}/dist"

cd "$PROJECT_ROOT"

if [[ ! -f "${DIST_DIR}/DualCast-Receiver.pkg" ]]; then
    echo "ERROR: Packages not found in ${DIST_DIR}. Run ./scripts/package.sh on the build Mac first."
    exit 1
fi

echo "==> Installing receiver package..."
sudo installer -pkg "${DIST_DIR}/DualCast-Receiver.pkg" -target /

echo "==> Installing sender package..."
sudo installer -pkg "${DIST_DIR}/DualCast-Sender.pkg" -target /

echo "==> Clearing quarantine flags..."
sudo xattr -rd com.apple.quarantine /Applications/DualCast.app 2>/dev/null || true
sudo xattr -rd com.apple.quarantine /Applications/DualCastSwitcher.app 2>/dev/null || true
sudo xattr -rd com.apple.quarantine /Library/Audio/Plug-Ins/HAL/DualCastAudioDriver.driver 2>/dev/null || true

echo "==> Restarting coreaudiod..."
sudo killall coreaudiod 2>/dev/null || true

echo ""
echo "==> Done."
echo "If the camera extension does not activate, install full Xcode and run ./scripts/setup-local.sh instead."
