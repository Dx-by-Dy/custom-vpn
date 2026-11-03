# shellcheck shell=bash
# ROLE=client: sing-box on a server as a local proxy (socks5 + http on
# CLIENT_LISTEN) through the hubs of one user's subscription; sourced by vpn.sh
#
# Hubs serve each user's sing-box outbounds next to the subscription
# (<subscription>/sing-box.json): VLESS REALITY and Hysteria 2 of every hub.
# The client takes them from the first of CLIENT_SUB that answers, keeps a copy
# (and keeps working on it when no hub answers) and uses the fastest hub
# (urltest), on any protocol or on CLIENT_PROTOCOL. Where traffic leaves is up to
# the hub: RU from the hub, the rest by the user's route; of a user with several,
# the first, or CLIENT_ROUTE. `client route` and `client protocol` change them.
CLIENT_DIR=data/client
CLIENT_SUB_FILE=$CLIENT_DIR/sub.json
# check fails when the subscription couldn't be refreshed for that long
CLIENT_SUB_MAX_AGE=$((2 * 86400))

# https://HOST:PORT/TOKEN/ from the import page or the /sub link
client_sub_base() {
  local url=${1%/}
  url=${url%/sub}
  echo "$url/"
}

client_subs() { tr ', ' '\n\n' <<<"${CLIENT_SUB:-}" | sed '/^$/d'; }

# Fetch the outbounds into CLIENT_SUB_FILE; CLIENT_SUB_CHANGED=true if they changed
CLIENT_SUB_CHANGED=false
client_fetch() {
  local url got
  for url in $(client_subs); do
    got=$(curl -fsS -m 20 "$(client_sub_base "$url")${CLIENT_ROUTE:+$(route_slug "$CLIENT_ROUTE")/}sing-box.json" 2>/dev/null) || continue
    jq -e '.v == 1 and (.outbounds | length > 0)' <<<"$got" >/dev/null 2>&1 || continue
    mkdir -p "$CLIENT_DIR"
    chmod 700 "$CLIENT_DIR"
    if ! cmp -s <(printf '%s\n' "$got") "$CLIENT_SUB_FILE"; then
      printf '%s\n' "$got" >"$CLIENT_SUB_FILE.tmp"
      chmod 600 "$CLIENT_SUB_FILE.tmp"
      mv "$CLIENT_SUB_FILE.tmp" "$CLIENT_SUB_FILE"
      CLIENT_SUB_CHANGED=true
    fi
    touch "$CLIENT_SUB_FILE"
    return 0
  done
  return 1
}

# The route of the copy of the subscription, if its hub says (hubs with older code don't)
client_copy_route() { jq -r '.route // empty' "$CLIENT_SUB_FILE" 2>/dev/null || true; }

# The route this client should be on, as far as the copy can tell
client_wanted_route() { echo "${CLIENT_ROUTE:-$(jq -r '.routes[0]? // empty' "$CLIENT_SUB_FILE" 2>/dev/null || true)}"; }

# A copy of another route holds the key of that route: traffic would leave there
client_copy_is_wanted() {
  local have want
  have=$(client_copy_route)
  want=$(client_wanted_route)
  [[ -z $have || -z $want || $have == "$want" ]]
}

# Outbounds of the copy on PROTOCOL
client_protocol_count() {
  jq --arg p "$1" '[.outbounds[] | select($p == "auto" or (.type == "vless" and $p == "reality")
    or (.type == "hysteria2" and $p == "hy2"))] | length' "$CLIENT_SUB_FILE"
}

check_client_protocol() {
  case $1 in
    auto | reality | hy2) ;;
    *) die "protocol $1: must be auto (the fastest), reality (VLESS REALITY, tcp) or hy2 (Hysteria 2, udp)" ;;
  esac
}

render_client() {
  local protocol=${CLIENT_PROTOCOL:-auto}
  check_client_protocol "$protocol"
  [[ -n $(client_subs) ]] || die "set CLIENT_SUB in $ENV_FILE: the subscription link of this client's user"
  if ! client_fetch; then
    [[ -s $CLIENT_SUB_FILE ]] || die "can't get the subscription from: $(client_subs | paste -sd' ')"
    client_copy_is_wanted ||
      die "can't get route $(client_wanted_route) from: $(client_subs | paste -sd' '), and the copy here is of route $(client_copy_route)"
    warn "can't refresh the subscription, using the copy from $(date -r "$CLIENT_SUB_FILE" '+%F %R')"
  fi
  [[ $(client_protocol_count "$protocol") != 0 ]] || die "the subscription has nothing on protocol $protocol"
  mkdir -p "$OUT" data/caddy "$RULE_SETS_DIR"
  chmod 700 "$OUT"
  render_jq templates/client.jq "$OUT/sing-box.json" sing-box \
    --slurpfile sub "$CLIENT_SUB_FILE" --arg test_url "${IP_ECHO_RU_URLS%% *}" --arg protocol "$protocol"
  check sing-box -v "$PWD/$OUT/sing-box.json:/c.json:ro,z" "$SINGBOX_IMAGE" check -c /c.json
}

# prune on a client: refresh the subscription, restart if the hubs changed
client_refresh() {
  if ! client_fetch; then
    warn "can't refresh the subscription from: $(client_subs | paste -sd' ')"
    return 0
  fi
  if $CLIENT_SUB_CHANGED; then
    info "the subscription changed"
    cmd_up
  fi
}

# host:port of the local proxy, for connecting to it
client_proxy() {
  local proxy=${CLIENT_LISTEN_HOST/#0.0.0.0/127.0.0.1}
  proxy=${proxy/#::/127.0.0.1}
  [[ $proxy == *:* ]] && proxy="[$proxy]"
  echo "$proxy:$CLIENT_LISTEN_PORT"
}

# After a switch: does anything go through? A warning only, the choice stays
client_verify() {
  local proxy seen
  proxy=$(client_proxy)
  sleep 2
  seen=$(echo_ip "$IP_ECHO_RU_URLS $IP_ECHO_URLS" --noproxy '' -x "socks5h://$proxy")
  if [[ -n $seen ]]; then
    info "the proxy $proxy works (a site saw $seen)"
  else
    warn "nothing goes through $proxy on route $(client_copy_route) and protocol ${CLIENT_PROTOCOL:-auto}; see $(vsh check)"
  fi
}

# client route [ROUTE|-]: the routes of this client's user, or go on to another
client_route() {
  local want=${1:-} r have main
  if [[ -z $want || $want == list ]]; then
    [[ -s $CLIENT_SUB_FILE ]] || die "no subscription yet: $(vsh up)"
    have=$(client_copy_route)
    if [[ -z $have ]]; then
      echo "On ${CLIENT_ROUTE:-the main route}. The hubs don't list the routes yet (their code is older): the user's links are in control."
      return
    fi
    main=$(jq -r '.routes[0]' "$CLIENT_SUB_FILE")
    while read -r r; do
      printf '%s %s%s\n' "$([[ $r == "$have" ]] && echo '*' || echo ' ')" "$r" "$([[ $r == "$main" ]] && echo ' (the main one)')"
    done < <(jq -r '.routes[]' "$CLIENT_SUB_FILE")
    echo "Another one: $(vsh route) ROUTE; - : the main one"
    return
  fi
  [[ $want != - ]] || want=""
  [[ $want =~ ^[a-z0-9_.+/-]*$ ]] || die "no such route: $want"
  # Nothing changes unless the hubs have that route for this user
  CLIENT_ROUTE=$want
  client_fetch || die "can't get route ${want:-the main one}: not a route of this user, or no hub answers ($(client_subs | paste -sd' '))"
  set_var CLIENT_ROUTE "$want"
  cmd_up
  info "route: ${want:-the main one}"
  client_verify
}

# client protocol [auto|reality|hy2]: how this client reaches the hubs
cmd_protocol() {
  local want=${1:-}
  require_role client protocol
  if [[ -z $want ]]; then
    echo "Protocol: ${CLIENT_PROTOCOL:-auto}"
    echo "  auto     the fastest hub on either protocol, checked every 3 minutes"
    echo "  reality  VLESS REALITY (tcp), the fastest hub on it"
    echo "  hy2      Hysteria 2 (udp), the fastest hub on it"
    echo "Another one: $(vsh protocol) auto|reality|hy2"
    return
  fi
  check_client_protocol "$want"
  [[ ! -s $CLIENT_SUB_FILE || $(client_protocol_count "$want") != 0 ]] || die "the subscription has nothing on protocol $want"
  set_var CLIENT_PROTOCOL "$want"
  cmd_up
  info "protocol: $want"
  client_verify
}

# Health check of a client; uses report from cmd_check
check_client() {
  local age proxy seen ru have
  if [[ -s $CLIENT_SUB_FILE ]]; then
    age=$(($(date +%s) - $(date -r "$CLIENT_SUB_FILE" +%s)))
    have=$(client_copy_route)
    if ! client_copy_is_wanted; then
      report subscription "FAIL: the copy is of route $have, CLIENT_ROUTE says $(client_wanted_route) ($(vsh up))"
    elif ((age <= CLIENT_SUB_MAX_AGE)); then
      report subscription "ok (${have:-${CLIENT_ROUTE:-the main route}}, protocol ${CLIENT_PROTOCOL:-auto}, via $(jq -r '[.outbounds[].server] | unique | join(" ")' "$CLIENT_SUB_FILE"), refreshed $((age / 3600))h ago)"
    else
      report subscription "FAIL: not refreshed for $((age / 3600))h (CLIENT_SUB unreachable?)"
    fi
  else
    report subscription "FAIL: none yet ($(vsh up))"
  fi
  proxy=$(client_proxy)
  ru=$(echo_ip "$IP_ECHO_RU_URLS" --noproxy '' -x "socks5h://$proxy")
  seen=$(echo_ip "$IP_ECHO_URLS" --noproxy '' -x "socks5h://$proxy")
  if [[ -n $ru ]]; then
    report proxy "ok ($proxy: RU leaves as $ru, the rest $(leaves_as "$seen"))"
  else
    if [[ ${CLIENT_PROTOCOL:-auto} == auto ]]; then
      report proxy "FAIL: nothing through $proxy (hubs unreachable?)"
    else
      report proxy "FAIL: nothing through $proxy on $CLIENT_PROTOCOL (blocked here? $(vsh protocol auto) tries both)"
    fi
  fi
}
