# shellcheck shell=bash
# ROLE=exit: hubs connect here and leave through one of EXIT_IPS; sourced by vpn.sh

# hubs.conf has one credential per hub and egress IP:
#   hub  egress_ip  uuid
# A hub picks the egress IP by the credential it connects with, so the exit
# knows nothing about the hub's users.
HUBS_FILE=hubs.conf
HUBS_HEADER='# hub  egress_ip  uuid'

hubs_init() { conf_init "$HUBS_FILE" "$HUBS_HEADER"; }
hubs_rows() { conf_rows "$HUBS_FILE"; }

hub_exists() { hubs_rows | awk -v n="$1" '$1 == n {f = 1} END {exit !f}'; }

# EXIT_IPS entries are NAME=IP (or just IP, named by itself). Hubs know the
# egress IPs by name only (routes EXIT/NAME), so an IP can be replaced here
# without touching any hub. Prints "name ip" per line.
exit_ip_pairs() {
  tr ', ' '\n\n' <<<"$EXIT_IPS" | sed '/^$/d' | awk -F= '{print $1, $NF}'
}

exit_ips() { exit_ip_pairs | awk '{print $2}'; }

exit_ip_pairs_json() { exit_ip_pairs | jq -Rn '[inputs | split(" ") | {name: .[0], ip: .[1]}]'; }

# Egress IPs as "name=ip ..." for messages
exit_ips_shown() { exit_ip_pairs | awk '{printf "%s%s", (NR > 1 ? " " : ""), ($1 == $2 ? $2 : $1 "=" $2)}'; }

# Public IPv4 addresses of this host, one per line
public_ipv4s() {
  ip -o -4 addr show scope global | awk '{split($4, a, "/"); print a[1]}' |
    grep -vE '^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.)' || true
}

# init for ROLE=exit: egress IPs, the local check secret, no users
exit_init() {
  if [[ -z ${EXIT_IPS:-} ]]; then
    local ips
    ips=$(public_ipv4s | awk '{printf "%sip%d=%s", (NR > 1 ? "," : ""), NR, $0}')
    [[ -n $ips ]] || die "no public IPv4 address on this host: set EXIT_IPS in $ENV_FILE"
    set_var EXIT_IPS "$ips"
    info "egress IPs: $ips (EXIT_IPS in $ENV_FILE)"
  fi
  hubs_init
  info "keys are in $ENV_FILE, hubs in $HUBS_FILE"
}

# Credentials of the current egress IPs as JSON for templates/exit.jq
hubs_json() {
  hubs_rows | jq -Rn --arg ips "$(exit_ips | paste -sd,)" '[inputs | [splits("[ \t]+")]
    | select(.[1] as $ip | $ips | split(",") | any(. == $ip))
    | {name: "\(.[0])@\(.[1])", uuid: .[2], ip: .[1]}]'
}

render_exit() {
  local name ip have
  [[ -n $(exit_ips) ]] || die "EXIT_IPS is empty, run: ./vpn.sh exit init"
  # sing-box can't bind to an address the host doesn't have: connections would just fail
  have=" $(ip -o -4 addr show | awk '{split($4, a, "/"); print a[1]}' | tr '\n' ' ') "
  while read -r name ip; do
    [[ $name =~ ^[a-z0-9_.-]{1,32}$ ]] || die "EXIT_IPS: name $name must be 1-32 chars of a-z, 0-9, _, . and -"
    [[ $have == *" $ip "* ]] || die "EXIT_IPS: $ip is not an address of this host"
  done < <(exit_ip_pairs)
  [[ -z $(exit_ip_pairs | awk '{print $1}' | sort | uniq -d) && -z $(exit_ips | sort | uniq -d) ]] ||
    die "EXIT_IPS: names and IPs must be unique"
  mkdir -p "$OUT"
  chmod 700 "$OUT"
  render_jq templates/exit.jq "$OUT/sing-box.json" sing-box --argjson hubs "$(hubs_json)" \
    --argjson ips "$(exit_ips | jq -Rn '[inputs]')" --argjson host_ips "$(host_ips_json)"
  check sing-box -v "$PWD/$OUT/sing-box.json:/c.json:ro,z" "$SINGBOX_IMAGE" check -c /c.json
}

# Give hub NAME a credential for every egress IP it has none for yet
hub_fill() {
  local name=$1 ip
  for ip in $(exit_ips); do
    if ! hubs_rows | awk -v n="$name" -v ip="$ip" '$1 == n && $2 == ip {f = 1} END {exit !f}'; then
      echo "$name $ip $(cat /proc/sys/kernel/random/uuid)" >>"$HUBS_FILE"
    fi
  done
}

# Everything a hub needs to use this exit, as one line: egress IPs with their
# names (the hub's routes) and the hub's credential for each
hub_token() {
  local name=$1
  hubs_rows | jq -Rn --arg name "$name" --argjson pairs "$(exit_ip_pairs_json)" \
    --arg address "${EXIT_ADDRESS:-$(exit_ips | head -1)}" --argjson port "$VLESS_PORT" \
    --arg sni "$REALITY_SNI" --arg pbk "$REALITY_PUBLIC_KEY" --arg sid "$REALITY_SHORT_ID" '
    [inputs | [splits("[ \t]+")] | select(.[0] == $name)] as $rows
    | {v: 1, address: $address, port: $port, sni: $sni, public_key: $pbk, short_id: $sid,
       ips: [$pairs[] as $p | $rows[] | select(.[1] == $p.ip) | {name: $p.name, ip: $p.ip, uuid: .[2]}]}' |
    jq -c . | base64 -w0 | sed 's/^/cvpn-exit:/'
}

hub_print_token() {
  local name=$1
  echo
  echo "[$name] egress IPs: $(exit_ips_shown)"
  echo "  in control:  ./vpn.sh control exit add EXIT_NAME '$(hub_token "$name")'"
  echo "  (on a stand-alone hub: ./vpn.sh hub exit add EXIT_NAME ...)"
  echo "  (routes there: EXIT_NAME/$(exit_ip_pairs | awk '{print $1}' | paste -sd' ' | sed 's| | EXIT_NAME/|g'))"
  echo
}

cmd_hub() {
  local action=${1:-} name=${2:-} before
  load_env
  if [[ $ROLE == control ]]; then
    cmd_control_hub "$@"
    return
  fi
  require_role exit "hub"
  case $action in
    add)
      check_name "$name" "hub name"
      hubs_init
      hub_exists "$name" && die "hub $name already exists (./vpn.sh exit hub token $name prints its token)"
      hub_fill "$name"
      cmd_up
      hub_print_token "$name"
      ;;
    token)
      # Also gives the hub credentials for egress IPs added to EXIT_IPS since
      check_name "$name" "hub name"
      hub_exists "$name" || die "no hub $name"
      before=$(hubs_rows)
      hub_fill "$name"
      [[ $(hubs_rows) == "$before" ]] || cmd_up
      hub_print_token "$name"
      ;;
    del)
      check_name "$name" "hub name"
      hub_exists "$name" || die "no hub $name"
      conf_rewrite "$HUBS_FILE" -v n="$name" '/^#/ || $1 != n'
      cmd_up
      info "hub $name removed, it can't connect anymore"
      ;;
    list)
      if [[ -z $(hubs_rows) ]]; then
        echo "No hubs yet. Add one: ./vpn.sh exit hub add NAME, then run the printed command in control."
        echo "Egress IPs: $(exit_ips_shown)"
        return
      fi
      hubs_rows | awk -v pairs="$(exit_ip_pairs | tr '\n' ',')" '
        BEGIN { n = split(pairs, p, ","); for (i = 1; i < n; i++) { split(p[i], f, " "); ipname[f[2]] = f[1] } }
        $2 in ipname {
          if (!($1 in seen)) order[++k] = $1
          seen[$1] = seen[$1] " " (ipname[$2] == $2 ? $2 : ipname[$2] "=" $2)
        }
        END {
          printf "%-20s %s\n", "HUB", "EGRESS IPS"
          for (i = 1; i <= k; i++) printf "%-20s%s\n", order[i], seen[order[i]]
        }'
      ;;
    *) die "usage: ./vpn.sh exit hub add|token|del|list [NAME]" ;;
  esac
}

# check for ROLE=exit: each egress IP is what the internet sees
check_egress() {
  local name ip seen
  while read -r name ip; do
    seen=$(via_check "check@$ip" "$IP_ECHO_URL")
    if [[ $seen == "$ip" ]]; then
      report egress "ok ($name: $ip)"
    else
      report egress "FAIL: traffic for $name ($ip) leaves $(leaves_as "$seen")"
    fi
  done < <(exit_ip_pairs)
}
