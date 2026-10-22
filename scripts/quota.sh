#!/usr/bin/env bash
# Batch quota test: run the real OpenCode client through several force-resolve
# relays (or direct) and classify free-tier availability per egress IP.
set -uo pipefail
mkdir -p /tmp/lab
unset HTTP_PROXY HTTPS_PROXY http_proxy https_proxy ALL_PROXY all_proxy

BASE="${BASE:-https://raw.githubusercontent.com/Xiaobei09/proxyip/main}"
SOURCE="${SOURCE:-all.txt}"
MODEL="${MODEL:-opencode/big-pickle}"
RELAY="${RELAY:-}"
COUNT="${COUNT:-10}"

ORIG=/tmp/lab/hosts.orig
sudo cp /etc/hosts "$ORIG"

echo '--- install opencode ---'
curl -fsSL --retry 3 https://opencode.ai/v2/install | bash >/tmp/lab/install.log 2>&1
export PATH="$HOME/.opencode/bin:$PATH"
opencode --version

echo '--- build target list ---'
: > /tmp/lab/targets.txt
case "$RELAY" in
  direct)
    echo 'direct' > /tmp/lab/targets.txt
    ;;
  ''|auto)
    curl -fsSL --retry 5 --retry-delay 2 --max-time 180 "$BASE/data/valid/$SOURCE" -o /tmp/lab/relays.txt || exit 1
    { head -8 /tmp/lab/relays.txt; shuf -n "$((COUNT * 3))" /tmp/lab/relays.txt; } \
      | cut -d'#' -f1 | awk '!seen[$0]++' > /tmp/lab/candidates.txt
    echo 'direct' >> /tmp/lab/targets.txt
    while read -r hp; do
      ip=${hp%:*}; port=${hp##*:}
      code=$(curl -sS -o /dev/null -m 10 -w '%{http_code}' \
        --connect-to opencode.ai:443:"$ip":"$port" https://opencode.ai/zen/v1/models 2>/dev/null || echo 000)
      if [ "$code" = "200" ]; then
        echo "$hp" >> /tmp/lab/targets.txt
        echo "candidate ok: $hp"
      fi
      [ "$(wc -l < /tmp/lab/targets.txt)" -ge "$((COUNT + 1))" ] && break
    done < /tmp/lab/candidates.txt
    ;;
  *)
    printf '%s\n' "$RELAY" | tr ',' '\n' | sed '/^$/d' > /tmp/lab/targets.txt
    ;;
esac

echo "targets=$(wc -l < /tmp/lab/targets.txt)"
printf '%-24s %-6s %-34s %-5s %s\n' TARGET RESULT EGRESS COLO NOTE | tee /tmp/lab/summary.txt

while read -r hp; do
  [ -z "$hp" ] && continue
  sudo cp "$ORIG" /etc/hosts
  if [ "$hp" = "direct" ]; then
    echo "===== direct (runner egress) ====="
    egress=$(curl -sS -m 12 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | grep -E '^(ip|colo|loc)=' | tr '\n' ' ')
    echo "egress: $egress"
    peer=$(curl -sS -m 12 -o /dev/null -w '%{remote_ip}' https://opencode.ai/zen/v1/models 2>/dev/null)
    echo "peer: $peer"
    eg=$(printf '%s' "$egress" | awk -F= '/^ip=/{print $2}' | awk '{print $1}')
    colo=$(printf '%s' "$egress" | awk -F= '/^colo=/{print $2}' | awk '{print $1}')
  else
    ip=${hp%:*}; port=${hp##*:}
    echo "===== $hp ====="
    egress=$(curl -sS -m 12 --connect-to www.cloudflare.com:443:"$ip":"$port" https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | grep -E '^(ip|colo|loc)=' | tr '\n' ' ')
    eg=$(printf '%s' "$egress" | awk -F= '/^ip=/{print $2}' | awk '{print $1}')
    colo=$(printf '%s' "$egress" | awk -F= '/^colo=/{print $2}' | awk '{print $1}')
    echo "egress: $egress"
    if [ "$port" = "443" ]; then
      echo "$ip opencode.ai" | sudo tee -a /etc/hosts >/dev/null
    else
      sudo pkill -f 'scripts/forward.py' >/dev/null 2>&1 || true
      sudo nohup python3 scripts/forward.py "$ip" "$port" >/tmp/lab/forward.log 2>&1 &
      sleep 0.5
      echo "127.0.0.1 opencode.ai" | sudo tee -a /etc/hosts >/dev/null
    fi
    getent hosts opencode.ai | head -1
    peer=$(curl -sS -m 12 -o /dev/null -w '%{remote_ip}' https://opencode.ai/zen/v1/models 2>/dev/null)
    echo "peer: $peer"
  fi

  log=/tmp/lab/run-$(echo "$hp" | tr ':/' '__').log
  timeout 180 opencode run --standalone --model "$MODEL" "hi" > "$log" 2>&1
  rc=$?
  if grep -qiE 'free usage limit|free-limit|FreeUsageLimitError' "$log"; then
    result=LIMITED
  elif [ "$rc" -eq 0 ] && grep -qE 'assistant|^>' "$log"; then
    result=SUCCESS
  else
    result=ERROR
  fi
  note=$(sed 's/\x1b\[[0-9;]*m//g' "$log" | grep -vE '^timestamp=|^$' | tail -1 | cut -c1-90)
  printf '%-24s %-6s %-34s %-5s %s\n' "$hp" "$result" "${eg:-FAIL}" "${colo:--}" "$note" | tee -a /tmp/lab/summary.txt
  echo '--- run tail ---'
  sed 's/\x1b\[[0-9;]*m//g' "$log" | tail -6
done < /tmp/lab/targets.txt

echo '=== SUMMARY ==='
cat /tmp/lab/summary.txt
