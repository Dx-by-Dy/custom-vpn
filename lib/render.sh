# shellcheck shell=bash
# Rendering configs into generated/; sourced by vpn.sh

# This host's own addresses as a JSON list of /32 and /128: clients must not reach
# services on it (they would bypass the firewall, traffic to itself goes over lo)
host_ips_json() {
  ip -o addr show scope global 2>/dev/null |
    awk '{split($4, a, "/"); print a[1] (index(a[1], ":") ? "/128" : "/32")}' | jq -Rn '[inputs]'
}

# Valid credentials with the user's route as JSON for the sing-box template
users_json() {
  users_valid | jq -Rn --argjson routes "$(user_routes_json)" '[inputs | [splits("[ \t]+")] | {
    name: (if .[5] == "-" then .[0] else .[0] + "~" + .[5] end),
    uuid: .[1],
    hy2: (.[2] + ":" + .[3]),
    route: ($routes[.[0]] // "none")
  }]'
}

# hysteria needs caddy's certificate; without it sing-box runs VLESS only
HY2=false

# What clients need to connect to this hub (also in `control join`'s token)
hub_info_json() {
  jq -n --arg domain "$DOMAIN" --argjson vless_port "$VLESS_PORT" --argjson hysteria_port "$HYSTERIA_PORT" \
    --argjson sub_port "$SUB_PORT" --arg sni "$REALITY_SNI" --arg pbk "$REALITY_PUBLIC_KEY" --arg sid "$REALITY_SHORT_ID" '
    {domain: $domain, vless_port: $vless_port, hysteria_port: $hysteria_port, sub_port: $sub_port,
     sni: $sni, public_key: $pbk, short_id: $sid}'
}

# Hubs a subscription lists: this one first, then the others of control's snapshot
sub_hubs_json() {
  local others='[]'
  if managed && [[ -s $CONTROL_DIR/state.json ]]; then
    others=$(jq -c --arg self "$HUB_NAME" '[.hubs[]? | select(.name != $self)]' "$CONTROL_DIR/state.json")
  fi
  hub_info_json | jq -c --arg name "${HUB_NAME:-hub}" --argjson others "$others" '[{name: $name} + .] + $others'
}

# sub_links UUID HY_USER HY_PASS: the user's links for client apps on every hub
# of SUB_HUBS (one hub: names as before, "SUB_NAME-reality")
sub_links() {
  jq -r --arg uuid "$1" --arg hy "$2:$3" --arg sub "$SUB_NAME" '
    (length > 1) as $many | .[] |
    ($sub + (if $many then "-" + .name else "" end)) as $label |
    "vless://\($uuid)@\(.domain):\(.vless_port)?encryption=none&flow=xtls-rprx-vision&security=reality&sni=\(.sni)&fp=chrome&pbk=\(.public_key)&sid=\(.short_id)&type=tcp#\($label + "-reality" | @uri)",
    "hysteria2://\($hy)@\(.domain):\(.hysteria_port)/?sni=\(.domain)#\($label + "-hy2" | @uri)"' <<<"$SUB_HUBS"
}

# sub_outbounds UUID HY_USER HY_PASS: the same as sing-box outbounds (for ROLE=client)
sub_outbounds() {
  jq --arg uuid "$1" --arg hy "$2:$3" --arg sub "$SUB_NAME" '
    {v: 1, name: $sub, outbounds: [.[] | {
      type: "vless",
      tag: (.name + "-reality"),
      server: .domain,
      server_port: .vless_port,
      uuid: $uuid,
      flow: "xtls-rprx-vision",
      packet_encoding: "xudp",
      tls: {
        enabled: true,
        server_name: .sni,
        utls: {enabled: true, fingerprint: "chrome"},
        reality: {enabled: true, public_key: .public_key, short_id: .short_id}
      }
    }, {
      type: "hysteria2",
      tag: (.name + "-hy2"),
      server: .domain,
      server_port: .hysteria_port,
      password: $hy,
      tls: {enabled: true, server_name: .domain}
    }]}' <<<"$SUB_HUBS"
}

cmd_render() {
  load_env
  command -v jq >/dev/null || die "jq is not installed, run: $(vsh init)"
  if [[ $ROLE == exit ]]; then
    render_exit
    info "configs rendered to $OUT/"
    return
  fi
  if [[ $ROLE == client ]]; then
    render_client
    info "configs rendered to $OUT/"
    return
  fi
  [[ $(printf '%s\n' "$VLESS_LISTEN_PORT" "$SUB_PORT" "$ACME_HTTP_PORT" | sort -u | wc -l) == 3 ]] ||
    die "VLESS_PORT (or the port of VLESS_LISTEN), SUB_PORT and ACME_HTTP_PORT must be different tcp ports"
  [[ -n $(users_active) ]] || die "no users, run: $(vsh init)"

  [[ -s $CERT ]] && HY2=true || HY2=false
  # Missing RU lists only; the timer refreshes them daily
  rule_sets_update 1000000
  mkdir -p "$OUT/sub"
  chmod 700 "$OUT"
  render_jq templates/hub.jq "$OUT/sing-box.json" sing-box \
    --argjson users "$(users_json)" --argjson routes "$(exit_routes_json)" \
    --argjson rule_sets "$(rule_sets_json)" --argjson host_ips "$(host_ips_json)" --argjson hy2 "$HY2"
  render_file templates/Caddyfile "$OUT/Caddyfile" caddy

  # Per-user subscription (every hub), sing-box outbounds and import page; drop
  # pages of removed users
  local name uuid hy_user hy_pass token exp tokens=" "
  SUB_HUBS=$(sub_hubs_json)
  while read -r name uuid hy_user hy_pass token exp; do
    user_vars "$uuid" "$hy_user" "$hy_pass" "$token"
    mkdir -p "$OUT/sub/$token"
    render_file templates/sub.html "$OUT/sub/$token/index.html"
    write_file "$OUT/sub/$token/sub" "$(sub_links "$uuid" "$hy_user" "$hy_pass" | base64 -w0)"
    write_file "$OUT/sub/$token/sing-box.json" "$(sub_outbounds "$uuid" "$hy_user" "$hy_pass")"
    tokens+="$token "
  done < <(users_active)
  local dir
  for dir in "$OUT"/sub/*/; do
    dir=$(basename "$dir")
    [[ $tokens == *" $dir "* ]] || rm -rf "${OUT:?}/sub/$dir"
  done

  mkdir -p data/caddy "$RULE_SETS_DIR"
  check sing-box -v "$PWD/$OUT/sing-box.json:/c.json:ro,z" -v "$PWD/data/caddy:/caddy-data:ro,z" \
    -v "$PWD/$RULE_SETS_DIR:/rule-sets:ro,z" "$SINGBOX_IMAGE" check -c /c.json
  check caddy -v "$PWD/$OUT/Caddyfile:/c:ro,z" "$CADDY_IMAGE" caddy validate --config /c --adapter caddyfile
  info "configs rendered to $OUT/"
}
