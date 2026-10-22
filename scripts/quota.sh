#!/usr/bin/env bash
# Run the real OpenCode client through a relay (force-resolve opencode.ai) and
# classify whether the relay's egress has free-tier quota.
set -uo pipefail
mkdir -p /tmp/lab
unset HTTP_PROXY HTTPS_PROXY http_proxy https_proxy ALL_PROXY all_proxy

BASE="${BASE:-https://raw.githubusercontent.com/Xiaobei09/proxyip/main}"
SOURCE="${SOURCE:-all.txt}"
MODEL="${MODEL:-opencode/big-pickle}"
RELAY="${RELAY:-}"

if [ -z "$RELAY" ]; then
  curl -fsSL --retry 5 --retry-delay 2 --max-time 180 "$BASE/data/valid/$SOURCE" -o /tmp/lab/relays.txt || exit 1
  while read -r hp; do
    ip=${hp%:*}; port=${hp##*:}
    code=$(curl -sS -o /dev/null -m 10 -w '%{http_code}' \
      --connect-to opencode.ai:443:"$ip":"$port" https://opencode.ai/zen/v1/models 2>/dev/null || echo 000)
    echo "candidate $hp -> $code"
    if [ "$code" = "200" ]; then RELAY="$hp"; break; fi
  done < <(head -40 /tmp/lab/relays.txt | cut -d'#' -f1)
fi

echo "RELAY=${RELAY:-<none>} MODEL=$MODEL"
if [ -z "$RELAY" ]; then echo 'RESULT=NO_RELAY'; exit 2; fi

ip=${RELAY%:*}; port=${RELAY##*:}

echo '--- relay connectivity + egress ---'
curl -sS -o /dev/null -m 12 -w 'models http=%{http_code}\n' \
  --connect-to opencode.ai:443:"$ip":"$port" https://opencode.ai/zen/v1/models || true
curl -sS -m 12 --connect-to www.cloudflare.com:443:"$ip":"$port" \
  https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | grep -E '^(ip|colo|loc)=' || true

echo '--- install opencode ---'
curl -fsSL --retry 3 https://opencode.ai/v2/install | bash
export PATH="$HOME/.opencode/bin:$PATH"
opencode --version || true

echo '--- map opencode.ai -> relay ---'
if [ "$port" = "443" ]; then
  echo "$ip opencode.ai" | sudo tee -a /etc/hosts
else
  sudo nohup python3 scripts/forward.py "$ip" "$port" > /tmp/lab/forward.log 2>&1 &
  sleep 1
  echo "127.0.0.1 opencode.ai" | sudo tee -a /etc/hosts
fi
tail -3 /etc/hosts

echo '--- connectivity after mapping ---'
curl -sS -o /dev/null -m 15 -w 'models http=%{http_code}\n' https://opencode.ai/zen/v1/models || true

echo '--- opencode run ---'
timeout 240 opencode run --standalone --model "$MODEL" "hi" > /tmp/lab/run.log 2>&1
rc=$?
echo "rc=$rc"
sed 's/\x1b\[[0-9;]*m//g' /tmp/lab/run.log | grep -vE '^timestamp=' | tail -40

if grep -qiE 'free usage limit|free-limit|FreeUsageLimitError' /tmp/lab/run.log; then
  echo 'RESULT=LIMITED'
elif [ "$rc" -eq 0 ]; then
  echo 'RESULT=SUCCESS'
else
  echo 'RESULT=ERROR'
fi
