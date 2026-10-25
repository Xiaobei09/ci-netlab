#!/usr/bin/env bash
# Test real OpenCode inference through each candidate egress using zengate.
# zengate creates a fresh OpenCode session for every HTTP request, so every
# candidate is validated with a new conversation rather than a synthetic curl.
set -uo pipefail

COUNT="${COUNT:-5}"
SOURCE="${SOURCE:-all_rep_verified.txt}"
MODEL="${MODEL:-big-pickle}"
ZG_PORT="${ZG_PORT:-18083}"
EGRESS_PORT="${EGRESS_LOCAL_PORT:-8089}"
EGRESS_DIR="${EGRESS_STATE_DIR:-/tmp/lab/zengate-egress}"
BASE="https://raw.githubusercontent.com/Xiaobei09/proxyip/main/data/valid"
OUT="${OUT:-/tmp/lab/zengate-probe.tsv}"
mkdir -p /tmp/lab "$EGRESS_DIR"
: > "$OUT"

log() { echo "$(date -u +%FT%TZ) $*" | tee -a /tmp/lab/zengate-probe.log; }

export EGRESS_LOCAL_PORT="$EGRESS_PORT" EGRESS_STATE_DIR="$EGRESS_DIR"
printf 'direct\n' > "$EGRESS_DIR/upstream"
echo 0 > "$EGRESS_DIR/epoch"

log "starting local egress proxy on 127.0.0.1:$EGRESS_PORT"
python3 scripts/egress-proxy.py > /tmp/lab/egress-proxy.log 2>&1 &
PROXY_PID=$!
cleanup() {
  kill "${ZG_PID:-}" 2>/dev/null || true
  kill "$PROXY_PID" 2>/dev/null || true
  wait "${ZG_PID:-}" 2>/dev/null || true
  wait "$PROXY_PID" 2>/dev/null || true
}
trap cleanup EXIT
for _ in $(seq 1 40); do
  if curl -sS -m 1 --noproxy '*' -o /dev/null "http://127.0.0.1:$EGRESS_PORT" 2>/dev/null; then break; fi
  kill -0 "$PROXY_PID" 2>/dev/null || { log "proxy died"; exit 1; }
  sleep 0.2
done

log "installing zengate"
npm install -g zengate@1.3.1 >/tmp/lab/zengate-install.log 2>&1 || { log "npm install failed"; tail -30 /tmp/lab/zengate-install.log; exit 1; }
command -v zengate >/dev/null || { log "zengate binary missing"; exit 1; }

export HOST=127.0.0.1 PORT="$ZG_PORT" ALLOW_NO_AUTH=true
export LOG_LEVEL=warn REQUEST_TIMEOUT_MS=90000 MAX_CONCURRENT=1
export HTTP_PROXY="http://127.0.0.1:$EGRESS_PORT" HTTPS_PROXY="http://127.0.0.1:$EGRESS_PORT"
export http_proxy="$HTTP_PROXY" https_proxy="$HTTPS_PROXY"
export NO_PROXY="127.0.0.1,localhost" no_proxy="127.0.0.1,localhost"
zengate > /tmp/lab/zengate.log 2>&1 &
ZG_PID=$!
log "starting zengate pid=$ZG_PID"
ready=0
for _ in $(seq 1 120); do
  if curl -sS -m 2 --noproxy '*' -o /dev/null "http://127.0.0.1:$ZG_PORT/ready" 2>/dev/null; then ready=1; break; fi
  kill -0 "$ZG_PID" 2>/dev/null || { log "zengate died during startup"; tail -60 /tmp/lab/zengate.log; exit 1; }
  sleep 1
done
[ "$ready" = 1 ] || { log "zengate did not become ready"; tail -60 /tmp/lab/zengate.log; exit 1; }
log "zengate ready"

CAND="$EGRESS_DIR/candidates.tsv"
printf 'direct\t-\tdirect\n' > "$CAND"
if [ "$COUNT" -gt 0 ]; then
  if curl -fsSL -m 30 --noproxy '*' "$BASE/$SOURCE" -o "$EGRESS_DIR/relays.txt"; then
    head -n "$COUNT" "$EGRESS_DIR/relays.txt" | tr -d '\r' | sed 's/#.*//' \
      | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}:[0-9]{1,5}$' | awk '!seen[$0]++' \
      | while IFS= read -r hp; do printf 'relay\t%s\tproxyip\n' "$hp"; done >> "$CAND"
  else
    log "could not fetch relay source $SOURCE"
  fi
fi
log "candidates: $(wc -l < "$CAND")"

n=0
while IFS=$'\t' read -r kind target source; do
  [ -n "${kind:-}" ] || continue
  n=$((n + 1))
  up=direct
  [ "$kind" = relay ] && up="relay:$target"
  printf '%s\n' "$up" > "$EGRESS_DIR/upstream"
  epoch=$(($(cat "$EGRESS_DIR/epoch" 2>/dev/null || echo 0) + 1))
  printf '%s\n' "$epoch" > "$EGRESS_DIR/epoch"
  sleep 1
  body=$(jq -nc --arg m "$MODEL" '{model:$m,stream:false,max_tokens:24,messages:[{role:"user",content:"Reply with exactly: OK"}]}')
  t0=$(date +%s)
  raw=$(curl -sS -m 90 --noproxy '*' -w '\n%{http_code}' \
    -H 'Content-Type: application/json' -d "$body" \
    "http://127.0.0.1:$ZG_PORT/v1/chat/completions" 2>>/tmp/lab/zengate-probe.log)
  rc=$?
  t1=$(date +%s)
  code=${raw##*$'\n'}
  js=${raw%$'\n'*}
  id=$(printf '%s' "$js" | jq -r '.id // empty' 2>/dev/null || true)
  content=$(printf '%s' "$js" | jq -r '.choices[0].message.content // empty' 2>/dev/null || true)
  err=$(printf '%s' "$js" | jq -r '.error.message // empty' 2>/dev/null || true)
  status=bad
  if [ "$rc" = 0 ] && [ "$code" = 200 ] && [ -n "$content" ]; then status=ok; fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$n" "$kind" "$target" "$status" "$code" "$t1-$t0" "$id" "$content" >> "$OUT"
  log "candidate $n kind=$kind target=$target status=$status code=$code dur=$((t1-t0))s id=$id content=${content:0:60} err=${err:0:120}"
done < "$CAND"

log "results:"
column -t -s $'\t' "$OUT" 2>/dev/null || cat "$OUT"
log "done"
