# shellcheck shell=bash
# ROLE=hub: exits, groups and the route of each user; sourced by vpn.sh

# A route is where a user's traffic leaves, except RU, which leaves from this hub:
#   local           from this hub
#   none            nowhere: only RU works (fail-closed)
#   EXIT/IPNAME     through exit EXIT from its egress IP named IPNAME
#   EXIT/IPNAME+ru  the same, and RU too: everything leaves through the exit
# A user's routes: their own, else their group's, else ROUTE_DEFAULT. Each of
# these is a list, ROUTE[,ROUTE...]: the user picks one in the app, every route
# being a subscription of its own (/<token>/<route>/sub), the first also the
# main one (/<token>/sub). Each route has its own credentials (route_cred), so
# the hub knows the route from the key and a route outside the list can't be
# used. A route that doesn't exist (exit removed, IP renamed) gets no
# credentials: there is no silent fallback to another IP.
#
# exits.conf:   exit  token          (the token `exit hub add` printed on the exit)
# groups.conf:  group  routes        (routes "-": ROUTE_DEFAULT)
# routing.conf: user  group  routes  ("-": no group / no routes of their own)
# sites.conf:   domain  hub|route    (exceptions from what counts as RU: site ...)
EXITS_FILE=exits.conf
EXITS_HEADER='# exit  token'
GROUPS_FILE=groups.conf
GROUPS_HEADER='# group  route'
ROUTING_FILE=routing.conf
ROUTING_HEADER='# user  group  route'
SITES_FILE=sites.conf
SITES_HEADER='# domain  hub|route'

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
  exit_routes_json | jq -r '.[] | .name, .name + "+ru"'
}

# (not `grep -q` in a pipe: it quits on the first match, and pipefail sees the SIGPIPE)
route_exists() { [[ $'\n'$(route_names)$'\n' == *$'\n'"$1"$'\n'* ]]; }

# Die unless ROUTE can be assigned ("-" too, if allowed)
# check_route ROUTE[,ROUTE...] [dash-ok]: every route of the list exists, none twice
check_route() {
  [[ $1 == - && ${2:-} == dash-ok ]] && return
  local r seen=" " list=()
  [[ -n $1 ]] || die "no route given; routes: $(route_names | paste -sd' ')"
  IFS=, read -ra list <<<"$1,"
  for r in "${list[@]}"; do
    route_exists "$r" || die "no route ${r:-(empty)}; routes: $(route_names | paste -sd' ')"
    [[ $seen != *" $r "* ]] || die "route $r is in the list twice"
    seen+="$r "
  done
}

# Routes of a list that don't exist, comma-separated
routes_missing() {
  local r out=() list=()
  IFS=, read -ra list <<<"$1,"
  for r in "${list[@]}"; do route_exists "$r" || out+=("$r"); done
  (IFS=,; echo "${out[*]}")
}

# user_route_subs USER BASE_URL INDENT: the subscription of each route of a
# user with several (printed by `user links`)
user_route_subs() {
  local list r
  list=$(user_route_lines | awk -v u="$1" '$1 == u {print $2}')
  [[ $list == *,* ]] || return 0
  echo "${3}a subscription per route (the app shows each as a profile; the first is the main one):"
  for r in ${list//,/ }; do printf '%s  %-14s %s%s/sub\n' "$3" "$r" "$2" "$(route_slug "$r")"; done
}

# A route in paths, file names and hysteria users: cz1/ip1 -> cz1-ip1,
# cz1/ip1+ru -> cz1-ip1--ru (IP names can't have a "+", and it's not safe in links)
route_slug() {
  local s=${1//\//-}
  echo "${s//+/--}"
}

# route_cred UUID HY_USER HY_PASS ROUTE: "uuid hysteria_user hysteria_pass" of the
# user's key for a route other than their first: derived from their own key, so
# it changes with `user rotate` and needs no storage
route_cred() {
  local u p
  u=$(printf 'cvpn-route\n%s\n%s' "$1" "$4" | sha256sum)
  p=$(printf 'cvpn-route-hy2\n%s\n%s' "$3" "$4" | sha256sum)
  echo "${u:0:8}-${u:8:4}-4${u:13:3}-8${u:17:3}-${u:20:12} $2+$(route_slug "$4") ${p:0:32}"
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
      n = split(route, rs, ","); bad = ""
      for (i = 1; i <= n; i++) if (!index(known, " " rs[i] " ")) bad = bad (bad == "" ? "" : ",") rs[i]
      print u, grp, route, from, (bad == "" ? "-" : bad)
    }' <(conf_rows "$GROUPS_FILE") <(conf_rows "$ROUTING_FILE") <(users_active)
}

# {user: route} for templates/hub.jq, missing routes as none
user_routes_json() {
  [[ -z $(routes_missing "${ROUTE_DEFAULT:-none}") ]] ||
    warn "ROUTE_DEFAULT=$ROUTE_DEFAULT: $(routes_missing "${ROUTE_DEFAULT:-none}") doesn't exist, users without a route of their own don't get it"
  user_routes | jq -Rn '[inputs | split(" ") | (.[4] | split(",")) as $bad
    | {(.[0]): ([.[2] | split(",")[] | select(. as $r | $bad | all(. != $r))] | if length == 0 then ["none"] else . end)}]
    | add // {}'
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

# Users whose route is one of the given ones (space-separated list on one line),
# or the same one with RU through the exit
users_on_routes() {
  user_routes | awk -v routes=" $* " '{
    n = split($3, rs, ",")
    for (i = 1; i <= n; i++) {
      sub(/\+ru$/, "", rs[i])
      if (index(routes, " " rs[i] " ")) { printf "%s%s", (c++ ? " " : ""), $1; break }
    }
  }'
}

# --- exceptions from what counts as RU ---------------------------------------

# {hub: [domains], route: [domains]} for templates/hub.jq
sites_json() {
  conf_rows "$SITES_FILE" | jq -Rn '[inputs | [splits("[ \t]+")]] |
    {hub: [.[] | select(.[1] == "hub") | .[0]], route: [.[] | select(.[1] == "route") | .[0]]}'
}

# A domain as sites.conf keeps it, or die: lower case, without the last dot.
# sing-box compares names as they are on the wire, so IDNs must be punycode.
site_domain() {
  local LC_ALL=C d=${1,,}
  d=${d%.}
  [[ $d == *[![:ascii:]]* ]] && die "$1: write it as punycode (xn--...), that's what connections carry"
  [[ $d != *[/:*]* ]] || die "$1: only the name, like example.com (it covers the subdomains too)"
  [[ ! $d =~ ^[0-9.]+$ ]] || die "$1: exceptions go by name, not by IP"
  [[ ${#d} -le 253 && $d =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] ||
    die "$1: not a domain with a parent, like example.com"
  echo "$d"
}

# Domains in the other list than WHERE that are DOMAIN's parent or subdomain:
# a name and its subdomains go one way, there is no "most specific wins"
site_conflicts() {
  conf_rows "$SITES_FILE" | awk -v d="$1" -v w="$2" '
    function under(a, b) { return length(a) > length(b) && substr(a, length(a) - length(b)) == "." b }
    $2 != w && (under(d, $1) || under($1, d)) { printf "%s%s", (n++ ? " " : ""), $1 }'
}

# site_set DOMAIN WHERE: put a checked domain into a list, out of the other one
site_set() {
  conf_init "$SITES_FILE" "$SITES_HEADER"
  conf_rewrite "$SITES_FILE" -v d="$1" '/^#/ || $1 != d'
  echo "$1 $2" >>"$SITES_FILE"
}

cmd_site() {
  local action=${1:-} where d conflicts domains=()
  require_role "hub control" site
  [[ $action == list ]] || require_editable "site $action"
  shift || true
  case $action in
    hub | route)
      (($#)) || die "usage: $(vsh site "$action") DOMAIN..."
      where=$action
      for d in "$@"; do
        d=$(site_domain "$d") || exit 1
        conflicts=$(site_conflicts "$d" "$where")
        [[ -z $conflicts ]] || die "$d overlaps $conflicts in the other list: $(vsh site del) it first"
        domains+=("$d")
      done
      for d in "${domains[@]}"; do site_set "$d" "$where"; done
      cmd_up
      if [[ $where == hub ]]; then
        info "${domains[*]}: from the hub, like RU (subdomains too)"
      else
        info "${domains[*]}: not RU, by the user's route (subdomains too)"
      fi
      ;;
    del)
      (($#)) || die "usage: $(vsh site del) DOMAIN..."
      for d in "$@"; do
        d=$(site_domain "$d") || exit 1
        conf_rows "$SITES_FILE" | awk -v d="$d" '$1 == d {f = 1} END {exit !f}' || die "no exception for $d"
        domains+=("$d")
      done
      for d in "${domains[@]}"; do conf_rewrite "$SITES_FILE" -v d="$d" '/^#/ || $1 != d'; done
      cmd_up
      info "${domains[*]}: decided by the RU lists again"
      ;;
    list)
      if [[ -z $(conf_rows "$SITES_FILE") ]]; then
        echo "No exceptions: the RU lists decide. Add one: $(vsh site hub) DOMAIN or $(vsh site route) DOMAIN"
        return
      fi
      conf_rows "$SITES_FILE" | sort -k2,2 -k1,1 | awk '
        BEGIN { printf "%-36s %s\n", "SITE (and subdomains)", "LEAVES" }
        { printf "%-36s %s\n", $1, $2 == "hub" ? "from the hub, like RU" : "by the route of the user, not RU" }'
      ;;
    *) die "usage: $(vsh site) hub DOMAIN... | route DOMAIN... | del DOMAIN... | list" ;;
  esac
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
        warn "can't download the $tag list (./vpn.sh hub update rules): until it's there, fewer sites count as RU"
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
  require_role "hub control" exit
  [[ $action == list ]] || require_editable "exit $action"
  case $action in
    add)
      check_name "$name" "exit name"
      [[ -n $token ]] || die "usage: $(vsh exit add) NAME TOKEN (./vpn.sh exit hub add|token on the exit prints it)"
      token_json "$token" >/dev/null ||
        die "that's not an exit token: it starts with cvpn-exit: (./vpn.sh exit hub add|token on the exit prints it)"
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
        [[ $ROLE != control ]] || echo "   for code updates from here: $(vsh exit token) $name (a command for the exit, once)"
      fi
      cmd_up
      # The hub can reach the exit, and each route leaves from its IP
      if [[ $ROLE == hub ]]; then
        sleep 2
        check_exit_routes "$name"
      fi
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
        echo "No exits yet. On the exit: ./vpn.sh exit hub add NAME, then here: $(vsh exit add) EXIT_NAME TOKEN"
        return
      fi
      printf '%-16s %-28s %s\n' EXIT ADDRESS ROUTES
      while read -r name token; do
        token_json "$token" | jq -r --arg e "$name" '"\($e) \(.address):\(.port) \([.ips[] | "\($e)/\(.name)=\(.ip)"] | join(" "))"' |
          awk '{printf "%-16s %-28s", $1, $2; for (i = 3; i <= NF; i++) printf " %s", $i; print ""}'
      done < <(conf_rows "$EXITS_FILE")
      ;;
    update)
      [[ $ROLE == control ]] || die "code updates are ordered from control: ./vpn.sh control exit update"
      control_update exit "$name" "$token"
      ;;
    token)
      [[ $ROLE == control ]] || die "./vpn.sh control exit token NAME, in control"
      exit_exists "$name" || die "no exit $name"
      [[ -n $(control_domains) ]] || die "no CONTROL_DOMAIN: exits get control's orders only through DNS"
      echo "[$name] on the exit, once (the token holds control's update key, keep it private):"
      echo "  ./vpn.sh exit control set '$(control_exit_token "$name")'"
      ;;
    *)
      if [[ $ROLE == control ]]; then
        die "usage: $(vsh exit) add NAME TOKEN | del NAME | list | update [NAME|--all [COMMIT|-]] | token NAME"
      fi
      die "usage: $(vsh exit) add NAME TOKEN | del NAME | list"
      ;;
  esac
}

cmd_group() {
  local action=${1:-} name=${2:-} route=${3:-} members
  require_role "hub control" group
  [[ $action == list ]] || require_editable "group $action"
  case $action in
    add)
      check_name "$name" "group name"
      group_exists "$name" && die "group $name already exists"
      route=${route:--}
      check_route "$route" dash-ok
      conf_init "$GROUPS_FILE" "$GROUPS_HEADER"
      echo "$name $route" >>"$GROUPS_FILE"
      [[ $ROLE != control ]] || control_changed
      info "group $name added (route: ${route/#-/ROUTE_DEFAULT}); add users: $(vsh user group) USER $name"
      ;;
    route)
      check_name "$name" "group name"
      group_exists "$name" || die "no group $name"
      [[ -n $route ]] || die "usage: $(vsh group route) NAME ROUTE|-"
      check_route "$route" dash-ok
      conf_rewrite "$GROUPS_FILE" -v n="$name" -v r="$route" '!/^#/ && $1 == n {$2 = r} {print}'
      cmd_up
      info "group $name now leaves through ${route/#-/ROUTE_DEFAULT ($ROUTE_DEFAULT)}"
      ;;
    del)
      check_name "$name" "group name"
      group_exists "$name" || die "no group $name"
      members=$(conf_rows "$ROUTING_FILE" | awk -v g="$name" '$2 == g {printf "%s%s", (n++ ? " " : ""), $1}')
      [[ -z $members ]] || die "group $name has users: $members ($(vsh user group) USER - or another group)"
      conf_rewrite "$GROUPS_FILE" -v n="$name" '/^#/ || $1 != n'
      [[ $ROLE != control ]] || control_changed
      info "group $name removed"
      ;;
    list)
      if [[ -z $(conf_rows "$GROUPS_FILE") ]]; then
        echo "No groups yet. Add one: $(vsh group add) NAME [ROUTE]"
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
    *) die "usage: $(vsh group) add NAME [ROUTE] | route NAME ROUTE|- | del NAME | list" ;;
  esac
}

cmd_route() {
  local where
  if [[ $(env_role) == client ]]; then
    load_env
    client_route "$@"
    return
  fi
  require_role "hub control" route
  case ${1:-list} in
    list)
      user_routes | awk -v def="${ROUTE_DEFAULT:-none}" '
        BEGIN { printf "%-20s %-16s %-24s %s\n", "USER", "GROUP", "ROUTES", "FROM" }
        {
          why = $4 == "default" ? "ROUTE_DEFAULT" : $4 == "group" ? "group" : "own"
          if ($5 != "-") why = why "; " $5 " does not exist"
          printf "%-20s %-16s %-24s %s\n", $1, $2, $3, why
        }'
      echo
      echo "Routes: $(route_names | paste -sd' ')"
      echo "Several routes (ROUTE,ROUTE...): the user picks one in the app; the first is the main one."
      if [[ $ROLE == control ]]; then where="always leaves from the hub the user is connected to"; else where="leaves from this hub for everyone"; fi
      echo "RU (.ru .su .рф, Russian services, Russian IPs) $where,"
      echo "but on routes EXIT/IPNAME+ru: they send everything through the exit. Exceptions by name: $(vsh site list)."
      ;;
    ip)
      if [[ -n ${2:-} ]]; then
        [[ $2 != *,* ]] || die "one route at a time (or none for all)"
        [[ $2 != none ]] || die "route none leaves nowhere (only RU, from the hub)"
        check_route "$2"
      fi
      # The same IP with or without RU
      where=${2:-}
      if [[ $ROLE == control ]]; then control_route_ip "${where%+ru}"; else hub_route_ip "${where%+ru}"; fi
      ;;
    *) die "usage: $(vsh route) list | ip [ROUTE]" ;;
  esac
}

# route ip on a hub: the IP each route (or ROUTE) leaves from now, and the one
# it should
hub_route_ip() {
  local r want seen
  printf '%-20s %-18s %s\n' ROUTE "LEAVES AS" "SHOULD BE"
  while read -r r want; do
    [[ -z $1 || $1 == "$r" ]] || continue
    if [[ $r == local ]]; then
      seen=$(via_ip check@local "$IP_ECHO_RU_URLS")
      want="(this hub)"
    else
      seen=$(via_ip "check@$r" "$IP_ECHO_URLS")
    fi
    printf '%-20s %-18s %s\n' "$r" "${seen:-nowhere}" "$want"
  done < <(echo "local -"; exit_routes_json | jq -r '.[] | "\(.name) \(.ip)"')
}

# --- check -------------------------------------------------------------------

# Routes with RU through the exit that someone uses: RU sites must see the exit
# as the address. Russian sites may refuse foreign addresses, so silence proves
# nothing either way; leaving from the hub is the failure this looks for.
check_ru_through_exit() {
  local used route ip seen
  used=" $(user_route_lines | awk '{print $2}' | tr ',\n' '  ') "
  while read -r route ip; do
    [[ $used == *" $route+ru "* ]] || continue
    seen=$(via_ip "check@$route+ru" "$IP_ECHO_RU_URLS")
    if [[ $seen == "$ip" ]]; then
      report all-exit "ok ($route+ru: RU leaves as $ip)"
    elif [[ -z $seen ]]; then
      report all-exit "ok ($route+ru: no RU site answered through the exit, not verified)"
    else
      report all-exit "FAIL: $route+ru: RU leaves as $seen, should be $ip"
    fi
  done < <(exit_routes_json | jq -r '.[] | "\(.name) \(.ip)"')
}

# Each route of exit NAME (all exits without one) leaves from the IP it should;
# uses report from cmd_check, or prints when called on its own
check_exit_routes() {
  local only=${1:-} route ip seen
  declare -F report >/dev/null || report() { printf '%-12s %s\n' "$1" "$2"; }
  while read -r route ip; do
    seen=$(via_ip "check@$route" "$IP_ECHO_URLS")
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
  local_ip=$(via_ip check@local "$IP_ECHO_RU_URLS")
  if [[ -n $local_ip ]]; then report route "ok (local: $local_ip)"; else report route "FAIL: local doesn't work"; fi
  check_exit_routes

  # No route: nothing but RU, and RU leaves from the hub
  seen=$(via_ip check@none "$IP_ECHO_URLS")
  if [[ -z $seen ]]; then report fail-closed "ok (no route, no internet)"; else report fail-closed "FAIL: route none leaves as $seen"; fi
  # Route none and RU still leaves (from the hub)
  seen=$(via_ip check@none "$IP_ECHO_RU_URLS")
  if [[ -n $seen && $seen == "$local_ip" ]]; then
    report ru "ok (leaves from the hub: $seen)"
  else
    report ru "FAIL: RU sites ($IP_ECHO_RU_URLS) with no route: leave $(leaves_as "$seen"), should be ${local_ip:-the hub}"
  fi
  check_ru_through_exit

  for entry in "${RULE_SETS[@]}"; do
    tag=${entry%% *} file=$RULE_SETS_DIR/$tag.srs
    if [[ ! -s $file ]]; then
      report ru-lists "FAIL: no $tag list (./vpn.sh hub update rules)"
      continue
    fi
    age=$((($(date +%s) - $(stat -c %Y "$file")) / 86400))
    ((age <= 7)) && report ru-lists "ok ($tag, ${age}d old)" || report ru-lists "FAIL: $tag is ${age} days old"
  done

  [[ -z $(routes_missing "${ROUTE_DEFAULT:-none}") ]] ||
    report routes "FAIL: ROUTE_DEFAULT=$ROUTE_DEFAULT: $(routes_missing "${ROUTE_DEFAULT:-none}") doesn't exist"
  missing=$(user_routes | awk '$5 != "-" {printf "%s%s -> %s", (n++ ? ", " : ""), $1, $5}')
  [[ -z $missing ]] || report users "FAIL: routes don't exist, these users can't use them: $missing"
}
