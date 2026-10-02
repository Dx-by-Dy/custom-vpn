#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"

ENV_FILE=.env
USERS_FILE=users.conf
OUT=generated
DOCKER=${DOCKER:-docker}
DEFAULT_GRACE_HOURS=24
# `update repo` pulls from here; override with REPO_URL / REPO_BRANCH in .env
DEFAULT_REPO_URL=https://github.com/Dx-by-Dy/custom-vpn.git
DEFAULT_REPO_BRANCH=main
# Files and directories that hold this server's state; never taken from the repo
STATE_PATHS=(.env users.conf data generated)
ASSUME_YES=false

usage() {
  cat <<'EOF'
Usage: ./vpn.sh <command> [args]

Setup:
  deploy                  full setup: tune, init, up, expiry timer, links
  init                    create .env, generate missing keys, create the first user
  up                      render configs, check ports, start/restart containers
  down                    stop containers
  logs                    follow container logs
  tune                    enable BBR and bigger UDP buffers (sysctl)
  install-docker          install docker via get.docker.com
  firewall [--dry-run]    enable ufw for ssh, VPN ports and other listening
                          services, optionally disable SSH password login

Users:
  user add NAME           add a user and print their links
  user del NAME           remove a user, their links stop working immediately
  user list               list users
  links [NAME]            print subscription links (all users or one)
  rotate NAME|--all [--grace HOURS]
                          issue new credentials, the old ones keep working for
                          HOURS (default 24) so clients can refresh the subscription

Maintenance:
  update images           upgrade xray / hysteria / caddy images to the latest releases
  update repo             update this repo's code from GitHub (keeps .env, users, certificates)
  render                  render configs into generated/ and validate them
  prune                   drop expired credentials (run hourly by vpn-prune.timer)
  help                    show this help

Options:
  -y                      answer yes to all questions
EOF
}

die() { echo "error: $*" >&2; exit 1; }
warn() { echo "warning: $*" >&2; }
info() { echo ">> $*"; }

# ask "Question" y|n: returns 0 on yes; an empty answer means the default.
ask() {
  local question=$1 default=$2 hint answer
  $ASSUME_YES && return 0
  [[ -t 0 ]] || die "$question: no terminal to ask, rerun with -y"
  [[ $default == y ]] && hint="[Y/n]" || hint="[y/N]"
  read -r -p "$question $hint " answer
  [[ ${answer:-$default} == [yY]* ]]
}

# Serialize commands that change state (manual runs vs. the prune timer)
lock() {
  exec 9>.vpn.lock
  flock 9
}

require_root() { [[ $EUID -eq 0 ]] || die "$1 needs root"; }

urlencode() {
  local LC_ALL=C s=$1 out='' c i
  for ((i = 0; i < ${#s}; i++)); do
    c=${s:i:1}
    case $c in
      [a-zA-Z0-9.~_-]) out+=$c ;;
      *) out+=$(printf '%%%02X' "'$c") ;;
    esac
  done
  printf '%s' "$out"
}

rand_hex() { od -An -tx1 -N"$1" /dev/urandom | tr -d ' \n'; }

load_env() {
  [[ -f $ENV_FILE ]] || die "no $ENV_FILE: cp .env.example .env, then set DOMAIN and ACME_EMAIL"
  set -a; . "./$ENV_FILE"; set +a
  SUB_NAME_ENC=$(urlencode "$SUB_NAME")
  SUB_TITLE_B64=$(printf '%s' "$SUB_NAME" | base64 -w0)
}

# Write KEY=VALUE into .env (replace or append) and set it in this shell.
set_var() {
  local key=$1 val=$2
  if grep -q "^$key=" "$ENV_FILE"; then
    sed -i "s|^$key=.*|$key=$val|" "$ENV_FILE"
  else
    echo "$key=$val" >>"$ENV_FILE"
  fi
  export "$key=$val"
}

xray_cli() { "$DOCKER" run --rm "$XRAY_IMAGE" "$@"; }

# --- users -------------------------------------------------------------------
#
# users.conf has one credential per line:
#   name  xray_uuid  hysteria_user  hysteria_pass  sub_token  expires
# Active credentials have expires "-". Rotated-out ones have sub_token "-" and
# an expiry time (unix epoch); they stay valid until then. The hysteria user
# ("name-xxxx") changes on rotation, so old and new passwords can be valid at
# the same time. No dots in it: hysteria's config loader treats them as nesting.

USERS_HEADER='# name  xray_uuid  hysteria_user  hysteria_pass  sub_token  expires'

users_init() {
  [[ -f $USERS_FILE ]] || { echo "$USERS_HEADER" >"$USERS_FILE"; chmod 600 "$USERS_FILE"; }
}

# Credentials that are active or not expired yet
users_valid() {
  awk -v now="$(date +%s)" '!/^#/ && NF && ($6 == "-" || $6 > now)' "$USERS_FILE" 2>/dev/null || true
}

users_active() { awk '!/^#/ && NF && $6 == "-"' "$USERS_FILE" 2>/dev/null || true; }

user_exists() { users_active | awk -v n="$1" '$1 == n {f = 1} END {exit !f}'; }

check_name() {
  [[ $1 =~ ^[a-z0-9_-]{1,32}$ ]] || die "user name must be 1-32 chars of a-z, 0-9, _ and -"
}

# Prints "name uuid hysteria_user hysteria_pass" for a fresh credential
new_cred() { echo "$1 $(cat /proc/sys/kernel/random/uuid) $1-$(rand_hex 2) $(rand_hex 16)"; }

# Rewrite users.conf: awk program gets each non-comment line as fields
users_rewrite() {
  local tmp
  tmp=$(mktemp "$USERS_FILE.XXXX")
  awk "$@" "$USERS_FILE" >"$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$USERS_FILE"
}

# Sets per-user link variables used by templates and `links`
user_vars() {
  local uuid=$1 hy_user=$2 hy_pass=$3 token=$4
  SUB_URL="https://$DOMAIN:$SUB_PORT/$token/sub"
  SUB_PAGE="https://$DOMAIN:$SUB_PORT/$token/"
  SUB_URL_ENC=$(urlencode "$SUB_URL")
  VLESS_LINK="vless://$uuid@$DOMAIN:$XRAY_PORT?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$REALITY_SNI&fp=chrome&pbk=$XRAY_PUBLIC_KEY&sid=$XRAY_SHORT_ID&type=tcp#$SUB_NAME_ENC-reality"
  HY2_LINK="hysteria2://$hy_user:$hy_pass@$DOMAIN:$HYSTERIA_PORT/?sni=$DOMAIN#$SUB_NAME_ENC-hy2"
}

cmd_user() {
  local action=${1:-} name=${2:-}
  case $action in
    add)
      check_name "$name"
      load_env
      users_init
      user_exists "$name" && die "user $name already exists"
      echo "$(new_cred "$name") $(rand_hex 16) -" >>"$USERS_FILE"
      cmd_up
      cmd_links "$name"
      ;;
    del)
      check_name "$name"
      user_exists "$name" || die "no user $name"
      users_rewrite -v n="$name" '/^#/ || $1 != n'
      cmd_up
      info "user $name removed"
      ;;
    list)
      [[ -f $USERS_FILE ]] || die "no users yet, run: ./vpn.sh init"
      awk -v now="$(date +%s)" '
        !/^#/ && NF && $6 == "-" { order[++n] = $1; token[$1] = $5 }
        !/^#/ && NF && $6 != "-" && $6 > now { old[$1]++ }
        END {
          printf "%-20s %-34s %s\n", "NAME", "SUB TOKEN", "OLD CREDENTIALS"
          for (i = 1; i <= n; i++) printf "%-20s %-34s %s\n", order[i], token[order[i]], old[order[i]] + 0
        }' "$USERS_FILE"
      ;;
    *) die "usage: ./vpn.sh user add|del|list [NAME]" ;;
  esac
}

cmd_rotate() {
  local target=${1:-} grace=$DEFAULT_GRACE_HOURS names expires line
  [[ -n $target ]] || die "usage: ./vpn.sh rotate NAME|--all [--grace HOURS]"
  shift
  while (($#)); do
    case $1 in
      --grace) grace=${2:-}; shift 2 || die "--grace needs a value" ;;
      *) die "unknown option: $1" ;;
    esac
  done
  [[ $grace =~ ^[0-9]+$ ]] || die "--grace must be a number of hours"
  load_env
  if [[ $target == --all ]]; then
    names=$(users_active | awk '{print $1}')
    [[ -n $names ]] || die "no users"
  else
    check_name "$target"
    user_exists "$target" || die "no user $target"
    names=$target
  fi

  expires=$(($(date +%s) + grace * 3600))
  local tmp
  tmp=$(mktemp "$USERS_FILE.XXXX")
  while IFS= read -r line; do
    read -r name uuid hy_user hy_pass token exp <<<"$line"
    if [[ $line != \#* && ${exp:-} == - ]] && grep -qx "$name" <<<"$names"; then
      ((grace == 0)) || echo "$name $uuid $hy_user $hy_pass - $expires"
      echo "$(new_cred "$name") $token -"
    else
      echo "$line"
    fi
  done <"$USERS_FILE" >"$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$USERS_FILE"

  cmd_up
  if ((grace == 0)); then
    info "rotated: $(echo $names); old credentials no longer work"
  else
    info "rotated: $(echo $names); old credentials work until $(date -d "@$expires" '+%F %R %Z')"
  fi
  echo "Clients get the new credentials on the next subscription refresh (links didn't change)."
}

cmd_prune() {
  [[ -f $USERS_FILE ]] || return 0
  local now
  now=$(date +%s)
  awk -v now="$now" '!/^#/ && NF && $6 != "-" && $6 <= now {f = 1} END {exit !f}' "$USERS_FILE" || return 0
  users_rewrite -v now="$now" '/^#/ || !NF || $6 == "-" || $6 > now'
  info "expired credentials removed"
  cmd_up
}

# --- setup -------------------------------------------------------------------

cmd_init() {
  [[ -f $ENV_FILE ]] || { cp .env.example "$ENV_FILE"; chmod 600 "$ENV_FILE"; }
  # Pick up keys added to .env.example after this .env was created
  local line
  while IFS= read -r line; do
    [[ $line =~ ^([A-Z0-9_]+)= ]] || continue
    grep -q "^${BASH_REMATCH[1]}=" "$ENV_FILE" || echo "$line" >>"$ENV_FILE"
  done <.env.example
  load_env
  [[ $DOMAIN != vpn.example.com && $ACME_EMAIL != you@example.com ]] ||
    die "set DOMAIN and ACME_EMAIL in $ENV_FILE first"
  # caddy stores certificates under the lowercase name, hysteria reads them from there
  [[ $DOMAIN == "${DOMAIN,,}" ]] || set_var DOMAIN "${DOMAIN,,}"

  [[ -n $XRAY_SHORT_ID ]] || set_var XRAY_SHORT_ID "$(rand_hex 8)"
  if [[ -z $XRAY_PRIVATE_KEY || -z $XRAY_PUBLIC_KEY ]]; then
    local keys
    if [[ -n $XRAY_PRIVATE_KEY ]]; then
      keys=$(xray_cli x25519 -i "$XRAY_PRIVATE_KEY")
    else
      keys=$(xray_cli x25519)
    fi
    # "PrivateKey: ..." / "Password (PublicKey): ..." (older xray: "Public key: ...")
    set_var XRAY_PRIVATE_KEY "$(awk '/^Private/ {print $NF}' <<<"$keys")"
    set_var XRAY_PUBLIC_KEY "$(awk '/Public/ {print $NF}' <<<"$keys")"
    [[ -n $XRAY_PRIVATE_KEY && -n $XRAY_PUBLIC_KEY ]] || die "can't parse xray x25519 output: $keys"
  fi

  # Single-user setups kept the credentials in .env: move them to the "default" user
  if [[ ! -f $USERS_FILE && -n ${XRAY_UUID:-} && -n ${HYSTERIA_PASSWORD:-} && -n ${SUB_TOKEN:-} ]]; then
    users_init
    echo "default $XRAY_UUID default-$(rand_hex 2) $HYSTERIA_PASSWORD $SUB_TOKEN -" >>"$USERS_FILE"
    info "moved credentials from $ENV_FILE to user \"default\" in $USERS_FILE"
  fi
  sed -i -E '/^(XRAY_UUID|HYSTERIA_PASSWORD|SUB_TOKEN)=/d' "$ENV_FILE"

  users_init
  if [[ -z $(users_active) ]]; then
    echo "$(new_cred default) $(rand_hex 16) -" >>"$USERS_FILE"
    info "created user \"default\""
  fi
  info "keys are in $ENV_FILE, users in $USERS_FILE"
}

# Services whose config changed during render (they need a restart)
CHANGED=()

# Write content to a file only if it differs (in place: bind mounts keep the same inode);
# with a service name, mark that service as changed.
write_file() {
  local out=$1 content=$2 service=${3:-}
  cmp -s "$out" <(printf '%s\n' "$content") && return
  printf '%s\n' "$content" >"$out"
  chmod 644 "$out"
  [[ -z $service ]] || CHANGED+=("$service")
}

# Substitute ${VAR} in a template; every referenced variable must be non-empty.
render_file() {
  local tpl=$1 out=$2 service=${3:-} content var
  content=$(<"$tpl")
  for var in $(grep -o '\${[A-Z0-9_]*}' "$tpl" | tr -d '${}' | sort -u); do
    [[ -n ${!var:-} ]] || die "$var is empty (used in $tpl)"
    content=${content//"\${$var}"/"${!var}"}
  done
  write_file "$out" "$content" "$service"
}

check() {
  local name=$1 out
  shift
  out=$("$DOCKER" run --rm "$@" 2>&1) || die "$name config test failed: $out"
}

cmd_render() {
  load_env
  [[ $SUB_PORT != "$XRAY_PORT" ]] || die "SUB_PORT and XRAY_PORT are both tcp/$XRAY_PORT"
  local valid
  valid=$(users_valid)
  [[ -n $(users_active) ]] || die "no users, run: ./vpn.sh init"

  # Credential lists for the server configs; rotated-out ones get a distinct xray email
  XRAY_CLIENTS=$(awk '{
    printf "%s{\"id\": \"%s\", \"flow\": \"xtls-rprx-vision\", \"email\": \"%s\"}",
      (NR > 1 ? ",\n          " : ""), $2, ($6 == "-" ? $1 : $1 "~" $6)
  }' <<<"$valid")
  HYSTERIA_USERS=$(awk '{printf "%s%s: %s", (NR > 1 ? "\n    " : ""), $3, $4}' <<<"$valid")

  mkdir -p "$OUT/sub"
  chmod 700 "$OUT"
  render_file templates/xray.json "$OUT/xray.json" xray
  render_file templates/hysteria.yaml "$OUT/hysteria.yaml" hysteria
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

  check xray -v "$PWD/$OUT/xray.json:/c.json:ro,z" "$XRAY_IMAGE" run -test -c /c.json
  check caddy -v "$PWD/$OUT/Caddyfile:/c:ro,z" "$CADDY_IMAGE" caddy validate --config /c --adapter caddyfile
  info "configs rendered to $OUT/"
}

# --- ports -------------------------------------------------------------------

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
  echo "$XRAY_PORT/tcp xray (VLESS REALITY)"
  echo "$HYSTERIA_PORT/udp hysteria"
  echo "$SUB_PORT/tcp caddy (subscription)"
  echo "$SUB_PORT/udp caddy (subscription, HTTP/3)"
  echo "80/tcp caddy (Let's Encrypt HTTP-01)"
}

# Fail if a port we need is held by something other than our containers
check_ports() {
  local ours all need desc proto port lport pid proc busy=()
  ours=" $(our_pids | tr '\n' ' ') "
  all=$(listeners)
  while read -r need desc; do
    port=${need%/*} proto=${need#*/}
    [[ $need == "$SUB_PORT/udp" ]] && continue # optional, caddy works without HTTP/3
    while read -r p lport pid proc; do
      [[ $p == "$proto" && $lport == "$port" && $ours != *" $pid "* ]] || continue
      busy+=("  $need ($desc) is taken by $proc (pid $pid)")
    done <<<"$all"
  done < <(vpn_ports)
  ((${#busy[@]} == 0)) && return
  printf '%s\n' "ports are busy:" "${busy[@]}" >&2
  if [[ $EUID -ne 0 ]]; then
    warn "not root, can't see which processes own the ports; continuing"
    return
  fi
  die "free them or change XRAY_PORT / HYSTERIA_PORT / SUB_PORT in $ENV_FILE (80/tcp can't be changed: Let's Encrypt needs it)"
}

preflight() {
  local resolved public
  # Repeated ACME failures hit Let's Encrypt rate limits
  resolved=$(getent ahostsv4 "$DOMAIN" | awk 'NR==1 {print $1}' || true)
  public=$(curl -4 -fsS -m 5 https://ifconfig.me 2>/dev/null || true)
  if [[ -z $resolved ]]; then
    warn "$DOMAIN doesn't resolve, caddy won't get a certificate"
  elif [[ -n $public && $resolved != "$public" ]]; then
    warn "$DOMAIN -> $resolved, but this server is $public"
  fi
  # REALITY contacts its target on every handshake; sites sometimes block server IPs
  curl -s -o /dev/null -m 8 "https://$REALITY_SNI/" ||
    warn "this server can't reach https://$REALITY_SNI/: VLESS won't work, change REALITY_SNI"
  check_ports
}

cmd_up() {
  local running restart=() svc
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
  "$DOCKER" compose ps
}

cmd_links() {
  local only=${1:-} name uuid hy_user hy_pass token exp found=false
  load_env
  while read -r name uuid hy_user hy_pass token exp; do
    [[ -z $only || $name == "$only" ]] || continue
    found=true
    user_vars "$uuid" "$hy_user" "$hy_pass" "$token"
    echo
    echo "[$name]"
    echo "  import page:   $SUB_PAGE"
    echo "  subscription:  $SUB_URL"
    if [[ -n $only ]]; then
      echo "  vless:         $VLESS_LINK"
      echo "  hysteria2:     $HY2_LINK"
      if command -v qrencode >/dev/null; then
        qrencode -t ansiutf8 "$SUB_PAGE"
      else
        echo "  (apt install qrencode to get a QR code of the import page here)"
      fi
    fi
  done < <(users_active)
  $found || die "no user ${only:-found}"
  echo
}

cmd_tune() {
  require_root tune
  # BBR for xray (TCP), bigger UDP buffers for hysteria (QUIC)
  cat >/etc/sysctl.d/99-vpn.conf <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
EOF
  sysctl -q -p /etc/sysctl.d/99-vpn.conf
  info "sysctl tuned (/etc/sysctl.d/99-vpn.conf)"
}

install_prune_timer() {
  if [[ $EUID -ne 0 ]] || ! command -v systemctl >/dev/null; then
    warn "not root or no systemd: rotated credentials won't expire automatically, run ./vpn.sh prune yourself"
    return
  fi
  cat >/etc/systemd/system/vpn-prune.service <<EOF
[Unit]
Description=Remove expired VPN credentials

[Service]
Type=oneshot
ExecStart=$PWD/vpn.sh prune
EOF
  cat >/etc/systemd/system/vpn-prune.timer <<'EOF'
[Unit]
Description=Remove expired VPN credentials hourly

[Timer]
OnCalendar=hourly
Persistent=true

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable -q --now vpn-prune.timer
  info "vpn-prune.timer enabled"
}

cmd_install_docker() {
  command -v docker >/dev/null && { info "docker already installed"; return; }
  curl -fsSL https://get.docker.com | sh
}

cmd_deploy() {
  command -v "$DOCKER" >/dev/null || die "$DOCKER not found, run: ./vpn.sh install-docker"
  if [[ $EUID -eq 0 ]]; then cmd_tune; else warn "not root, skipping sysctl tuning"; fi
  cmd_init
  cmd_up
  install_prune_timer
  cmd_links
}

# --- update ------------------------------------------------------------------

latest_release() {
  local json tag
  json=$(curl -fsSL -m 15 "https://api.github.com/repos/$1/releases/latest") || return 1
  tag=$(grep -m1 '"tag_name"' <<<"$json" | cut -d'"' -f4)
  [[ -n $tag ]] && echo "$tag"
}

cmd_update() {
  case ${1:-} in
    images) cmd_update_images ;;
    repo) cmd_update_repo ;;
    *) die "usage: ./vpn.sh update images|repo" ;;
  esac
}

cmd_update_images() {
  load_env
  local x h c var new changes=()
  x=$(latest_release XTLS/Xray-core) || die "can't reach GitHub"
  h=$(latest_release apernet/hysteria) || die "can't reach GitHub"
  c=$(latest_release caddyserver/caddy) || die "can't reach GitHub"
  declare -A latest=(
    [XRAY_IMAGE]="${XRAY_IMAGE%:*}:${x#v}"
    [HYSTERIA_IMAGE]="${HYSTERIA_IMAGE%:*}:${h#app/}"
    [CADDY_IMAGE]="${CADDY_IMAGE%:*}:${c#v}-alpine"
  )
  for var in XRAY_IMAGE HYSTERIA_IMAGE CADDY_IMAGE; do
    new=${latest[$var]}
    [[ ${!var} == "$new" ]] && continue
    # Images often appear in registries some time after the GitHub release
    if "$DOCKER" pull -q "$new" >/dev/null 2>&1; then
      changes+=("$var")
      echo "  ${!var}  ->  $new"
    else
      echo "  ${!var}  (${new##*:} is released, but the image isn't published yet)"
    fi
  done
  ((${#changes[@]})) || { info "nothing to update"; return; }
  ask "Update?" n || return 0

  cp "$ENV_FILE" "$ENV_FILE.bak"
  for var in "${changes[@]}"; do set_var "$var" "${latest[$var]}"; done
  # On failure (e.g. a config the new version rejects) go back to the old images
  local rc
  set +e
  (set -e; cmd_up)
  rc=$?
  set -e
  if ((rc != 0)); then
    mv "$ENV_FILE.bak" "$ENV_FILE"
    warn "update failed, restoring previous versions"
    cmd_up
    exit 1
  fi
  rm -f "$ENV_FILE.bak"
  info "updated"
}

cmd_update_repo() {
  load_env
  local url=${REPO_URL:-$DEFAULT_REPO_URL} branch=${REPO_BRANCH:-$DEFAULT_REPO_BRANCH}
  local new old tracked index changes

  if ! command -v git >/dev/null; then
    command -v apt-get >/dev/null || die "git is not installed"
    ask "git is not installed. Install it?" y || return 0
    apt-get install -y -qq git >/dev/null
  fi
  # Deployments copied without .git become a checkout on the first update
  [[ -d .git ]] || git init -q
  git fetch -q "$url" "$branch" || die "can't fetch $branch from $url"
  new=$(git rev-parse FETCH_HEAD)
  old=$(git rev-parse -q --verify HEAD || true)

  # A reset to a commit that tracks local state would overwrite it
  tracked=$(git ls-tree -r --name-only "$new" -- "${STATE_PATHS[@]}")
  [[ -z $tracked ]] || die "upstream tracks local state ($(echo $tracked)), refusing to update"

  # What the working tree would look like after the update
  index=$(mktemp -u)
  GIT_INDEX_FILE=$index git read-tree "$new"
  changes=$(GIT_INDEX_FILE=$index git diff -R --stat=72 || true)
  rm -f "$index"
  if [[ -n $old ]]; then
    changes+=$(git diff --stat=72 --diff-filter=D "$old" "$new" | sed '$d')
  fi

  if [[ -z $changes ]]; then
    git reset -q --hard "$new"
    info "up to date: $(git log -1 --format='%h %s' "$new")"
    return
  fi

  echo "Update from $url ($branch):"
  if [[ -n $old ]] && git merge-base --is-ancestor "$old" "$new" 2>/dev/null; then
    git log --format='  %h %s' "$old..$new"
  else
    echo "  -> $(git log -1 --format='%h %s' "$new")"
  fi
  echo "Files that will change:"
  echo "$changes" | sed 's/^/  /'
  if [[ -n $old && -n $(git status --porcelain --untracked-files=no) ]]; then
    warn "local edits to these files will be lost:"
    git status --porcelain --untracked-files=no | sed 's/^/  /' >&2
  fi
  echo "Kept as is: ${STATE_PATHS[*]} (keys, users, certificates)."
  echo "Containers whose config changes will be restarted: VPN connections drop for a few seconds."
  ask "Update?" n || return 0

  # Belt and braces: back up the state and check it survived the reset
  local backup sums
  mkdir -p backups
  chmod 700 backups
  backup=backups/state-$(date +%Y%m%d-%H%M%S).tar.gz
  local files=() f
  for f in .env users.conf; do [[ -f $f ]] && files+=("$f"); done
  tar -czf "$backup" "${files[@]}"
  ls -1t backups/state-*.tar.gz | tail -n +11 | xargs -r rm -f
  sums=$(sha256sum .env users.conf 2>/dev/null || true)

  git reset -q --hard "$new"

  if [[ -n $sums ]] && ! sha256sum --quiet -c <<<"$sums" >/dev/null 2>&1; then
    tar -xzf "$backup"
    die "local state changed during the update; restored it from $backup"
  fi
  info "code updated to $(git log -1 --format='%h %s' "$new") (state backup: $backup)"

  # Continue with the new vpn.sh: pick up new .env keys, re-render, restart what changed
  exec 9>&-
  exec bash -c './vpn.sh init && ./vpn.sh up'
}

# --- firewall ----------------------------------------------------------------

cmd_firewall() {
  local dry=false
  [[ ${1:-} == --dry-run ]] && dry=true
  require_root firewall
  load_env

  local ours all rules=() others=() p port pid proc rule desc
  ours=" $(our_pids | tr '\n' ' ') "
  all=$(listeners)

  # SSH first, so the current session survives
  local ssh_ports
  ssh_ports=$(awk '$4 == "sshd" && $1 == "tcp" {print $2}' <<<"$all" | sort -u)
  [[ -n $ssh_ports ]] || { warn "no sshd listener found, assuming 22/tcp"; ssh_ports=22; }
  for port in $ssh_ports; do rules+=("$port/tcp ssh"); done
  while read -r rule desc; do rules+=("$rule $desc"); done < <(vpn_ports)

  # Anything else listening publicly (another site, a game server...)
  local known
  known=" $(printf '%s\n' "${rules[@]}" | awk '{print $1}' | tr '\n' ' ') "
  while read -r p port pid proc; do
    [[ -n $p && $ours != *" $pid "* && $known != *" $port/$p "* ]] || continue
    others+=("$port/$p $proc")
    known+="$port/$p "
  done <<<"$all"

  echo "Allow incoming:"
  for rule in "${rules[@]}"; do printf '  %-12s %s\n' "${rule%% *}" "${rule#* }"; done
  if ((${#others[@]})); then
    echo "Other services listening on public addresses:"
    for rule in "${others[@]}"; do printf '  %-12s %s\n' "${rule%% *}" "${rule#* }"; done
  fi
  echo "Everything else incoming will be dropped."
  $dry && return

  if ((${#others[@]})) && ask "Keep the other services reachable?" y; then
    rules+=("${others[@]}")
  fi
  ask "Enable the firewall?" n || return 0

  if ! command -v ufw >/dev/null; then
    command -v apt-get >/dev/null || die "ufw is not installed"
    apt-get install -y -qq ufw >/dev/null
  fi
  ufw default deny incoming >/dev/null
  ufw default allow outgoing >/dev/null
  for rule in "${rules[@]}"; do
    # ufw rejects some characters in comments (e.g. the apostrophe in "Let's")
    ufw allow "${rule%% *}" comment "$(tr -cd 'A-Za-z0-9 ()/._-' <<<"${rule#* }")" >/dev/null
  done
  ufw --force enable >/dev/null
  ufw status verbose

  harden_ssh
}

# Optional: key-only SSH login, only when some key is installed
harden_ssh() {
  local conf=/etc/ssh/sshd_config.d/00-vpn-hardening.conf keys
  keys=$(cat /root/.ssh/authorized_keys /home/*/.ssh/authorized_keys 2>/dev/null | grep -cE '^(ssh-|ecdsa-|sk-)' || true)
  if ((keys == 0)); then
    warn "no SSH keys in authorized_keys, keeping password login"
    return
  fi
  grep -qE '^Include /etc/ssh/sshd_config.d/' /etc/ssh/sshd_config || {
    warn "sshd_config doesn't include sshd_config.d, skipping SSH hardening"
    return
  }
  [[ -f $conf ]] && { info "SSH password login is already disabled ($conf)"; return; }
  ask "Disable SSH password login ($keys keys found in authorized_keys)?" n || return 0
  # First value wins in sshd, hence 00- to override cloud-init's 50-*.conf
  cat >"$conf" <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
EOF
  if ! sshd -t; then
    rm -f "$conf"
    die "sshd rejected the config, nothing changed"
  fi
  if systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null; then
    info "SSH password login disabled ($conf)"
  else
    warn "couldn't reload sshd; $conf applies after sshd restarts"
  fi
}

# --- main --------------------------------------------------------------------

args=()
for arg in "$@"; do
  [[ $arg == -y ]] && ASSUME_YES=true || args+=("$arg")
done
set -- "${args[@]+"${args[@]}"}"

cmd=${1:-help}
(($#)) && shift
case $cmd in
  deploy | init | up | render | user | rotate | prune | update | firewall) lock ;;
esac
case $cmd in
  deploy) cmd_deploy ;;
  init) cmd_init ;;
  up) cmd_up ;;
  down) "$DOCKER" compose down ;;
  logs) "$DOCKER" compose logs -f --tail=100 ;;
  tune) cmd_tune ;;
  install-docker) cmd_install_docker ;;
  firewall) cmd_firewall "$@" ;;
  user) cmd_user "$@" ;;
  links) cmd_links "$@" ;;
  rotate) cmd_rotate "$@" ;;
  update) cmd_update "$@" ;;
  render) cmd_render ;;
  prune) cmd_prune ;;
  help | -h | --help) usage ;;
  *) echo "unknown command: $cmd" >&2; usage >&2; exit 1 ;;
esac
