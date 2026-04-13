#!/bin/bash
# scripts/install-helper.sh — installs the privileged launchd daemon.
#
# Copies the helper binary to /Library/PrivilegedHelperTools/ and the
# launchd plist to /Library/LaunchDaemons/, then bootstraps the service
# into the system domain. Requires sudo.
set -euo pipefail

cd "$(dirname "$0")/.."

HELPER_LABEL="com.laurinfrank.MacFanControl.helper"
APP_NAME="MacFanControl"
BUNDLE="build/${APP_NAME}.app"

HELPER_SRC="${BUNDLE}/Contents/MacOS/${HELPER_LABEL}"
PLIST_SRC="${BUNDLE}/Contents/Library/LaunchDaemons/${HELPER_LABEL}.plist"

HELPER_DST="/Library/PrivilegedHelperTools/${HELPER_LABEL}"
PLIST_DST="/Library/LaunchDaemons/${HELPER_LABEL}.plist"

if [[ ! -f "${HELPER_SRC}" || ! -f "${PLIST_SRC}" ]]; then
    echo "Missing build artifacts. Run ./scripts/build.sh first."
    exit 1
fi

if [[ $EUID -ne 0 ]]; then
    echo "This script requires sudo. Re-running with sudo..."
    exec sudo -- "$0" "$@"
fi

echo "==> bootout old service (ignore errors if not loaded)"
launchctl bootout system "${PLIST_DST}" 2>/dev/null || true

echo "==> installing helper binary → ${HELPER_DST}"
mkdir -p /Library/PrivilegedHelperTools
cp "${HELPER_SRC}" "${HELPER_DST}"
chown root:wheel  "${HELPER_DST}"
chmod 755         "${HELPER_DST}"

echo "==> installing plist → ${PLIST_DST}"
cp "${PLIST_SRC}" "${PLIST_DST}"
chown root:wheel  "${PLIST_DST}"
chmod 644         "${PLIST_DST}"

echo "==> bootstrapping service"
launchctl bootstrap system "${PLIST_DST}"
launchctl enable "system/${HELPER_LABEL}"

echo "==> verification"
launchctl list | grep "${HELPER_LABEL}" || echo "(service not listed — check /var/log/${HELPER_LABEL}.log)"
echo "Log tail:"
tail -n 20 "/var/log/${HELPER_LABEL}.log" 2>/dev/null || echo "(log file not created yet)"
echo "==> install complete"
