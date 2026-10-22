#!/usr/bin/env bash
# Watch the OpenCode run log for the free-tier quota error and rotate egress.
# Runs in the same step as OpenCode so it inherits the local proxy environment.
#
# Usage: egress-watch.sh <run-log>
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=egress-lib.sh
. "$SCRIPT_DIR/egress-lib.sh"

LOG="${1:?usage: egress-watch.sh <run-log>}"
mkdir -p "$EGRESS_STATE_DIR"
WATCH_LOG="$EGRESS_STATE_DIR/watch.log"
: > "$WATCH_LOG"

last=0
fail_until=0

log() { echo "$(egress_iso) $*" >> "$WATCH_LOG"; }

log "watch start log=$LOG upstream=$(cat "$EGRESS_UPSTREAM_FILE" 2>/dev/null || echo '?')"

while [ ! -f "$LOG" ]; do sleep 1; done

while IFS= read -r line; do
  case "$line" in
    *"Free usage limit reached"*|*"FreeUsageLimitError"*|*"free usage limit reached"*)
      now=$(egress_now)
      if [ "$now" -lt "$fail_until" ]; then
        continue
      fi
      if [ $((now - last)) -lt 20 ]; then
        continue
      fi
      last=$now
      log "quota error detected; rotating egress"
      if bash "$SCRIPT_DIR/egress-rotate.sh" --reason quota >> "$WATCH_LOG" 2>&1; then
        state=$(jq -c '{kind,upstream,egress_ip}' "$EGRESS_STATE_FILE" 2>/dev/null || echo '{}')
        log "rotate ok $state"
        if [ -n "${TG_BOT_TOKEN:-}" ] && [ -n "${TG_PUSH_CHAT:-}" ]; then
          curl -sS -m 20 -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
            --data-urlencode "chat_id=${TG_PUSH_CHAT}" \
            --data-urlencode "text=CI egress switched: ${state}" \
            >/dev/null 2>&1 || true
        fi
      else
        log "rotate failed; keeping current egress"
        fail_until=$((now + 60))
        if [ -n "${TG_BOT_TOKEN:-}" ] && [ -n "${TG_PUSH_CHAT:-}" ]; then
          curl -sS -m 20 -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
            --data-urlencode "chat_id=${TG_PUSH_CHAT}" \
            --data-urlencode "text=CI egress rotate FAILED: no candidate passed preflight" \
            >/dev/null 2>&1 || true
        fi
      fi
      ;;
  esac
done < <(tail -n +1 -F "$LOG" 2>/dev/null)

log "watch end"
