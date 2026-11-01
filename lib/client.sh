# shellcheck shell=bash
# ROLE=client: sing-box on a server as a local proxy (socks5 + http on
# CLIENT_LISTEN) through the hubs of one user's subscription; sourced by vpn.sh
#
# Hubs serve each user's sing-box outbounds next to the subscription
# (<subscription>/sing-box.json): VLESS REALITY and Hysteria 2 of every hub.
# The client takes them from the first of CLIENT_SUB that answers, keeps a copy
# (and keeps working on it when no hub answers) and uses the fastest hub
# (urltest). Where traffic leaves is up to the hub: RU from the hub, the rest
# by the user's route.
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
    got=$(curl -fsS -m 20 "$(client_sub_base "$url")sing-box.json" 2>/dev/null) || continue
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

render_client() {
  [[ -n $(client_subs) ]] || die "set CLIENT_SUB in $ENV_FILE: the subscription link of this client's user"
  if ! client_fetch; then
    [[ -s $CLIENT_SUB_FILE ]] || die "can't get the subscription from: $(client_subs | paste -sd' ')"
    warn "can't refresh the subscription, using the copy from $(date -r "$CLIENT_SUB_FILE" '+%F %R')"
  fi
  mkdir -p "$OUT" data/caddy "$RULE_SETS_DIR"
  chmod 700 "$OUT"
  render_jq templates/client.jq "$OUT/sing-box.json" sing-box \
    --slurpfile sub "$CLIENT_SUB_FILE" --arg test_url "$IP_ECHO_RU_URL"
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

# Health check of a client; uses report from cmd_check
check_client() {
  local age proxy seen ru
  if [[ -s $CLIENT_SUB_FILE ]]; then
    age=$(($(date +%s) - $(date -r "$CLIENT_SUB_FILE" +%s)))
    if ((age <= CLIENT_SUB_MAX_AGE)); then
      report subscription "ok ($(jq -r '[.outbounds[].server] | unique | join(" ")' "$CLIENT_SUB_FILE"), refreshed $((age / 3600))h ago)"
    else
      report subscription "FAIL: not refreshed for $((age / 3600))h (CLIENT_SUB unreachable?)"
    fi
  else
    report subscription "FAIL: none yet (./vpn.sh up)"
  fi
  proxy=${CLIENT_LISTEN_HOST/#0.0.0.0/127.0.0.1}
  proxy=${proxy/#::/127.0.0.1}
  [[ $proxy == *:* ]] && proxy="[$proxy]"
  proxy=$proxy:$CLIENT_LISTEN_PORT
  ru=$(curl -s -m 15 --noproxy '' -x "socks5h://$proxy" "$IP_ECHO_RU_URL" 2>/dev/null || true)
  seen=$(curl -s -m 15 --noproxy '' -x "socks5h://$proxy" "$IP_ECHO_URL" 2>/dev/null || true)
  if [[ -n $ru ]]; then
    report proxy "ok ($proxy: RU leaves as $ru, the rest $(leaves_as "$seen"))"
  else
    report proxy "FAIL: nothing through $proxy (hubs unreachable?)"
  fi
}
