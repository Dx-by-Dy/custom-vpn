# shellcheck shell=bash
# Updating images and this repository; sourced by vpn.sh


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
    rules)
      require_role hub "update rules"
      rule_sets_refresh 0
      info "RU lists: $(rule_sets_json | jq -r 'join(", ")') ($RULE_SETS_DIR)"
      ;;
    *) die "usage: $(vsh update) images|repo|rules" ;;
  esac
}

cmd_update_images() {
  load_env
  local sb c var new changes=()
  sb=$(latest_release SagerNet/sing-box) || die "can't reach GitHub"
  c=$(latest_release caddyserver/caddy) || die "can't reach GitHub"
  declare -A latest=(
    [SINGBOX_IMAGE]="${SINGBOX_IMAGE%:*}:$sb" # ghcr tags keep the "v"
    [CADDY_IMAGE]="${CADDY_IMAGE%:*}:${c#v}-alpine"
  )
  local vars=(SINGBOX_IMAGE)
  [[ $ROLE == exit ]] || vars+=(CADDY_IMAGE)
  for var in "${vars[@]}"; do
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

  need_pkg git "updates are fetched with it"
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
  for f in "${CONF_FILES[@]}"; do [[ -f $f ]] && files+=("$f"); done
  tar -czf "$backup" "${files[@]}"
  ls -1t backups/state-*.tar.gz | tail -n +11 | xargs -r rm -f
  sums=$(sha256sum "${files[@]}")

  git reset -q --hard "$new"

  if [[ -n $sums ]] && ! sha256sum --quiet -c <<<"$sums" >/dev/null 2>&1; then
    tar -xzf "$backup"
    die "local state changed during the update; restored it from $backup"
  fi
  info "code updated to $(git log -1 --format='%h %s' "$new") (state backup: $backup)"

  # Continue with the new vpn.sh: new .env keys, configs, restarts of what changed, timer
  exec 9>&-
  exec ./vpn.sh deploy
}
