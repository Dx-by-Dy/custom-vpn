# shellcheck shell=bash
# ROLE=control (the scheme on a laptop) and hubs managed by it; sourced by vpn.sh

# Control keeps users, groups, routes and exits like a hub does, plus the hubs
# (hubs.conf: hub  token). Changes are only saved; `control publish` makes a
# snapshot of all of it (`control diff`: what isn't published yet):
#   JSON -> gzip -> age (one recipient per hub) -> signed with ssh-keygen -Y sign
# written as one line "cvpn-state1.<signature>.<data>" (both base64). A hub
# applies a snapshot only if control signed it, it can decrypt it and its
# version is newer than the one it has; otherwise it stays as it is.
CONTROL_DIR=data/control
CONTROL_HUBS_HEADER='# hub  token'
STATE_FILE=$OUT/state.txt
# The scheme as last published, to tell what isn't (control diff)
PUBLISHED_FILE=$CONTROL_DIR/published.json
# ssh-keygen -Y namespace and principal of control's signatures
SIG_NAMESPACE=cvpn-state
SIG_PRINCIPAL=cvpn-control

managed() { [[ $ROLE == hub && -n ${CONTROL_KEY:-} ]]; }

# Commands that change users / routes: on a hub under control they belong to control
require_editable() {
  managed || return 0
  die "this hub is managed by control (hub $HUB_NAME): ./vpn.sh control $1 there; it comes here as a snapshot"
}

# JSON from a "PREFIX:base64" token, or nothing
token_decode() {
  [[ $2 == "$1":* ]] || return 1
  base64 -d <<<"${2#"$1":}" 2>/dev/null | jq -ce 'select(.v == 1)' 2>/dev/null
}

token_encode() { jq -c . | base64 -w0 | sed "s/^/$1:/"; }

# --- control -----------------------------------------------------------------

control_init() {
  if [[ ! -f $ENV_FILE ]]; then
    cat >"$ENV_FILE" <<'EOF'
ROLE=control
# Route of users who have none of their own and none from a group: none or
# empty (no internet but RU), local (leave from the hub) or EXIT/IPNAME
ROUTE_DEFAULT=none
# Profile name shown in client apps (quote it if it has spaces: SUB_NAME="My VPN")
SUB_NAME=SVOi
EOF
    chmod 600 "$ENV_FILE"
  fi
  grep -q '^CONTROL_DOMAIN=' "$ENV_FILE" || cat >>"$ENV_FILE" <<'EOF'

# Snapshots go into TXT records under CONTROL_DOMAIN: a domain of its own or a
# subdomain, in a zone of the DNSmanager account below; several, space-separated,
# go into each (CONTROL_DOMAIN="a.ru b.ru"). Hubs read them from there and learn
# the list from `control hub add`'s token, then from snapshots: to move to another
# domain, add it, publish, drop the old one later. Empty: by ssh only
# (./vpn.sh hub control apply on each hub).
CONTROL_DOMAIN=
# DNSmanager (ISPsystem) API, e.g. https://dns-01.example.ru:1501/dnsmgr
DNS_API=
DNS_USER=
DNS_PASSWORD=
# TTL of the records, seconds: hubs see a new snapshot within 5 min + TTL
DNS_TTL=300
EOF
  load_env
  need_pkg age "snapshots are encrypted with it"
  mkdir -p "$CONTROL_DIR"
  chmod 700 "$CONTROL_DIR"
  if [[ ! -f $CONTROL_DIR/sign ]]; then
    ssh-keygen -q -t ed25519 -N '' -C "$SIG_PRINCIPAL" -f "$CONTROL_DIR/sign"
    info "signing key: $CONTROL_DIR/sign (back it up: hubs trust only this key)"
  fi
  users_init
  conf_init "$HUBS_FILE" "$CONTROL_HUBS_HEADER"
  [[ -n ${CONTROL_DOMAIN:-} ]] || warn "CONTROL_DOMAIN is empty: snapshots go to hubs by ssh only (see $ENV_FILE)"
  info "control is ready: add exits (./vpn.sh control exit add), hubs (./vpn.sh control hub add), users"
}

control_hub_exists() { conf_rows "$HUBS_FILE" | awk -v n="$1" '$1 == n {f = 1} END {exit !f}'; }

# Hubs as JSON: [{name, domain, vless_port, hysteria_port, sub_port, sni, public_key, short_id, recipient}]
control_hubs_json() {
  local name token
  while read -r name token; do
    token_decode cvpn-hub "$token" | jq -c --arg n "$name" '{name: $n} + del(.v)' ||
      warn "$HUBS_FILE: the token of $name is broken, add the hub again"
  done < <(conf_rows "$HUBS_FILE") | jq -sc .
}

# The token a hub needs to trust control
control_token() {
  jq -n --arg hub "$1" --arg key "$(cat "$CONTROL_DIR/sign.pub")" --arg domain "$(control_domains_line)" '
    {v: 1, hub: $hub, key: $key} + (if $domain != "" then {domain: $domain} else {} end)' |
    token_encode cvpn-ctl
}

# conf file rows as a JSON list of lists
conf_json() { conf_rows "$1" | jq -Rn '[inputs | [splits("[ \t]+")]]'; }

# The scheme as snapshots carry it, without version and time; hubs with their
# recipients (who can read it)
scheme_json() {
  local hubs=${1:-$(control_hubs_json)}
  jq -n --argjson users "$(conf_json "$USERS_FILE")" --argjson groups "$(conf_json "$GROUPS_FILE")" \
    --argjson routing "$(conf_json "$ROUTING_FILE")" --argjson exits "$(conf_json "$EXITS_FILE")" --argjson hubs "$hubs" \
    --arg route_default "${ROUTE_DEFAULT:-none}" --arg sub_name "$SUB_NAME" --arg domains "$(control_domains_line)" \
    --argjson updates "$(conf_json "$UPDATES_FILE")" '
    {users: $users, groups: $groups, routing: $routing, exits: $exits, hubs: $hubs,
     settings: {ROUTE_DEFAULT: $route_default, SUB_NAME: $sub_name, CONTROL_DOMAIN: $domains}}
    + (if $updates != [] then {updates: $updates} else {} end)'
}

# Is there something the hubs don't have yet?
control_pending() {
  [[ -s $PUBLISHED_FILE ]] || return 0
  [[ $(scheme_json | jq -cS .) != "$(jq -cS . "$PUBLISHED_FILE")" ]]
}

# A change in control (its cmd_up): vpn.sh says at the end that it's saved
CONTROL_CHANGED=false
control_changed() { CONTROL_CHANGED=true; }

# Saved, published only by `control publish`
control_saved() {
  if [[ $(control_hubs_json | jq length) == 0 ]]; then
    info "saved (no hubs yet: ./vpn.sh control hub add NAME TOKEN)"
  elif control_pending; then
    info "saved, not published yet: ./vpn.sh control publish (what changes: ./vpn.sh control diff)"
  else
    info "saved; the hubs have this already"
  fi
}

# control diff: what the next publish changes, without credentials
cmd_control_diff() {
  local cur
  if [[ ! -s $PUBLISHED_FILE ]]; then
    echo "Nothing recorded as published yet (published by an older version, or never): ./vpn.sh control publish"
    return
  fi
  cur=$(scheme_json)
  if [[ $(jq -cS . <<<"$cur") == "$(jq -cS . "$PUBLISHED_FILE")" ]]; then
    echo "Nothing to publish: the hubs have v$(cat "$CONTROL_DIR/version" 2>/dev/null || echo ?)"
    return
  fi
  echo "Not published yet (the hubs have v$(cat "$CONTROL_DIR/version" 2>/dev/null || echo ?)):"
  jq -rn --slurpfile old "$PUBLISHED_FILE" --argjson new "$cur" '
    $old[0] as $o |
    # rows of a conf file by their first column (users have a row per credential)
    def by($x): $x | group_by(.[0]) | map({key: .[0][0], value: .}) | from_entries;
    def objs($x): $x | map({key: .name, value: .}) | from_entries;
    def orders($x): $x // [] | map({key: "\(.[0]) \(.[1])", value: .}) | from_entries;
    def cmp($what; $a; $b; show):
      ($b | keys[] | select($a[.] == null) as $k | "  \($what) + \($k)\($b[$k] | show)"),
      ($a | keys[] | select($b[.] == null) | "  \($what) - \(.)"),
      ($b | keys[] | select($a[.] != null and $a[.] != $b[.]) as $k | "  \($what) ~ \($k)\($b[$k] | show)");
    cmp("user"; by($o.users); by($new.users); if length > 1 then " (\(length - 1) old key(s) in grace)" else "" end),
    cmp("routes"; by($o.routing); by($new.routing); .[0] | ": group \(.[1]), routes \(.[2])"),
    cmp("group"; by($o.groups); by($new.groups); .[0] | ": routes \(.[1])"),
    cmp("exit"; by($o.exits); by($new.exits); ""),
    cmp("hub"; objs($o.hubs); objs($new.hubs); " (\(.domain))"),
    cmp("update"; orders($o.updates); orders($new.updates); ": to \(.[2][:12])"),
    ($new.settings | keys[] | select($o.settings[.] != $new.settings[.]) as $k |
      "  setting ~ \($k): \($o.settings[$k]) -> \($new.settings[$k])")'
}

# Build the snapshot into STATE_FILE and publish it (control publish)
cmd_publish() {
  local hubs version last tmp r scheme recipients=() args=()
  hubs=$(control_hubs_json)
  if [[ $(jq length <<<"$hubs") == 0 ]]; then
    info "saved; no hubs yet, so nothing to publish (./vpn.sh control hub add NAME TOKEN)"
    return
  fi
  mapfile -t recipients < <(jq -r '.[].recipient' <<<"$hubs")
  # Versions only grow, even if the clock goes back
  last=$(cat "$CONTROL_DIR/version" 2>/dev/null || echo 0)
  version=$(date +%s)
  ((version > last)) || version=$((last + 1))

  tmp_dir tmp
  for r in "${recipients[@]}"; do args+=(-r "$r"); done
  scheme=$(scheme_json "$hubs")
  jq --argjson version "$version" --arg created "$(date -u +%FT%TZ)" --arg update_key "$(control_update_key)" '
    {v: 1, version: $version, created: $created} + . + {update_key: $update_key}
    | .hubs |= map(del(.recipient)) | del(.updates)' <<<"$scheme" |
    gzip -9 | age "${args[@]}" -o "$tmp/data"
  ssh-keygen -Y sign -q -f "$CONTROL_DIR/sign" -n "$SIG_NAMESPACE" "$tmp/data"
  mkdir -p "$OUT"
  chmod 700 "$OUT"
  printf 'cvpn-state1.%s.%s\n' "$(base64 -w0 "$tmp/data.sig")" "$(base64 -w0 "$tmp/data")" >"$STATE_FILE.tmp"
  chmod 600 "$STATE_FILE.tmp"
  mv "$STATE_FILE.tmp" "$STATE_FILE"
  echo "$version" >"$CONTROL_DIR/version"
  update_build "$version" "$hubs"
  info "snapshot v$version for $(jq -r 'map(.name) | join(", ")' <<<"$hubs"): $STATE_FILE ($(wc -c <"$STATE_FILE") bytes)"
  if dns_enabled; then
    dns_publish "$version"
  else
    echo "   on each hub: ssh HUB 'cd /opt/custom-vpn && ./vpn.sh hub control apply' < $STATE_FILE"
  fi
  printf '%s\n' "$scheme" >"$PUBLISHED_FILE.tmp"
  chmod 600 "$PUBLISHED_FILE.tmp"
  mv "$PUBLISHED_FILE.tmp" "$PUBLISHED_FILE"
}

# Subscription links of a user on every hub (control's `links`)
control_links() {
  local only=${1:-} name uuid hy_user hy_pass token exp found=false hubs hub base
  hubs=$(control_hubs_json)
  while read -r name uuid hy_user hy_pass token exp; do
    [[ -z $only || $name == "$only" ]] || continue
    found=true
    echo
    echo "[$name]"
    if [[ $(jq length <<<"$hubs") == 0 ]]; then
      echo "  no hubs yet: links appear after ./vpn.sh control hub add"
      continue
    fi
    while read -r hub base; do
      echo "  $hub:"
      echo "    import page:   $base"
      echo "    subscription:  ${base}sub"
      user_route_subs "$name" "$base" "    "
    done < <(jq -r --arg t "$token" '.[] | "\(.name) https://\(.domain):\(.sub_port)/\($t)/"' <<<"$hubs")
  done < <(users_active)
  $found || die "no user ${only:-found}"
  echo
}

cmd_control_hub() {
  local action=${1:-} name=${2:-} token=${3:-}
  require_role control hub
  case $action in
    add)
      check_name "$name" "hub name"
      [[ -n $token ]] || die "usage: ./vpn.sh control hub add NAME TOKEN (./vpn.sh hub control join on the hub prints it)"
      token_decode cvpn-hub "$token" | jq -e '.domain and .recipient and .public_key' >/dev/null 2>&1 ||
        die "that's not a hub token: it starts with cvpn-hub: (./vpn.sh hub control join on the hub prints it)"
      conf_init "$HUBS_FILE" "$CONTROL_HUBS_HEADER"
      if control_hub_exists "$name"; then
        conf_rewrite "$HUBS_FILE" -v n="$name" '/^#/ || $1 != n'
        info "hub $name updated"
      fi
      echo "$name $token" >>"$HUBS_FILE"
      control_changed
      echo
      echo "[$name] 1. here: ./vpn.sh control publish (so that the snapshot includes $name)"
      echo "       2. on the hub, once:  ./vpn.sh hub control set '$(control_token "$name")'"
      dns_enabled || echo "       3. apply the snapshot there (publish prints how)"
      echo
      ;;
    del)
      check_name "$name" "hub name"
      control_hub_exists "$name" || die "no hub $name"
      conf_rewrite "$HUBS_FILE" -v n="$name" '/^#/ || $1 != n'
      info "hub $name removed: it can't read snapshots published from now on (it keeps the last one it applied)"
      control_changed
      ;;
    token)
      check_name "$name" "hub name"
      control_hub_exists "$name" || die "no hub $name"
      echo "[$name] on the hub:  ./vpn.sh hub control set '$(control_token "$name")'"
      ;;
    list)
      if [[ -z $(conf_rows "$HUBS_FILE") ]]; then
        echo "No hubs yet. On a hub: ./vpn.sh hub control join, then here: ./vpn.sh control hub add NAME TOKEN"
        return
      fi
      printf '%-16s %-30s %s\n' HUB DOMAIN PORTS
      control_hubs_json | jq -r '.[] | "\(.name) \(.domain) vless:\(.vless_port) hy2:\(.hysteria_port) sub:\(.sub_port)"' |
        awk '{printf "%-16s %-30s %s %s %s\n", $1, $2, $3, $4, $5}'
      ;;
    update) control_update hub "$name" "$token" ;;
    *) die "usage: ./vpn.sh control hub add NAME TOKEN | token NAME | del NAME | list | update [NAME|--all [COMMIT|-]]" ;;
  esac
}

# Merge what `state export` printed on a stand-alone hub: users keep their
# credentials, so their links keep working
cmd_import() {
  local file=${1:-} json conflicts
  require_role control import
  [[ -n $file ]] || die "usage: ./vpn.sh control import FILE (from ./vpn.sh hub control export on the hub)"
  json=$(jq -ce 'select(.v == 1 and .kind == "export")' "$file" 2>/dev/null) || die "$file isn't a state export"
  conflicts=$(jq -r '[.users[][0]] | unique[]' <<<"$json" | while read -r name; do
    if user_exists "$name"; then echo "$name"; fi
  done | paste -sd' ')
  [[ -z $conflicts ]] || die "these users exist here already: $conflicts (remove or rename them first)"
  conf_init "$USERS_FILE" "$USERS_HEADER"
  conf_init "$GROUPS_FILE" "$GROUPS_HEADER"
  conf_init "$ROUTING_FILE" "$ROUTING_HEADER"
  conf_init "$EXITS_FILE" "$EXITS_HEADER"
  jq -r '.users[] | join(" ")' <<<"$json" >>"$USERS_FILE"
  jq -r '.routing[] | join(" ")' <<<"$json" >>"$ROUTING_FILE"
  local name rest
  while read -r name rest; do
    group_exists "$name" || echo "$name $rest" >>"$GROUPS_FILE"
  done < <(jq -r '.groups[] | join(" ")' <<<"$json")
  while read -r name rest; do
    if ! exit_exists "$name"; then
      echo "$name $rest" >>"$EXITS_FILE"
    elif ! conf_rows "$EXITS_FILE" | awk -v n="$name" -v t="$rest" '$1 == n && $2 == t {f = 1} END {exit !f}'; then
      warn "exit $name exists here with another token: kept this one"
    fi
  done < <(jq -r '.exits[] | join(" ")' <<<"$json")
  info "imported users: $(jq -r '[.users[][0]] | unique | join(" ")' <<<"$json")"
  # Settings stay control's: say where the hub's differ
  local key theirs
  for key in ROUTE_DEFAULT SUB_NAME; do
    theirs=$(jq -r --arg k "$key" '.settings[$k] // empty' <<<"$json")
    [[ -z $theirs || $theirs == "${!key:-none}" ]] ||
      warn "the hub had $key=$theirs, here it's ${!key:-none} (snapshots carry this one; change $ENV_FILE if needed)"
  done
  control_changed
}

# --- control: what the system looks like -------------------------------------

# Version of head.DOMAIN through RESOLVER, or "-"
head_version() {
  local h
  h=$(dns_txt "head.$1" "$2")
  [[ $h =~ ^cvpn1\ v=([0-9]+)\  ]] && echo "${BASH_REMATCH[1]}" || echo -
}

# control dns: the control domains in the order hubs read them, their zones,
# what their name servers and the public resolvers give
cmd_control_dns() {
  local d zone ns r line version
  dns_enabled || { echo "No CONTROL_DOMAIN: snapshots go to hubs by ssh only (./vpn.sh hub control apply)"; return; }
  dns_settings
  need_dig
  dns_login
  version=$(cat "$CONTROL_DIR/version" 2>/dev/null || echo -)
  echo "Published: v$version. Hubs read the domains in this order, through: ${DNS_RESOLVERS_DEFAULT}"
  printf '%-24s %-20s %s\n' DOMAIN ZONE HEAD
  for d in $(control_domains); do
    zone=$(dns_zone_of "$d")
    line=
    if [[ -n $zone ]]; then
      for ns in $(dig +short NS "$zone" | sed 's/\.$//'); do line+="$ns v$(head_version "$d" "$ns"), "; done
    fi
    for r in 77.88.8.8 1.1.1.1 8.8.8.8; do line+="$r v$(head_version "$d" "$r"), "; done
    printf '%-24s %-20s %s\n' "$d" "${zone:-(no such zone in the account)}" "${line%, }"
  done
}

# A hub's status.json (nothing if it doesn't answer): DOMAIN PORT RECIPIENT
hub_status_get() {
  curl -fsS --noproxy '*' -m 15 "https://$1:$2/$(status_token "$3")/status.json" 2>/dev/null || true
}

# The routes of a status.json's check: "ROUTE ok|FAIL IP" (IP - : nowhere)
status_routes() {
  jq -r '.check.lines[]? | select(startswith("route ")) | sub("^route +"; "") |
    if test("^ok \\(") then capture("^ok \\((?<r>[^:]+): (?<ip>[^)]+)\\)") + {s: "ok"}
    else (capture("^FAIL: (?<r>[^ ,:]+)( leaves as (?<ip>[^ ,]+))?") // {r: "?"}) + {s: "FAIL"} end |
    "\(.r) \(.s) \(.ip // "-")"' <<<"$1"
}

# route ip in control: the IP each route (or ROUTE) leaves from on every hub,
# as the hub's last check saw it
control_route_ip() {
  local hubs name domain port recipient status at r s ip found rows=()
  local -A should=([local]="(the hub)")
  hubs=$(control_hubs_json)
  [[ $(jq length <<<"$hubs") != 0 ]] || die "no hubs yet: $(vsh hub add) NAME TOKEN"
  while read -r r ip; do should[$r]=$ip; done < <(exit_routes_json | jq -r '.[] | "\(.name) \(.ip)"')
  while read -r name domain port recipient; do
    status=$(hub_status_get "$domain" "$port" "$recipient")
    if ! jq -e '.v == 1' <<<"$status" >/dev/null 2>&1; then
      rows+=("${1:-*}"$'\t'"$name"$'\t?\t?\tno status (./vpn.sh control check)')
      continue
    fi
    at=$(jq -r '.check.at // empty' <<<"$status")
    [[ -n $at ]] && at="$(mins_since "$at") min ago" || at=never
    found=false
    while read -r r s ip; do
      [[ -z $1 || $1 == "$r" ]] || continue
      found=true
      rows+=("$r"$'\t'"$name"$'\t'"${ip/#-/nowhere}"$'\t'"${should[$r]:-?}"$'\t'"$at")
    done < <(status_routes "$status")
    $found || rows+=("${1:-*}"$'\t'"$name"$'\t?\t'"${should[${1:-local}]:-?}"$'\tnot checked yet')
  done < <(jq -r '.[] | "\(.name) \(.domain) \(.sub_port) \(.recipient)"' <<<"$hubs")
  printf '%s\n' "${rows[@]}" | sort -s -t $'\t' -k1,1 | awk -F '\t' '
    BEGIN { printf "%-20s %-10s %-18s %-18s %s\n", "ROUTE", "HUB", "LEAVES AS", "SHOULD BE", "CHECKED" }
    { printf "%-20s %-10s %-18s %-18s %s\n", $1 == prev ? "" : $1, $2, $3, $4, $5; prev = $1 }'
  echo "From each hub's last check (hourly); right now, on a hub: ./vpn.sh hub route ip [ROUTE]"
}

# minutes since an ISO time (UTC), or a big number
mins_since() {
  local t
  t=$(date -d "$1" +%s 2>/dev/null) || { echo 999999; return; }
  echo $((($(date +%s) - t) / 60))
}

# control check: DNS, every hub (snapshot, DNS, its check, the subscription)
# and every route on every hub; non-zero exit when something is wrong
cmd_control_check() {
  load_env
  local failed=0 version d zone ns v bad hubs name domain port recipient status code ordered at ver ago problems sub token nhubs links
  local -A routes_bad=() routes_ok=()
  report() { printf '%-12s %s\n' "$1" "$2"; [[ $2 == ok* ]] || failed=1; }
  version=$(cat "$CONTROL_DIR/version" 2>/dev/null || echo 0)

  if dns_enabled; then
    dns_settings
    need_dig
    if ! (dns_login) >/dev/null 2>&1; then
      report dns-panel "FAIL: can't log in to $DNS_API as $DNS_USER"
    else
      dns_login
      report dns-panel "ok ($DNS_USER at $DNS_API)"
      for d in $(control_domains); do
        zone=$(dns_zone_of "$d")
        if [[ -z $zone ]]; then
          report dns "FAIL: $d isn't in any zone of $DNS_USER"
          continue
        fi
        bad=
        for ns in $(dig +short NS "$zone" | sed 's/\.$//'); do
          v=$(head_version "$d" "$ns")
          [[ $v == "$version" ]] || bad+=" $ns has v$v"
        done
        if [[ -n $bad ]]; then
          report dns "FAIL: $d:$bad, published v$version (./vpn.sh control publish)"
        else
          report dns "ok ($d: v$version on the name servers of $zone, 77.88.8.8 v$(head_version "$d" 77.88.8.8))"
        fi
      done
    fi
  else
    report dns "ok (no CONTROL_DOMAIN: snapshots go by ssh)"
  fi

  hubs=$(control_hubs_json)
  nhubs=$(jq length <<<"$hubs")
  ((nhubs > 0)) || report hubs "FAIL: no hubs (./vpn.sh control hub add)"
  if ((nhubs > 0)) && control_pending; then
    report publish "FAIL: changes not published (./vpn.sh control diff, ./vpn.sh control publish)"
  elif ((nhubs > 0)); then
    report publish "ok (v$version has every change)"
  fi
  token=$(users_active | awk '{print $5; exit}')
  while read -r name domain port recipient; do
    status=$(hub_status_get "$domain" "$port" "$recipient")
    if ! jq -e '.v == 1' <<<"$status" >/dev/null 2>&1; then
      report hub "FAIL: $name: no status at $domain:$port (down, blocked, or its code is older: ./vpn.sh hub update repo there)"
      continue
    fi
    problems=()
    ver=$(jq -r '.snapshot.version // 0' <<<"$status")
    # a fresh snapshot takes up to 5 min + DNS_TTL
    if ((ver < version && $(date +%s) - version > 300 + ${DNS_TTL:-300} + 120)); then
      problems+=("on v$ver, v$version is out")
    fi
    if dns_enabled; then
      ago=$(mins_since "$(jq -r '.synced // empty' <<<"$status")")
      ((ago <= 60)) || problems+=("DNS not read for ${ago} min")
    fi
    ago=$(mins_since "$(jq -r '.check.at // empty' <<<"$status")")
    ((ago <= 120)) || problems+=("no check for ${ago} min")
    while read -r line; do problems+=("$line"); done < <(jq -r '.check.lines[]? | select(test("^\\S+ +FAIL"))' <<<"$status")
    # routes as this hub sees them
    while read -r r s _; do
      if [[ $s == ok ]]; then routes_ok[$r]+="$name "; else routes_bad[$r]+="$name "; fi
    done < <(status_routes "$status")
    # the code control ordered (update FAIL lines came above); 15 min to get there
    code=$(jq -r '.update.code // empty' <<<"$status")
    read -r ordered at < <(conf_rows "$UPDATES_FILE" | awk -v n="$name" '$1 == "hub" && $2 == n {print $3, $4}') || true
    if [[ -n ${ordered:-} && $code != "$ordered" ]] && (($(date +%s) - at > 900)) &&
      ! jq -e '.update.result // "" | startswith("FAIL")' <<<"$status" >/dev/null; then
      problems+=("ordered ${ordered:0:12}, runs ${code:-an older version}")
    fi
    # the subscription of one user lists every hub
    if [[ -n $token ]]; then
      sub=$(curl -fsS --noproxy '*' -m 15 "https://$domain:$port/$token/sub" 2>/dev/null | base64 -d 2>/dev/null || true)
      links=$(grep -c '^vless://' <<<"$sub" || true)
      [[ $links == "$nhubs" ]] || problems+=("its subscription lists $links of $nhubs hubs")
    fi
    if ((${#problems[@]})); then
      report hub "FAIL: $name: $(printf '%s; ' "${problems[@]}" | sed 's/; $//')"
    else
      report hub "ok ($name: v$ver${code:+, code ${code:0:7}}, check $(mins_since "$(jq -r '.check.at' <<<"$status")") min ago: $(jq '.check.lines | length' <<<"$status") ok)"
    fi
  done < <(jq -r '.[] | "\(.name) \(.domain) \(.sub_port) \(.recipient)"' <<<"$hubs")

  local r
  for r in $(exit_routes_json | jq -r '.[].name'); do
    if [[ -n ${routes_bad[$r]:-} ]]; then
      report route "FAIL: $r doesn't work from ${routes_bad[$r]% } (./vpn.sh hub check there)"
    elif [[ -n ${routes_ok[$r]:-} ]]; then
      report route "ok ($r from ${routes_ok[$r]% })"
    else
      report route "FAIL: $r: no hub has checked it yet"
    fi
  done
  return $failed
}

# --- hub under control -------------------------------------------------------

cmd_control() {
  local action=${1:-} token=${2:-} json
  require_role "hub exit" control
  if [[ $ROLE == exit ]]; then
    cmd_exit_control "$@"
    return
  fi
  case $action in
    join)
      # This hub's key for snapshots, and what control needs to know about it
      need_pkg age "snapshots are encrypted with it"
      mkdir -p "$CONTROL_DIR"
      chmod 700 "$CONTROL_DIR"
      [[ -f $CONTROL_DIR/age.key ]] || age-keygen -o "$CONTROL_DIR/age.key" 2>/dev/null
      echo
      echo "in control:  ./vpn.sh control hub add NAME '$(hub_info_json |
        jq --arg recipient "$(age-keygen -y "$CONTROL_DIR/age.key")" '{v: 1} + . + {recipient: $recipient}' |
        token_encode cvpn-hub)'"
      echo
      ;;
    set)
      json=$(token_decode cvpn-ctl "$token") && jq -e '.hub and .key' >/dev/null <<<"$json" ||
        die "that's not a control token: it starts with cvpn-ctl: (./vpn.sh control hub add prints it)"
      [[ -f $CONTROL_DIR/age.key ]] || die "run ./vpn.sh hub control join first"
      set_var HUB_NAME "$(jq -r .hub <<<"$json")"
      set_var CONTROL_KEY "$(jq -r .key <<<"$json")"
      set_var CONTROL_DOMAIN "$(jq -r '.domain // empty' <<<"$json")"
      info "hub $HUB_NAME is managed by control now: users and routes come from its snapshots"
      if [[ -z $CONTROL_DOMAIN ]]; then
        remove_sync_timer
        echo "apply one: ./vpn.sh hub control apply < state.txt (users here are replaced by control's)"
        return
      fi
      install_sync_timer
      cmd_sync
      ;;
    unset)
      managed || die "this hub isn't managed by control"
      sed -i -E '/^(CONTROL_KEY|HUB_NAME|CONTROL_DOMAIN)=/d' "$ENV_FILE"
      remove_sync_timer
      info "this hub manages its users itself again (it keeps those of the last snapshot)"
      ;;
    sync) cmd_sync ;;
    apply) state_apply "${2:--}" ;;
    export) cmd_state export ;;
    *) die "usage: $(vsh control) join | set TOKEN | sync | apply [FILE] | export | unset" ;;
  esac
}

cmd_state() {
  local action=${1:-}
  require_role hub state
  case $action in
    apply) state_apply "${2:--}" ;;
    export)
      managed && die "this hub is managed by control already"
      echo "warning: this is every user's credentials; move it to control and delete it" >&2
      jq -n --argjson users "$(conf_json "$USERS_FILE")" --argjson groups "$(conf_json "$GROUPS_FILE")" \
        --argjson routing "$(conf_json "$ROUTING_FILE")" --argjson exits "$(conf_json "$EXITS_FILE")" \
        --arg route_default "${ROUTE_DEFAULT:-none}" --arg sub_name "$SUB_NAME" '
        {v: 1, kind: "export", users: $users, groups: $groups, routing: $routing, exits: $exits,
         settings: {ROUTE_DEFAULT: $route_default, SUB_NAME: $sub_name}}'
      ;;
    *) die "usage: ./vpn.sh hub control apply [FILE] | export" ;;
  esac
}

# Write rows (JSON list of lists) into a conf file with its header
conf_from_json() {
  local file=$1 header=$2 rows=$3
  { echo "$header"; jq -r '.[] | join(" ")' <<<"$rows"; } >"$file.tmp"
  chmod 600 "$file.tmp"
  mv "$file.tmp" "$file"
}

state_apply() {
  local src=$1 line sig data tmp json version applied
  managed || die "this hub isn't managed by control: ./vpn.sh hub control join, then hub control set"
  need_pkg age "snapshots are encrypted with it"
  if [[ $src == - ]]; then line=$(tr -d ' \n\r'); else line=$(tr -d ' \n\r' <"$src"); fi
  [[ $line =~ ^cvpn-state1\.([A-Za-z0-9+/=]+)\.([A-Za-z0-9+/=]+)$ ]] || die "not a snapshot (cvpn-state1....)"
  sig=${BASH_REMATCH[1]} data=${BASH_REMATCH[2]}

  tmp_dir tmp
  base64 -d <<<"$sig" >"$tmp/data.sig"
  base64 -d <<<"$data" >"$tmp/data"
  echo "$SIG_PRINCIPAL $CONTROL_KEY" >"$tmp/signers"
  ssh-keygen -Y verify -f "$tmp/signers" -I "$SIG_PRINCIPAL" -n "$SIG_NAMESPACE" -s "$tmp/data.sig" \
    <"$tmp/data" >/dev/null 2>&1 || die "the snapshot isn't signed by this hub's control"
  age -d -i "$CONTROL_DIR/age.key" "$tmp/data" 2>/dev/null | gunzip >"$tmp/json" 2>/dev/null ||
    die "can't decrypt the snapshot: this hub isn't among its recipients (hub add in control, then publish)"
  json=$(jq -ce 'select(.v == 1 and (.version | type) == "number" and (.users | type) == "array")' "$tmp/json") ||
    die "the snapshot has an unknown format (update this hub: ./vpn.sh hub update repo)"

  version=$(jq .version <<<"$json")
  applied=$(cat "$CONTROL_DIR/version" 2>/dev/null || echo 0)
  if ((version <= applied)); then
    info "snapshot v$version: this hub has v$applied already, nothing to do"
    return
  fi

  conf_from_json "$USERS_FILE" "$USERS_HEADER" "$(jq -c .users <<<"$json")"
  conf_from_json "$GROUPS_FILE" "$GROUPS_HEADER" "$(jq -c .groups <<<"$json")"
  conf_from_json "$ROUTING_FILE" "$ROUTING_HEADER" "$(jq -c .routing <<<"$json")"
  conf_from_json "$EXITS_FILE" "$EXITS_HEADER" "$(jq -c .exits <<<"$json")"
  set_var ROUTE_DEFAULT "$(jq -r .settings.ROUTE_DEFAULT <<<"$json")"
  set_var SUB_NAME "$(jq -r .settings.SUB_NAME <<<"$json")"
  # The key of control's update orders (lib/remote.sh)
  if [[ -n $(jq -r '.update_key // empty' <<<"$json") ]]; then
    (umask 077 && jq -r .update_key <<<"$json" >"$UPDATE_KEY")
  fi
  apply_control_domains "$(jq -r '.settings.CONTROL_DOMAIN // empty' <<<"$json")"
  # Everything control said, for what comes later (other hubs in the subscription)
  printf '%s\n' "$json" >"$CONTROL_DIR/state.json"
  chmod 600 "$CONTROL_DIR/state.json"
  echo "$version" >"$CONTROL_DIR/version"
  cmd_up
  hub_status_snapshot
  info "snapshot v$version from $(jq -r .created <<<"$json") applied"
}

# Domains a snapshot names: the hub reads the next one from there. A hub on
# ssh only stays so (it has no CONTROL_DOMAIN until `control set` gives one)
apply_control_domains() {
  local new=$1
  [[ -n $new && -n $(control_domains) && $new != "$(control_domains_line)" ]] || return 0
  set_var CONTROL_DOMAIN "$new"
  info "control's snapshots come from $new now"
}

# --- a managed hub's status, read by `control check` -------------------------
# https://DOMAIN:SUB_PORT/<status token>/status.json: the snapshot applied, when
# DNS was read, the last `check`. The token comes from the hub's age recipient,
# which only this hub and control know; the file is served like the subscriptions.
status_token() { printf 'cvpn-status\n%s' "$1" | sha256sum | cut -c1-32; }

hub_status_token() {
  [[ -f $CONTROL_DIR/age.key ]] || return 1
  status_token "$(age-keygen -y "$CONTROL_DIR/age.key")"
}

# hub_status KEY JSON: set .KEY of this hub's status.json
hub_status() {
  local token dir
  managed && token=$(hub_status_token) || return 0
  dir=$OUT/sub/$token
  mkdir -p "$dir"
  { [[ -s $dir/status.json ]] && cat "$dir/status.json" || echo '{}'; } |
    jq -c --arg k "$1" --argjson val "$2" --arg hub "$HUB_NAME" '. + {v: 1, hub: $hub} + {($k): $val}' >"$dir/status.json.tmp"
  chmod 644 "$dir/status.json.tmp"
  mv "$dir/status.json.tmp" "$dir/status.json"
}

# The snapshot this hub has applied, into its status
hub_status_snapshot() {
  [[ -f $CONTROL_DIR/version ]] || return 0
  hub_status snapshot "$(jq -cn --argjson v "$(cat "$CONTROL_DIR/version")" \
    --arg at "$(date -u -r "$CONTROL_DIR/version" +%FT%TZ)" '{version: $v, applied: $at}')"
}

# check on a managed hub; uses report from cmd_check
check_control() {
  local version
  managed || return 0
  version=$(cat "$CONTROL_DIR/version" 2>/dev/null || true)
  if [[ -n $version ]]; then
    report control "ok (hub $HUB_NAME, snapshot v$version applied $(date -r "$CONTROL_DIR/version" '+%F %R'))"
  else
    report control "FAIL: no snapshot applied yet (./vpn.sh hub control ${CONTROL_DOMAIN:+sync}${CONTROL_DOMAIN:-apply})"
  fi
  check_sync
}
