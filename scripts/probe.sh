#!/usr/bin/env bash
# Probe relay IPs (force-resolve / SNI relays) from the CI network.
set -uo pipefail
mkdir -p /tmp/lab
BASE="${BASE:-https://raw.githubusercontent.com/Xiaobei09/proxyip/main}"
SRC="${SOURCE:-all.txt}"
COUNT="${COUNT:-12}"
LIST=/tmp/lab/relays.txt

if ! curl -fsSL --retry 5 --retry-delay 2 --max-time 180 "$BASE/data/valid/$SRC" -o "$LIST"; then
  echo "fallback to data/download/all.txt"
  curl -fsSL --retry 5 --retry-delay 2 --max-time 180 "$BASE/data/download/all.txt" -o "$LIST" || exit 1
fi
echo "list=$SRC lines=$(wc -l < "$LIST")"

{ head -5 "$LIST"; shuf -n "$COUNT" "$LIST" 2>/dev/null || head -n "$COUNT" "$LIST"; } \
  | cut -d'#' -f1 | awk '!seen[$0]++' | head -n "$((COUNT + 5))" > /tmp/lab/sample.txt

echo "sample=$(wc -l < /tmp/lab/sample.txt)"
printf '%-24s %-4s %-18s %s\n' ENTRY HTTP EGRESS COLO | tee /tmp/lab/probe.txt
while read -r hp; do
  ip=${hp%:*}; port=${hp##*:}
  code=$(curl -sS -o /dev/null -m 12 -w '%{http_code}' \
    --connect-to opencode.ai:443:"$ip":"$port" https://opencode.ai/zen/v1/models 2>/dev/null || echo 000)
  trace=$(curl -sS -m 12 --connect-to www.cloudflare.com:443:"$ip":"$port" \
    https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null || true)
  eg=$(printf '%s\n' "$trace" | awk -F= '/^ip=/{print $2}')
  colo=$(printf '%s\n' "$trace" | awk -F= '/^colo=/{print $2}')
  printf '%-24s %-4s %-18s %s\n' "$hp" "$code" "${eg:-FAIL}" "${colo:--}" | tee -a /tmp/lab/probe.txt
done < /tmp/lab/sample.txt
