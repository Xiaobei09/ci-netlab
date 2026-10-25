#!/usr/bin/env bash
set -uo pipefail
npm install -g zengate@1.3.1 >/tmp/lab/zengate-install.log 2>&1 || { echo "npm install failed"; tail -30 /tmp/lab/zengate-install.log; exit 1; }
export RUNNER_TEMP="${RUNNER_TEMP:-/tmp/lab/select-run}"
export EGRESS_STATE_DIR="$RUNNER_TEMP/egress"
rm -rf "$RUNNER_TEMP"
mkdir -p "$EGRESS_STATE_DIR"
export EGRESS_ALLOW_PUBLIC_HTTP=0
export EGRESS_BLACKLIST_ENABLED=0
export EGRESS_SELECT_MAX="${COUNT:-3}"
export EGRESS_SELECT_BUDGET="${BUDGET:-90}"
export EGRESS_PREFLIGHT_TIMEOUT=20
bash scripts/select-proxy.sh
rc=$?
echo "select rc=$rc"
echo "--- state ---"
cat "$HOME/.config/opencode/exit-proxy.json" 2>/dev/null || true
echo "--- candidates ---"
cat "$EGRESS_STATE_DIR/candidates.tsv" 2>/dev/null | head -20
echo "--- blacklist exists? ---"
ls -l "$HOME/.config/opencode/egress-blacklist.json" 2>/dev/null || echo "none"
echo "--- probe proxy log ---"
tail -20 "$EGRESS_STATE_DIR/probe/proxy.log" 2>/dev/null || true

if [ "${ROTATE:-0}" = "1" ]; then
  echo "--- rotate transport test ---"
  bash scripts/egress-rotate.sh --reason transport
  echo "rotate rc=$?"
  echo "--- state after rotate ---"
  cat "$HOME/.config/opencode/exit-proxy.json" 2>/dev/null || true
  echo "--- probe proxy log after rotate ---"
  tail -30 "$EGRESS_STATE_DIR/probe/proxy.log" 2>/dev/null || true
fi
exit "$rc"
