#!/bin/bash
# scripts/uninstall-helper.sh — removes the privileged helper.
set -euo pipefail

HELPER_LABEL="com.laurinfrank.MacFanControl.helper"
HELPER_DST="/Library/PrivilegedHelperTools/${HELPER_LABEL}"
PLIST_DST="/Library/LaunchDaemons/${HELPER_LABEL}.plist"

if [[ $EUID -ne 0 ]]; then
    echo "This script requires sudo. Re-running with sudo..."
    exec sudo -- "$0" "$@"
fi

echo "==> bootout"
launchctl bootout system "${PLIST_DST}" 2>/dev/null || true

echo "==> removing files"
rm -f "${PLIST_DST}"
rm -f "${HELPER_DST}"

echo "==> removing log (optional)"
rm -f "/var/log/${HELPER_LABEL}.log"

echo "==> done"
