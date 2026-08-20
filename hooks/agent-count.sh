#!/usr/bin/env bash
# fleetline hook: maintains an approximate running count of active
# background subagents, read by bin/statusline.sh's bg-agent segment when
# agents.hookCounterEnabled is on in the config.
#
# Best-effort only: a subagent killed outside the normal SubagentStop path
# never decrements this counter, so it can drift high over time. The main
# script corrects that drift on its next `claude agents --json` reconcile
# (throttled by agents.bgAgentPollSeconds) — this hook only fills the gaps
# between those polls with a fast, approximate signal.
#
# Usage: agent-count.sh start   (wired to the SubagentStart hook)
#        agent-count.sh stop    (wired to the SubagentStop hook)

DIRECTION="${1:-}"
input=$(cat)

command -v jq >/dev/null 2>&1 || exit 0

SESSION_ID=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)
[ -z "$SESSION_ID" ] && SESSION_ID="nosession"

STATE_DIR="$HOME/.claude/cache-state"
mkdir -p "$STATE_DIR" 2>/dev/null
COUNT_FILE="$STATE_DIR/${SESSION_ID}.agents-hookcount"

CUR=0
[ -f "$COUNT_FILE" ] && CUR=$(cat "$COUNT_FILE" 2>/dev/null)
case "$CUR" in ''|*[!0-9]*) CUR=0 ;; esac

case "$DIRECTION" in
    start) CUR=$(( CUR + 1 )) ;;
    stop)  CUR=$(( CUR - 1 )); [ "$CUR" -lt 0 ] && CUR=0 ;;
    *) exit 0 ;;
esac

printf '%s\n' "$CUR" > "$COUNT_FILE" 2>/dev/null
exit 0
