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
trap 'if [[ -n ${KEEP:-} ]]; then echo "kept $WORK"; else rm -rf "$WORK"; fi' EXIT
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
echo '{"version": 3, "rules": [{"domain_suffix": ["ru", "su"]}]}' >"$BASE/rule-sets/geosite-ru.json"
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
printf '# user  group  route\nalice sales -\nbob - none\ncarol - none,cz1/ip1\n' >"$BASE/hub/routing.conf"

# Control with the same scheme, a fake second hub and a real one (hub2)
fixture "$BASE/control" control
(cd "$BASE/control" && rm .env && ROLE=control ./vpn.sh control init >/dev/null 2>&1)
cp "$BASE"/hub/{users,exits,groups,routing}.conf "$BASE/control/"
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
# credential and route (alice 2, bob 1 + 1 rotated, carol 2), a subscription per
# route, a profile title per route in the Caddyfile
expect_hub() {
  local h=$1/generated
  [[ $(jq '[.inbounds[] | select(.type == "vless") | .users[]] | length' "$h/sing-box.json") == 6 ]] ||
    fail "vless users: $(jq -c '[.inbounds[] | select(.type == "vless") | .users[].name]' "$h/sing-box.json")"
  jq -e '.route.rules | any(.auth_user? // [] | index("carol@cz1/ip1")) and any(.auth_user? // [] | index("alice@local"))' \
    "$h/sing-box.json" >/dev/null || fail "no rules for the second routes of carol / alice"
  for f in sub sing-box.json none/sub cz1-ip1/sub cz1-ip1/sing-box.json; do
    [[ -s $h/sub/c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3/$f ]] || fail "carol has no $f"
  done
  [[ ! -e $h/sub/b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2/cz1-ip1 ]] || fail "bob has a route he doesn't have"
  cmp -s "$h/sub/c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3/sub" "$h/sub/c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3/none/sub" ||
    fail "carol's main subscription isn't her first route"
  [[ $(grep -c 'profile-title' "$h/Caddyfile") -ge 4 ]] || fail "no profile titles of the routes in the Caddyfile"
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
  vpn "$dir/hub2" "$bin" hub control set "$ctl" >"$dir/hub2.log" 2>&1 || { cat "$dir/hub2.log"; fail "$name: hub2 control set"; }
  vpn "$dir/hub2" "$bin" hub control apply <"$dir/control/generated/state.txt" >>"$dir/hub2.log" 2>&1 ||
    { cat "$dir/hub2.log"; fail "$name: hub2 control apply"; }
  grep -q 'applied' "$dir/hub2.log" || { cat "$dir/hub2.log"; fail "$name: hub2 didn't apply the snapshot"; }
  (cd "$dir" && find hub/generated exit/generated client/generated hub2/generated hub2/users.conf hub2/exits.conf \
    hub2/groups.conf hub2/routing.conf -type f ! -name '*.tmp' | sort | xargs sha256sum) >"$WORK/$name.sums"
}

# This host's jq, then each image as "jq" first in PATH
run local ""
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
