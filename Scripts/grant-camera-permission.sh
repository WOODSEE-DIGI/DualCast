#!/bin/zsh
#
# grant-camera-permission.sh
#
# Manually grants camera permission to DualCast in the macOS TCC database.
# Use this only if the normal "Grant Access..." button in DualCast fails to
# show the system camera permission prompt.
#
# Requires the app to have been launched at least once (so macOS knows the
# bundle ID) and the TCC database to be writable.
#

set -e

BUNDLE_ID="com.woodseedigi.DualCast"
DB="$HOME/Library/Application Support/com.apple.TCC/TCC.db"

if [[ ! -f "$DB" ]]; then
    echo "ERROR: TCC database not found at $DB"
    exit 1
fi

echo "Granting camera permission to $BUNDLE_ID..."

sqlite3 "$DB" <<EOF
INSERT OR REPLACE INTO access (
    service,
    client,
    client_type,
    auth_value,
    auth_reason,
    auth_version,
    csreq,
    policy_id,
    indirect_object_identifier_type,
    indirect_object_identifier,
    indirect_object_code_identity,
    flags,
    last_modified,
    pid,
    pid_version,
    boot_uuid,
    last_reminded
) VALUES (
    'kTCCServiceCamera',
    '$BUNDLE_ID',
    0,
    2,
    3,
    1,
    NULL,
    NULL,
    0,
    'UNUSED',
    NULL,
    0,
    CAST(strftime('%s','now') AS INTEGER),
    NULL,
    NULL,
    'UNUSED',
    CAST(strftime('%s','now') AS INTEGER)
);
EOF

echo "Done. Quit and relaunch DualCast."
