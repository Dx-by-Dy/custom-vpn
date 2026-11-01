# shellcheck shell=bash
# Snapshot delivery through DNS TXT records; sourced by vpn.sh
#
# Control writes the snapshot line under CONTROL_DOMAIN through the DNSmanager
# API (ISPsystem; dnsmanage of many Russian registrars and hosters):
#   v<VERSION>-<I>.CONTROL_DOMAIN  TXT  piece I of the line (DNS_PIECE chars)
#   head.CONTROL_DOMAIN            TXT  "cvpn1 v=VERSION n=PIECES sha256=HEX"
# The pieces go first and head last, once every name server of the zone
# answers with them, so a resolver never sees a head without its pieces. Hubs
# read head through several resolvers, then the pieces, and apply the line as
# `state apply` does: the signature and the version decide, DNS only carries it.
# Pieces of old versions are deleted once their successor is older than 2 TTL.
DNS_PIECE=1000
DNS_RESOLVERS_DEFAULT="system 77.88.8.8 1.1.1.1 8.8.8.8"
# How often hubs read head (vpn-sync.timer) and how long `check` tolerates not reading it
SYNC_EVERY=5min
SYNC_MAX_AGE=3600
SYNCED_FILE=$CONTROL_DIR/synced

# dns_txt NAME [RESOLVER]: the value of NAME's TXT record (its strings joined)
dns_txt() {
  local at=()
  [[ ${2:-system} == system ]] || at=("@$2")
  dig +short +time=3 +tries=2 TXT "$1" "${at[@]}" 2>/dev/null | grep -m1 '^"' | sed -E 's/" "//g; s/^"//; s/"$//' || true
}

sha256() { printf '%s' "$1" | sha256sum | cut -d' ' -f1; }

need_dig() { need_pkg dig "snapshots come through DNS" dnsutils bind-utils; }

# --- control: writing the records -------------------------------------------

dns_enabled() { [[ -n ${CONTROL_DOMAIN:-} ]]; }

dns_settings() {
  DNS_ZONE=${DNS_ZONE:-$CONTROL_DOMAIN}
  DNS_TTL=${DNS_TTL:-300}
  [[ -n ${DNS_API:-} && -n ${DNS_USER:-} && -n ${DNS_PASSWORD:-} ]] ||
    die "CONTROL_DOMAIN is set: set DNS_API, DNS_USER and DNS_PASSWORD in $ENV_FILE too"
  [[ $CONTROL_DOMAIN == "$DNS_ZONE" || $CONTROL_DOMAIN == *."$DNS_ZONE" ]] ||
    die "CONTROL_DOMAIN=$CONTROL_DOMAIN isn't in DNS_ZONE=$DNS_ZONE"
}

# dns_api FUNC [curl args]: the "doc" of DNSmanager's answer; dies on an error
dns_api() {
  local func=$1 out auth=()
  shift
  [[ -z ${DNS_AUTH:-} ]] || auth=(--data "auth=$DNS_AUTH")
  out=$(curl -sS -m 30 "$DNS_API" --data "out=json&func=$func" "${auth[@]}" "$@") ||
    die "DNS API $DNS_API: no answer"
  jq -e '.doc | type == "object"' <<<"$out" >/dev/null 2>&1 || die "DNS API $DNS_API: not a DNSmanager answer"
  ! jq -e '.doc.error' <<<"$out" >/dev/null ||
    die "DNS API $func: $(jq -r '.doc.error.msg["$"] // .doc.error["$type"] // "error"' <<<"$out")"
  jq -c .doc <<<"$out"
}

dns_login() {
  DNS_AUTH=
  # The password goes through stdin: not in the command line of curl
  DNS_AUTH=$(printf '%s' "$DNS_PASSWORD" |
    dns_api auth --data-urlencode "username=$DNS_USER" --data-urlencode password@- | jq -r '.auth["$"] // empty')
  [[ -n $DNS_AUTH ]] || die "DNS API: can't log in as $DNS_USER (DNS_USER / DNS_PASSWORD)"
}

# TXT records under CONTROL_DOMAIN: "LABEL<TAB>VALUE<TAB>KEY" (LABEL without the domain)
dns_records() {
  dns_api domain.record --data-urlencode "elid=$DNS_ZONE" | jq -r --arg d ".$CONTROL_DOMAIN." '
    .elem[]? | select(.rtype_hidden["$"] == "TXT" and (.name["$"] | endswith($d)))
    | [(.name["$"] | rtrimstr($d)), .value["$"], .rkey["$"]] | @tsv'
}

# dns_put LABEL VALUE [KEY]: create LABEL.CONTROL_DOMAIN, or change the record KEY
dns_put() {
  local name=$1.$CONTROL_DOMAIN key=()
  name=${name%"$DNS_ZONE"}
  [[ -z ${3:-} ]] || key=(--data-urlencode "elid=$3")
  dns_api domain.record.edit --data-urlencode "plid=$DNS_ZONE" --data-urlencode "name=${name%.}" \
    --data "rtype=txt&sok=ok" --data-urlencode "ttl=$DNS_TTL" --data-urlencode "value=$2" "${key[@]}" >/dev/null
}

dns_delete() {
  local keys
  keys=$(paste -sd, - | sed 's/,/, /g')
  [[ -z $keys ]] || dns_api domain.record.delete --data-urlencode "plid=$DNS_ZONE" --data-urlencode "elid=$keys" >/dev/null
}

# dns_wait LABEL VALUE ...: until every name server of the zone answers with these
dns_wait() {
  local servers ns deadline=$((SECONDS + 180)) want=("$@") i
  servers=$(dig +short NS "$DNS_ZONE" | sed 's/\.$//')
  [[ -n $servers ]] || die "no NS records for $DNS_ZONE"
  for ns in $servers; do
    for ((i = 0; i < ${#want[@]}; i += 2)); do
      until [[ $(dns_txt "${want[i]}.$CONTROL_DOMAIN" "$ns") == "${want[i + 1]}" ]]; do
        ((SECONDS < deadline)) || return 1
        sleep 3
      done
    done
  done
}

# Put STATE_FILE (snapshot VERSION) into DNS; part of control's publish
dns_publish() {
  local version=$1 line pieces n i head records old_head now keys
  dns_settings
  need_dig
  line=$(<"$STATE_FILE")
  n=$(((${#line} + DNS_PIECE - 1) / DNS_PIECE))
  head="cvpn1 v=$version n=$n sha256=$(sha256 "$line")"

  dns_login
  records=$(dns_records)
  pieces=()
  for ((i = 0; i < n; i++)); do
    dns_put "v$version-$i" "${line:i*DNS_PIECE:DNS_PIECE}"
    pieces+=("v$version-$i" "${line:i*DNS_PIECE:DNS_PIECE}")
  done
  dns_wait "${pieces[@]}" ||
    die "the name servers of $DNS_ZONE don't show v$version yet; head is unchanged, run ./vpn.sh publish again"

  old_head=$(awk -F'\t' '$1 == "head" {print $3; exit}' <<<"$records")
  dns_put head "$head" "$old_head"
  dns_wait head "$head" || warn "the name servers of $DNS_ZONE don't show the new head yet"

  # Old versions: once their successor is older than 2 TTL, no cached head
  # points to them. Versions above this one aren't control's (they only grow)
  now=$(date +%s)
  keys=$(awk -F'\t' -v cur="$version" -v now="$now" -v ttl="$DNS_TTL" '
    $1 == "head" && seen_head++ {print $3}
    match($1, /^v[0-9]+-/) {v = substr($1, 2, RLENGTH - 2) + 0; if (v != cur) {key[v] = key[v] $3 "\n"; vs[v]}}
    END {
      for (v in vs) {
        next_v = cur
        for (w in vs) if (w + 0 > v + 0 && w + 0 < next_v + 0) next_v = w
        if (v + 0 > cur + 0 || now - next_v > 2 * ttl) printf "%s", key[v]
      }
    }' <<<"$records")
  dns_delete <<<"$keys"
  info "in DNS: head.$CONTROL_DOMAIN -> v$version ($n TXT records); hubs take it within ${SYNC_EVERY%min} min + TTL ${DNS_TTL}s"
}

# --- hub: reading them -------------------------------------------------------

cmd_sync() {
  local applied head v n sha line i piece r answered=false newest=0
  require_role hub sync
  managed || die "this hub isn't managed by control"
  [[ -n ${CONTROL_DOMAIN:-} ]] || die "no CONTROL_DOMAIN: snapshots come by ssh only (./vpn.sh state apply)"
  need_dig
  applied=$(cat "$CONTROL_DIR/version" 2>/dev/null || echo 0)
  for r in ${CONTROL_RESOLVERS:-$DNS_RESOLVERS_DEFAULT}; do
    head=$(dns_txt "head.$CONTROL_DOMAIN" "$r")
    [[ $head =~ ^cvpn1\ v=([0-9]+)\ n=([0-9]+)\ sha256=([0-9a-f]{64})$ ]] || continue
    answered=true
    v=${BASH_REMATCH[1]} n=${BASH_REMATCH[2]} sha=${BASH_REMATCH[3]}
    ((v > newest)) && newest=$v
    ((v > applied && n > 0 && n <= 500)) || continue
    line=
    for ((i = 0; i < n; i++)); do
      piece=$(dns_txt "v$v-$i.$CONTROL_DOMAIN" "$r")
      [[ -n $piece ]] || break
      line+=$piece
    done
    if [[ $(sha256 "$line") != "$sha" ]]; then
      warn "v$v through $r: pieces are missing or don't match head"
      continue
    fi
    touch "$SYNCED_FILE"
    state_apply - <<<"$line"
    return
  done
  $answered || die "can't read head.$CONTROL_DOMAIN through any of: ${CONTROL_RESOLVERS:-$DNS_RESOLVERS_DEFAULT}"
  ((newest <= applied)) || die "v$newest is in DNS, but no resolver gave all its pieces"
  touch "$SYNCED_FILE"
  info "up to date: v$applied"
}

install_sync_timer() {
  if [[ $EUID -ne 0 ]] || ! command -v systemctl >/dev/null; then
    warn "not root or no systemd: run ./vpn.sh sync every few minutes yourself (e.g. from cron)"
    return
  fi
  cat >/etc/systemd/system/vpn-sync.service <<EOF
[Unit]
Description=VPN: apply control's snapshot from DNS

[Service]
Type=oneshot
ExecStart=$PWD/vpn.sh -y sync
EOF
  cat >/etc/systemd/system/vpn-sync.timer <<EOF
[Unit]
Description=Read control's snapshot from DNS every $SYNC_EVERY

[Timer]
OnBootSec=1min
OnUnitActiveSec=$SYNC_EVERY
RandomizedDelaySec=30

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable -q --now vpn-sync.timer
  info "vpn-sync.timer enabled: reads head.$CONTROL_DOMAIN every $SYNC_EVERY"
}

remove_sync_timer() {
  [[ -f /etc/systemd/system/vpn-sync.timer ]] || return 0
  systemctl disable -q --now vpn-sync.timer 2>/dev/null || true
  rm -f /etc/systemd/system/vpn-sync.{timer,service}
  systemctl daemon-reload
  info "vpn-sync.timer removed"
}

# check on a managed hub; uses report from cmd_check
check_sync() {
  local age
  [[ -n ${CONTROL_DOMAIN:-} ]] || return 0
  if [[ ! -f $SYNCED_FILE ]]; then
    report dns "FAIL: head.$CONTROL_DOMAIN not read yet (./vpn.sh sync)"
    return
  fi
  age=$(($(date +%s) - $(date -r "$SYNCED_FILE" +%s)))
  if ((age <= SYNC_MAX_AGE)); then
    report dns "ok (head.$CONTROL_DOMAIN read $((age / 60)) min ago)"
  else
    report dns "FAIL: head.$CONTROL_DOMAIN unreadable for $((age / 60)) min (./vpn.sh sync)"
  fi
}
