#!/usr/bin/env bash
# Hot-swap proof: one long-lived OpenCode process, egress switched mid-run.
#
# Phase 1  direct egress, client talks to a local CONNECT proxy.
# Phase 2  after the first model round-trips, the proxy's upstream is switched
#          to a proxyip relay and all live tunnels are closed, so the next
#          request has to reconnect through the relay - without restarting
#          OpenCode.
#
# Output: proxy.log shows every CONNECT and which upstream served it.
set -uo pipefail
mkdir -p /tmp/lab
unset HTTP_PROXY HTTPS_PROXY http_proxy https_proxy ALL_PROXY all_proxy NO_PROXY no_proxy

MODEL="${MODEL:-opencode/big-pickle}"
SOURCE="${SOURCE:-all_rep_verified.txt}"
RELAY="${RELAY:-}"
COUNT="${COUNT:-8}"
RANK="${RANK:-1}"
SWITCH_DELAY="${SWITCH_DELAY:-2}"
WS="${GITHUB_WORKSPACE:-$PWD}"
UP=/tmp/lab/upstream
EPOCH=/tmp/lab/epoch
PROXY_LOG=/tmp/lab/proxy.log

echo direct > "$UP"
echo 0 > "$EPOCH"
: > "$PROXY_LOG"

bump_epoch() {
  e=$(cat "$EPOCH" 2>/dev/null || echo 0)
  echo $((e + 1)) > "$EPOCH"
}

echo '--- install opencode ---'
: > /tmp/lab/install.log
export PATH="$HOME/.opencode/bin:$PATH"
BIN=''
for attempt in 1 2 3 4; do
  echo "install attempt $attempt" >> /tmp/lab/install.log
  curl -fsSL --retry 3 --retry-delay 3 https://opencode.ai/v2/install | bash >> /tmp/lab/install.log 2>&1 || true
  BIN="$(command -v opencode || true)"
  if [ -z "$BIN" ] && [ -x "$HOME/.opencode/bin/opencode" ]; then BIN="$HOME/.opencode/bin/opencode"; fi
  if [ -n "$BIN" ] && [ -x "$BIN" ]; then break; fi
  sleep $((attempt * 5))
done
if [ -z "$BIN" ] || [ ! -x "$BIN" ]; then
  echo 'opencode install failed after retries'
  tail -30 /tmp/lab/install.log
  exit 1
fi
"$BIN" --version || { echo 'opencode version check failed'; exit 1; }

make_home() {
  d="$1"
  rm -rf "$d"
  mkdir -p "$d/work" "$d/home/.config/opencode"
  git init -q "$d/work"
  cat > "$d/home/.config/opencode/opencode.json" <<'JSON'
{
  "$schema": "https://opencode.ai/config.json",
  "permission": {
    "read": "allow", "glob": "allow", "grep": "allow", "list": "allow",
    "bash": "allow", "edit": "deny", "task": "deny", "external_directory": "deny",
    "todowrite": "deny", "question": "deny", "webfetch": "deny", "websearch": "deny",
    "lsp": "deny", "doom_loop": "deny", "skill": "deny", "execute": "deny"
  }
}
JSON
}

ISO=/tmp/iso-hotswap
ISO_PROBE=/tmp/iso-probe
make_home "$ISO"
make_home "$ISO_PROBE"

proxy_env() {
  echo "HTTP_PROXY=http://127.0.0.1:8080"
  echo "HTTPS_PROXY=http://127.0.0.1:8080"
  echo "http_proxy=http://127.0.0.1:8080"
  echo "https_proxy=http://127.0.0.1:8080"
  echo "NO_PROXY=localhost,127.0.0.1,::1,api.telegram.org,github.com,api.github.com,objects.githubusercontent.com,release-assets.githubusercontent.com,raw.githubusercontent.com,codeload.github.com,registry.npmjs.org"
  echo "no_proxy=localhost,127.0.0.1,::1,api.telegram.org,github.com,api.github.com,objects.githubusercontent.com,release-assets.githubusercontent.com,raw.githubusercontent.com,codeload.github.com,registry.npmjs.org"
}

DIRECT_EG=$(curl -sS -m 12 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | awk -F= '/^ip=/{print $2}')
DIRECT_COLO=$(curl -sS -m 12 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | awk -F= '/^colo=/{print $2}')
echo "runner egress: ${DIRECT_EG:-unknown} colo=${DIRECT_COLO:-?}"

echo '--- start local CONNECT proxy ---'
python3 "$WS/scripts/connect_proxy.py" > "$PROXY_LOG" 2>&1 &
PROXY_PID=$!
trap 'kill "$PROXY_PID" 2>/dev/null || true' EXIT
for _ in $(seq 1 50); do
  if curl -sS -m 2 -x http://127.0.0.1:8080 -o /dev/null https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null; then break; fi
  sleep 0.2
done
DIRECT_PROXY_EG=$(curl -sS -m 12 -x http://127.0.0.1:8080 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | awk -F= '/^ip=/{print $2}')
echo "proxy direct egress: ${DIRECT_PROXY_EG:-unknown}"

run_client() {
  # run_client <iso> <log> <prompt> <timeout> [proxy?]
  iso="$1"; log="$2"; prompt="$3"; tmo="$4"; use_proxy="${5:-1}"
  (
    cd "$iso/work" || exit 1
    if [ "$use_proxy" = 1 ]; then
      env $(proxy_env) HOME="$iso/home" XDG_CONFIG_HOME="$iso/home/.config" \
        setsid -w timeout "$tmo" "$BIN" run --standalone --model "$MODEL" "$prompt" > "$log" 2>&1
    else
      env -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy \
        HOME="$iso/home" XDG_CONFIG_HOME="$iso/home/.config" \
        setsid -w timeout "$tmo" "$BIN" run --standalone --model "$MODEL" "$prompt" > "$log" 2>&1
    fi
  )
}

classify() {
  rc="$1"; log="$2"
  if [ "$rc" -eq 0 ]; then echo SUCCESS
  elif sed 's/\x1b\[[0-9;]*m//g' "$log" | tail -5 | grep -qE '^Error: Free usage limit reached'; then echo LIMITED
  else echo ERROR; fi
}

# ---- pick a relay that still has quota (one real probe per candidate) ----
if [ -z "$RELAY" ] || [ "$RELAY" = auto ]; then
  curl -fsSL --retry 5 --retry-delay 2 --max-time 180 "https://raw.githubusercontent.com/Xiaobei09/proxyip/main/data/valid/$SOURCE" -o /tmp/lab/relays.txt || exit 1
  if [ "$RANK" = 1 ]; then
    python3 "$WS/scripts/rank.py" /tmp/lab/relays.txt "$((COUNT * 6))" > /tmp/lab/ranked.txt || exit 1
    cut -d'#' -f1 /tmp/lab/ranked.txt | awk '!seen[$0]++' > /tmp/lab/candidates.txt
  else
    shuf -n "$((COUNT * 5))" /tmp/lab/relays.txt | cut -d'#' -f1 | awk '!seen[$0]++' > /tmp/lab/candidates.txt
  fi
  echo "selection: source=$SOURCE rank=$RANK candidates=$(wc -l < /tmp/lab/candidates.txt)"
  n=0
  while read -r hp; do
    [ -z "$hp" ] && continue
    n=$((n + 1)); [ "$n" -gt "$COUNT" ] && break
    ip=${hp%:*}; port=${hp##*:}
    code=$(curl -sS -o /dev/null -m 10 -w '%{http_code}' \
      --connect-to opencode.ai:443:"$ip":"$port" https://opencode.ai/zen/v1/models 2>/dev/null || echo 000)
    echo "candidate $hp models=$code"
    [ "$code" != 200 ] && continue
    echo "$hp" > "$UP"
    bump_epoch
    sleep 0.5
    run_client "$ISO_PROBE" "/tmp/lab/probe-$n.log" "Reply with exactly: OK" 45 1
    rc=$?
    res=$(classify "$rc" "/tmp/lab/probe-$n.log")
    echo "probe $hp -> $res rc=$rc"
    if [ "$res" = SUCCESS ]; then RELAY="$hp"; break; fi
  done < /tmp/lab/candidates.txt
fi

if [ -z "$RELAY" ] || [ "$RELAY" = auto ]; then
  echo 'HOTSWAP: no relay with free quota found'
  exit 0
fi

ip=${RELAY%:*}; port=${RELAY##*:}
RELAY_TRACE=$(curl -sS -m 12 --connect-to www.cloudflare.com:443:"$ip":"$port" https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null || true)
RELAY_EG=$(printf '%s\n' "$RELAY_TRACE" | awk -F= '/^ip=/{print $2}')
RELAY_COLO=$(printf '%s\n' "$RELAY_TRACE" | awk -F= '/^colo=/{print $2}')
echo "relay: $RELAY egress=${RELAY_EG:-?} colo=${RELAY_COLO:-?}"

# ---- phase 1: direct, then switch to relay mid-run ----
echo direct > "$UP"
bump_epoch
echo "HOTSWAP START direct=${DIRECT_EG:-?} relay=$RELAY relay_egress=${RELAY_EG:-?}"

PROMPT='You must use the bash tool exactly three times, one command per call, in this order: first `sleep 3; echo one`, then `sleep 3; echo two`, then `sleep 3; echo three`. After the third result, reply with exactly: DONE'
LOG=/tmp/lab/hotswap.log
(
  cd "$ISO/work" || exit 1
  env $(proxy_env) HOME="$ISO/home" XDG_CONFIG_HOME="$ISO/home/.config" \
    setsid -w timeout 120 "$BIN" run --standalone --model "$MODEL" "$PROMPT" > "$LOG" 2>&1
) &
RUN_PID=$!

# wait for the first opencode CONNECT, then switch after a short delay
first=0
for _ in $(seq 1 120); do
  n=$(grep -ac 'target=opencode.ai:443' "$PROXY_LOG" 2>/dev/null || true)
  n=${n:-0}
  if [ "$n" -ge 1 ]; then first=1; break; fi
  sleep 0.5
done
sleep "$SWITCH_DELAY"
n_before=$(grep -ac 'target=opencode.ai:443' "$PROXY_LOG" 2>/dev/null || true)
n_before=${n_before:-0}
echo relay > "$UP"
bump_epoch
echo "--- SWITCH to $RELAY at $(date -u +%Y-%m-%dT%H:%M:%SZ) after ${n_before} CONNECT(s) ---" >> "$PROXY_LOG"

wait "$RUN_PID"; rc=$?
res=$(classify "$rc" "$LOG")
echo "HOTSWAP RESULT=$res rc=$rc first_connect=$first connects_before_switch=$n_before"
echo '--- hotswap log tail ---'
sed 's/\x1b\[[0-9;]*m//g' "$LOG" | tail -8
echo '--- proxy log (opencode + switch) ---'
grep -aE 'target=opencode.ai|SWITCH|epoch' "$PROXY_LOG" | tail -40
echo '--- egress after switch (via proxy trace with RELAY_ALL) ---'
# A separate trace through the relay itself proves the relay exit; the proxy log
# above proves the OpenCode process used it.
echo "relay trace: ip=${RELAY_EG:-?} colo=${RELAY_COLO:-?}"

kill "$PROXY_PID" 2>/dev/null || true
