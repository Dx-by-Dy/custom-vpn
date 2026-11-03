#!/usr/bin/env bash
# Render the configs of every role with each jq and check that they come out
# byte for byte the same (and pass `sing-box check` / `caddy validate`, which
# render runs). Hubs run Ubuntu 24.04 with jq 1.7.1, laptops something newer:
# the templates and the jq programs in lib/ must work the same on both.
#
#   tests/templates.sh                               # this host's jq + jq 1.7.1
#   JQ_IMAGES="ghcr.io/jqlang/jq:1.7.1 ghcr.io/jqlang/jq:1.8.1" tests/templates.sh
#   KEEP=1 tests/templates.sh                        # keep the rendered fixtures to look at
#
# Roles: a stand-alone hub (users, a rotated credential, a group, routes via an
# exit, users with several routes, hysteria with a certificate), an exit, a client, and control publishing
# a snapshot that a second hub applies (its subscription then lists two hubs).
# The hub's real rules also run in sing-box, to see where each connection leaves.
# Needs docker or podman (DOCKER=podman), the sing-box and caddy images of
# .env.example, age, ssh-keygen and openssl. No network: everything is local.
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")/.."
REPO=$PWD
DOCKER=${DOCKER:-docker}
command -v "$DOCKER" >/dev/null || DOCKER=podman
JQ_IMAGES=${JQ_IMAGES:-ghcr.io/jqlang/jq:1.7.1}
for c in "$DOCKER" jq age age-keygen ssh-keygen openssl; do
  command -v "$c" >/dev/null || { echo "error: $c is needed" >&2; exit 1; }
done

WORK=$(mktemp -d)
SB_NAME=cvpn-test-$$
trap '"$DOCKER" rm -f "$SB_NAME" >/dev/null 2>&1 || true; if [[ -n ${KEEP:-} ]]; then echo "kept $WORK"; else rm -rf "$WORK"; fi' EXIT
mkdir -p "$WORK/bin" "$WORK/tmp"
export TMPDIR=$WORK/tmp
SINGBOX_IMAGE=$(sed -n 's/^SINGBOX_IMAGE=//p' .env.example)

step() { echo "== $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }
# setenv FILE KEY VALUE: KEY=VALUE in a .env (VALUE as the shell reads it)
setenv() { K=$2 V=$3 awk 'index($0, ENVIRON["K"] "=") == 1 {print ENVIRON["K"] "=" ENVIRON["V"]; f = 1; next} {print} END {if (!f) print ENVIRON["K"] "=" ENVIRON["V"]}' "$1" >"$1.n" && mv "$1.n" "$1"; }
# vpn ROLE_DIR JQ_BIN_DIR ARGS...: vpn.sh of a fixture with that jq first in PATH
vpn() { local dir=$1 bin=$2; shift 2; (cd "$dir" && PATH="$bin:$PATH" DOCKER="$WORK/bin/docker" ./vpn.sh -y "$@"); }

# docker for vpn.sh: `run` is real (sing-box / caddy checks), compose does nothing
cat >"$WORK/bin/docker" <<EOF
#!/usr/bin/env bash
[[ \$1 == compose ]] && exit 0
exec $DOCKER "\$@"
EOF
chmod +x "$WORK/bin/docker"

step "fixtures"
keys=$("$DOCKER" run --rm "$SINGBOX_IMAGE" generate reality-keypair)
PRIV=$(awk '/^PrivateKey/ {print $NF}' <<<"$keys")
PUB=$(awk '/^PublicKey/ {print $NF}' <<<"$keys")
BASE=$WORK/base
mkdir -p "$BASE"

# Minimal RU lists, compiled by sing-box itself
mkdir -p "$BASE/rule-sets"
echo '{"version": 3, "rules": [{"domain_suffix": ["ru", "su", "listed.example.com"]}]}' >"$BASE/rule-sets/geosite-ru.json"
echo '{"version": 3, "rules": [{"ip_cidr": ["5.8.0.0/16"]}]}' >"$BASE/rule-sets/geoip-ru.json"
for t in geosite-ru geoip-ru; do
  "$DOCKER" run --rm -v "$BASE/rule-sets:/r:z" "$SINGBOX_IMAGE" rule-set compile -o "/r/$t.srs" "/r/$t.json"
done

# fixture DIR ROLE [DOMAIN]: a copy of the code with a filled-in .env
fixture() {
  local dir=$1 role=$2 domain=${3:-}
  mkdir -p "$dir"
  cp -a "$REPO"/{vpn.sh,lib,templates,compose.yaml,.env.example} "$dir/"
  cp "$dir/.env.example" "$dir/.env"
  setenv "$dir/.env" ROLE "$role"
  setenv "$dir/.env" REALITY_PRIVATE_KEY "$PRIV"
  setenv "$dir/.env" REALITY_PUBLIC_KEY "$PUB"
  setenv "$dir/.env" REALITY_SHORT_ID 0123456789abcdef
  setenv "$dir/.env" CHECK_TOKEN 00112233445566778899aabbccddeeff
  setenv "$dir/.env" ACME_CHECK_TOKEN ffeeddccbbaa99887766554433221100
  [[ -z $domain ]] && return
  setenv "$dir/.env" DOMAIN "$domain"
  setenv "$dir/.env" SUB_NAME '"Test VPN & co"'
  mkdir -p "$dir/data/rule-sets"
  cp "$BASE"/rule-sets/*.srs "$dir/data/rule-sets/"
  # a certificate, so hysteria is in the config too
  local cert=$dir/data/caddy/caddy/certificates/acme-v02.api.letsencrypt.org-directory/$domain
  mkdir -p "$cert"
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 30 -subj "/CN=$domain" \
    -keyout "$cert/$domain.key" -out "$cert/$domain.crt" 2>/dev/null
}

USERS='# name  vless_uuid  hysteria_user  hysteria_pass  sub_token  expires
alice 11111111-1111-4111-8111-111111111111 alice-0a1b 0123456789abcdef0123456789abcdef a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1 -
bob 22222222-2222-4222-8222-222222222222 bob-0c2d 1123456789abcdef0123456789abcdef b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2 -
bob 33333333-3333-4333-8333-333333333333 bob-9f9f 2123456789abcdef0123456789abcdef - 4102444800
carol 44444444-4444-4444-8444-444444444444 carol-1e3f 3123456789abcdef0123456789abcdef c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3 -'

# The exit, and its token for the hubs
fixture "$BASE/exit" exit
setenv "$BASE/exit/.env" EXIT_IPS ip1=127.0.0.1
printf '# hub  egress_ip  uuid\nmain 127.0.0.1 55555555-5555-4555-8555-555555555555\n' >"$BASE/exit/hubs.conf"
EXIT_TOKEN=$(vpn "$BASE/exit" "" exit hub token main | grep -o 'cvpn-exit:[A-Za-z0-9+/=]*')
[[ -n $EXIT_TOKEN ]] || fail "no exit token"

# A stand-alone hub with routes
fixture "$BASE/hub" hub hub.test
setenv "$BASE/hub/.env" ROUTE_DEFAULT local
printf '%s\n' "$USERS" >"$BASE/hub/users.conf"
printf '# exit  token\ncz1 %s\n' "$EXIT_TOKEN" >"$BASE/hub/exits.conf"
# several routes: alice from her group, carol her own (the first is the main one)
printf '# group  route\nsales cz1/ip1,local\n' >"$BASE/hub/groups.conf"
# carol also has the route that sends RU through the exit
printf '# user  group  route\nalice sales -\nbob - none\ncarol - none,cz1/ip1,cz1/ip1+ru\n' >"$BASE/hub/routing.conf"
# Exceptions: a foreign name that goes from the hub, RU ones that go by the route
printf '# domain  hub|route\nkeep.example.com hub\nblocked.example.ru route\nlisted.example.com route\n' >"$BASE/hub/sites.conf"

# Control with the same scheme, a fake second hub and a real one (hub2)
fixture "$BASE/control" control
(cd "$BASE/control" && rm .env && ROLE=control ./vpn.sh control init >/dev/null 2>&1)
cp "$BASE"/hub/{users,exits,groups,routing,sites}.conf "$BASE/control/"
fixture "$BASE/hub2" hub hub2.test
HUB2_TOKEN=$(vpn "$BASE/hub2" "" hub control join | grep -o 'cvpn-hub:[A-Za-z0-9+/=]*')
[[ -n $HUB2_TOKEN ]] || fail "no hub2 token"
age-keygen -o "$BASE/hubx.key" 2>/dev/null
HUBX_TOKEN=cvpn-hub:$(jq -cn --arg pbk "$PUB" --arg r "$(age-keygen -y "$BASE/hubx.key")" \
  '{v: 1, domain: "hubx.test", vless_port: 443, hysteria_port: 443, sub_port: 8443, sni: "music.yandex.ru",
    public_key: $pbk, short_id: "fedcba9876543210", recipient: $r}' | base64 -w0)
printf '# hub  token\nhubx %s\n' "$HUBX_TOKEN" >"$BASE/control/hubs.conf"

# The client of alice, from the hub's subscription
fixture "$BASE/client" client
setenv "$BASE/client/.env" CLIENT_SUB '"http://127.0.0.1:9/a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1/sub"'

# What the hub's config must have (checked with this host's jq): a key per
# credential and route (alice 2, bob 1 + 1 rotated, carol 3), a subscription per
# route, a profile title per route in the Caddyfile
expect_hub() {
  local h=$1/generated
  [[ $(jq '[.inbounds[] | select(.type == "vless") | .users[]] | length' "$h/sing-box.json") == 7 ]] ||
    fail "vless users: $(jq -c '[.inbounds[] | select(.type == "vless") | .users[].name]' "$h/sing-box.json")"
  jq -e '.route.rules | any(.auth_user? // [] | index("carol@cz1/ip1")) and any(.auth_user? // [] | index("alice@local"))
    and any(.auth_user? // [] | index("carol@cz1/ip1+ru"))' \
    "$h/sing-box.json" >/dev/null || fail "no rules for the other routes of carol / alice"
  for f in sub sing-box.json none/sub cz1-ip1/sub cz1-ip1/sing-box.json cz1-ip1--ru/sub cz1-ip1--ru/sing-box.json; do
    [[ -s $h/sub/c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3/$f ]] || fail "carol has no $f"
  done
  [[ ! -e $h/sub/b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2/cz1-ip1 ]] || fail "bob has a route he doesn't have"
  cmp -s "$h/sub/c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3/sub" "$h/sub/c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3/none/sub" ||
    fail "carol's main subscription isn't her first route"
  [[ $(grep -c 'profile-title' "$h/Caddyfile") -ge 4 ]] || fail "no profile titles of the routes in the Caddyfile"
  base64 -d "$h/sub/c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3/cz1-ip1--ru/sub" | grep -q '^hysteria2://carol-1e3f+cz1-ip1--ru:' ||
    fail "the links of a +ru route aren't safe: $(base64 -d "$h/sub/c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3/cz1-ip1--ru/sub")"
  grep -q 'российские сайты тоже' "$h/sub/c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3/index.html" ||
    fail "the import page doesn't say what the +ru route does"
}

# Where the rules of the rendered hub config send a connection: real sing-box,
# with outbounds that lead nowhere (nothing leaves this host) and logging which
# one was used. A connection that got no outbound was refused by the hub.
routing_test() {
  local dir=$1 cfg=$WORK/routing.json port=$((21000 + $$ % 1000)) token=00112233445566778899aabbccddeeff n=0 failed=0
  jq --argjson port "$port" '
    .log.level = "warn"
    | .inbounds = [.inbounds[] | select(.tag == "check-in") | .listen_port = $port]
    | .outbounds = [.outbounds[] | {type: "socks", tag, server: "127.0.0.1", server_port: 1}]
    | .dns.servers = [{type: "hosts", tag: "doh", predefined: {
        "plain.example.ru": "203.0.113.9", "blocked.example.ru": "203.0.113.9", "keep.example.com": "203.0.113.9",
        "sub.keep.example.com": "203.0.113.9", "listed.example.com": "203.0.113.9", "lan.example.ru": "127.0.0.1",
        "foreign.example.com": "203.0.113.9", "other.example.ru": "203.0.113.9"}}]' \
    "$dir/hub/generated/sing-box.json" >"$cfg"
  "$DOCKER" run -d --rm --name "$SB_NAME" --network host -v "$cfg:/c.json:ro,z" -v "$dir/hub/data/rule-sets:/rule-sets:ro,z" \
    "$SINGBOX_IMAGE" run -c /c.json >/dev/null
  sleep 2
  # expect WANT USER CURL_ARGS...: the outbound of the connection, or "refused"
  expect() {
    local want=$1 user=$2 got
    shift 2
    n=$("$DOCKER" logs "$SB_NAME" 2>&1 | wc -l)
    curl -s -o /dev/null -m 3 --noproxy '' --proxy-user "check@$user:$token" "$@" || true
    sleep 0.2
    got=$("$DOCKER" logs "$SB_NAME" 2>&1 | tail -n +$((n + 1)) | { grep -o 'using outbound/socks\[[^]]*\]' || true; } | tail -1 | sed 's/.*\[//; s/\]//')
    if [[ ${got:-refused} != "$want" ]]; then
      echo "   FAIL: check@$user $*: ${got:-refused}, should be $want" >&2
      failed=1
    fi
  }
  name() { echo "--socks5-hostname 127.0.0.1:$port http://$1/"; }
  # shellcheck disable=SC2046
  {
    # the usual: RU from the hub, the rest by the route
    expect local cz1/ip1 $(name plain.example.ru)
    expect cz1/ip1 cz1/ip1 $(name foreign.example.com)
    expect local local $(name foreign.example.com)
    expect refused none $(name foreign.example.com)
    expect local none $(name plain.example.ru)
    # by the IP the client sent, by the list of Russian IPs
    expect local cz1/ip1 --socks5 "127.0.0.1:$port" http://5.8.0.1/
    expect cz1/ip1 cz1/ip1 --socks5 "127.0.0.1:$port" http://198.51.100.1/
    # +ru: everything through the exit, exceptions too
    expect cz1/ip1 cz1/ip1+ru $(name plain.example.ru)
    expect cz1/ip1 cz1/ip1+ru --socks5 "127.0.0.1:$port" http://5.8.0.1/
    expect cz1/ip1 cz1/ip1+ru $(name foreign.example.com)
    expect cz1/ip1 cz1/ip1+ru $(name keep.example.com)
    # site hub: from the hub for every route, subdomains too, not lookalikes
    expect local cz1/ip1 $(name keep.example.com)
    expect local cz1/ip1 $(name sub.keep.example.com)
    expect local none $(name keep.example.com)
    expect cz1/ip1 cz1/ip1 $(name notkeep.example.com)
    # site route: not RU, whatever the lists say; the route decides what's next
    expect cz1/ip1 cz1/ip1 $(name blocked.example.ru)
    expect cz1/ip1 cz1/ip1 $(name listed.example.com)
    expect local local $(name blocked.example.ru)
    expect refused none $(name blocked.example.ru)
    expect local cz1/ip1 $(name other.example.ru)
    # the name in TLS counts over a Russian IP from the client
    expect cz1/ip1 cz1/ip1 --socks5 "127.0.0.1:$port" --resolve blocked.example.ru:443:5.8.0.1 https://blocked.example.ru/
    expect local cz1/ip1 --socks5 "127.0.0.1:$port" --resolve foreign.example.com:443:5.8.0.1 https://foreign.example.com/
    # nothing reaches private addresses: through the hub on any route, by name too
    expect refused cz1/ip1+ru --socks5 "127.0.0.1:$port" http://10.1.2.3/
    expect refused cz1/ip1 --socks5 "127.0.0.1:$port" http://10.1.2.3/
    expect refused cz1/ip1 $(name lan.example.ru)
  }
  "$DOCKER" rm -f "$SB_NAME" >/dev/null
  ((failed == 0)) || fail "the hub's rules send connections to the wrong place"
  echo "   the hub's rules: connections leave where they should"
}

# What an exit says about itself reaches the hubs and control: its real config in
# sing-box, the hub's fetch through its "tunnel" (the exit's check inbound with the
# hub's user name), the merge control does. On a copy of hub2, as it stays managed.
exit_report_test() {
  local dir=$1 cfg=$WORK/exit-status.json port=$((22000 + $$ % 1000)) h=$1/hub2-t got
  [[ $(jq -r '.experimental.clash_api.external_controller' "$dir/exit/generated/sing-box.json") == 127.0.0.1:* ]] || fail "exit: no status file server"
  [[ -f $dir/exit/data/status/index.html ]] || fail "exit: no empty index, sing-box would download a UI"
  jq --argjson port "$port" '
    .inbounds = [.inbounds[] | select(.tag == "check-in") | .listen_port = $port | .users += [{username: "check@cz1/ip1", password: .users[0].password}]]
    | .experimental.clash_api.external_controller = "127.0.0.1:\($port + 1)"
    | (.route.rules[] | select(.override_address?) | .override_port) = ($port + 1)' "$dir/exit/generated/sing-box.json" >"$cfg"
  (cd "$dir/exit" && eval "$(sed -n '/^ENV_FILE=/,/^ASSUME_YES=/p' vpn.sh)" && for f in lib/*.sh; do . "$f"; done
    load_env; EXIT_NAME=cz1 server_status code '"abc123abc123abc123"'; server_status sing_box '"v1"'
    server_status check '{"at": "2026-01-01T00:00:00Z", "lines": ["egress ok"]}')
  "$DOCKER" run -d --rm --name "$SB_NAME" --network host -v "$cfg:/c.json:ro,z" -v "$dir/exit/data/status:/status:ro,z" \
    "$SINGBOX_IMAGE" run -c /c.json >/dev/null
  sleep 2
  cp -a "$dir/hub2" "$h"
  setenv "$h/.env" CHECK_PORT "$port"
  (cd "$h" && eval "$(sed -n '/^ENV_FILE=/,/^ASSUME_YES=/p' vpn.sh)" && for f in lib/*.sh; do . "$f"; done
    load_env; hub_exit_reports; cat "$(status_file)") >"$dir/hub-status.json" 2>"$dir/hub-status.log" ||
    { cat "$dir/hub-status.log"; "$DOCKER" rm -f "$SB_NAME" >/dev/null; fail "the hub's fetch"; }
  # nothing but the token's path gets through: no list of tokens, no API
  got=$(curl -s -m 5 --noproxy '' --socks5-hostname "127.0.0.1:$port" --proxy-user "check@cz1/ip1:00112233445566778899aabbccddeeff" http://status.cvpn.internal/ui/)
  [[ -z $got ]] || { "$DOCKER" rm -f "$SB_NAME" >/dev/null; fail "the status server lists: $got"; }
  got=$(curl -s -o /dev/null -w '%{http_code}' -m 5 --noproxy '' --socks5-hostname "127.0.0.1:$port" --proxy-user "check@cz1/ip1:00112233445566778899aabbccddeeff" http://status.cvpn.internal/configs)
  "$DOCKER" rm -f "$SB_NAME" >/dev/null
  [[ $got == 401 ]] || fail "the sing-box API answers without its secret: $got"
  jq -e '.exits.cz1.code == "abc123abc123abc123" and .exits.cz1.sing_box == "v1" and (.exits.cz1.seen | type) == "string"' "$dir/hub-status.json" >/dev/null ||
    fail "the hub didn't hear the exit: $(cat "$dir/hub-status.json")"
  got=$( (cd "$dir/control" && eval "$(sed -n '/^ENV_FILE=/,/^ASSUME_YES=/p' vpn.sh)" && for f in lib/*.sh; do . "$f"; done
    exit_reports_of) <"$dir/hub-status.json")
  jq -e '.cz1.code == "abc123abc123abc123" and .cz1.via == "hub2"' <<<"$got" >/dev/null || fail "control's merge: $got"
  rm -rf "$h"
  echo "   an exit's report: through its tunnel to the hub, to control; no listing, no API"
}

# The route and protocol of a client, on a copy (the fixture's output is compared
# between jq versions). Its subscription comes from the files of hub2, which lists
# two hubs; nothing listens on its proxy, so the check after a switch only warns.
client_test() {
  local name=$1 bin=$2 dir=$3 c=$3/client-t sub=$3/hub2/generated/sub cfg got bad
  cp -a "$dir/client" "$c"
  cfg=$c/generated/sing-box.json
  setenv "$c/.env" CLIENT_LISTEN 127.0.0.1:9
  setenv "$c/.env" CLIENT_SUB "file://$sub/a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1/sub"
  # what auto|reality|hy2 leaves in the config: "type type ...", and urltest uses just them
  outbounds() { jq -r '[.outbounds[] | select(.type == "vless" or .type == "hysteria2") | .type] | sort | join(" ")' "$cfg"; }
  vpn "$c" "$bin" client up >/dev/null 2>&1 || fail "$name: client up"
  [[ $(outbounds) == "hysteria2 hysteria2 vless vless" ]] || fail "$name: auto: $(outbounds)"
  vpn "$c" "$bin" client protocol hy2 >"$dir/ct.log" 2>&1 || { cat "$dir/ct.log"; fail "$name: client protocol hy2"; }
  grep -q 'nothing goes through' "$dir/ct.log" || fail "$name: no warning about a dead proxy: $(cat "$dir/ct.log")"
  [[ $(outbounds) == "hysteria2 hysteria2" ]] || fail "$name: hy2: $(outbounds)"
  jq -e '(.outbounds[] | select(.tag == "auto") | .outbounds | length) == 2' "$cfg" >/dev/null || fail "$name: hy2: urltest isn't over the hubs"
  vpn "$c" "$bin" client protocol reality >/dev/null 2>&1 || fail "$name: client protocol reality"
  [[ $(outbounds) == "vless vless" ]] || fail "$name: reality: $(outbounds)"
  grep -q '^Protocol: reality$' <<<"$(vpn "$c" "$bin" client protocol)" || fail "$name: client protocol shows"
  if vpn "$c" "$bin" client protocol wireguard >/dev/null 2>&1; then fail "$name: took protocol wireguard"; fi
  grep -q '^CLIENT_PROTOCOL=reality$' "$c/.env" || fail "$name: a bad protocol changed .env"
  vpn "$c" "$bin" client protocol auto >/dev/null 2>&1 || fail "$name: client protocol auto"
  [[ $(outbounds) == "hysteria2 hysteria2 vless vless" ]] || fail "$name: back to auto: $(outbounds)"
  # routes: alice has cz1/ip1 (the main one) and local, each with its key
  got=$(vpn "$c" "$bin" client route) || fail "$name: client route"
  grep -q '^\* cz1/ip1 (the main one)$' <<<"$got" && grep -q '^  local$' <<<"$got" || fail "$name: client route shows: $got"
  vpn "$c" "$bin" client route local >/dev/null 2>&1 || fail "$name: client route local"
  [[ $(jq -r .route "$c/data/client/sub.json") == local ]] && grep -q '^CLIENT_ROUTE=local$' "$c/.env" || fail "$name: not on route local"
  got=$(jq -r '.outbounds[] | select(.type == "vless") | .uuid' "$cfg" | sort -u)
  [[ $got != 11111111-1111-4111-8111-111111111111 ]] || fail "$name: route local with the key of the main route"
  # a route the user doesn't have changes nothing
  for bad in cz1/ip1+ru none nope '../x' 'a b'; do
    if vpn "$c" "$bin" client route "$bad" >/dev/null 2>&1; then fail "$name: took route '$bad'"; fi
    [[ $(jq -r .route "$c/data/client/sub.json") == local ]] && grep -q '^CLIENT_ROUTE=local$' "$c/.env" || fail "$name: route '$bad' changed something"
  done
  # no hub answers: the copy works if it's of the route asked for, and only then
  setenv "$c/.env" CLIENT_SUB http://127.0.0.1:9/a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1/sub
  vpn "$c" "$bin" client render >/dev/null 2>&1 || fail "$name: render on the copy of the same route"
  setenv "$c/.env" CLIENT_ROUTE cz1/ip1
  if vpn "$c" "$bin" client render >/dev/null 2>&1; then fail "$name: rendered the copy of another route"; fi
  setenv "$c/.env" CLIENT_SUB "file://$sub/a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1/sub"
  vpn "$c" "$bin" client route - >/dev/null 2>&1 || fail "$name: client route -"
  grep -q '^CLIENT_ROUTE=$' "$c/.env" && [[ $(jq -r .route "$c/data/client/sub.json") == cz1/ip1 ]] || fail "$name: not back on the main route"
  # +ru by its name, though its path differs (carol)
  setenv "$c/.env" CLIENT_SUB "file://$sub/c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3/sub"
  vpn "$c" "$bin" client route cz1/ip1+ru >/dev/null 2>&1 || fail "$name: client route cz1/ip1+ru"
  [[ $(jq -r .route "$c/data/client/sub.json") == cz1/ip1+ru ]] || fail "$name: not on route cz1/ip1+ru"
  rm -rf "$c"
}

# The CLI of exceptions in control; leaves the scheme as it was
site_test() {
  local name=$1 bin=$2 dir=$3 bad
  vpn "$dir/control" "$bin" control site route new.example.org >/dev/null 2>&1 || fail "$name: site route"
  grep -q '^  site + new.example.org: route$' <<<"$(vpn "$dir/control" "$bin" control diff 2>&1)" || fail "$name: diff doesn't show the new site"
  # a name and its subdomains go one way, both ways round
  if vpn "$dir/control" "$bin" control site hub sub.new.example.org >/dev/null 2>&1; then fail "$name: a subdomain went into the other list"; fi
  if vpn "$dir/control" "$bin" control site hub example.org >/dev/null 2>&1; then fail "$name: a parent went into the other list"; fi
  # the same name moves; case and the last dot don't matter
  vpn "$dir/control" "$bin" control site hub NEW.Example.org. >/dev/null 2>&1 || fail "$name: site hub moving a name"
  [[ $(grep -c 'new.example.org' "$dir/control/sites.conf") == 1 ]] && grep -q '^new.example.org hub$' "$dir/control/sites.conf" ||
    fail "$name: the moved name: $(cat "$dir/control/sites.conf")"
  vpn "$dir/control" "$bin" control site del new.example.org >/dev/null 2>&1 || fail "$name: site del"
  if vpn "$dir/control" "$bin" control site del new.example.org >/dev/null 2>&1; then fail "$name: site del of nothing"; fi
  for bad in 'https://example.org/' '*.example.org' 'example.org:443' 1.2.3.4 com 'пример.рф' '-a.example.org' 'a b.org'; do
    if vpn "$dir/control" "$bin" control site route "$bad" >/dev/null 2>&1; then fail "$name: site route took '$bad'"; fi
  done
  grep -q '^keep.example.com ' <<<"$(vpn "$dir/control" "$bin" control site list)" || fail "$name: site list"
  # routes: +ru only of exits that exist, as the list of the user
  for bad in local+ru none+ru cz1/nope+ru cz1/ip1+all; do
    if vpn "$dir/control" "$bin" control user route carol "$bad" >/dev/null 2>&1; then fail "$name: route '$bad' accepted"; fi
  done
}

# run VARIANT JQ_BIN_DIR: render everything with that jq, list "sha256 file"
run() {
  local name=$1 bin=$2 dir=$WORK/$1 ctl
  rm -rf "$dir"
  cp -a "$BASE" "$dir"
  step "$name: $(cd "$WORK" && PATH="$bin:$PATH" jq --version)"
  vpn "$dir/hub" "$bin" hub render >"$dir/hub.log" 2>&1 || { cat "$dir/hub.log"; fail "$name: hub render"; }
  expect_hub "$dir/hub"
  vpn "$dir/exit" "$bin" exit render >"$dir/exit.log" 2>&1 || { cat "$dir/exit.log"; fail "$name: exit render"; }
  mkdir -p "$dir/client/data/client"
  cp "$dir/hub/generated/sub/a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1/sing-box.json" "$dir/client/data/client/sub.json"
  vpn "$dir/client" "$bin" client render >"$dir/client.log" 2>&1 || { cat "$dir/client.log"; fail "$name: client render"; }
  ctl=$(vpn "$dir/control" "$bin" control hub add hub2 "$HUB2_TOKEN" 2>&1) || { echo "$ctl"; fail "$name: control hub add"; }
  ctl=$(grep -o "cvpn-ctl:[^']*" <<<"$ctl")
  # changes are only saved: diff shows them, publish sends them
  vpn "$dir/control" "$bin" control diff >"$dir/diff.log" 2>&1 || { cat "$dir/diff.log"; fail "$name: control diff"; }
  vpn "$dir/control" "$bin" control publish >"$dir/publish.log" 2>&1 || { cat "$dir/publish.log"; fail "$name: control publish"; }
  vpn "$dir/control" "$bin" control group add qa local >/dev/null 2>&1 || fail "$name: control group add"
  vpn "$dir/control" "$bin" control user route carol cz1/ip1,local >/dev/null 2>&1 || fail "$name: control user route"
  vpn "$dir/control" "$bin" control diff >"$dir/diff.log" 2>&1 || { cat "$dir/diff.log"; fail "$name: control diff"; }
  if ! grep -q '^  group + qa: routes local$' "$dir/diff.log" ||
    ! grep -q '^  routes ~ carol: group -, routes cz1/ip1,local$' "$dir/diff.log"; then
    cat "$dir/diff.log"
    fail "$name: control diff doesn't show the changes"
  fi
  vpn "$dir/control" "$bin" control group del qa >/dev/null 2>&1 || fail "$name: control group del"
  vpn "$dir/control" "$bin" control user route carol none,cz1/ip1,cz1/ip1+ru >/dev/null 2>&1 || fail "$name: control user route back"
  site_test "$name" "$bin" "$dir"
  vpn "$dir/control" "$bin" control diff 2>&1 | grep -q '^Nothing to publish' || fail "$name: control diff after undoing"
  vpn "$dir/hub2" "$bin" hub control set "$ctl" >"$dir/hub2.log" 2>&1 || { cat "$dir/hub2.log"; fail "$name: hub2 control set"; }
  vpn "$dir/hub2" "$bin" hub control apply <"$dir/control/generated/state.txt" >>"$dir/hub2.log" 2>&1 ||
    { cat "$dir/hub2.log"; fail "$name: hub2 control apply"; }
  grep -q 'applied' "$dir/hub2.log" || { cat "$dir/hub2.log"; fail "$name: hub2 didn't apply the snapshot"; }
  # control's update key comes with the snapshot (code update orders, lib/remote.sh)
  [[ $(grep '^AGE-SECRET' "$dir/control/data/control/update.key") == "$(cat "$dir/hub2/data/control/update.key" 2>/dev/null)" ]] ||
    fail "$name: hub2 didn't get control's update key"
  # exceptions come with the snapshot, are control's and reach the hub's config
  [[ $(grep -v '^#' "$dir/control/sites.conf") == "$(grep -v '^#' "$dir/hub2/sites.conf" 2>/dev/null)" ]] ||
    fail "$name: hub2 didn't get the exceptions"
  jq -e '[.. | .domain_suffix? // empty | arrays | .[]] | index("keep.example.com") and index("blocked.example.ru")' \
    "$dir/hub2/generated/sing-box.json" >/dev/null || fail "$name: the exceptions aren't in hub2's config"
  if vpn "$dir/hub2" "$bin" hub site route x.example.org >/dev/null 2>&1; then fail "$name: a managed hub changed its exceptions"; fi
  grep -q '^keep.example.com ' <<<"$(vpn "$dir/hub2" "$bin" hub site list)" || fail "$name: site list on a managed hub"
  client_test "$name" "$bin" "$dir"
  (cd "$dir" && find hub/generated exit/generated client/generated hub2/generated hub2/users.conf hub2/exits.conf \
    hub2/groups.conf hub2/routing.conf hub2/sites.conf -type f ! -name '*.tmp' ! -name status.json | sort | xargs sha256sum) >"$WORK/$name.sums"
}

# This host's jq, then each image as "jq" first in PATH
run local ""
routing_test "$WORK/local"
exit_report_test "$WORK/local"
for image in $JQ_IMAGES; do
  "$DOCKER" image inspect "$image" >/dev/null 2>&1 || "$DOCKER" pull -q "$image" >/dev/null
  v=$(tr -c 'a-z0-9.\n' '_' <<<"$image")
  b=$WORK/bin/$v
  mkdir -p "$b"
  cat >"$b/jq" <<EOF
#!/usr/bin/env bash
# jq of $image: the fixtures and \$TMPDIR are under $WORK; \$ENV is what vpn.sh exported
echo >>"$b/calls"
exec $DOCKER run -i --rm --network none -v "$WORK:$WORK:z" -w "\$PWD" \\
  --env-file <(env | grep -E '^[A-Z][A-Z0-9_]*=' | grep -vE '^(PATH|HOME|PWD|OLDPWD|TMPDIR|HOSTNAME|TERM|SHLVL|_)=') \\
  $image "\$@"
EOF
  chmod +x "$b/jq"
  run "$v" "$b"
  if ! diff -q "$WORK/local.sums" "$WORK/$v.sums" >/dev/null; then
    diff "$WORK/local.sums" "$WORK/$v.sums" >&2 || true
    f=$(diff "$WORK/local.sums" "$WORK/$v.sums" | awk '/^[<>]/ {print $3; exit}')
    diff "$WORK/local/$f" "$WORK/$v/$f" >&2 || true
    fail "$image renders differently from $(jq --version)"
  fi
  echo "   same as $(jq --version): $(wc -l <"$WORK/local.sums") files ($(wc -l <"$b/calls") jq calls in the container)"
done
echo "ok"
