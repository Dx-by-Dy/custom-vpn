# shellcheck shell=bash
# ROLE=control (the scheme on a laptop) and hubs managed by it; sourced by vpn.sh

# Control keeps users, groups, routes and exits like a hub does, plus the hubs
# (hubs.conf: hub  token). Every change becomes a snapshot of all of it:
#   JSON -> gzip -> age (one recipient per hub) -> signed with ssh-keygen -Y sign
# written as one line "cvpn-state1.<signature>.<data>" (both base64). A hub
# applies a snapshot only if control signed it, it can decrypt it and its
# version is newer than the one it has; otherwise it stays as it is.
CONTROL_DIR=data/control
CONTROL_HUBS_HEADER='# hub  token'
STATE_FILE=$OUT/state.txt
# ssh-keygen -Y namespace and principal of control's signatures
SIG_NAMESPACE=cvpn-state
SIG_PRINCIPAL=cvpn-control

managed() { [[ $ROLE == hub && -n ${CONTROL_KEY:-} ]]; }

# Commands that change users / routes: on a hub under control they belong to control
require_editable() {
  managed || return 0
  die "this hub is managed by control (hub $HUB_NAME): ./vpn.sh $1 there, then apply the snapshot here"
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

# Snapshots go into TXT records under CONTROL_DOMAIN (a domain of its own, or a
# subdomain of DNS_ZONE); hubs read them from there. Empty: by ssh only
# (./vpn.sh state apply on each hub). Hubs learn it from `hub add`'s token.
CONTROL_DOMAIN=
# DNSmanager (ISPsystem) API of the zone, e.g. https://dns-01.example.ru:1501/dnsmgr
DNS_API=
# The zone in DNSmanager that holds CONTROL_DOMAIN (default: CONTROL_DOMAIN)
DNS_ZONE=
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
  info "control is ready: add exits (./vpn.sh exit add), hubs (./vpn.sh hub add), users"
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
  jq -n --arg hub "$1" --arg key "$(cat "$CONTROL_DIR/sign.pub")" --arg domain "${CONTROL_DOMAIN:-}" '
    {v: 1, hub: $hub, key: $key} + (if $domain != "" then {domain: $domain} else {} end)' |
    token_encode cvpn-ctl
}

# conf file rows as a JSON list of lists
conf_json() { conf_rows "$1" | jq -Rn '[inputs | [splits("[ \t]+")]]'; }

# Build the snapshot into STATE_FILE (control's cmd_up)
cmd_publish() {
  local hubs version last tmp r recipients=() args=()
  hubs=$(control_hubs_json)
  if [[ $(jq length <<<"$hubs") == 0 ]]; then
    info "saved; no hubs yet, so nothing to publish (./vpn.sh hub add NAME TOKEN)"
    return
  fi
  mapfile -t recipients < <(jq -r '.[].recipient' <<<"$hubs")
  # Versions only grow, even if the clock goes back
  last=$(cat "$CONTROL_DIR/version" 2>/dev/null || echo 0)
  version=$(date +%s)
  ((version > last)) || version=$((last + 1))

  tmp_dir tmp
  for r in "${recipients[@]}"; do args+=(-r "$r"); done
  jq -n --argjson version "$version" --arg created "$(date -u +%FT%TZ)" \
    --argjson users "$(conf_json "$USERS_FILE")" --argjson groups "$(conf_json "$GROUPS_FILE")" \
    --argjson routing "$(conf_json "$ROUTING_FILE")" --argjson exits "$(conf_json "$EXITS_FILE")" \
    --argjson hubs "$(jq 'map(del(.recipient))' <<<"$hubs")" \
    --arg route_default "${ROUTE_DEFAULT:-none}" --arg sub_name "$SUB_NAME" '
    {v: 1, version: $version, created: $created, users: $users, groups: $groups,
     routing: $routing, exits: $exits, hubs: $hubs,
     settings: {ROUTE_DEFAULT: $route_default, SUB_NAME: $sub_name}}' |
    gzip -9 | age "${args[@]}" -o "$tmp/data"
  ssh-keygen -Y sign -q -f "$CONTROL_DIR/sign" -n "$SIG_NAMESPACE" "$tmp/data"
  mkdir -p "$OUT"
  chmod 700 "$OUT"
  printf 'cvpn-state1.%s.%s\n' "$(base64 -w0 "$tmp/data.sig")" "$(base64 -w0 "$tmp/data")" >"$STATE_FILE.tmp"
  chmod 600 "$STATE_FILE.tmp"
  mv "$STATE_FILE.tmp" "$STATE_FILE"
  echo "$version" >"$CONTROL_DIR/version"
  info "snapshot v$version for $(jq -r 'map(.name) | join(", ")' <<<"$hubs"): $STATE_FILE ($(wc -c <"$STATE_FILE") bytes)"
  if dns_enabled; then
    dns_publish "$version"
  else
    echo "   on each hub: ssh HUB 'cd /opt/custom-vpn && ./vpn.sh state apply' < $STATE_FILE"
  fi
}

# Subscription links of a user on every hub (control's `links`)
control_links() {
  local only=${1:-} name uuid hy_user hy_pass token exp found=false hubs
  hubs=$(control_hubs_json)
  while read -r name uuid hy_user hy_pass token exp; do
    [[ -z $only || $name == "$only" ]] || continue
    found=true
    echo
    echo "[$name]"
    if [[ $(jq length <<<"$hubs") == 0 ]]; then
      echo "  no hubs yet: links appear after ./vpn.sh hub add"
      continue
    fi
    jq -r --arg t "$token" '.[] | "  \(.name):\n    import page:   https://\(.domain):\(.sub_port)/\($t)/\n    subscription:  https://\(.domain):\(.sub_port)/\($t)/sub"' <<<"$hubs"
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
      [[ -n $token ]] || die "usage: ./vpn.sh hub add NAME TOKEN (./vpn.sh control join on the hub prints it)"
      token_decode cvpn-hub "$token" | jq -e '.domain and .recipient and .public_key' >/dev/null 2>&1 ||
        die "that's not a hub token: it starts with cvpn-hub: (./vpn.sh control join on the hub prints it)"
      conf_init "$HUBS_FILE" "$CONTROL_HUBS_HEADER"
      if control_hub_exists "$name"; then
        conf_rewrite "$HUBS_FILE" -v n="$name" '/^#/ || $1 != n'
        info "hub $name updated"
      fi
      echo "$name $token" >>"$HUBS_FILE"
      cmd_publish
      echo
      echo "[$name] on the hub, once:  ./vpn.sh control set '$(control_token "$name")'"
      dns_enabled || echo "  then apply the snapshot there (see above)"
      echo
      ;;
    del)
      check_name "$name" "hub name"
      control_hub_exists "$name" || die "no hub $name"
      conf_rewrite "$HUBS_FILE" -v n="$name" '/^#/ || $1 != n'
      cmd_publish
      info "hub $name removed: it can't read new snapshots (it keeps the last one it applied)"
      ;;
    list)
      if [[ -z $(conf_rows "$HUBS_FILE") ]]; then
        echo "No hubs yet. On a hub: ./vpn.sh control join, then here: ./vpn.sh hub add NAME TOKEN"
        return
      fi
      printf '%-16s %-30s %s\n' HUB DOMAIN PORTS
      control_hubs_json | jq -r '.[] | "\(.name) \(.domain) vless:\(.vless_port) hy2:\(.hysteria_port) sub:\(.sub_port)"' |
        awk '{printf "%-16s %-30s %s %s %s\n", $1, $2, $3, $4, $5}'
      ;;
    *) die "usage: ./vpn.sh hub add NAME TOKEN | del NAME | list" ;;
  esac
}

# Merge what `state export` printed on a stand-alone hub: users keep their
# credentials, so their links keep working
cmd_import() {
  local file=${1:-} json conflicts
  require_role control import
  [[ -n $file ]] || die "usage: ./vpn.sh import FILE (from ./vpn.sh state export on the hub)"
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
  cmd_publish
}

# --- hub under control -------------------------------------------------------

cmd_control() {
  local action=${1:-} token=${2:-} json
  require_role hub control
  case $action in
    join)
      # This hub's key for snapshots, and what control needs to know about it
      need_pkg age "snapshots are encrypted with it"
      mkdir -p "$CONTROL_DIR"
      chmod 700 "$CONTROL_DIR"
      [[ -f $CONTROL_DIR/age.key ]] || age-keygen -o "$CONTROL_DIR/age.key" 2>/dev/null
      echo
      echo "in control:  ./vpn.sh hub add NAME '$(jq -n --arg domain "$DOMAIN" \
        --argjson vless_port "$VLESS_PORT" --argjson hysteria_port "$HYSTERIA_PORT" --argjson sub_port "$SUB_PORT" \
        --arg sni "$REALITY_SNI" --arg pbk "$REALITY_PUBLIC_KEY" --arg sid "$REALITY_SHORT_ID" \
        --arg recipient "$(age-keygen -y "$CONTROL_DIR/age.key")" '
        {v: 1, domain: $domain, vless_port: $vless_port, hysteria_port: $hysteria_port, sub_port: $sub_port,
         sni: $sni, public_key: $pbk, short_id: $sid, recipient: $recipient}' | token_encode cvpn-hub)'"
      echo
      ;;
    set)
      json=$(token_decode cvpn-ctl "$token") && jq -e '.hub and .key' >/dev/null <<<"$json" ||
        die "that's not a control token: it starts with cvpn-ctl: (./vpn.sh hub add in control prints it)"
      [[ -f $CONTROL_DIR/age.key ]] || die "run ./vpn.sh control join first"
      set_var HUB_NAME "$(jq -r .hub <<<"$json")"
      set_var CONTROL_KEY "\"$(jq -r .key <<<"$json")\""
      set_var CONTROL_DOMAIN "$(jq -r '.domain // empty' <<<"$json")"
      info "hub $HUB_NAME is managed by control now: users and routes come from its snapshots"
      if [[ -z $CONTROL_DOMAIN ]]; then
        remove_sync_timer
        echo "apply one: ./vpn.sh state apply < state.txt (users here are replaced by control's)"
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
    *) die "usage: ./vpn.sh control join | set TOKEN | unset" ;;
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
    *) die "usage: ./vpn.sh state apply [FILE] | export" ;;
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
  managed || die "this hub isn't managed by control: ./vpn.sh control join, then control set"
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
    die "the snapshot has an unknown format (update this hub: ./vpn.sh update repo)"

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
  set_var SUB_NAME "$(printf '%q' "$(jq -r .settings.SUB_NAME <<<"$json")")"
  # Everything control said, for what comes later (other hubs in the subscription)
  printf '%s\n' "$json" >"$CONTROL_DIR/state.json"
  chmod 600 "$CONTROL_DIR/state.json"
  echo "$version" >"$CONTROL_DIR/version"
  cmd_up
  info "snapshot v$version from $(jq -r .created <<<"$json") applied"
}

# check on a managed hub; uses report from cmd_check
check_control() {
  local version
  managed || return 0
  version=$(cat "$CONTROL_DIR/version" 2>/dev/null || true)
  if [[ -n $version ]]; then
    report control "ok (hub $HUB_NAME, snapshot v$version applied $(date -r "$CONTROL_DIR/version" '+%F %R'))"
  else
    report control "FAIL: no snapshot applied yet (./vpn.sh ${CONTROL_DOMAIN:+sync}${CONTROL_DOMAIN:-state apply})"
  fi
  check_sync
}
