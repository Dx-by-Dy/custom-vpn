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

cmd_render() {
  load_env
  command -v jq >/dev/null || die "jq is not installed, run: ./vpn.sh init"
  if [[ $ROLE == exit ]]; then
    render_exit
    info "configs rendered to $OUT/"
    return
  fi
  [[ $(printf '%s\n' "$VLESS_PORT" "$SUB_PORT" "$ACME_HTTP_PORT" | sort -u | wc -l) == 3 ]] ||
    die "VLESS_PORT, SUB_PORT and ACME_HTTP_PORT must be different tcp ports"
  [[ -n $(users_active) ]] || die "no users, run: ./vpn.sh init"

  [[ -s $CERT ]] && HY2=true || HY2=false
  # Missing RU lists only; the timer refreshes them daily
  rule_sets_update 1000000
  mkdir -p "$OUT/sub"
  chmod 700 "$OUT"
  render_jq templates/hub.jq "$OUT/sing-box.json" sing-box \
    --argjson users "$(users_json)" --argjson routes "$(exit_routes_json)" \
    --argjson rule_sets "$(rule_sets_json)" --argjson host_ips "$(host_ips_json)" --argjson hy2 "$HY2"
  render_file templates/Caddyfile "$OUT/Caddyfile" caddy

  # Per-user subscription and import page; drop pages of removed users
  local name uuid hy_user hy_pass token exp tokens=" "
  while read -r name uuid hy_user hy_pass token exp; do
    user_vars "$uuid" "$hy_user" "$hy_pass" "$token"
    mkdir -p "$OUT/sub/$token"
    render_file templates/sub.html "$OUT/sub/$token/index.html"
    write_file "$OUT/sub/$token/sub" "$(printf '%s\n' "$VLESS_LINK" "$HY2_LINK" | base64 -w0)"
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
