#!/usr/bin/env bash
# fleetline — subagentStatusLine renderer (fleet/agent-panel view).
#
# This is a DIFFERENT settings key from the main `statusLine` — it renders
# rows in Claude Code's multi-agent/fleet view, not the main terminal line.
# It receives {"tasks": [...]} on stdin and must emit one JSON line per
# task, {"id": "<task id>", "content": "<row body>"}, to override that
# task's displayed row.
#
# Least-verified part of this plugin: built from documented field names
# (id, name, type, status, description, label, startTime, model, effort,
# contextWindowSize, tokenCount, tokenSamples, cwd), but there was no live
# multi-agent fleet session available to capture a real payload against —
# tested only with synthetic tasks[] matching the documented shape. The
# `status` enum values in particular are not confirmed, so the "stuck agent"
# flag below matches loosely (any status containing "block" or "wait")
# rather than a single exact string.

input=$(cat)
command -v jq >/dev/null 2>&1 || exit 0

LIB_DIR="${BASH_SOURCE%/*}"
# shellcheck disable=SC1091
source "${LIB_DIR}/lib.sh"

STATE_DIR="$HOME/.claude/cache-state"
mkdir -p "$STATE_DIR" 2>/dev/null
BLOCKED_FILE="$STATE_DIR/subagent-blocked-since.json"
OLD_BLOCKED=$(cat "$BLOCKED_FILE" 2>/dev/null)
echo "$OLD_BLOCKED" | jq empty >/dev/null 2>&1 || OLD_BLOCKED='{}'
NEW_BLOCKED='{}'
NOW_MS=$(( $(date +%s) * 1000 ))
STUCK_AFTER_MS=120000

while IFS= read -r task; do
    [ -z "$task" ] && continue

    # One jq call per task instead of seven — this loop runs on every
    # render tick for every visible task, so the fork count multiplies
    # with N tasks. \x1f (not @tsv's tab) as the join char: see the note
    # in bin/statusline.sh's own field extraction for why tab breaks on
    # empty fields.
    IFS=$'\x1f' read -r TID NAME STATUS MODEL EFFORT START TOKENS CTXSIZE <<<"$(
        printf '%s' "$task" | jq -r '
            [
              (.id // ""),
              (.name // .label // .description // "agent"),
              (.status // ""),
              (.model // ""),
              (.effort // ""),
              (.startTime // "" | tostring),
              (.tokenCount // "" | tostring),
              (.contextWindowSize // "" | tostring)
            ] | join("")
        ' 2>/dev/null
    )"
    [ -z "$TID" ] && continue

    NAME=$(sanitize "$NAME")
    [ "${#NAME}" -gt 40 ] && NAME="${NAME:0:40}…"
    MODEL=$(sanitize "$MODEL")
    EFFORT=$(sanitize "$EFFORT")

    ELAPSED=""
    case "$START" in ''|*[!0-9]*) START="" ;; esac
    if [ -n "$START" ]; then
        SECS=$(( (NOW_MS - START) / 1000 ))
        [ "$SECS" -lt 0 ] && SECS=0
        if [ "$SECS" -ge 60 ]; then ELAPSED="$(( SECS / 60 ))m"; else ELAPSED="${SECS}s"; fi
    fi

    CTX_SEG=""
    case "$TOKENS" in ''|*[!0-9]*) TOKENS="" ;; esac
    case "$CTXSIZE" in ''|*[!0-9]*) CTXSIZE="" ;; esac
    if [ -n "$TOKENS" ] && [ -n "$CTXSIZE" ] && [ "$CTXSIZE" -gt 0 ]; then
        TPCT=$(( TOKENS * 100 / CTXSIZE ))
        CTX_SEG=$(rate_bar "$TPCT")
    fi

    STUCK=""
    case "$STATUS" in
        *[Bb][Ll][Oo][Cc][Kk]*|*[Ww][Aa][Ii][Tt]*)
            PREV_TS=$(printf '%s' "$OLD_BLOCKED" | jq -r --arg id "$TID" '.[$id] // empty' 2>/dev/null)
            case "$PREV_TS" in ''|*[!0-9]*) PREV_TS="" ;; esac
            if [ -n "$PREV_TS" ]; then
                AGE_MS=$(( NOW_MS - PREV_TS ))
                if [ "$AGE_MS" -ge "$STUCK_AFTER_MS" ]; then
                    if [ "$ASCII" = "true" ]; then STUCK=" ${RED}[STUCK]${RESET}"; else STUCK=" ${RED}⚠ stuck${RESET}"; fi
                fi
                NEW_BLOCKED=$(printf '%s' "$NEW_BLOCKED" | jq --arg id "$TID" --argjson ts "$PREV_TS" '.[$id]=$ts' 2>/dev/null)
            else
                NEW_BLOCKED=$(printf '%s' "$NEW_BLOCKED" | jq --arg id "$TID" --argjson ts "$NOW_MS" '.[$id]=$ts' 2>/dev/null)
            fi
            ;;
    esac

    ROW="${CYAN}${NAME}${RESET}"
    [ -n "$ELAPSED" ] && ROW="${ROW} ${DIM}${ELAPSED}${RESET}"
    [ -n "$CTX_SEG" ] && ROW="${ROW} ${CTX_SEG}"
    [ -n "$MODEL" ]   && ROW="${ROW} ${DIM}${MODEL}${RESET}"
    [ -n "$EFFORT" ]  && ROW="${ROW} ${MAGENTA}${EFFORT}${RESET}"
    ROW="${ROW}${STUCK}"

    jq -cn --arg id "$TID" --arg content "$ROW" '{id: $id, content: $content}'
done < <(printf '%s' "$input" | jq -c '.tasks[]? // empty' 2>/dev/null)

printf '%s\n' "${NEW_BLOCKED:-\{\}}" > "$BLOCKED_FILE" 2>/dev/null
exit 0
