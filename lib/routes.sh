# shellcheck shell=bash
# ROLE=hub: exits, groups and the route of each user; sourced by vpn.sh

# A route is where a user's traffic leaves, except RU, which always leaves from
# this hub:
#   local        from this hub
#   none         nowhere: only RU works (fail-closed)
#   EXIT/IPNAME  through exit EXIT from its egress IP named IPNAME
# A user's route: their own, else their group's, else ROUTE_DEFAULT. A route
# that doesn't exist (exit removed, IP renamed) counts as none: there is no
# silent fallback to another IP.
#
# exits.conf:   exit  token          (the token `hub add` printed on the exit)
# groups.conf:  group  route         (route "-": ROUTE_DEFAULT)
# routing.conf: user  group  route   ("-": no group / no route of their own)
EXITS_FILE=exits.conf
EXITS_HEADER='# exit  token'
GROUPS_FILE=groups.conf
GROUPS_HEADER='# group  route'
ROUTING_FILE=routing.conf
ROUTING_HEADER='# user  group  route'

# RU lists for sing-box (tag, then URL); SagerNet rebuilds them daily
RULE_SETS_DIR=data/rule-sets
RULE_SETS=(
  "geosite-ru https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-category-ru.srs"
  "geoip-ru https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-ru.srs"
)

# --- exits -------------------------------------------------------------------

# Token printed by `hub add` on an exit -> compact JSON (fails if it isn't one).
# Tokens from before egress IPs had names name them by the IP itself.
token_json() {
  [[ $1 == cvpn-exit:* ]] || return 1
  base64 -d <<<"${1#cvpn-exit:}" 2>/dev/null | jq -ce '
    select(.v == 1 and (.address | type) == "string" and (.port | type) == "number"
      and (.sni | type) == "string" and (.public_key | type) == "string" and (.short_id | type) == "string"
      and (.ips | type) == "array" and (.ips | length) > 0)
    | .ips |= map(.name //= .ip)
    | select(all(.ips[]; (.name | test("^[a-z0-9_.-]{1,32}$")) and (.uuid | type) == "string"))' 2>/dev/null
}

exit_exists() { conf_rows "$EXITS_FILE" | awk -v n="$1" '$1 == n {f = 1} END {exit !f}'; }

# Routes through exits: [{name: "EXIT/IPNAME", ip, uuid, server, port, sni, public_key, short_id}]
exit_routes_json() {
  local name token
  while read -r name token; do
    token_json "$token" | jq -c --arg exit "$name" '. as $t | .ips[] | {
      name: "\($exit)/\(.name)", ip, uuid,
      server: $t.address, port: $t.port, sni: $t.sni, public_key: $t.public_key, short_id: $t.short_id
    }' || warn "$EXITS_FILE: the token of $name is broken, add the exit again"
  done < <(conf_rows "$EXITS_FILE") | jq -sc .
}

# Every route there is, one per line
route_names() {
  echo local
  echo none
  exit_routes_json | jq -r '.[].name'
}

# (not `grep -q` in a pipe: it quits on the first match, and pipefail sees the SIGPIPE)
route_exists() { [[ $'\n'$(route_names)$'\n' == *$'\n'"$1"$'\n'* ]]; }

# Die unless ROUTE can be assigned ("-" too, if allowed)
check_route() {
  [[ $1 == - && ${2:-} == dash-ok ]] && return
  route_exists "$1" || die "no route $1; routes: $(route_names | paste -sd' ')"
}

# --- who leaves where --------------------------------------------------------

# "user group route from" for every user; from: user|group|default, or
# missing when the route doesn't exist (then the user leaves nowhere)
user_routes() {
  local known
  known=" $(route_names | tr '\n' ' ') "
  awk -v known="$known" -v def="${ROUTE_DEFAULT:-none}" '
    FILENAME == ARGV[1] { groute[$1] = $2; next }
    FILENAME == ARGV[2] { ugroup[$1] = $2; uroute[$1] = $3; next }
    {
      u = $1
      grp = (u in ugroup) ? ugroup[u] : "-"
      if (uroute[u] != "" && uroute[u] != "-") { route = uroute[u]; from = "user" }
      else if (grp != "-" && groute[grp] != "" && groute[grp] != "-") { route = groute[grp]; from = "group" }
      else { route = def; from = "default" }
      if (!index(known, " " route " ")) from = "missing"
      print u, grp, route, from
    }' <(conf_rows "$GROUPS_FILE") <(conf_rows "$ROUTING_FILE") <(users_active)
}

# {user: route} for templates/hub.jq, missing routes as none
user_routes_json() {
  route_exists "${ROUTE_DEFAULT:-none}" ||
    warn "ROUTE_DEFAULT=$ROUTE_DEFAULT doesn't exist: users without a route get no internet but RU"
  user_routes | jq -Rn '[inputs | split(" ") | {(.[0]): (if .[3] == "missing" then "none" else .[2] end)}] | add // {}'
}

# Set a user's group and/or route in routing.conf; an empty value keeps the current one
routing_set() {
  local user=$1 group=$2 route=$3 cur_group=- cur_route=-
  read -r _ cur_group cur_route < <(conf_rows "$ROUTING_FILE" | awk -v u="$user" '$1 == u') || true
  group=${group:-$cur_group} route=${route:-$cur_route}
  conf_init "$ROUTING_FILE" "$ROUTING_HEADER"
  conf_rewrite "$ROUTING_FILE" -v u="$user" '/^#/ || $1 != u'
  [[ $group == - && $route == - ]] || echo "$user $group $route" >>"$ROUTING_FILE"
}

routing_del() {
  [[ -f $ROUTING_FILE ]] || return 0
  conf_rewrite "$ROUTING_FILE" -v u="$1" '/^#/ || $1 != u'
}

group_exists() { conf_rows "$GROUPS_FILE" | awk -v n="$1" '$1 == n {f = 1} END {exit !f}'; }

# Users whose route is one of the given ones (space-separated list on one line)
users_on_routes() {
  user_routes | awk -v routes=" $* " 'index(routes, " " $3 " ") {printf "%s%s", (n++ ? " " : ""), $1}'
}

# --- RU lists ----------------------------------------------------------------

# Download the RU lists older than HOURS (missing ones always): directly, else
# through each exit route. A failed download keeps the old file.
rule_sets_update() {
  local hours=$1 entry tag url file tmp route ok
  mkdir -p "$RULE_SETS_DIR"
  for entry in "${RULE_SETS[@]}"; do
    read -r tag url <<<"$entry"
    file=$RULE_SETS_DIR/$tag.srs
    if [[ -s $file ]] && (($(date +%s) - $(stat -c %Y "$file") < hours * 3600)); then
      continue
    fi
    tmp=$(mktemp "$file.XXXX")
    ok=false
    if curl -fsSL -m 60 -o "$tmp" "$url" 2>/dev/null; then
      ok=true
    else
      # GitHub may be blocked from here, but not from the exits
      for route in $(exit_routes_json | jq -r '.[].name'); do
        curl -fsSL -m 60 --socks5-hostname "127.0.0.1:$CHECK_PORT" \
          --proxy-user "check@$route:$CHECK_TOKEN" -o "$tmp" "$url" 2>/dev/null && { ok=true; break; }
      done
    fi
    # .srs files start with "SRS"
    if $ok && [[ $(head -c3 "$tmp") == SRS ]]; then
      chmod 644 "$tmp"
      mv "$tmp" "$file"
    else
      rm -f "$tmp"
      if [[ -s $file ]]; then
        warn "can't download the $tag list, keeping the one from $(date -r "$file" +%F)"
      else
        warn "can't download the $tag list (./vpn.sh update rules): until it's there, fewer sites count as RU"
      fi
    fi
  done
}

# Refresh the RU lists older than HOURS; sing-box reloads replaced files by
# itself, a list that wasn't there before needs a new config
rule_sets_refresh() {
  rule_sets_update "$1"
  [[ $(rule_sets_json | jq -c .) == "$(jq -c '[.route.rule_set[]?.tag]' "$OUT/sing-box.json" 2>/dev/null)" ]] || cmd_up
}

# Tags of the RU lists that are there, as JSON
rule_sets_json() {
  local entry tag
  for entry in "${RULE_SETS[@]}"; do
    tag=${entry%% *}
    [[ -s $RULE_SETS_DIR/$tag.srs ]] && echo "$tag"
  done | jq -Rn '[inputs]'
}

# --- commands ----------------------------------------------------------------

cmd_exit() {
  local action=${1:-} name=${2:-} token=${3:-} gone users route
  require_role hub exit
  case $action in
    add)
      check_name "$name" "exit name"
      [[ -n $token ]] || die "usage: ./vpn.sh exit add NAME TOKEN (./vpn.sh hub add|token on the exit prints it)"
      token_json "$token" >/dev/null ||
        die "that's not an exit token: it starts with cvpn-exit: (./vpn.sh hub add|token on the exit prints it)"
      conf_init "$EXITS_FILE" "$EXITS_HEADER"
      if exit_exists "$name"; then
        # Routes the new token doesn't have any more
        gone=$(comm -23 <(exit_routes_json | jq -r --arg e "$name/" '.[].name | select(startswith($e))' | sort) \
          <(token_json "$token" | jq -r --arg e "$name/" '.ips[] | $e + .name' | sort) | paste -sd' ')
        users=$([[ -z $gone ]] || users_on_routes "$gone")
        [[ -z $users ]] || warn "routes $gone are gone; these users get no internet but RU: $users"
        conf_rewrite "$EXITS_FILE" -v n="$name" '/^#/ || $1 != n'
        echo "$name $token" >>"$EXITS_FILE"
        info "exit $name updated"
      else
        echo "$name $token" >>"$EXITS_FILE"
        info "exit $name added"
      fi
      cmd_up
      # The hub can reach the exit, and each route leaves from its IP
      sleep 2
      check_exit_routes "$name"
      ;;
    del)
      check_name "$name" "exit name"
      exit_exists "$name" || die "no exit $name"
      users=$(users_on_routes "$(exit_routes_json | jq -r --arg e "$name/" '[.[].name | select(startswith($e))] | join(" ")')")
      if [[ -n $users ]]; then
        echo "Users on routes of $name get no internet but RU: $users"
        ask "Remove exit $name?" n || return 0
      fi
      conf_rewrite "$EXITS_FILE" -v n="$name" '/^#/ || $1 != n'
      cmd_up
      info "exit $name removed"
      ;;
    list)
      if [[ -z $(conf_rows "$EXITS_FILE") ]]; then
        echo "No exits yet. On the exit: ./vpn.sh hub add NAME, then here: ./vpn.sh exit add EXIT_NAME TOKEN"
        return
      fi
      printf '%-16s %-28s %s\n' EXIT ADDRESS ROUTES
      while read -r name token; do
        token_json "$token" | jq -r --arg e "$name" '"\($e) \(.address):\(.port) \([.ips[] | "\($e)/\(.name)=\(.ip)"] | join(" "))"' |
          awk '{printf "%-16s %-28s", $1, $2; for (i = 3; i <= NF; i++) printf " %s", $i; print ""}'
      done < <(conf_rows "$EXITS_FILE")
      ;;
    *) die "usage: ./vpn.sh exit add NAME TOKEN | del NAME | list" ;;
  esac
}

cmd_group() {
  local action=${1:-} name=${2:-} route=${3:-} members
  require_role hub group
  case $action in
    add)
      check_name "$name" "group name"
      group_exists "$name" && die "group $name already exists"
      route=${route:--}
      check_route "$route" dash-ok
      conf_init "$GROUPS_FILE" "$GROUPS_HEADER"
      echo "$name $route" >>"$GROUPS_FILE"
      info "group $name added (route: ${route/#-/ROUTE_DEFAULT}); add users: ./vpn.sh user group USER $name"
      ;;
    route)
      check_name "$name" "group name"
      group_exists "$name" || die "no group $name"
      [[ -n $route ]] || die "usage: ./vpn.sh group route NAME ROUTE|-"
      check_route "$route" dash-ok
      conf_rewrite "$GROUPS_FILE" -v n="$name" -v r="$route" '!/^#/ && $1 == n {$2 = r} {print}'
      cmd_up
      info "group $name now leaves through ${route/#-/ROUTE_DEFAULT ($ROUTE_DEFAULT)}"
      ;;
    del)
      check_name "$name" "group name"
      group_exists "$name" || die "no group $name"
      members=$(conf_rows "$ROUTING_FILE" | awk -v g="$name" '$2 == g {printf "%s%s", (n++ ? " " : ""), $1}')
      [[ -z $members ]] || die "group $name has users: $members (./vpn.sh user group USER - or another group)"
      conf_rewrite "$GROUPS_FILE" -v n="$name" '/^#/ || $1 != n'
      info "group $name removed"
      ;;
    list)
      if [[ -z $(conf_rows "$GROUPS_FILE") ]]; then
        echo "No groups yet. Add one: ./vpn.sh group add NAME [ROUTE]"
        return
      fi
      awk '
        FILENAME == ARGV[1] { order[++n] = $1; route[$1] = $2; next }
        { members[$2] = members[$2] " " $1 }
        END {
          printf "%-20s %-20s %s\n", "GROUP", "ROUTE", "USERS"
          for (i = 1; i <= n; i++) printf "%-20s %-20s%s\n", order[i], route[order[i]], members[order[i]]
        }' <(conf_rows "$GROUPS_FILE") <(conf_rows "$ROUTING_FILE")
      ;;
    *) die "usage: ./vpn.sh group add NAME [ROUTE] | route NAME ROUTE|- | del NAME | list" ;;
  esac
}

cmd_route() {
  require_role hub route
  case ${1:-} in
    list)
      user_routes | awk -v def="${ROUTE_DEFAULT:-none}" '
        BEGIN { printf "%-20s %-16s %-20s %s\n", "USER", "GROUP", "ROUTE", "FROM" }
        {
          why = $4 == "default" ? "ROUTE_DEFAULT" : $4 == "group" ? "group" : "own"
          if ($4 == "missing") { why = $3 " does not exist"; $3 = "none" }
          printf "%-20s %-16s %-20s %s\n", $1, $2, $3, why
        }'
      echo
      echo "Routes: $(route_names | paste -sd' ')"
      echo "RU (.ru .su .рф, Russian services, Russian IPs) leaves from this hub for everyone."
      ;;
    *) die "usage: ./vpn.sh route list" ;;
  esac
}

# --- check -------------------------------------------------------------------

# Each route of exit NAME (all exits without one) leaves from the IP it should;
# uses report from cmd_check, or prints when called on its own
check_exit_routes() {
  local only=${1:-} route ip seen
  declare -F report >/dev/null || report() { printf '%-12s %s\n' "$1" "$2"; }
  while read -r route ip; do
    seen=$(via_check "check@$route" "$IP_ECHO_URL")
    if [[ $seen == "$ip" ]]; then
      report route "ok ($route: $ip)"
    else
      report route "FAIL: $route leaves $(leaves_as "$seen"), should be $ip"
    fi
  done < <(exit_routes_json | jq -r --arg e "${only:+$only/}" '.[] | select(.name | startswith($e)) | "\(.name) \(.ip)"')
}

check_routes() {
  local seen local_ip entry tag file age missing
  # A Russian site: RU providers slow down some foreign ones (Cloudflare) from here
  local_ip=$(via_check check@local "$IP_ECHO_RU_URL")
  if [[ -n $local_ip ]]; then report route "ok (local: $local_ip)"; else report route "FAIL: local doesn't work"; fi
  check_exit_routes

  # No route: nothing but RU, and RU leaves from the hub
  seen=$(via_check check@none "$IP_ECHO_URL")
  if [[ -z $seen ]]; then report fail-closed "ok (no route, no internet)"; else report fail-closed "FAIL: route none leaves as $seen"; fi
  # Route none and RU still leaves (from the hub)
  seen=$(via_check check@none "$IP_ECHO_RU_URL")
  if [[ -n $seen && $seen == "$local_ip" ]]; then
    report ru "ok (leaves from the hub: $seen)"
  else
    report ru "FAIL: $IP_ECHO_RU_URL with no route leaves $(leaves_as "$seen"), should be ${local_ip:-the hub}"
  fi

  for entry in "${RULE_SETS[@]}"; do
    tag=${entry%% *} file=$RULE_SETS_DIR/$tag.srs
    if [[ ! -s $file ]]; then
      report ru-lists "FAIL: no $tag list (./vpn.sh update rules)"
      continue
    fi
    age=$((($(date +%s) - $(stat -c %Y "$file")) / 86400))
    ((age <= 7)) && report ru-lists "ok ($tag, ${age}d old)" || report ru-lists "FAIL: $tag is ${age} days old"
  done

  route_exists "${ROUTE_DEFAULT:-none}" || report routes "FAIL: ROUTE_DEFAULT=$ROUTE_DEFAULT doesn't exist"
  missing=$(user_routes | awk '$4 == "missing" {printf "%s%s -> %s", (n++ ? ", " : ""), $1, $3}')
  [[ -z $missing ]] || report users "FAIL: routes don't exist, no internet but RU: $missing"
}
