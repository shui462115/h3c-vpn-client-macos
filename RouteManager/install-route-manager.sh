#!/bin/sh
set -eu

ACTION="${1:-}"
SOURCE="${2:-}"
OWNER_UID="${3:-}"
LABEL="com.codex.local-route-manager"
OLD_LABEL="com.codex.polardb-en5-route"
ROOT="/Library/Application Support/LocalRouteManager"
SCRIPT="/usr/local/sbin/local-route-manager.sh"
OLD_SCRIPT="/usr/local/sbin/polardb-en5-route.sh"
PLIST="/Library/LaunchDaemons/$LABEL.plist"
OLD_PLIST="/Library/LaunchDaemons/$OLD_LABEL.plist"
STATE="/var/run/com.codex.local-route-manager.ips"
OLD_STATE="/var/run/com.codex.polardb-en5-route.ips"
RESOLVER_STATE="/var/run/com.codex.local-route-manager.resolvers"

route_field() {
  /usr/bin/awk -v name="$2" '$1 == name {print $2; exit}' <<EOF
$1
EOF
}

remove_routes() {
  state="$1"
  [ -f "$state" ] || return 0
  while IFS='|' read -r ip gateway interface rule_id; do
    [ -n "$ip" ] || continue
    # Legacy v5 state contained only an IP and cannot prove route ownership.
    [ -n "$gateway" ] && [ -n "$interface" ] || continue
    info=$(/sbin/route -n get "$ip" 2>/dev/null || true)
    /usr/bin/printf '%s\n' "$info" | /usr/bin/grep -Eq 'flags:.*<[^>]*HOST' || continue
    if [ -n "$gateway" ] && [ -n "$interface" ]; then
      current_gateway=$(route_field "$info" "gateway:")
      current_interface=$(route_field "$info" "interface:")
      [ "$current_gateway" = "$gateway" ] && [ "$current_interface" = "$interface" ] || continue
    fi
    /sbin/route -n delete -host "$ip" >/dev/null 2>&1 || true
  done < "$state"
}

remove_resolvers() {
  if [ -f "$RESOLVER_STATE" ]; then
    while IFS= read -r domain; do
      [ -n "$domain" ] || continue
      resolver="/etc/resolver/$domain"
      [ -f "$resolver" ] || continue
      /usr/bin/grep -Fqx '# Managed by com.codex.local-route-manager' "$resolver" && \
        /bin/rm -f "$resolver"
    done < "$RESOLVER_STATE"
  fi
}

if [ "$ACTION" = "restore" ]; then
  /bin/launchctl bootout "system/$LABEL" >/dev/null 2>&1 || true
  /bin/launchctl bootout "system/$OLD_LABEL" >/dev/null 2>&1 || true
  remove_routes "$STATE"
  remove_routes "$OLD_STATE"
  remove_resolvers
  /bin/rm -f "$STATE" "$OLD_STATE" /var/run/com.codex.local-route-manager.status \
    /var/run/com.codex.polardb-en5-route.status "$RESOLVER_STATE" "$PLIST" "$OLD_PLIST" \
    "$SCRIPT" "$OLD_SCRIPT"
  /bin/rm -rf "$ROOT"
  exit 0
fi

[ "$ACTION" = "install" ] || { /usr/bin/printf 'unsupported action\n' >&2; exit 2; }
case "$OWNER_UID" in ''|*[!0-9]*) /usr/bin/printf 'invalid owner uid\n' >&2; exit 2;; esac
[ -d "$SOURCE" ] && [ ! -L "$SOURCE" ] || {
  /usr/bin/printf 'invalid rules directory\n' >&2
  exit 2
}
[ "$(/usr/bin/stat -f '%u' "$SOURCE")" = "$OWNER_UID" ] || {
  /usr/bin/printf 'rules directory owner mismatch\n' >&2
  exit 2
}
/bin/chmod 700 "$SOURCE"

/bin/launchctl bootout "system/$LABEL" >/dev/null 2>&1 || true
/bin/launchctl bootout "system/$OLD_LABEL" >/dev/null 2>&1 || true
/bin/mkdir -p "$ROOT" /etc/resolver /usr/local/sbin
/bin/rm -rf "$ROOT/rules"
[ -f "$STATE" ] || { [ -f "$OLD_STATE" ] && /bin/cp "$OLD_STATE" "$STATE" || true; }
/bin/rm -f "$OLD_PLIST" "$OLD_SCRIPT" "$OLD_STATE" \
  /var/run/com.codex.polardb-en5-route.status
/usr/bin/install -o root -g wheel -m 755 "$(dirname "$0")/local-route-manager.sh" "$SCRIPT"
/usr/bin/printf '6\n' > "$ROOT/daemon-version"
/usr/sbin/chown root:wheel "$ROOT/daemon-version"
/bin/chmod 644 "$ROOT/daemon-version"
XML_SOURCE=$(/usr/bin/printf '%s' "$SOURCE" | /usr/bin/sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g')
/bin/cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$LABEL</string>
<key>ProgramArguments</key><array><string>$SCRIPT</string><string>--rules</string><string>$XML_SOURCE</string><string>--uid</string><string>$OWNER_UID</string></array>
<key>RunAtLoad</key><true/><key>StartInterval</key><integer>5</integer>
<key>WatchPaths</key><array><string>$XML_SOURCE</string></array>
<key>ProcessType</key><string>Background</string>
</dict></plist>
EOF
/usr/sbin/chown root:wheel "$PLIST"
/bin/chmod 644 "$PLIST"
/usr/bin/plutil -lint "$PLIST" >/dev/null
/bin/launchctl enable "system/$LABEL"
/bin/launchctl bootstrap system "$PLIST" || {
  /bin/sleep 1
  /bin/launchctl bootstrap system "$PLIST"
}
/bin/launchctl kickstart -k "system/$LABEL"
