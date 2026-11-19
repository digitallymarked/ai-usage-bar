#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
[[ -x build/AIUsageBar ]] || swiftc -O -o build/AIUsageBar Sources/*.swift -framework Cocoa

python3 tests/codex_mock.py & MOCK=$!
trap 'kill $MOCK 2>/dev/null' EXIT
sleep 0.5

HOME_DIR=$(mktemp -d)
echo '{"tokens":{"access_token":"test-token","refresh_token":"x","account_id":"acct-123"}}' > "$HOME_DIR/auth.json"

OUT=$(CODEX_HOME="$HOME_DIR" AI_USAGE_BAR_CODEX_URL=http://127.0.0.1:8765/wham/usage \
      build/AIUsageBar --snapshot codex "${TMPDIR:-/tmp}/codex-test.png")
echo "$OUT"
grep -q "^Session (5h): 72%" <<<"$OUT"
grep -q "^Weekly: 41%" <<<"$OUT"

echo '{"tokens":{"access_token":"wrong","refresh_token":"x"}}' > "$HOME_DIR/auth.json"
ERR=$(CODEX_HOME="$HOME_DIR" AI_USAGE_BAR_CODEX_URL=http://127.0.0.1:8765/wham/usage \
      build/AIUsageBar --snapshot codex /dev/null || true)
if grep -q "Session expired" <<<"$ERR"; then
  echo "401 handled"
else
  echo "FAIL: 401 not handled"; exit 1
fi
rm -rf "$HOME_DIR"
echo "PASS"
