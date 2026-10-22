#!/usr/bin/env bash
# Capacity test: find a fresh relay, then keep sending real client requests
# through it until the free-tier limit hits (or MAX_RUNS is reached).
set -uo pipefail
mkdir -p /tmp/lab
unset HTTP_PROXY HTTPS_PROXY http_proxy https_proxy ALL_PROXY all_proxy NO_PROXY no_proxy

BASE="${BASE:-https://raw.githubusercontent.com/Xiaobei09/proxyip/main}"
SOURCE="${SOURCE:-all.txt}"
MODEL="${MODEL:-opencode/big-pickle}"
RELAY="${RELAY:-}"
MAX_RUNS="${MAX_RUNS:-30}"
WAIT_SECONDS="${WAIT_SECONDS:-0}"
WS="${GITHUB_WORKSPACE:-$PWD}"

sudo cp /etc/hosts /tmp/lab/hosts.orig

echo '--- install opencode ---'
curl -fsSL --retry 3 https://opencode.ai/v2/install | bash >/tmp/lab/install.log 2>&1
export PATH="$HOME/.opencode/bin:$PATH"
BIN="$(command -v opencode || true)"
[ -z "$BIN" ] && BIN="$HOME/.opencode/bin/opencode"
"$BIN" --version || true

ISO=/tmp/iso
rm -rf "$ISO"
mkdir -p "$ISO/work" "$ISO/home/.config/opencode"
git init -q "$ISO/work"
cat > "$ISO/home/.config/opencode/opencode.json" <<'JSON'
{
  "$schema": "https://opencode.ai/config.json",
  "permission": {
    "read": "allow", "glob": "allow", "grep": "allow", "list": "allow",
    "bash": "deny", "edit": "deny", "task": "deny", "external_directory": "deny",
    "todowrite": "deny", "question": "deny", "webfetch": "deny", "websearch": "deny",
    "lsp": "deny", "doom_loop": "deny", "skill": "deny", "execute": "deny"
  }
}
JSON

DIRECT_EG=$(curl -sS -m 12 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | awk -F= '/^ip=/{print $2}')
echo "runner egress: ${DIRECT_EG:-unknown}"

map_relay() {
  ip=${1%:*}; port=${1##*:}
  sudo pkill -f "$WS/scripts/forward.py" >/dev/null 2>&1 || true
  sudo nohup python3 "$WS/scripts/forward.py" "$ip" "$port" >/tmp/lab/forward.log 2>&1 &
  sleep 0.7
  sudo cp /tmp/lab/hosts.orig /etc/hosts
  echo "127.0.0.1 opencode.ai" | sudo tee -a /etc/hosts >/dev/null
  echo "mapped 127.0.0.1:443 -> $1"
}

run_client() {
  label="$1"
  log="/tmp/lab/cap-$label.log"
  (
    cd "$ISO/work" || exit 1
    HOME="$ISO/home" XDG_CONFIG_HOME="$ISO/home/.config" \
      setsid -w timeout 30 "$BIN" run --standalone --model "$MODEL" "Reply with exactly: OK" > "$log" 2>&1
  )
  RC=$?
  ERR=$(sed 's/\x1b\[[0-9;]*m//g' "$log" | grep -aE '^Error:' | head -1 | cut -c1-100)
  if [ "$RC" -eq 0 ]; then
    RESULT=SUCCESS
  elif sed 's/\x1b\[[0-9;]*m//g' "$log" | tail -5 | grep -qE '^Error: Free usage limit reached'; then
    RESULT=LIMITED
  else
    RESULT=ERROR
  fi
}

# ---- find a fresh relay (unless one was given) ----
if [ -z "$RELAY" ] || [ "$RELAY" = 'auto' ]; then
  curl -fsSL --retry 5 --retry-delay 2 --max-time 180 "$BASE/data/valid/$SOURCE" -o /tmp/lab/relays.txt || exit 1
  shuf -n 40 /tmp/lab/relays.txt | cut -d'#' -f1 | awk '!seen[$0]++' > /tmp/lab/candidates.txt
  declare -A seen_eg=()
  while read -r hp; do
    [ -z "$hp" ] && continue
    ip=${hp%:*}; port=${hp##*:}
    trace=$(curl -sS -m 10 --connect-to www.cloudflare.com:443:"$ip":"$port" https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null || true)
    eg=$(printf '%s\n' "$trace" | awk -F= '/^ip=/{print $2}')
    [ -z "$eg" ] && continue
    [ "$eg" = "$DIRECT_EG" ] && continue
    [ -n "${seen_eg[$eg]:-}" ] && continue
    seen_eg[$eg]="$hp"
    map_relay "$hp"
    run_client "probe"
    echo "probe $hp egress=$eg -> $RESULT ${ERR}"
    if [ "$RESULT" = SUCCESS ]; then
      RELAY="$hp"; EGRESS="$eg"; COLO=$(printf '%s\n' "$trace" | awk -F= '/^colo=/{print $2}')
      break
    fi
  done < /tmp/lab/candidates.txt
else
  ip=${RELAY%:*}; port=${RELAY##*:}
  trace=$(curl -sS -m 10 --connect-to www.cloudflare.com:443:"$ip":"$port" https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null || true)
  EGRESS=$(printf '%s\n' "$trace" | awk -F= '/^ip=/{print $2}')
  COLO=$(printf '%s\n' "$trace" | awk -F= '/^colo=/{print $2}')
  map_relay "$RELAY"
fi

if [ -z "$RELAY" ]; then
  echo 'CAPACITY: no fresh relay found'
  exit 0
fi

echo "CAPACITY START relay=$RELAY egress=$EGRESS colo=$COLO model=$MODEL max_runs=$MAX_RUNS"
map_relay "$RELAY"

ok=0
limited_at=0
transport=0
i=0
while [ "$i" -lt "$MAX_RUNS" ]; do
  i=$((i + 1))
  run_client "run-$i"
  conns=$(grep -ac '^connect ' /tmp/lab/forward.log 2>/dev/null || true)
  [ -z "$conns" ] && conns=0
  printf 'run %-2d result=%-7s rc=%-3s conns=%-3s %s\n' "$i" "$RESULT" "$RC" "$conns" "$ERR"
  if [ "$RESULT" = SUCCESS ]; then
    ok=$((ok + 1))
    transport=0
  elif [ "$RESULT" = LIMITED ]; then
    limited_at=$i
    break
  else
    transport=$((transport + 1))
    echo "transport/error streak=$transport (continuing)"
    if [ "$transport" -ge 5 ]; then
      echo "too many transport errors, stopping"
      break
    fi
  fi
done

echo "CAPACITY relay=$RELAY egress=$EGRESS colo=$COLO successes=$ok first_non_success_run=$limited_at total_conns=$(grep -ac '^connect ' /tmp/lab/forward.log 2>/dev/null || echo 0)"

if [ "$limited_at" -gt 0 ] && [ "$WAIT_SECONDS" -gt 0 ]; then
  echo "RESET waiting ${WAIT_SECONDS}s after first non-success ..."
  sleep "$WAIT_SECONDS"
  run_client "after-wait"
  echo "RESET result=$RESULT rc=$RC ${ERR}"
fi

sudo cp /tmp/lab/hosts.orig /etc/hosts
