#!/bin/sh

RULES="/Library/Application Support/LocalRouteManager/rules"
EXPECTED_UID=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --rules) [ "$#" -ge 2 ] || exit 2; RULES="$2"; shift 2;;
    --uid) [ "$#" -ge 2 ] || exit 2; EXPECTED_UID="$2"; shift 2;;
    *) exit 2;;
  esac
done

MANAGED=""
MANAGED_RESOLVERS=""
ENABLED_COUNT=0
ERROR_COUNT=0
STATUS="/var/run/com.codex.local-route-manager.status"
STATE="/var/run/com.codex.local-route-manager.ips"
RESOLVER_STATE="/var/run/com.codex.local-route-manager.resolvers"
RESOLVER_ROOT="/etc/resolver"
OLD=$([ -f "$STATE" ] && /bin/cat "$STATE" || true)

write_status() {
  managed_count=$(/usr/bin/printf '%s\n' "$MANAGED" | /usr/bin/awk -F'|' 'NF {print $1}' | \
    /usr/bin/sort -u | /usr/bin/wc -l | /usr/bin/tr -d ' ')
  /usr/bin/printf 'timestamp=%s\nenabled=%s\nmanaged=%s\nerrors=%s\n' \
    "$(/bin/date +%s)" "$ENABLED_COUNT" "$managed_count" "$ERROR_COUNT" > "$STATUS"
  /bin/chmod 644 "$STATUS"
}

is_ipv4() {
  /usr/bin/printf '%s\n' "$1" | /usr/bin/awk -F. '
    BEGIN {valid = 1}
    NF != 4 {valid = 0}
    {for (i = 1; i <= 4; i++) if ($i !~ /^[0-9]+$/ || $i < 0 || $i > 255) valid = 0}
    END {exit valid ? 0 : 1}'
}

is_domain() {
  /usr/bin/printf '%s\n' "$1" | /usr/bin/awk '
    BEGIN {valid = 1}
    length($0) < 1 || length($0) > 253 {valid = 0}
    {
      count = split($0, labels, "."); if (count < 2) valid = 0
      for (i = 1; i <= count; i++) {
        if (length(labels[i]) < 1 || length(labels[i]) > 63) valid = 0
        if (labels[i] !~ /^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$/) valid = 0
      }
    }
    END {exit valid ? 0 : 1}'
}

route_field() {
  /usr/bin/printf '%s\n' "$1" | /usr/bin/awk -v name="$2" '$1 == name {print $2; exit}'
}

old_record_for_ip() {
  /usr/bin/printf '%s\n' "$OLD" | /usr/bin/awk -F'|' -v ip="$1" '$1 == ip {print; exit}'
}

append_managed() {
  [ -n "$1" ] || return 0
  MANAGED=$(/usr/bin/printf '%s\n%s\n' "$MANAGED" "$1" | /usr/bin/awk 'NF' | /usr/bin/sort -u)
}

preserve_old_for_rule() {
  preserved=$(/usr/bin/printf '%s\n' "$OLD" | /usr/bin/awk -F'|' -v rule="$1" \
    'NF >= 4 && $4 == rule {print}')
  [ -n "$preserved" ] && append_managed "$preserved"
}

route_ip() {
  ip="$1"
  rule_id="$2"
  route_info=$(/sbin/route -n get "$ip" 2>/dev/null || true)
  current_interface=$(route_field "$route_info" "interface:")
  current_gateway=$(route_field "$route_info" "gateway:")
  current_is_host=0
  /usr/bin/printf '%s\n' "$route_info" | /usr/bin/grep -Eq 'flags:.*<[^>]*HOST' && current_is_host=1
  old_record=$(old_record_for_ip "$ip")
  old_gateway=$(/usr/bin/printf '%s\n' "$old_record" | /usr/bin/awk -F'|' 'NF >= 2 {print $2; exit}')
  old_interface=$(/usr/bin/printf '%s\n' "$old_record" | /usr/bin/awk -F'|' 'NF >= 3 {print $3; exit}')

  if [ "$current_is_host" = "1" ]; then
    if [ -z "$old_record" ]; then
      # A matching foreign host route already satisfies the rule, but remains
      # outside this service's state so it will never be removed by us.
      [ "$current_interface" = "$INTERFACE" ] && [ "$current_gateway" = "$GATEWAY" ]
      return $?
    fi
    # A legacy v5 record contains no gateway/interface ownership metadata.
    # Never delete or take over such a route after another component may have
    # changed it; a later successful apply will establish v6 metadata safely.
    case "$old_record" in
      *'|'*) ;;
      *) return 1;;
    esac
    if [ -n "$old_gateway" ] && { [ "$current_gateway" != "$old_gateway" ] || \
       [ "$current_interface" != "$old_interface" ]; }; then
      return 1
    fi
    if [ "$current_interface" = "$INTERFACE" ] && [ "$current_gateway" = "$GATEWAY" ]; then
      append_managed "$ip|$GATEWAY|$INTERFACE|$rule_id"
      return 0
    fi
    /sbin/route -n delete -host "$ip" >/dev/null 2>&1 || return 1
  fi

  /sbin/route -n add -host "$ip" "$GATEWAY" >/dev/null 2>&1 || return 1
  append_managed "$ip|$GATEWAY|$INTERFACE|$rule_id"
  return 0
}

remove_owned_route() {
  record="$1"
  ip=$(/usr/bin/printf '%s\n' "$record" | /usr/bin/awk -F'|' '{print $1}')
  expected_gateway=$(/usr/bin/printf '%s\n' "$record" | /usr/bin/awk -F'|' 'NF >= 2 {print $2}')
  expected_interface=$(/usr/bin/printf '%s\n' "$record" | /usr/bin/awk -F'|' 'NF >= 3 {print $3}')
  [ -n "$ip" ] || return 0
  [ -n "$expected_gateway" ] && [ -n "$expected_interface" ] || return 0
  route_info=$(/sbin/route -n get "$ip" 2>/dev/null || true)
  /usr/bin/printf '%s\n' "$route_info" | /usr/bin/grep -Eq 'flags:.*<[^>]*HOST' || return 0
  if [ -n "$expected_gateway" ] && [ -n "$expected_interface" ]; then
    [ "$(route_field "$route_info" "gateway:")" = "$expected_gateway" ] || return 0
    [ "$(route_field "$route_info" "interface:")" = "$expected_interface" ] || return 0
  fi
  /sbin/route -n delete -host "$ip" >/dev/null 2>&1 || true
}

case "$EXPECTED_UID" in ''|*[!0-9]*) ERROR_COUNT=1; write_status; exit 2;; esac
if [ ! -d "$RULES" ] || [ -L "$RULES" ] || \
   [ "$(/usr/bin/stat -f '%u' "$RULES" 2>/dev/null || true)" != "$EXPECTED_UID" ] || \
   [ "$(/usr/bin/stat -f '%Lp' "$RULES" 2>/dev/null || true)" != "700" ]; then
  ERROR_COUNT=1
  write_status
  exit 2
fi

/bin/mkdir -p "$RESOLVER_ROOT"
for CONFIG in "$RULES"/*.conf; do
  [ -f "$CONFIG" ] || continue
  if [ -L "$CONFIG" ] || \
     [ "$(/usr/bin/stat -f '%u' "$CONFIG" 2>/dev/null || true)" != "$EXPECTED_UID" ] || \
     [ "$(/usr/bin/stat -f '%Lp' "$CONFIG" 2>/dev/null || true)" != "600" ]; then
    ERROR_COUNT=$((ERROR_COUNT + 1))
    continue
  fi
  RULE_ID=$(/usr/bin/basename "$CONFIG" .conf)
  /usr/bin/printf '%s\n' "$RULE_ID" | /usr/bin/grep -Eq '^[A-Za-z0-9._-]+$' || {
    ERROR_COUNT=$((ERROR_COUNT + 1)); continue;
  }
  ENABLED=$(/usr/bin/awk -F= '$1 == "enabled" {print $2; exit}' "$CONFIG")
  [ "${ENABLED:-1}" = "1" ] || continue
  ENABLED_COUNT=$((ENABLED_COUNT + 1))
  INTERFACE=$(/usr/bin/awk -F= '$1 == "interface" {print $2; exit}' "$CONFIG")
  DNS=$(/usr/bin/awk -F= '$1 == "dns" {print $2; exit}' "$CONFIG")
  HOST=$(/usr/bin/awk -F= '$1 == "host" {print $2; exit}' "$CONFIG")
  /usr/bin/printf '%s\n' "$INTERFACE" | /usr/bin/grep -Eq '^[A-Za-z0-9._-]+$' || {
    ERROR_COUNT=$((ERROR_COUNT + 1)); continue;
  }
  /sbin/ifconfig "$INTERFACE" >/dev/null 2>&1 || {
    ERROR_COUNT=$((ERROR_COUNT + 1)); continue;
  }

  IS_IP=0
  is_ipv4 "$HOST" && IS_IP=1
  if [ "$IS_IP" = "0" ]; then
    is_domain "$HOST" || { ERROR_COUNT=$((ERROR_COUNT + 1)); continue; }
    if [ -z "$DNS" ]; then
      DNS=$(/usr/sbin/ipconfig getoption "$INTERFACE" domain_name_server 2>/dev/null | \
        /usr/bin/awk 'NR == 1 {print; exit}')
    fi
    is_ipv4 "$DNS" || { ERROR_COUNT=$((ERROR_COUNT + 1)); preserve_old_for_rule "$RULE_ID"; continue; }
  fi
  GATEWAY=$(/sbin/route -n get -ifscope "$INTERFACE" default 2>/dev/null | \
    /usr/bin/awk '/gateway:/{print $2; exit}')
  if [ -z "$GATEWAY" ]; then
    ERROR_COUNT=$((ERROR_COUNT + 1))
    preserve_old_for_rule "$RULE_ID"
    continue
  fi

  RULE_ERROR=0
  if [ "$IS_IP" = "0" ]; then
    route_ip "$DNS" "$RULE_ID" || RULE_ERROR=1
    RESOLVER="$RESOLVER_ROOT/$HOST"
    RESOLVER_OWNED=0
    if [ -e "$RESOLVER" ]; then
      if [ -L "$RESOLVER" ] || [ ! -f "$RESOLVER" ]; then
        RULE_ERROR=1
      elif /usr/bin/grep -Fqx '# Managed by com.codex.local-route-manager' "$RESOLVER"; then
        /usr/bin/printf '# Managed by com.codex.local-route-manager\nnameserver %s\n' "$DNS" > "$RESOLVER"
        /bin/chmod 644 "$RESOLVER"
        RESOLVER_OWNED=1
      elif [ "$(/usr/bin/grep -v '^#' "$RESOLVER" | /usr/bin/grep -v '^$' || true)" = "nameserver $DNS" ]; then
        # An external resolver already has the exact requested setting; do not
        # claim or remove it.
        RESOLVER_OWNED=0
      else
        RULE_ERROR=1
      fi
    else
      /usr/bin/printf '# Managed by com.codex.local-route-manager\nnameserver %s\n' "$DNS" > "$RESOLVER"
      /bin/chmod 644 "$RESOLVER"
      RESOLVER_OWNED=1
    fi
    [ "$RESOLVER_OWNED" = "1" ] && MANAGED_RESOLVERS=$(/usr/bin/printf '%s\n%s\n' "$MANAGED_RESOLVERS" "$HOST" | \
      /usr/bin/awk 'NF' | /usr/bin/sort -u)
    IPS=$(/usr/bin/dig +short @"$DNS" "$HOST" A 2>/dev/null | \
      /usr/bin/awk '/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ {print}' | /usr/bin/sort -u)
  else
    IPS="$HOST"
  fi
  if [ -z "$IPS" ]; then
    RULE_ERROR=1
  else
    for ip in $IPS; do
      is_ipv4 "$ip" && route_ip "$ip" "$RULE_ID" || RULE_ERROR=1
    done
  fi
  if [ "$RULE_ERROR" != "0" ]; then
    ERROR_COUNT=$((ERROR_COUNT + 1))
    preserve_old_for_rule "$RULE_ID"
  fi
done

/usr/bin/printf '%s\n' "$OLD" | /usr/bin/awk 'NF' | while IFS= read -r record; do
  ip=$(/usr/bin/printf '%s\n' "$record" | /usr/bin/awk -F'|' '{print $1}')
  /usr/bin/printf '%s\n' "$MANAGED" | /usr/bin/awk -F'|' -v ip="$ip" '$1 == ip {found = 1} END {exit !found}' || \
    remove_owned_route "$record"
done
OLD_RESOLVERS=$([ -f "$RESOLVER_STATE" ] && /bin/cat "$RESOLVER_STATE" || true)
for domain in $OLD_RESOLVERS; do
  /usr/bin/printf '%s\n' "$MANAGED_RESOLVERS" | /usr/bin/grep -qx "$domain" || \
    (/bin/test -f "$RESOLVER_ROOT/$domain" && \
      /usr/bin/grep -Fqx '# Managed by com.codex.local-route-manager' "$RESOLVER_ROOT/$domain" && \
      /bin/rm -f "$RESOLVER_ROOT/$domain") || true
done
/usr/bin/printf '%s\n' "$MANAGED" | /usr/bin/awk 'NF' > "$STATE"
/bin/chmod 600 "$STATE"
/usr/bin/printf '%s\n' "$MANAGED_RESOLVERS" | /usr/bin/awk 'NF' > "$RESOLVER_STATE"
/bin/chmod 600 "$RESOLVER_STATE"
write_status
