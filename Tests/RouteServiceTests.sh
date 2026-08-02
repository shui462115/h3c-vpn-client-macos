#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
INSTALLER="$ROOT/RouteManager/install-route-manager.sh"
DAEMON="$ROOT/RouteManager/local-route-manager.sh"
SWIFT="$ROOT/GUI/H3CVPNRoutes.swift"

sh -n "$INSTALLER" "$DAEMON"

require_text() {
    /usr/bin/grep -Fq -- "$1" "$2" || {
        echo "FAILED: missing '$1' in $2" >&2
        exit 1
    }
}

require_text 'currentRouteManagerVersion = "6"' "$SWIFT"
require_text "/usr/bin/printf '6\\n'" "$INSTALLER"
require_text '<string>--uid</string><string>$OWNER_UID</string>' "$INSTALLER"
require_text '[ -L "$RULES" ]' "$DAEMON"
require_text '[ -L "$CONFIG" ]' "$DAEMON"
require_text 'preserve_old_for_rule "$RULE_ID"' "$DAEMON"
require_text 'A matching foreign host route already satisfies the rule' "$DAEMON"
require_text 'remove_owned_route "$record"' "$DAEMON"
require_text '# Managed by com.codex.local-route-manager' "$DAEMON"
require_text '[ -n "$gateway" ] && [ -n "$interface" ] || continue' "$INSTALLER"

if "$INSTALLER" unsupported /tmp 0 >/dev/null 2>&1; then
    echo "FAILED: unsupported installer action accepted" >&2
    exit 1
fi
if "$DAEMON" --unsupported >/dev/null 2>&1; then
    echo "FAILED: unsupported daemon argument accepted" >&2
    exit 1
fi

echo "Route service guard tests passed"
