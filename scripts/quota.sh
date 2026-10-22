#!/usr/bin/env bash
# Batch quota test: run the real OpenCode client through several force-resolve
# relays (or direct) and classify free-tier availability per egress IP.
#
# Isolation:
#   - empty work dir (no repo/README for the model to read)
#   - private HOME + config with ALL tools denied (the free model is agentic)
#   - classification only by rc and the client's own "^Error: Free usage limit reached"
set -uo pipefail
mkdir -p /tmp/lab
unset HTTP_PROXY HTTPS_PROXY http_proxy https_proxy ALL_PROXY all_proxy NO_PROXY no_proxy

BASE="${BASE:-https://raw.githubusercontent.com/Xiaobei09/proxyip/main}"
SOURCE="${SOURCE:-all.txt}"
MODEL="${MODEL:-opencode/big-pickle}"
RELAY="${RELAY:-}"
COUNT="${COUNT:-10}"
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
# Keep read/list/grep/glob available: the server rejects tool-less requests as
# "free tier can only be used from within OpenCode". Deny only side effects.
cat > "$ISO/home/.config/opencode/opencode.json" <<'JSON'
{
  "$schema": "https://opencode.ai/config.json",
  "permission": {
    "read": "allow",
    "glob": "allow",
    "grep": "allow",
    "list": "allow",
    "bash": "deny",
    "edit": "deny",
    "task": "deny",
    "external_directory": "deny",
    "todowrite": "deny",
    "question": "deny",
    "webfetch": "deny",
    "websearch": "deny",
    "lsp": "deny",
    "doom_loop": "deny",
    "skill": "deny"
  }
}
JSON

DIRECT_EG=$(curl -sS -m 12 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | awk -F= '/^ip=/{print $2}')
echo "runner egress: ${DIRECT_EG:-unknown}"

echo '--- build target list ---'
: > /tmp/lab/targets.txt
case "$RELAY" in
  direct)
    echo 'direct' > /tmp/lab/targets.txt
    ;;
  ''|auto)
    curl -fsSL --retry 5 --retry-delay 2 --max-time 180 "$BASE/data/valid/$SOURCE" -o /tmp/lab/relays.txt || exit 1
    shuf -n "$((COUNT * 5))" /tmp/lab/relays.txt | cut -d'#' -f1 | awk '!seen[$0]++' > /tmp/lab/candidates.txt
    echo 'direct' >> /tmp/lab/targets.txt
    declare -A seen_eg=()
    while read -r hp; do
      [ -z "$hp" ] && continue
      ip=${hp%:*}; port=${hp##*:}
      trace=$(curl -sS -m 10 --connect-to www.cloudflare.com:443:"$ip":"$port" https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null || true)
      eg=$(printf '%s\n' "$trace" | awk -F= '/^ip=/{print $2}')
      if [ -z "$eg" ]; then echo "skip $hp (no trace)"; continue; fi
      if [ "$eg" = "$DIRECT_EG" ]; then echo "skip $hp (egress==runner $eg)"; continue; fi
      if [ -n "${seen_eg[$eg]:-}" ]; then echo "skip $hp (dup egress $eg via ${seen_eg[$eg]})"; continue; fi
      code=$(curl -sS -o /dev/null -m 10 -w '%{http_code}' \
        --connect-to opencode.ai:443:"$ip":"$port" https://opencode.ai/zen/v1/models 2>/dev/null || echo 000)
      if [ "$code" != '200' ]; then echo "skip $hp (models $code)"; continue; fi
      seen_eg[$eg]="$hp"
      echo "$hp" >> /tmp/lab/targets.txt
      echo "target $hp egress $eg"
      [ "$(wc -l < /tmp/lab/targets.txt)" -ge "$((COUNT + 1))" ] && break
    done < /tmp/lab/candidates.txt
    ;;
  *)
    printf '%s\n' "$RELAY" | tr ',' '\n' | sed '/^$/d' > /tmp/lab/targets.txt
    ;;
esac

echo 'targets:'; cat /tmp/lab/targets.txt
printf '%-24s %-7s %-34s %-5s %s\n' TARGET RESULT EGRESS COLO NOTE | tee /tmp/lab/summary.txt

while read -r hp; do
  [ -z "$hp" ] && continue
  sudo cp /tmp/lab/hosts.orig /etc/hosts
  log="/tmp/lab/run-$(echo "$hp" | tr ':/' '__').log"
  echo "===== $hp ====="
  if [ "$hp" = 'direct' ]; then
    eg="$DIRECT_EG"
    colo=$(curl -sS -m 10 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | awk -F= '/^colo=/{print $2}')
  else
    ip=${hp%:*}; port=${hp##*:}
    trace=$(curl -sS -m 10 --connect-to www.cloudflare.com:443:"$ip":"$port" https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null || true)
    eg=$(printf '%s\n' "$trace" | awk -F= '/^ip=/{print $2}')
    colo=$(printf '%s\n' "$trace" | awk -F= '/^colo=/{print $2}')
    # Always go through the local forwarder so the connection log proves the
    # client really used the relay (also works for non-443 CF edge ports).
    sudo pkill -f "$WS/scripts/forward.py" >/dev/null 2>&1 || true
    sudo nohup python3 "$WS/scripts/forward.py" "$ip" "$port" >/tmp/lab/forward.log 2>&1 &
    sleep 0.7
    echo "127.0.0.1 opencode.ai" | sudo tee -a /etc/hosts >/dev/null
    echo "hosts: $(getent ahosts opencode.ai | head -1)"
  fi
  code=$(curl -sS -o /dev/null -m 15 -w '%{http_code}' https://opencode.ai/zen/v1/models 2>/dev/null || echo 000)
  echo "mapped models http=$code"
  if [ "$code" != '200' ]; then
    printf '%-24s %-7s %-34s %-5s %s\n' "$hp" ERROR "${eg:-?}" "${colo:-?}" "mapped http=$code" | tee -a /tmp/lab/summary.txt
    continue
  fi
  (
    cd "$ISO/work" || exit 1
    HOME="$ISO/home" XDG_CONFIG_HOME="$ISO/home/.config" \
      setsid -w timeout 90 "$BIN" run --standalone --model "$MODEL" "hi" > "$log" 2>&1
  )
  rc=$?
  err=$(grep -aE '^Error:' "$log" | head -1 | cut -c1-100)
  conns=0
  if [ "$hp" != 'direct' ]; then
    conns=$(grep -ac '^connect ' /tmp/lab/forward.log 2>/dev/null || true)
    [ -z "$conns" ] && conns=0
  fi
  if [ "$hp" != 'direct' ] && [ "$conns" -eq 0 ]; then
    result=INVALID
  elif [ "$rc" -eq 0 ]; then
    result=SUCCESS
  elif tail -5 "$log" | grep -aq '^Error: Free usage limit reached'; then
    result=LIMITED
  else
    result=ERROR
  fi
  printf '%-24s %-7s %-34s %-5s %s\n' "$hp" "$result" "${eg:-?}" "${colo:-?}" "${err:-rc=$rc} conns=$conns" | tee -a /tmp/lab/summary.txt
  echo '--- log tail ---'
  sed 's/\x1b\[[0-9;]*m//g' "$log" | tail -4
done < /tmp/lab/targets.txt

sudo cp /tmp/lab/hosts.orig /etc/hosts
echo '=== SUMMARY ==='
cat /tmp/lab/summary.txt
