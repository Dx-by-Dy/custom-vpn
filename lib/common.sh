# shellcheck shell=bash
# Helpers shared by all commands: messages, prompts, .env, rendering; sourced by vpn.sh

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
  grep -qE '^XRAY_(PORT|PRIVATE_KEY)=' "$ENV_FILE" && die "$ENV_FILE is from the xray version, run: ./vpn.sh init"
  set -a; . "./$ENV_FILE"; set +a
  REALITY_TARGET=${REALITY_TARGET:-$REALITY_SNI:443}
  local host=${REALITY_TARGET%:*}
  host=${host#[}
  export REALITY_TARGET_HOST=${host%]} REALITY_TARGET_PORT=${REALITY_TARGET##*:}
  # caddy's certificate for DOMAIN: on the host and in the sing-box container
  CERT=data/caddy/caddy/certificates/acme-v02.api.letsencrypt.org-directory/$DOMAIN/$DOMAIN.crt
  export CERT_DIR=/caddy-data/caddy/certificates/acme-v02.api.letsencrypt.org-directory/$DOMAIN
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

singbox_cli() { "$DOCKER" run --rm "$SINGBOX_IMAGE" "$@"; }

# Install a missing command from the package of the same name, asking first
need_pkg() {
  local pkg=$1 why=$2
  command -v "$pkg" >/dev/null && return
  command -v apt-get >/dev/null || die "$pkg is not installed ($why)"
  ask "$pkg is not installed ($why). Install it?" y || die "$pkg is required"
  local out
  out=$(DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$pkg" 2>&1) || die "can't install $pkg: $out"
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

# Render a jq template (templates/*.jq); every $ENV.VAR it uses must be non-empty
render_jq() {
  local tpl=$1 out=$2 service=$3 var content
  shift 3
  for var in $(grep -o '\$ENV\.[A-Z0-9_]*' "$tpl" | cut -d. -f2 | sort -u); do
    [[ -n ${!var:-} ]] || die "$var is empty (used in $tpl)"
  done
  content=$(jq -n "$@" -f "$tpl") || die "can't render $tpl"
  write_file "$out" "$content" "$service"
}
