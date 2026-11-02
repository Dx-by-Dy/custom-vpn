# shellcheck shell=bash
# Ports, starting the containers, health check; sourced by vpn.sh

# REALITY contacts its target on every handshake; sites sometimes block server IPs.
# Ask the target the way sing-box does: SNI REALITY_SNI at REALITY_TARGET.
reality_target_ok() {
  curl -s -o /dev/null -m 8 --connect-to "$REALITY_SNI:443:$REALITY_TARGET" "https://$REALITY_SNI/"
}


# Sockets on non-loopback addresses: "proto port pid process"
listeners() {
  ss -Hlntup 2>/dev/null | awk '{
    port = addr = $5
    sub(/.*:/, "", port)
    sub(/:[^:]*$/, "", addr)
    if (addr ~ /^127\.|^\[::1\]|%lo$/) next
    pid = proc = "?"
    if (match($0, /\("[^"]+",pid=[0-9]+/)) {
      split(substr($0, RSTART + 2, RLENGTH - 2), a, "\",pid=")
      proc = a[1]; pid = a[2]
    }
    print $1, port, pid, proc
  }' | sort -u
}

# Host PIDs of this stack's containers
our_pids() {
  local ids
  ids=$("$DOCKER" compose ps -q 2>/dev/null || true)
  [[ -z $ids ]] || "$DOCKER" inspect -f '{{.State.Pid}}' $ids
}

# Ports this stack listens on: "port/proto description"
vpn_ports() {
  echo "$VLESS_PORT/tcp sing-box (VLESS REALITY)"
  [[ $ROLE == hub ]] || return 0
  echo "$HYSTERIA_PORT/udp sing-box (hysteria)"
  echo "$SUB_PORT/tcp caddy (subscription)"
  echo "$SUB_PORT/udp caddy (subscription, HTTP/3)"
  echo "$ACME_HTTP_PORT/tcp caddy (Let's Encrypt HTTP-01)"
}

# nginx config that owns VLESS_PORT and passes REALITY_SNI on to sing-box on
# VLESS_LISTEN, DOMAIN to caddy (its own certificate, 404 but for subscriptions;
# otherwise a probe of DOMAIN:443 would get a site's certificate), everything
# else to the sites (moved to a local port)
sni_proxy_snippet() {
  cat <<EOF
      # /etc/nginx/nginx.conf, top level (needs libnginx-mod-stream):
      stream {
          # by SNI: REALITY_SNI -> sing-box, DOMAIN -> caddy, everything else -> the sites
          map \$ssl_preread_server_name \$sni_backend {
              $REALITY_SNI 127.0.0.1:4441;
              $DOMAIN 127.0.0.1:4442;
              default 127.0.0.1:4443;
          }
          server {
              listen $VLESS_PORT;
              listen [::]:$VLESS_PORT;
              ssl_preread on;
              proxy_pass \$sni_backend;
              # the sites see the real client address
              proxy_protocol on;
          }
          # sing-box and caddy here don't read the PROXY protocol header: drop it
          server {
              listen 127.0.0.1:4441 proxy_protocol;
              proxy_pass ${VLESS_LISTEN_HOST/#::/127.0.0.1}:$VLESS_LISTEN_PORT;
          }
          server {
              listen 127.0.0.1:4442 proxy_protocol;
              proxy_pass 127.0.0.1:$SUB_PORT;
          }
      }
      # each site: instead of "listen 443 ssl" / "listen [::]:443 ssl":
          listen 127.0.0.1:4443 ssl proxy_protocol;
          set_real_ip_from 127.0.0.1;
          real_ip_header proxy_protocol;
EOF
}

# nginx config that hands Let's Encrypt HTTP-01 requests to caddy on ACME_HTTP_PORT
acme_proxy_snippet() {
  local port=$ACME_HTTP_PORT
  [[ $port == 80 ]] && port=8880
  cat <<EOF
      server {
          listen 80;
          listen [::]:80;
          server_name $DOMAIN;
          location /.well-known/acme-challenge/ {
              proxy_pass http://127.0.0.1:$port;
              proxy_set_header Host \$host;
          }
      }
EOF
}

# What to do when a port is taken
port_hint() {
  case $1 in
    "$ACME_HTTP_PORT/tcp")
      if [[ $ACME_HTTP_PORT == 80 ]]; then
        echo "    Let's Encrypt only checks port 80. If a web server owns it, keep it there:"
        echo "    set ACME_HTTP_PORT=8880 in $ENV_FILE and make it pass the checks to caddy, e.g. nginx:"
        acme_proxy_snippet
        echo "    (or just the location block inside an existing server for $DOMAIN)"
      else
        echo "    set ACME_HTTP_PORT to another free local port and point the port-80 proxy at it"
      fi
      ;;
    "$VLESS_PORT/tcp")
      echo "    another HTTPS server? Set VLESS_PORT to a free port (REALITY off 443 looks less"
      echo "    natural), or let nginx pass VLESS on by SNI: VLESS_LISTEN=127.0.0.1:8444 in $ENV_FILE and"
      VLESS_LISTEN_HOST=127.0.0.1 VLESS_LISTEN_PORT=8444 sni_proxy_snippet
      ;;
    "$HYSTERIA_PORT/udp")
      echo "    set HYSTERIA_PORT to any free UDP port; clients get it on the next subscription refresh"
      ;;
    "$SUB_PORT/tcp")
      echo "    set SUB_PORT to a free port; the port is part of subscription links,"
      echo "    so every user has to import the subscription again"
      ;;
  esac
}

# Fail if a port we need is held by something other than our containers
check_ports() {
  local ours all need desc proto port lport pid proc busy=()
  ours=" $(our_pids | tr '\n' ' ') "
  all=$(listeners)
  while read -r need desc; do
    port=${need%/*} proto=${need#*/}
    [[ $need == "$SUB_PORT/udp" ]] && continue # optional, caddy works without HTTP/3
    # VLESS_LISTEN: VLESS_PORT belongs to the proxy in front of sing-box
    [[ $need == "$VLESS_PORT/tcp" && -n ${VLESS_LISTEN:-} ]] && continue
    while read -r p lport pid proc; do
      [[ $p == "$proto" && $lport == "$port" && $ours != *" $pid "* ]] || continue
      busy+=("$need is taken by $proc (pid $pid), needed for $desc")
      busy+=("$(port_hint "$need")")
      break
    done <<<"$all"
  done < <(vpn_ports)
  ((${#busy[@]} == 0)) && return
  printf '%s\n' "ports are busy:" "${busy[@]}" >&2
  if [[ $EUID -ne 0 ]]; then
    warn "not root, can't see which processes own the ports; continuing"
    return
  fi
  die "nothing started"
}

# Let's Encrypt validates via http://DOMAIN:80/.well-known/acme-challenge/...; caddy
# answers "ok" on a secret path there, so we can see that port 80 really reaches it
# (directly or through a proxy) long before a renewal would fail.
acme_path_ok() {
  local i
  for i in 1 2 3 4 5; do
    [[ $(curl -s -m 5 --resolve "$DOMAIN:80:127.0.0.1" \
      "http://$DOMAIN/.well-known/acme-challenge/$ACME_CHECK_TOKEN" 2>/dev/null) == ok ]] && return 0
    sleep 2
  done
  return 1
}

acme_path_warning() {
  warn "port 80 doesn't reach caddy: Let's Encrypt can't renew the certificate for $DOMAIN"
  if [[ $ACME_HTTP_PORT == 80 ]]; then
    echo "    caddy should own 80/tcp; see what holds it: ss -ltnp 'sport = :80'" >&2
  else
    echo "    the web server on port 80 must pass ACME checks to caddy on $ACME_HTTP_PORT, e.g. nginx:" >&2
    acme_proxy_snippet >&2
  fi
}

preflight() {
  local resolved public
  # a client only listens on CLIENT_LISTEN; sing-box fails clearly if it's taken
  [[ $ROLE != client ]] || return 0
  # Repeated ACME failures hit Let's Encrypt rate limits
  if [[ $ROLE == hub ]]; then
    resolved=$(getent ahostsv4 "$DOMAIN" | awk 'NR==1 {print $1}' || true)
    public=$(curl -4 -fsS -m 5 https://ifconfig.me 2>/dev/null || true)
    if [[ -z $resolved ]]; then
      warn "$DOMAIN doesn't resolve, caddy won't get a certificate"
    elif [[ -n $public && $resolved != "$public" ]]; then
      warn "$DOMAIN -> $resolved, but this server is $public"
    fi
  fi
  reality_target_ok ||
    warn "this server can't reach $REALITY_TARGET as https://$REALITY_SNI/: VLESS won't work, check REALITY_SNI / REALITY_TARGET"
  check_ports
}

cmd_up() {
  local running restart=() svc
  # control: a change is saved; `control publish` sends it to the hubs
  if [[ $(env_role) == control ]]; then
    load_env
    control_saved
    return
  fi
  running=$("$DOCKER" compose ps --services --status running 2>/dev/null || true)
  CHANGED=()
  cmd_render
  preflight
  "$DOCKER" compose up -d --remove-orphans
  # compose doesn't notice changed config files; restart what was already running
  for svc in $(printf '%s\n' "${CHANGED[@]}" | sort -u); do
    grep -qx "$svc" <<<"$running" && restart+=("$svc")
  done
  ((${#restart[@]} == 0)) || "$DOCKER" compose restart "${restart[@]}"
  [[ $ROLE != hub ]] || $HY2 || hy2_wait_cert
  "$DOCKER" compose ps
  [[ $ROLE != hub ]] || acme_path_ok || acme_path_warning
}

# First start: caddy gets the certificate in a minute or so, then hysteria can start
hy2_wait_cert() {
  local i
  info "waiting for caddy to get the certificate for $DOMAIN (hysteria starts after it, VLESS already works)"
  for ((i = 0; i < 36; i++)); do
    [[ -s $CERT ]] && break
    sleep 5
  done
  if [[ ! -s $CERT ]]; then
    warn "no certificate for $DOMAIN yet, hysteria is off; see ./vpn.sh hub logs, then run ./vpn.sh hub up"
    return
  fi
  CHANGED=()
  cmd_render
  "$DOCKER" compose restart sing-box
}

# Health check for people and for vpn-maintenance.timer (non-zero exit = problem)
cmd_check() {
  if [[ $(env_role) == control ]]; then
    cmd_control_check
    return
  fi
  load_env
  local failed=0 svc running services=sing-box lines=()
  report() { printf '%-12s %s\n' "$1" "$2"; lines+=("$1 $2"); [[ $2 == ok* ]] || failed=1; }

  [[ $ROLE != hub ]] || services+=" caddy"
  running=$("$DOCKER" compose ps --services --status running 2>/dev/null || true)
  for svc in $services; do
    grep -qx "$svc" <<<"$running" && continue
    report containers "FAIL: $svc is not running"
  done
  [[ $failed == 1 ]] || report containers "ok"
  if [[ $ROLE == client ]]; then
    check_client
    return $failed
  fi

  [[ $ROLE == exit ]] || check_hub_cert
  [[ $ROLE == exit ]] || check_control
  if reality_target_ok; then
    report reality "ok ($REALITY_SNI via $REALITY_TARGET)"
  else
    report reality "FAIL: can't reach $REALITY_SNI via $REALITY_TARGET, VLESS is down"
  fi
  # Through the proxy in front: only sing-box (REALITY passes the handshake on to
  # the target) answers SNI REALITY_SNI with a valid certificate, a site wouldn't;
  # SNI DOMAIN gets caddy (its certificate, 404), not a site's certificate
  if [[ -n ${VLESS_LISTEN:-} ]]; then
    if ! curl -s -o /dev/null -m 8 --connect-to "$REALITY_SNI:443:127.0.0.1:$VLESS_PORT" "https://$REALITY_SNI/"; then
      report sni-proxy "FAIL: $REALITY_SNI on $VLESS_PORT doesn't reach sing-box on $VLESS_LISTEN"
    elif [[ $(curl -s -o /dev/null -m 8 -w '%{http_code}' --connect-to "$DOMAIN:443:127.0.0.1:$VLESS_PORT" "https://$DOMAIN/") != 404 ]]; then
      report sni-proxy "FAIL: $DOMAIN on $VLESS_PORT doesn't reach caddy (a site's certificate?): map it to caddy, see the 443/tcp section of docs/hub.md"
    else
      report sni-proxy "ok ($VLESS_PORT passes $REALITY_SNI to sing-box, $DOMAIN to caddy)"
    fi
  fi
  if [[ $ROLE == hub ]]; then check_routes; else check_egress; fi
  # for `control check`
  [[ $ROLE != hub ]] || hub_status_snapshot
  [[ $ROLE != hub ]] || hub_status check "$(printf '%s\n' "${lines[@]}" |
    jq -Rn --arg at "$(date -u +%FT%TZ)" --argjson failed "$failed" '{at: $at, failed: ($failed == 1), lines: [inputs]}')"
  return $failed
}

# Certificate, hysteria and the Let's Encrypt path; uses report from cmd_check
check_hub_cert() {
  local days
  if [[ ! -f $CERT ]]; then
    report certificate "FAIL: no certificate yet ($CERT)"
  elif command -v openssl >/dev/null; then
    days=$((($(date -d "$(openssl x509 -enddate -noout -in "$CERT" | cut -d= -f2)" +%s) - $(date +%s)) / 86400))
    # caddy renews 30 days ahead, so less than 14 means renewals have been failing
    ((days >= 14)) && report certificate "ok ($days days left)" || report certificate "FAIL: expires in $days days"
  fi

  # Configs rendered before the certificate came have no hysteria
  if [[ -f $CERT ]] && ! jq -e '.inbounds | any(.type == "hysteria2")' "$OUT/sing-box.json" >/dev/null 2>&1; then
    report hysteria "FAIL: off (no certificate when configs were rendered), run: ./vpn.sh hub up"
  fi

  if acme_path_ok; then
    report acme "ok (port 80 reaches caddy)"
  else
    report acme "FAIL: port 80 doesn't reach caddy, renewals will fail"
    acme_path_warning 2>&1 | tail -n +2
  fi
}
