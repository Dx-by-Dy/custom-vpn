#!/usr/bin/env bash
# Control's code update orders (lib/remote.sh), without DNS and servers:
# - the record control builds opens only with control's signature and the
#   update key; another signer, a snapshot's signature or a changed byte fail;
# - an order reaches the hub or exit it is for (the hash of its key), no other;
# - a server goes only forward along its branch, goes back when its check gets
#   worse, and doesn't try that order again until control orders it anew;
# - the way back: only to the commit control marked and this server ran; by order,
#   by hand, without GitHub, with the code at HEAD broken; a hold against old orders.
#
#   tests/update.sh          (needs age, ssh-keygen, git, jq; no network)
set -euo pipefail
shopt -s inherit_errexit
cd "$(dirname "$(readlink -f "$0")")/.."
REPO=$PWD
for c in age age-keygen ssh-keygen git jq; do
  command -v "$c" >/dev/null || { echo "error: $c is needed" >&2; exit 1; }
done
WORK=$(mktemp -d)
trap 'if [[ -n ${KEEP:-} ]]; then echo "kept $WORK"; else rm -rf "$WORK"; fi' EXIT
export TMPDIR=$WORK GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
step() { echo "== $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

# vpn.sh's settings and functions in this shell (run it in a subshell)
libs() {
  eval "$(sed -n '/^ENV_FILE=/,/^ASSUME_YES=/p' "$REPO/vpn.sh")"
  local f
  for f in common users setup render service update firewall uninstall exit routes control dns client remote; do
    # shellcheck source=/dev/null
    . "$REPO/lib/$f.sh"
  done
  load_env
}

step "control builds a record"
C=$WORK/control
mkdir -p "$C/data/control" "$C/generated"
ssh-keygen -q -t ed25519 -N '' -C cvpn-control -f "$C/data/control/sign"
printf 'ROLE=control\nCONTROL_DOMAIN="ctl.example.org ctl2.example.net"\nSUB_NAME=t\n' >"$C/.env"
age-keygen -o "$WORK/hub1.key" 2>/dev/null
age-keygen -o "$WORK/hub2.key" 2>/dev/null
hub_token() {
  jq -cn --arg r "$(age-keygen -y "$WORK/$1.key")" --arg d "$1.example.org" '
    {v: 1, domain: $d, vless_port: 443, hysteria_port: 443, sub_port: 8443, sni: "s.example", public_key: "P", short_id: "00", recipient: $r}' |
    base64 -w0 | sed 's/^/cvpn-hub:/'
}
exit_token() {
  jq -cn --arg pbk "$1" '{v: 1, address: "198.51.100.1", port: 443, sni: "s.example", public_key: $pbk, short_id: "00",
    ips: [{name: "ip1", ip: "198.51.100.1", uuid: "11111111-2222-3333-4444-555555555555"}]}' | base64 -w0 | sed 's/^/cvpn-exit:/'
}
printf '# hub  token\nhub1 %s\nhub2 %s\n' "$(hub_token hub1)" "$(hub_token hub2)" >"$C/hubs.conf"
printf '# exit  token\ncz1 %s\ncz2 %s\n' "$(exit_token PBK-CZ1)" "$(exit_token PBK-CZ2)" >"$C/exits.conf"
A=1111111111111111111111111111111111111111
B=2222222222222222222222222222222222222222
(
  cd "$C" && libs
  echo "$B" >"$STABLE_FILE"
  scheme_json >"$PUBLISHED_FILE"
  control_update hub hub1 "$A" >/dev/null
  control_update exit cz2 "$B" >/dev/null
  # the order shows in diff before publish
  cmd_control_diff | grep -q "update + exit cz2: to ${B:0:12}" || { cmd_control_diff; exit 1; }
  update_build 42 "$(control_hubs_json)"
)
LINE=$(<"$C/generated/update.txt")
[[ $LINE =~ ^cvpn-upd1\.[A-Za-z0-9+/=]{100,}\.[A-Za-z0-9+/=]{100,}$ ]] || fail "not a record: ${LINE:0:40}"
# (not three-letter names: they turn up in base64 by chance, about one run in 150)
for n in hub1 hub2 "$A" "$B" example; do
  [[ $LINE != *"$n"* ]] || fail "the record shows $n"
done
[[ ${#LINE} -le 2000 ]] || fail "the record is ${#LINE} chars"
echo "   ${#LINE} chars, names and commits not in it"

# server DIR ROLE: a hub or an exit that follows this control
server() {
  local dir=$1 role=$2
  mkdir -p "$dir/data/control"
  {
    cat "$REPO/.env.example"
    echo "ROLE=$role"
    echo "CONTROL_KEY=\"$(cat "$C/data/control/sign.pub")\""
    echo 'CONTROL_DOMAIN="ctl.example.org"'
  } >"$dir/.env"
  cp "$C/data/control/update.key" "$dir/data/control/update.key"
}
# stable_in DIR LINE: the stable commit in the record
stable_in() {
  (
    cd "$1" && libs
    t= && tmp_dir t
    update_read "$2" "$t" | jq -r '.stable // "none"'
  )
}
# orders DIR LINE: what this server reads from LINE (its order, or "none")
orders() {
  (
    cd "$1" && libs
    t= && tmp_dir t
    json=$(update_read "$2" "$t") || exit 3
    jq -r --arg id "$(update_my_id)" '.orders[$id].commit // "none"' <<<"$json"
  )
}

step "each server finds only its order"
server "$WORK/hub1" hub
cp "$WORK/hub1.key" "$WORK/hub1/data/control/age.key"
server "$WORK/hub2" hub
cp "$WORK/hub2.key" "$WORK/hub2/data/control/age.key"
server "$WORK/cz1" exit
echo 'REALITY_PUBLIC_KEY=PBK-CZ1' >>"$WORK/cz1/.env"
server "$WORK/cz2" exit
echo 'REALITY_PUBLIC_KEY=PBK-CZ2' >>"$WORK/cz2/.env"
[[ $(orders "$WORK/hub1" "$LINE") == "$A" ]] || fail "hub1 doesn't see its order"
[[ $(orders "$WORK/hub2" "$LINE") == none ]] || fail "hub2 sees an order"
[[ $(orders "$WORK/cz1" "$LINE") == none ]] || fail "cz1 sees an order"
[[ $(orders "$WORK/cz2" "$LINE") == "$B" ]] || fail "cz2 doesn't see its order"
[[ $(stable_in "$WORK/cz1" "$LINE") == "$B" ]] || fail "the record doesn't carry the stable commit"

step "a record that isn't control's doesn't open"
data=${LINE##*.}
sig=${LINE#cvpn-upd1.}
sig=${sig%%.*}
# a changed byte of the data
bad=${data:0:100}$([[ ${data:100:1} == A ]] && echo B || echo A)${data:101}
orders "$WORK/cz2" "cvpn-upd1.$sig.$bad" >/dev/null 2>&1 && fail "a changed record opened"
# signed by someone else
ssh-keygen -q -t ed25519 -N '' -f "$WORK/other"
base64 -d <<<"$data" >"$WORK/data"
ssh-keygen -Y sign -q -f "$WORK/other" -n cvpn-update "$WORK/data"
orders "$WORK/cz2" "cvpn-upd1.$(base64 -w0 "$WORK/data.sig").$data" >/dev/null 2>&1 && fail "another signer's record opened"
# control's signature, but for snapshots (another namespace)
rm -f "$WORK/data.sig"
ssh-keygen -Y sign -q -f "$C/data/control/sign" -n cvpn-state "$WORK/data"
orders "$WORK/cz2" "cvpn-upd1.$(base64 -w0 "$WORK/data.sig").$data" >/dev/null 2>&1 && fail "a snapshot's signature opened it"
# another update key
age-keygen -o "$WORK/cz2/data/control/update.key.new" 2>/dev/null
mv "$WORK/cz2/data/control/update.key.new" "$WORK/cz2/data/control/update.key"
orders "$WORK/cz2" "$LINE" >/dev/null 2>&1 && fail "it opened with another update key"
echo "   changed data, another signer, a snapshot's signature, another key: refused"

step "a server goes forward, back when check gets worse, and once only"
# upstream: c0 -> c1 -> c2 -> c3 (c3 breaks check); a side branch c4
U=$WORK/upstream
git init -q -b main "$U"
echo 0 >"$U/zero" && git -C "$U" add zero && git -C "$U" commit -qm c0
c0=$(git -C "$U" rev-parse HEAD)
cat >"$U/vpn.sh" <<'EOF'
#!/usr/bin/env bash
# a stand-in: check fails at "route" if the file "broken" is here; update repo
# moves to the commit like the real one does
cd "$(dirname "$0")"
[[ $1 == -y ]] && shift
case $1 in
  check) echo "containers   ok"; [[ -f broken ]] && { echo "route        FAIL: broken"; exit 1; }; echo "route        ok" ;;
  deploy) echo "$(git rev-parse HEAD)" >>deploys.log ;;
  update) git fetch -q "$UPSTREAM" main && git reset -q --hard "$3" && echo "$3" >>updates.log ;;
esac
EOF
chmod +x "$U/vpn.sh"
git -C "$U" add vpn.sh && git -C "$U" commit -qm c1
c1=$(git -C "$U" rev-parse HEAD)
echo 2 >"$U/two" && mkdir "$U/lib" && echo 'STABLE_SCRIPT=x' >"$U/lib/remote.sh" && git -C "$U" add two lib && git -C "$U" commit -qm c2
c2=$(git -C "$U" rev-parse HEAD)
touch "$U/broken" && git -C "$U" add broken && git -C "$U" commit -qm c3
c3=$(git -C "$U" rev-parse HEAD)
git -C "$U" checkout -q -b side "$c1"
echo 4 >"$U/four" && git -C "$U" add four && git -C "$U" commit -qm c4
c4=$(git -C "$U" rev-parse HEAD)
git -C "$U" checkout -q main
S=$WORK/server
git clone -q "$U" "$S"
git -C "$S" reset -q --hard "$c1"
server "$S" exit
printf 'REALITY_PUBLIC_KEY=PBK\nREPO_URL=%s\n' "$U" >>"$S/.env"
export UPSTREAM=$U UPDATE_SETTLE=0
run() { (cd "$S" && libs && update_run "$1") >"$WORK/run.log" 2>&1 || { cat "$WORK/run.log"; fail "update_run"; }; }
result() { jq -r .result "$S/data/control/update.json"; }
here() { git -C "$S" rev-parse HEAD; }

run "{\"commit\": \"$c2\", \"at\": 1}"
[[ $(here) == "$c2" && $(result) == ok ]] || fail "c1 -> c2: at $(here), $(result)"
run "{\"commit\": \"$c1\", \"at\": 2}"
[[ $(here) == "$c2" && $(result) == *"only go forward"* ]] || fail "c2 -> c1 went back: $(result)"
run "{\"commit\": \"$c4\", \"at\": 3}"
[[ $(here) == "$c2" && $(result) == *"isn't on main"* ]] || fail "c4 (another branch): $(result)"
run "{\"commit\": \"$c3\", \"at\": 4}"
[[ $(here) == "$c2" && $(result) == *"broke route"* ]] || fail "c3 broke check, but: at $(here), $(result)"
n=$(wc -l <"$S/updates.log")
run "{\"commit\": \"$c3\", \"at\": 4}"
[[ $(wc -l <"$S/updates.log") == "$n" ]] || fail "the same order was tried again"
run "{\"commit\": \"$c3\", \"at\": 5}"
[[ $(wc -l <"$S/updates.log") -gt $n ]] || fail "a new order for c3 wasn't tried"
run ""
[[ $(result) == "no order" ]] || fail "no order: $(result)"
echo "   forward to c2; not back to c1, not to another branch; c3 broke check: back, once"

step "control names the stable commit and orders the way back"
K=$WORK/control2
git clone -q "$U" "$K"
mkdir -p "$K/data/control" "$K/generated"
cp "$C"/data/control/sign* "$K/data/control/"
cp "$C/.env" "$C/hubs.conf" "$C/exits.conf" "$K/"
(
  cd "$K" && libs
  ASSUME_YES=true
  scheme_json >"$PUBLISHED_FILE"
  cmd_publish() { echo published >>"$K/published.log"; }
  # code from before rollbacks can't be stable, one that's not here neither
  (cmd_stable "$c1") >/dev/null 2>&1 && exit 11
  (cmd_stable 3333333333333333333333333333333333333333) >/dev/null 2>&1 && exit 12
  (control_rollback hub1) >/dev/null 2>&1 && exit 13
  cmd_stable "$c2" >/dev/null
  [[ $(<"$STABLE_FILE") == "$c2" ]] || exit 14
  cmd_control_diff | grep -q "stable ~ - -> ${c2:0:12}" || { cmd_control_diff; exit 15; }
  (control_rollback nosuch) >/dev/null 2>&1 && exit 16
  control_rollback hub1 cz2 >/dev/null
  [[ $(wc -l <"$K/published.log") == 1 ]] || exit 17
  grep -q "^hub hub1 $c2 [0-9]* back$" "$UPDATES_FILE" && grep -q "^exit cz2 $c2 [0-9]* back$" "$UPDATES_FILE" || exit 18
  update_build 43 "$(control_hubs_json)"
  # a later order isn't "back" any more
  control_update hub hub1 "$c3" >/dev/null
  grep -q "^hub hub1 $c3 [0-9]*$" "$UPDATES_FILE" || exit 19
  control_rollback --all >/dev/null
  [[ $(conf_rows "$UPDATES_FILE" | wc -l) == 4 ]] || exit 20
) || fail "control's stable / rollback: step $?"
(cd "$WORK/hub1" && cp "$K/data/control/update.key" data/control/update.key && cp "$K/data/control/sign.pub" "$WORK/sign2.pub"
  sed -i "s|^CONTROL_KEY=.*|CONTROL_KEY=\"$(cat "$WORK/sign2.pub")\"|" .env && libs
  t= && tmp_dir t
  update_read "$(<"$K/generated/update.txt")" "$t" |
    jq -e --arg id "$(update_my_id)" --arg c "$c2" '.orders[$id] | .commit == $c and .back == true' >/dev/null) ||
  fail "the record doesn't say back"
echo "   old code, unknown commits and names refused; the record says back"

step "a server goes back only by such an order, and only to what it ran"
keep() { (cd "$S" && libs && stable_keep "$1") >"$WORK/run.log" 2>&1 || { cat "$WORK/run.log"; fail "stable_keep"; }; }
back() { run "{\"commit\": \"$1\", \"at\": $2, \"back\": true}"; }
back "$c1" 10
[[ $(here) == "$c1" && $(result) == ok ]] || fail "back to c1, which ran here: at $(here), $(result)"
run "{\"commit\": \"$c2\", \"at\": 11}"
[[ $(here) == "$c2" && $(result) == ok ]] || fail "forward again after going back: $(result)"
back "$c0" 12
[[ $(here) == "$c2" && $(result) == *"never ran here"* ]] || fail "back to c0, which never ran here: at $(here), $(result)"
back "$c4" 13
[[ $(here) == "$c2" && $(result) == *"isn't on main"* ]] || fail "back to another branch: $(result)"
# without GitHub: back works if the commit is here, forward waits
sed -i "s|^REPO_URL=.*|REPO_URL=$WORK/nowhere|" "$S/.env"
run "{\"commit\": \"$c3\", \"at\": 14}"
[[ $(here) == "$c2" && $(result) == *"can't fetch"* ]] || fail "forward without GitHub: $(result)"
back "$c1" 15
[[ $(here) == "$c1" && $(result) == ok ]] || fail "back without GitHub: at $(here), $(result)"
sed -i "s|^REPO_URL=.*|REPO_URL=$U|" "$S/.env"
run "{\"commit\": \"$c2\", \"at\": 16}"
# back into something broken stays there and says so: there's nowhere better
git -C "$U" rm -q broken && git -C "$U" commit -qm c5
c5=$(git -C "$U" rev-parse HEAD)
run "{\"commit\": \"$c5\", \"at\": 17}"
[[ $(here) == "$c5" && $(result) == ok ]] || fail "forward to c5: at $(here), $(result)"
back "$c3" 18
[[ $(here) == "$c3" && $(result) == *"as ordered, but check fails at: route"* ]] || fail "back to c3, which fails check: at $(here), $(result)"
# the real update repo on a day without GitHub: what's here works, the rest says so
git -C "$S" reset -q --hard "$c2"
sed -i "s|^REPO_URL=.*|REPO_URL=$WORK/nowhere|" "$S/.env"
(cd "$S" && libs && ASSUME_YES=true && cmd_update_repo "$c1") >"$WORK/run.log" 2>&1 || { cat "$WORK/run.log"; fail "update repo COMMIT without GitHub"; }
[[ $(here) == "$c1" ]] || fail "update repo COMMIT without GitHub: at $(here)"
(cd "$S" && libs && ASSUME_YES=true && cmd_update_repo "$c2") >/dev/null 2>&1 && fail "update repo went forward without GitHub"
(cd "$S" && libs && ASSUME_YES=true && cmd_update_repo) >/dev/null 2>&1 && fail "update repo without a commit and GitHub"
sed -i "s|^REPO_URL=.*|REPO_URL=$U|" "$S/.env"
echo "   to a commit it ran, with or without GitHub; not to others"

step "by hand: works with the code at HEAD broken, and old orders wait"
git -C "$S" reset -q --hard "$c2"
keep "$c1"
[[ -x $S/data/control/rollback.sh && $(<"$S/data/control/stable") == "$c1" ]] || fail "no way back kept"
grep -q "git reset -q --hard $c1" "$S/data/control/rollback.sh" || fail "the script doesn't go to the stable commit"
echo 'garbage(' >"$S/vpn.sh"
: >"$S/deploys.log"
env -u GIT_CONFIG_COUNT sh "$S/data/control/rollback.sh" >"$WORK/rb.log" 2>&1 || { cat "$WORK/rb.log"; fail "the script failed"; }
[[ $(here) == "$c1" && $(<"$S/deploys.log") == "$c1" ]] || fail "the script: at $(here), deployed $(cat "$S/deploys.log")"
[[ -s $S/data/control/update.hold ]] || fail "no hold"
grep -q '^ROLE=exit' "$S/.env" && ls "$S"/backups/state-*.tar.gz >/dev/null || fail "state lost or not saved"
# an order from before the hold doesn't bring back what was just left; a new one does
run "{\"commit\": \"$c2\", \"at\": 18}"
[[ $(here) == "$c1" && $(result) == *"rolled back by hand"* ]] || fail "an old order undid the rollback: at $(here), $(result)"
run "{\"commit\": \"$c2\", \"at\": $(($(date +%s) + 60))}"
[[ $(here) == "$c2" && $(result) == ok && ! -e $S/data/control/update.hold ]] || fail "a new order: at $(here), $(result)"
# the command does the same; without a stable commit and with a bad one it says so
(cd "$S" && libs && ASSUME_YES=true && cmd_rollback "$c1") >"$WORK/rb.log" 2>&1 || { cat "$WORK/rb.log"; fail "rollback COMMIT"; }
[[ $(here) == "$c1" ]] || fail "rollback COMMIT: at $(here)"
keep ""
[[ ! -e $S/data/control/stable && ! -e $S/data/control/rollback.sh ]] || fail "the stable commit stays after control dropped it"
(cd "$S" && libs && ASSUME_YES=true && cmd_rollback) >/dev/null 2>&1 && fail "rollback with no stable commit"
(cd "$S" && libs && ASSUME_YES=true && cmd_rollback 3333333) >/dev/null 2>&1 && fail "rollback to an unknown commit"
echo "   garbage in vpn.sh, the state kept, old orders wait, new ones lift it"
echo ok
