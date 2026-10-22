#!/usr/bin/env bash
# Direct-egress capacity: how many minimal client runs does a fresh GitHub
# runner IP get before OpenCode's free-tier limit? No proxy, no hosts changes.
set -uo pipefail
mkdir -p /tmp/lab
unset HTTP_PROXY HTTPS_PROXY http_proxy https_proxy ALL_PROXY all_proxy NO_PROXY no_proxy

MODEL="${MODEL:-opencode/big-pickle}"
MAX_RUNS="${MAX_RUNS:-80}"
WAIT_SECONDS="${WAIT_SECONDS:-0}"

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

ISO=/tmp/iso-direct
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
COLO=$(curl -sS -m 12 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | awk -F= '/^colo=/{print $2}')
echo "runner egress: ${DIRECT_EG:-unknown} colo=${COLO:-?}"
echo "CAPACITY START relay=direct egress=${DIRECT_EG:-unknown} colo=${COLO:-?} model=$MODEL max_runs=$MAX_RUNS"

ok=0
limited_at=0
transport=0
i=0
while [ "$i" -lt "$MAX_RUNS" ]; do
  i=$((i + 1))
  log="/tmp/lab/direct-$i.log"
  (
    cd "$ISO/work" || exit 1
    HOME="$ISO/home" XDG_CONFIG_HOME="$ISO/home/.config" \
      setsid -w timeout 45 "$BIN" run --standalone --model "$MODEL" "Reply with exactly: OK" > "$log" 2>&1
  )
  rc=$?
  err=$(sed 's/\x1b\[[0-9;]*m//g' "$log" | grep -aE '^Error:' | head -1 | cut -c1-100)
  if [ "$rc" -eq 0 ]; then
    result=SUCCESS
  elif sed 's/\x1b\[[0-9;]*m//g' "$log" | tail -5 | grep -qE '^Error: Free usage limit reached'; then
    result=LIMITED
  else
    result=ERROR
  fi
  printf 'run %-3d result=%-7s rc=%-3s %s\n' "$i" "$result" "$rc" "$err"
  if [ "$result" = SUCCESS ]; then
    ok=$((ok + 1))
    transport=0
  elif [ "$result" = LIMITED ]; then
    limited_at=$i
    break
  else
    transport=$((transport + 1))
    if [ "$transport" -ge 5 ]; then
      echo "too many transport errors, stopping"
      break
    fi
  fi
done

echo "CAPACITY relay=direct egress=${DIRECT_EG:-unknown} colo=${COLO:-?} successes=$ok first_non_success_run=$limited_at"

if [ "$limited_at" -gt 0 ] && [ "$WAIT_SECONDS" -gt 0 ]; then
  echo "RESET waiting ${WAIT_SECONDS}s after first non-success ..."
  sleep "$WAIT_SECONDS"
  log=/tmp/lab/direct-after-wait.log
  (
    cd "$ISO/work" || exit 1
    HOME="$ISO/home" XDG_CONFIG_HOME="$ISO/home/.config" \
      setsid -w timeout 45 "$BIN" run --standalone --model "$MODEL" "Reply with exactly: OK" > "$log" 2>&1
  )
  rc=$?
  err=$(sed 's/\x1b\[[0-9;]*m//g' "$log" | grep -aE '^Error:' | head -1 | cut -c1-100)
  echo "RESET result=$([ "$rc" -eq 0 ] && echo SUCCESS || echo NONSUCCESS) rc=$rc ${err}"
fi
