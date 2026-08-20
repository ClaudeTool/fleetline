#!/usr/bin/env bash
# fleetline — pluggable Claude Code statusline.
#
# Reads the session JSON Claude Code pipes on stdin, plus a user config file
# (outside this plugin's own directory, so plugin updates never wipe it), and
# prints 1-3 rendered lines. Three layout presets: minimal / hardened / power.

input=$(cat)

# ── Preflight ─────────────────────────────────────────────────────────────
if ! command -v jq >/dev/null 2>&1; then
    printf '%s\n' "[statusline: missing 'jq' — install it and try again (see README)]"
    exit 0
fi
GIT_OK=1
command -v git >/dev/null 2>&1 || GIT_OK=0

# shellcheck source=./lib.sh
LIB_DIR="${BASH_SOURCE%/*}"
# shellcheck disable=SC1091
source "${LIB_DIR}/lib.sh"

# git: never let a repo's own config run arbitrary commands (core.fsmonitor),
# and never let a status check take a lock that races a concurrent git op —
# this fires on every statusline refresh (every 30s by default).
GITOPTS=(-c core.fsmonitor= --no-optional-locks)

LAYOUT=$(cfg '.layout // "hardened"')
case "$LAYOUT" in minimal|hardened|power) ;; *) LAYOUT="hardened" ;; esac
COMPACT_HINT=$(cfg_bool '.hints.compactHint' true)
IDLE_ON=$(cfg_bool '.features.idleIndicator' true)
BURN_ON=$(cfg_bool '.features.burnRate' true)
OUTSTYLE_ON=$(cfg_bool '.features.outputStyleSegment' true)
VIM_ON=$(cfg_bool '.features.vimModeSegment' true)
ADDDIR_ON=$(cfg_bool '.features.addDirSegment' true)
CLICKABLE_ON=$(cfg_bool '.features.clickableLinks' false)
BG_SEGMENT_ON=$(cfg_bool '.agents.bgAgentSegment' false)
HOOK_COUNTER_ON=$(cfg_bool '.agents.hookCounterEnabled' false)
BG_POLL_SEC=$(cfg '.agents.bgAgentPollSeconds // 60')
case "$BG_POLL_SEC" in ''|*[!0-9]*) BG_POLL_SEC=60 ;; esac

# ── Extract fields from stdin ────────────────────────────────────────────────
# One jq call (was ~26 separate `echo | jq` forks) — this runs on every
# refresh, so forks are the actual cost center here. `// ""` (never `//
# empty`) throughout: inside an array literal, `// empty` drops the element
# entirely and shifts every field after it, silently misaligning the read
# below. Booleans get their own null-check instead of `// false` for the
# same reason jq's `//` bit us in config reading — `false // false` happens
# to look right, but `.thinking.enabled // empty` genuinely doesn't: an
# explicit `false` is falsy to `//` too, so it was read back as absent and
# "thinking:off" could never actually render.
#
# Joined with \x1f (Unit Separator), not a tab: bash's `read` classifies
# tab as "IFS whitespace" no matter what IFS is set to, which collapses
# consecutive delimiters — exactly the empty fields most of these values
# are — and silently shifts every field after the first gap. \x1f isn't
# whitespace to `read`, so empty fields between two of it are preserved.
IFS=$'\x1f' read -r \
    MODEL VERSION CWD GIT_WORKTREE REPO_HOST REPO_OWNER REPO_NAME ADDED_DIRS_COUNT \
    PCT CTX_SIZE EXCEEDS LINES_ADD LINES_REM COST_USD \
    SESSION_ID SESSION_NAME PROMPT_ID EFFORT THINKING PR_NUM PR_REVIEW OUTPUT_STYLE VIM_MODE \
    RATE_5H RATE_5H_AT RATE_7D RATE_7D_AT \
    <<<"$(echo "$input" | jq -r '
        [
          (.model.display_name // "?"),
          (.version // ""),
          (.workspace.current_dir // .cwd // ""),
          (.workspace.git_worktree // ""),
          (.workspace.repo.host // ""),
          (.workspace.repo.owner // ""),
          (.workspace.repo.name // ""),
          ((.workspace.added_dirs // []) | length | tostring),
          (.context_window.used_percentage // 0 | tostring | split(".")[0]),
          (.context_window.context_window_size // 200000 | tostring),
          (if .exceeds_200k_tokens == null then "false" else (.exceeds_200k_tokens | tostring) end),
          (.cost.total_lines_added // 0 | tostring),
          (.cost.total_lines_removed // 0 | tostring),
          (.cost.total_cost_usd // "" | tostring),
          (.session_id // ""),
          (.session_name // ""),
          (.prompt_id // ""),
          (.effort.level // ""),
          (if .thinking.enabled == null then "" else (.thinking.enabled | tostring) end),
          (.pr.number // "" | tostring),
          (.pr.review_state // ""),
          (.output_style.name // ""),
          (.vim.mode // ""),
          (.rate_limits.five_hour.used_percentage // "" | tostring),
          (.rate_limits.five_hour.resets_at // "" | tostring),
          (.rate_limits.seven_day.used_percentage // "" | tostring),
          (.rate_limits.seven_day.resets_at // "" | tostring)
        ] | join("")
    ' 2>/dev/null)"

MODEL=$(sanitize "$MODEL")
VERSION=$(sanitize "$VERSION")
GIT_WORKTREE=$(sanitize "$GIT_WORKTREE")
REPO_HOST=$(sanitize "$REPO_HOST")
REPO_OWNER=$(sanitize "$REPO_OWNER")
REPO_NAME=$(sanitize "$REPO_NAME")
SESSION_NAME=$(sanitize "$SESSION_NAME")
EFFORT=$(sanitize "$EFFORT")
PR_REVIEW=$(sanitize "$PR_REVIEW")
OUTPUT_STYLE=$(sanitize "$OUTPUT_STYLE")
VIM_MODE=$(sanitize "$VIM_MODE")

case "$ADDED_DIRS_COUNT" in ''|*[!0-9]*) ADDED_DIRS_COUNT=0 ;; esac
PCT=$(clamp_pct "$PCT")
case "$CTX_SIZE" in ''|*[!0-9]*) CTX_SIZE=200000 ;; esac

STATE_DIR="$HOME/.claude/cache-state"
mkdir -p "$STATE_DIR" 2>/dev/null

# ── Shared "last activity" tracking (per session_id) ────────────────────────
# Feeds both the cache-TTL segment and the idle indicator: both need "how
# long since the last distinct turn", so it's computed once, here.
NOW=$(date +%s)
LAST_ACTIVITY_TS=""
if [ -n "$SESSION_ID" ]; then
    ACTIVITY_FILE="$STATE_DIR/${SESSION_ID}.activity"
    LAST_PROMPT_ID=""
    LAST_TS="$NOW"
    if [ -f "$ACTIVITY_FILE" ]; then
        LAST_PROMPT_ID=$(cut -d' ' -f1 "$ACTIVITY_FILE" 2>/dev/null)
        LAST_TS=$(cut -d' ' -f2 "$ACTIVITY_FILE" 2>/dev/null)
        case "$LAST_TS" in ''|*[!0-9]*) LAST_TS="$NOW" ;; esac
    fi
    if [ -z "$PROMPT_ID" ] || [ "$PROMPT_ID" != "$LAST_PROMPT_ID" ]; then
        LAST_TS="$NOW"
        printf '%s %s\n' "$PROMPT_ID" "$NOW" > "$ACTIVITY_FILE" 2>/dev/null
    fi
    LAST_ACTIVITY_TS="$LAST_TS"
fi

# ── Context bar + optional "/compact?" hint ─────────────────────────────────
CTX_K=$((CTX_SIZE / 1000))
EXCEEDS_LABEL=""
if [ "$EXCEEDS" = "true" ]; then
    if [ "$ASCII" = "true" ]; then EXCEEDS_LABEL="${RED}!${RESET} "; else EXCEEDS_LABEL="${RED}⚠${RESET} "; fi
fi
CTX_PART="${EXCEEDS_LABEL}Ctx $(draw_bar "$PCT") ${PCT}%/${CTX_K}k"
if [ "$COMPACT_HINT" = "true" ] && [ "$PCT" -ge "$CRIT_T" ]; then
    CTX_PART="${CTX_PART} ${RED}· /compact?${RESET}"
fi

MODEL_PART="${CYAN}[${MODEL}]${RESET}"
[ "$LAYOUT" != "minimal" ] && [ -n "$VERSION" ] && MODEL_PART="${MODEL_PART} ${DIM}v${VERSION}${RESET}"

LINES_PART="${GREEN}+${LINES_ADD}${RESET}/${RED}-${LINES_REM}${RESET}"

WT_PART=""
if [ -n "$GIT_WORKTREE" ]; then
    if [ "$ASCII" = "true" ]; then WT_PART="${MAGENTA}wt:${GIT_WORKTREE}${RESET}"
    else                           WT_PART="${MAGENTA}⬡ ${GIT_WORKTREE}${RESET}"; fi
fi

GIT_PART=""
if [ "$GIT_OK" -eq 1 ] && [ -n "$CWD" ] && git "${GITOPTS[@]}" -C "$CWD" rev-parse --git-dir >/dev/null 2>&1; then
    BRANCH=$(git "${GITOPTS[@]}" -C "$CWD" -c gc.auto=0 symbolic-ref --short HEAD 2>/dev/null \
             || git "${GITOPTS[@]}" -C "$CWD" -c gc.auto=0 rev-parse --short HEAD 2>/dev/null)
    BRANCH=$(sanitize "$BRANCH")
    STAGED=$(git "${GITOPTS[@]}" -C "$CWD" diff --cached --numstat 2>/dev/null | wc -l | tr -d ' ')
    MODIFIED=$(git "${GITOPTS[@]}" -C "$CWD" diff --numstat 2>/dev/null | wc -l | tr -d ' ')
    CHANGES=""
    [ "$STAGED"   -gt 0 ] 2>/dev/null && CHANGES="${CHANGES}${GREEN}+${STAGED}${RESET}"
    [ "$MODIFIED" -gt 0 ] 2>/dev/null && CHANGES="${CHANGES}${YELLOW}~${MODIFIED}${RESET}"

    BRANCH_DISPLAY="$BRANCH"
    if [ "$CLICKABLE_ON" = "true" ] && is_path_safe_token "$BRANCH" \
       && is_url_safe_token "$REPO_HOST" && is_url_safe_token "$REPO_OWNER" && is_url_safe_token "$REPO_NAME"; then
        BRANCH_URL="https://${REPO_HOST}/${REPO_OWNER}/${REPO_NAME}/tree/${BRANCH}"
        BRANCH_DISPLAY=$(osc8_link "$BRANCH_URL" "$BRANCH")
    fi
    if [ "$ASCII" = "true" ]; then GIT_PART="git:${GREEN}${BRANCH_DISPLAY}${RESET} ${CHANGES}"
    else                           GIT_PART="🌿 ${GREEN}${BRANCH_DISPLAY}${RESET} ${CHANGES}"; fi
fi

# ── Small bundle: output-style / vim-mode / add-dir count (hardened/power) ──
OUTSTYLE_SEG=""
[ "$LAYOUT" != "minimal" ] && [ "$OUTSTYLE_ON" = "true" ] && [ -n "$OUTPUT_STYLE" ] \
    && OUTSTYLE_SEG="${DIM}style:${RESET}${OUTPUT_STYLE}"

VIM_SEG=""
[ "$LAYOUT" != "minimal" ] && [ "$VIM_ON" = "true" ] && [ -n "$VIM_MODE" ] \
    && VIM_SEG="${DIM}vim:${RESET}${VIM_MODE}"

ADDDIR_SEG=""
if [ "$LAYOUT" != "minimal" ] && [ "$ADDDIR_ON" = "true" ] && [ "$ADDED_DIRS_COUNT" -gt 0 ] 2>/dev/null; then
    ADDDIR_SEG="${DIM}+${ADDED_DIRS_COUNT} dir${RESET}"
fi

# ── Idle indicator (hardened/power) ─────────────────────────────────────────
IDLE_SEG=""
if [ "$LAYOUT" != "minimal" ] && [ "$IDLE_ON" = "true" ] && [ -n "$LAST_ACTIVITY_TS" ]; then
    IDLE_THRESH_MIN=$(cfg '.hints.idleThresholdMin // 5')
    case "$IDLE_THRESH_MIN" in ''|*[!0-9]*) IDLE_THRESH_MIN=5 ;; esac
    IDLE_MIN=$(( (NOW - LAST_ACTIVITY_TS) / 60 ))
    [ "$IDLE_MIN" -ge "$IDLE_THRESH_MIN" ] && IDLE_SEG="${DIM}idle ${IDLE_MIN}m${RESET}"
fi

# ── Cache TTL (power layout only) — inferred, not a real API field ─────────
# TTL window: 60min if rate_limits is present in the payload (subscription
# plans expose it), else 5min (API key / pay-as-you-go) — matches
# Anthropic's documented prompt-cache TTLs.
CACHE_TTL_SEG=""
if [ "$LAYOUT" = "power" ] && [ -n "$LAST_ACTIVITY_TS" ]; then
    if [ -n "$RATE_5H" ] || [ -n "$RATE_7D" ]; then TTL_MIN=60; else TTL_MIN=5; fi
    ELAPSED=$(( NOW - LAST_ACTIVITY_TS ))
    REMAINING=$(( TTL_MIN * 60 - ELAPSED ))
    if [ "$REMAINING" -le 0 ]; then
        if [ "$ASCII" = "true" ]; then CACHE_TTL_SEG="${RED}TTL out${RESET}"
        else                           CACHE_TTL_SEG="${RED}❄ TTL out${RESET}"; fi
    elif [ "$REMAINING" -le 600 ]; then
        CACHE_TTL_SEG="${YELLOW}TTL:$(( REMAINING / 60 ))m${RESET}"
    else
        CACHE_TTL_SEG="${GREEN}TTL:$(( REMAINING / 60 ))m${RESET}"
    fi
fi

# ── Burn rate: $/h + ETA to exhaust the 5h rate-limit window ───────────────
# Needs two samples at least 30s apart (stored per-session) to compute a
# velocity — shows nothing on the first render after enabling it.
BURN_SEG=""
if [ "$LAYOUT" != "minimal" ] && [ "$BURN_ON" = "true" ] && [ -n "$SESSION_ID" ] \
   && [ -n "$RATE_5H" ] && [ -n "$COST_USD" ] && command -v awk >/dev/null 2>&1; then
    BURN_FILE="$STATE_DIR/${SESSION_ID}.burn"
    P_TS=""; P_COST=""; P_RATE=""
    if [ -f "$BURN_FILE" ]; then
        read -r P_TS P_COST P_RATE < "$BURN_FILE" 2>/dev/null
        case "$P_TS" in ''|*[!0-9]*) P_TS="" ;; esac
    fi
    if [ -n "$P_TS" ]; then
        DT=$(( NOW - P_TS ))
        if [ "$DT" -ge 30 ]; then
            PER_HOUR=$(awk -v a="$COST_USD" -v b="$P_COST" -v t="$DT" \
                'BEGIN{ if (t>0) printf "%.2f", (a-b)*3600/t; else print "0.00" }' 2>/dev/null)
            RATE_PER_MIN=$(awk -v a="$RATE_5H" -v b="$P_RATE" -v t="$DT" \
                'BEGIN{ if (t>0) printf "%.4f", (a-b)*60/t; else print "0" }' 2>/dev/null)
            IS_POS=$(awk -v r="${RATE_PER_MIN:-0}" 'BEGIN{ print (r>0.0001) ? 1 : 0 }' 2>/dev/null)
            ETA=""
            if [ "$IS_POS" = "1" ]; then
                REM_MIN=$(awk -v pct="$RATE_5H" -v r="$RATE_PER_MIN" 'BEGIN{ printf "%.0f", (100-pct)/r }' 2>/dev/null)
                case "$REM_MIN" in ''|*[!0-9]*) REM_MIN="" ;; esac
                if [ -n "$REM_MIN" ]; then
                    if [ "$REM_MIN" -ge 60 ]; then ETA="~$(( REM_MIN / 60 ))h"; else ETA="~${REM_MIN}m"; fi
                fi
            fi
            if [ -n "$PER_HOUR" ]; then
                BURN_SEG="${DIM}\$${PER_HOUR}/h${RESET}"
                [ -n "$ETA" ] && BURN_SEG="${BURN_SEG} ${DIM}·${RESET} 5h out in ${YELLOW}${ETA}${RESET}"
            fi
        fi
    fi
    printf '%s %s %s\n' "$NOW" "$COST_USD" "$RATE_5H" > "$BURN_FILE" 2>/dev/null
fi

# ── Background-agent segment (opt-in, power layout only) ───────────────────
# Two-speed design: `claude agents --json` is authoritative but spawns a
# full CLI process (~0.4s observed) — throttled to bgAgentPollSeconds. If
# hookCounterEnabled, a much cheaper hook-maintained counter (see
# hooks/agent-count.sh) fills the gaps between polls, marked with "~" since
# it can drift if a subagent is killed without firing SubagentStop.
AGENTS_SEG=""
if [ "$LAYOUT" = "power" ] && [ "$BG_SEGMENT_ON" = "true" ] && command -v claude >/dev/null 2>&1; then
    DETAIL_FILE="$STATE_DIR/${SESSION_ID:-nosession}.agents-detail.json"
    HOOK_COUNT_FILE="$STATE_DIR/${SESSION_ID:-nosession}.agents-hookcount"
    NEED_RECONCILE=1
    if [ -f "$DETAIL_FILE" ]; then
        LAST_POLL_TS=$(jq -r '.ts // 0' "$DETAIL_FILE" 2>/dev/null)
        case "$LAST_POLL_TS" in ''|*[!0-9]*) LAST_POLL_TS=0 ;; esac
        [ $(( NOW - LAST_POLL_TS )) -lt "$BG_POLL_SEC" ] && NEED_RECONCILE=0
    fi
    if [ "$NEED_RECONCILE" -eq 1 ]; then
        TIMEOUT_BIN=""
        command -v timeout >/dev/null 2>&1 && TIMEOUT_BIN="timeout 3"
        RAW=$($TIMEOUT_BIN claude agents --json --cwd "$CWD" 2>/dev/null)
        if [ -n "$RAW" ] && echo "$RAW" | jq empty >/dev/null 2>&1; then
            CNT=$(echo "$RAW" | jq 'length' 2>/dev/null)
            WORK=$(echo "$RAW" | jq '[.[] | select(.state=="working")] | length' 2>/dev/null)
            BLOCK=$(echo "$RAW" | jq '[.[] | select(.state=="blocked")] | length' 2>/dev/null)
            if [ -n "$CNT" ]; then
                printf '{"count":%s,"working":%s,"blocked":%s,"ts":%s}\n' \
                    "$CNT" "${WORK:-0}" "${BLOCK:-0}" "$NOW" > "$DETAIL_FILE" 2>/dev/null
                [ "$HOOK_COUNTER_ON" = "true" ] && printf '%s\n' "$CNT" > "$HOOK_COUNT_FILE" 2>/dev/null
            fi
        fi
    fi
    if [ -f "$DETAIL_FILE" ]; then
        DCNT=$(jq -r '.count // empty' "$DETAIL_FILE" 2>/dev/null)
        DWORK=$(jq -r '.working // 0' "$DETAIL_FILE" 2>/dev/null)
        DBLOCK=$(jq -r '.blocked // 0' "$DETAIL_FILE" 2>/dev/null)
        APPROX=""
        if [ "$HOOK_COUNTER_ON" = "true" ] && [ -f "$HOOK_COUNT_FILE" ]; then
            HC=$(cat "$HOOK_COUNT_FILE" 2>/dev/null)
            case "$HC" in ''|*[!0-9]*) HC="" ;; esac
            if [ -n "$HC" ] && [ "$HC" != "$DCNT" ]; then DCNT="$HC"; APPROX="~"; fi
        fi
        if [ -n "$DCNT" ]; then
            BREAKDOWN=""
            [ "${DWORK:-0}" -gt 0 ] 2>/dev/null && BREAKDOWN="w:${DWORK}"
            [ "${DBLOCK:-0}" -gt 0 ] 2>/dev/null && BREAKDOWN="${BREAKDOWN:+$BREAKDOWN }b:${DBLOCK}"
            AGENTS_SEG="${DIM}bg:${RESET}${APPROX}${DCNT}${BREAKDOWN:+ (${BREAKDOWN})}"
        fi
    fi
fi

# ── Assemble line 1 by layout (width-aware: least-important pieces drop) ───
case "$LAYOUT" in
    minimal)
        L1_PIECES=("$MODEL_PART" "$CTX_PART")
        [ -n "$GIT_PART" ] && L1_PIECES+=("$GIT_PART")
        ;;
    hardened|power)
        L1_PIECES=("$MODEL_PART" "$CTX_PART" "$LINES_PART")
        [ -n "$GIT_PART" ]     && L1_PIECES+=("$GIT_PART")
        [ -n "$WT_PART" ]      && L1_PIECES+=("$WT_PART")
        [ -n "$ADDDIR_SEG" ]   && L1_PIECES+=("$ADDDIR_SEG")
        [ -n "$OUTSTYLE_SEG" ] && L1_PIECES+=("$OUTSTYLE_SEG")
        [ -n "$VIM_SEG" ]      && L1_PIECES+=("$VIM_SEG")
        [ -n "$IDLE_SEG" ]     && L1_PIECES+=("$IDLE_SEG")
        ;;
esac
L1=$(fit_line " | " "${L1_PIECES[@]}")
printf '%s\n' "$L1"

# ── Line 2 — rate limits (hardened/power, only when the plan exposes them) ─
if [ "$LAYOUT" != "minimal" ] && { [ -n "$RATE_5H" ] || [ -n "$RATE_7D" ]; }; then
    if [ "$ASCII" = "true" ]; then ROT='^'; else ROT='↻'; fi
    L2_PIECES=()
    if [ -n "$RATE_5H" ]; then
        R5_BAR=$(rate_bar "$RATE_5H")
        R5_TIME=$(fmt_ts "$RATE_5H_AT")
        L2_PIECES+=("5h:${R5_BAR}${R5_TIME:+ (${ROT} ${R5_TIME})}")
    fi
    if [ -n "$RATE_7D" ]; then
        R7_BAR=$(rate_bar "$RATE_7D")
        R7_TIME=$(fmt_ts "$RATE_7D_AT")
        L2_PIECES+=("7d:${R7_BAR}${R7_TIME:+ (${ROT} ${R7_TIME})}")
    fi
    [ -n "$BURN_SEG" ] && L2_PIECES+=("$BURN_SEG")
    L2="Rate: $(fit_line " | " "${L2_PIECES[@]}")"
    printf '%s\n' "$L2"
fi

# ── Line 3 — power extras (only fields actually present in the payload) ────
if [ "$LAYOUT" = "power" ]; then
    PARTS=()
    [ -n "$COST_USD" ] && PARTS+=("$(printf '$%s' "$COST_USD")")
    if [ -n "$PR_NUM" ]; then
        PR_DISPLAY="PR #${PR_NUM}"
        if [ "$CLICKABLE_ON" = "true" ] && [[ "$PR_NUM" =~ ^[0-9]+$ ]] \
           && is_url_safe_token "$REPO_HOST" && is_url_safe_token "$REPO_OWNER" && is_url_safe_token "$REPO_NAME"; then
            PR_URL="https://${REPO_HOST}/${REPO_OWNER}/${REPO_NAME}/pull/${PR_NUM}"
            PR_DISPLAY=$(osc8_link "$PR_URL" "PR #${PR_NUM}")
        fi
        SEG="${CYAN}${PR_DISPLAY}${RESET}"
        [ -n "$PR_REVIEW" ] && SEG="${SEG} ${GREEN}(review: ${PR_REVIEW})${RESET}"
        PARTS+=("$SEG")
    fi
    [ -n "$EFFORT" ] && PARTS+=("${MAGENTA}effort:${EFFORT}${RESET}")
    [ -n "$SESSION_NAME" ] && PARTS+=("${DIM}session:${RESET}${SESSION_NAME}")
    if [ -n "$THINKING" ] && [ "$THINKING" != "null" ]; then
        if [ "$THINKING" = "true" ]; then PARTS+=("${DIM}thinking:on${RESET}"); else PARTS+=("${DIM}thinking:off${RESET}"); fi
    fi
    [ -n "$AGENTS_SEG" ]    && PARTS+=("$AGENTS_SEG")
    [ -n "$CACHE_TTL_SEG" ] && PARTS+=("$CACHE_TTL_SEG")
    if [ "${#PARTS[@]}" -gt 0 ]; then
        L3=$(fit_line " ${DIM}|${RESET} " "${PARTS[@]}")
        printf '%s\n' "$L3"
    fi
fi
