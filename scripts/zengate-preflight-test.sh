#!/usr/bin/env bash
set -uo pipefail
COUNT="${COUNT:-3}"
SOURCE="${SOURCE:-all_rep_verified.txt}"
BASE="https://raw.githubusercontent.com/Xiaobei09/proxyip/main/data/valid"
export EGRESS_STATE_DIR="${EGRESS_STATE_DIR:-/tmp/lab/egress-preflight}"
mkdir -p "$EGRESS_STATE_DIR"
npm install -g zengate@1.3.1 >/tmp/lab/zengate-install.log 2>&1 || { echo "npm install failed"; tail -30 /tmp/lab/zengate-install.log; exit 1; }
bash scripts/egress-probe-server.sh start || exit 1
trap 'bash scripts/egress-probe-server.sh stop' EXIT
printf 'direct\t-\tdirect\n' > "$EGRESS_STATE_DIR/zp-candidates.tsv"
curl -fsSL -m 30 --noproxy '*' "$BASE/$SOURCE" -o /tmp/lab/zp-relays.txt || exit 1
head -n "$COUNT" /tmp/lab/zp-relays.txt | tr -d '\r' | sed 's/#.*//' \
  | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}:[0-9]{1,5}$' | awk '!seen[$0]++' \
  | while IFS= read -r hp; do printf 'relay\t%s\tproxyip\n' "$hp"; done >> "$EGRESS_STATE_DIR/zp-candidates.tsv"
while IFS=$'\t' read -r kind target source; do
  [ -n "${kind:-}" ] || continue
  t0=$(date +%s)
  out=$(bash scripts/egress-preflight-zengate.sh "$kind" "$([ "$kind" = direct ] && echo '' || echo "$target")" 20)
  rc=$?
  t1=$(date +%s)
  echo "preflight kind=$kind target=${target:-direct} code=${out%%$'\t'*} reason=${out##*$'\t'} rc=$rc dur=$((t1-t0))s"
done < "$EGRESS_STATE_DIR/zp-candidates.tsv"
echo "proxy connections:"
tail -20 "$EGRESS_STATE_DIR/probe/proxy.log" 2>/dev/null || true
