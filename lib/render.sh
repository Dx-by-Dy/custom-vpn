# shellcheck shell=bash
# Rendering configs into generated/; sourced by vpn.sh

# This host's own addresses as a JSON list of /32 and /128: clients must not reach
# services on it (they would bypass the firewall, traffic to itself goes over lo)
host_ips_json() {
  ip -o addr show scope global 2>/dev/null |
    awk '{split($4, a, "/"); print a[1] (index(a[1], ":") ? "/128" : "/32")}' | jq -Rn '[inputs]'
}

# "user route,route..." of every active user (routes that exist, else none)
user_route_lines() { user_routes_json | jq -r 'to_entries[] | "\(.key) \(.value | join(","))"'; }

# Valid credentials as JSON for the sing-box template: one entry per credential
# and route of its user, {name, uuid, hy2, route}. The first route uses the
# credential itself, the others route_cred of it (named "name@route")
users_json() {
  local name uuid hy_user hy_pass token exp n r i list=() cred=()
  local -A routes=()
  while read -r name r; do routes[$name]=$r; done < <(user_route_lines)
  while read -r name uuid hy_user hy_pass token exp; do
    [[ $exp == - ]] && n=$name || n=$name~$exp
    IFS=, read -ra list <<<"${routes[$name]:-none}"
    for i in "${!list[@]}"; do
      r=${list[i]}
      if ((i == 0)); then
        echo "$n $uuid $hy_user:$hy_pass $r"
      else
        read -ra cred < <(route_cred "$uuid" "$hy_user" "$hy_pass" "$r")
        echo "$n@$r ${cred[0]} ${cred[1]}:${cred[2]} $r"
      fi
    done
  done < <(users_valid) | jq -Rn '[inputs | split(" ") | {name: .[0], uuid: .[1], hy2: .[2], route: .[3]}]'
}

# hysteria needs caddy's certificate; without it sing-box runs VLESS only
HY2=false

# Caddyfile headers of the route subscriptions /<token>/<route>/sub: the app
# shows each as a profile "SUB_NAME · route"
sub_route_headers() {
  local r i=0
  while read -r r; do
    i=$((i + 1))
    printf '\t@route%d path_regexp ^/[0-9a-f]+/%s/sub$\n' "$i" "$(route_slug "$r" | sed 's/\./\\./g')"
    printf '\theader @route%d {\n\t\tContent-Type "text/plain; charset=utf-8"\n\t\tCache-Control no-store\n' "$i"
    printf '\t\tprofile-title "base64:%s"\n\t\tprofile-update-interval 12\n\t}\n' "$(printf '%s · %s' "$SUB_NAME" "$r" | base64 -w0)"
  done < <(route_names)
}

# sub_page_buttons URL NAME: import buttons of one subscription
sub_page_buttons() {
  local url=$1 enc name
  enc=$(urlencode "$1")
  name=$(urlencode "$2")
  cat <<EOF
  <a class="btn" href="hiddify://import/$url#$name">Hiddify <span>Android, iOS, PC</span></a>
  <a class="btn" href="sn://subscription?url=$enc&amp;name=$name">NekoBox <span>Android</span></a>
  <a class="btn" href="v2box://install-sub?url=$enc&amp;name=$name">V2Box <span>iOS, macOS</span></a>
  <button data-url="$url">Скопировать ссылку <span>для других приложений</span></button>
  <code>$url</code>
EOF
}

# What a route does with Russian sites, where it isn't the usual, for people
route_note() {
  case $1 in
    local) echo "всё с российского адреса, и зарубежные сайты тоже" ;;
    *+ru) echo "всё через зарубежный выход, и российские сайты тоже" ;;
  esac
}

# sub_page_body TOKEN ROUTE...: the import page: one subscription, or one per route
sub_page_body() {
  local token=$1 r note first=true
  shift
  if (($# == 1)); then
    echo '  <p>Нажми на свое приложение — подписка добавится сама.</p>'
    sub_page_buttons "$SUB_URL" "$SUB_NAME"
    return
  fi
  echo '  <p>Каждый выход — отдельная подписка: добавь нужные и переключайся между ними в приложении.</p>'
  for r in "$@"; do
    note=$(route_note "$r")
    if $first; then note="основной${note:+, $note}"; fi
    echo "  <h2>$r${note:+ <span>$note</span>}</h2>"
    first=false
    sub_page_buttons "https://$DOMAIN:$SUB_PORT/$token/$(route_slug "$r")/sub" "$SUB_NAME · $r"
  done
}

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

# sub_links UUID HY_USER HY_PASS [LABEL]: the user's links for client apps on
# every hub of SUB_HUBS, named LABEL-HUB-reality / -hy2 (LABEL: SUB_NAME; one
# hub: LABEL-reality, as before)
sub_links() {
  jq -r --arg uuid "$1" --arg hy "$2:$3" --arg sub "${4:-$SUB_NAME}" '
    (length > 1) as $many | .[] |
    ($sub + (if $many then "-" + .name else "" end)) as $label |
    "vless://\($uuid)@\(.domain):\(.vless_port)?encryption=none&flow=xtls-rprx-vision&security=reality&sni=\(.sni)&fp=chrome&pbk=\(.public_key)&sid=\(.short_id)&type=tcp#\($label + "-reality" | @uri)",
    "hysteria2://\($hy)@\(.domain):\(.hysteria_port)/?sni=\(.domain)#\($label + "-hy2" | @uri)"' <<<"$SUB_HUBS"
}

# sub_outbounds UUID HY_USER HY_PASS [LABEL]: the same as sing-box outbounds (for ROLE=client)
sub_outbounds() {
  jq --arg uuid "$1" --arg hy "$2:$3" --arg sub "${4:-$SUB_NAME}" '
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
    --argjson rule_sets "$(rule_sets_json)" --argjson host_ips "$(host_ips_json)" --argjson hy2 "$HY2" \
    --argjson sites "$(sites_json)"
  SUB_ROUTE_HEADERS=$(sub_route_headers)
  render_file templates/Caddyfile "$OUT/Caddyfile" caddy

  # Per user: a subscription of every route (every hub, /<token>/<route>/sub and
  # sing-box.json), the first route also at /<token>/sub, and the import page;
  # drop pages of removed users and routes
  local name uuid hy_user hy_pass token exp tokens=" " r i slug label keep links obs list=() cred=() dir
  local -A routes=()
  while read -r name r; do routes[$name]=$r; done < <(user_route_lines)
  SUB_HUBS=$(sub_hubs_json)
  while read -r name uuid hy_user hy_pass token exp; do
    IFS=, read -ra list <<<"${routes[$name]:-none}"
    user_vars "$uuid" "$hy_user" "$hy_pass" "$token"
    mkdir -p "$OUT/sub/$token"
    SUB_BODY=$(sub_page_body "$token" "${list[@]}")
    render_file templates/sub.html "$OUT/sub/$token/index.html"
    keep=" "
    for i in "${!list[@]}"; do
      r=${list[i]} slug=$(route_slug "${list[i]}")
      if ((i == 0)); then cred=("$uuid" "$hy_user" "$hy_pass"); else read -ra cred < <(route_cred "$uuid" "$hy_user" "$hy_pass" "$r"); fi
      label=$SUB_NAME
      ((${#list[@]} == 1)) || label="$SUB_NAME $r"
      links=$(sub_links "${cred[@]}" "$label" | base64 -w0)
      obs=$(sub_outbounds "${cred[@]}" "$label")
      if ((i == 0)); then
        write_file "$OUT/sub/$token/sub" "$links"
        write_file "$OUT/sub/$token/sing-box.json" "$obs"
      fi
      mkdir -p "$OUT/sub/$token/$slug"
      write_file "$OUT/sub/$token/$slug/sub" "$links"
      write_file "$OUT/sub/$token/$slug/sing-box.json" "$obs"
      keep+="$slug "
    done
    for dir in "$OUT/sub/$token"/*/; do
      [[ -d $dir ]] || continue
      dir=$(basename "$dir")
      [[ $keep == *" $dir "* ]] || rm -rf "${OUT:?}/sub/$token/$dir"
    done
    tokens+="$token "
  done < <(users_active)
  # the status for `control check` lives there too
  ! managed || tokens+="$(hub_status_token || true) "
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
