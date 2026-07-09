#!/usr/bin/env bash
# S0 spike reproduction: drive Claude Code inside tmux, observe hooks + injection.
# See FINDINGS.md for the results this produced. Safe to re-run; uses a temp project.
set -euo pipefail

TM=/opt/homebrew/bin/tmux
PORT=49817
WORK="${TMPDIR:-/tmp}/pass-spike"
PROJ="$WORK/testproj"
LOG="$WORK/hook_log.jsonl"
SESS=spike-claude
HERE="$(cd "$(dirname "$0")" && pwd)"

mkdir -p "$PROJ/.claude"
git -C "$PROJ" init -q 2>/dev/null || true
cat > "$PROJ/.claude/settings.json" <<JSON
{
  "allowedHttpHookUrls": ["http://127.0.0.1:$PORT/hook/claude"],
  "hooks": {
    "UserPromptSubmit": [{ "hooks": [{ "type": "http", "url": "http://127.0.0.1:$PORT/hook/claude", "headers": { "X-Pass-Session": "\$PASS_SESSION" }, "allowedEnvVars": ["PASS_SESSION"], "timeout": 3 }] }],
    "Stop":             [{ "hooks": [{ "type": "http", "url": "http://127.0.0.1:$PORT/hook/claude", "headers": { "X-Pass-Session": "\$PASS_SESSION" }, "allowedEnvVars": ["PASS_SESSION"], "timeout": 3 }] }],
    "SessionEnd":       [{ "hooks": [{ "type": "http", "url": "http://127.0.0.1:$PORT/hook/claude", "headers": { "X-Pass-Session": "\$PASS_SESSION" }, "allowedEnvVars": ["PASS_SESSION"], "timeout": 3 }] }],
    "Notification":     [{ "matcher": "permission_prompt|idle_prompt|elicitation_dialog|agent_needs_input", "hooks": [{ "type": "http", "url": "http://127.0.0.1:$PORT/hook/claude", "headers": { "X-Pass-Session": "\$PASS_SESSION" }, "allowedEnvVars": ["PASS_SESSION"], "timeout": 3 }] }]
  }
}
JSON

python3 "$HERE/hook_logger.py" "$PORT" "$LOG" &
LOGGER=$!
trap '$TM kill-session -t "$SESS" 2>/dev/null || true; kill $LOGGER 2>/dev/null || true' EXIT
sleep 1

$TM has-session -t "$SESS" 2>/dev/null && $TM kill-session -t "$SESS"
$TM new-session -d -s "$SESS" -c "$PROJ" -x 220 -y 50 -e PASS_SESSION="$SESS"
$TM set-option -t "$SESS" @pass_project_root "$PROJ"
$TM set-option -t "$SESS" @pass_agent claude
$TM send-keys -t "$SESS" 'claude' Enter
sleep 8
$TM send-keys -t "$SESS" Enter          # confirm trust-folder prompt
sleep 6

# --- text injection (bracketed paste + delay + Enter) ---
printf '%s' 'say the single word: pong' | $TM load-buffer -
$TM paste-buffer -t "$SESS" -p -d; sleep 0.15; $TM send-keys -t "$SESS" Enter
sleep 8

# --- trigger a permission prompt, approve with bare digit '1' ---
printf '%s' 'Use the Write tool to create spike_out.txt with text HELLO. Do it now.' | $TM load-buffer -
$TM paste-buffer -t "$SESS" -p -d; sleep 0.15; $TM send-keys -t "$SESS" Enter
sleep 11
$TM capture-pane -p -t "$SESS" | tail -20
$TM send-keys -t "$SESS" 1              # approve once
sleep 4

echo "=== events observed ==="
python3 - "$LOG" <<'PY'
import sys, json
for ln in open(sys.argv[1]):
    b = json.loads(ln).get("body_json") or {}
    print(b.get("hook_event_name"), b.get("notification_type",""))
PY
