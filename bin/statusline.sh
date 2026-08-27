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
# EFFORT: extracted and sanitized but intentionally not rendered anywhere —
# Claude Code already shows the effort level itself, so a duplicate segment
# here was redundant. Kept in the jq/read pipeline rather than deleted: every
# field after it is positional (see CLAUDE.md's \x1f field-shift warning),
# so removing it from extraction would require re-checking every field below
# it for zero benefit.
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

# ── Rate-limit flicker guard (5h/7d) ────────────────────────────────────────
# Reported symptom: used_percentage occasionally reads ~0 for a single
# render mid-window, then jumps back up on the next one — well before the
# window could have actually reset. Root cause not confirmed (no captured
# payload showing it happen — see CLAUDE.md's verified/not-verified section);
# this is a debounce, not a fix for a known bug. It requires two consecutive
# low readings before trusting a drop from a real usage level (>5%) down to
# ~0 — a single-render dip shows the last confirmed value instead of the dip.
# A genuine reset costs at most one render's delay (~one refresh interval)
# before it displays for real.
rate_flicker_guard() {
    local raw="$1" statefile="$2" p confirmed="" prev_raw="" prev_ts=0
    [ -z "$raw" ] && { printf '%s' "$raw"; return; }
    p=$(printf '%.0f' "$raw" 2>/dev/null)
    case "$p" in ''|*[!0-9]*) printf '%s' "$raw"; return ;; esac
    if [ -f "$statefile" ]; then
        read -r confirmed prev_raw prev_ts < "$statefile" 2>/dev/null
        case "$confirmed" in ''|*[!0-9]*) confirmed="" ;; esac
        case "$prev_raw" in ''|*[!0-9]*) prev_raw="" ;; esac
    fi
    if [ "$p" -le 1 ] && [ -n "$confirmed" ] && [ "$confirmed" -gt 5 ] \
       && { [ -z "$prev_raw" ] || [ "$prev_raw" -gt 1 ]; }; then
        printf '%s %s %s\n' "$confirmed" "$p" "$NOW" > "$statefile" 2>/dev/null
        printf '%s' "$confirmed"
        return
    fi
    printf '%s %s %s\n' "$p" "$p" "$NOW" > "$statefile" 2>/dev/null
    printf '%s' "$p"
}
if [ -n "$SESSION_ID" ]; then
    [ -n "$RATE_5H" ] && RATE_5H=$(rate_flicker_guard "$RATE_5H" "$STATE_DIR/${SESSION_ID}.rate5h")
    [ -n "$RATE_7D" ] && RATE_7D=$(rate_flicker_guard "$RATE_7D" "$STATE_DIR/${SESSION_ID}.rate7d")
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

# ── Small bundle: output-style / vim-mode / add-dir count ──────────────────
# Not gated by $LAYOUT here — a custom `segments` list (see below) can place
# any of these on any layout. Each layout's *default* segment list still
# only includes the pieces the old hardcoded minimal/hardened/power did.
OUTSTYLE_SEG=""
[ "$OUTSTYLE_ON" = "true" ] && [ -n "$OUTPUT_STYLE" ] \
    && OUTSTYLE_SEG="${DIM}style:${RESET}${OUTPUT_STYLE}"

VIM_SEG=""
[ "$VIM_ON" = "true" ] && [ -n "$VIM_MODE" ] \
    && VIM_SEG="${DIM}vim:${RESET}${VIM_MODE}"

ADDDIR_SEG=""
if [ "$ADDDIR_ON" = "true" ] && [ "$ADDED_DIRS_COUNT" -gt 0 ] 2>/dev/null; then
    ADDDIR_SEG="${DIM}+${ADDED_DIRS_COUNT} dir${RESET}"
fi

# ── Idle indicator ───────────────────────────────────────────────────────────
IDLE_SEG=""
if [ "$IDLE_ON" = "true" ] && [ -n "$LAST_ACTIVITY_TS" ]; then
    IDLE_THRESH_MIN=$(cfg '.hints.idleThresholdMin // 5')
    case "$IDLE_THRESH_MIN" in ''|*[!0-9]*) IDLE_THRESH_MIN=5 ;; esac
    IDLE_MIN=$(( (NOW - LAST_ACTIVITY_TS) / 60 ))
    [ "$IDLE_MIN" -ge "$IDLE_THRESH_MIN" ] && IDLE_SEG="${DIM}idle ${IDLE_MIN}m${RESET}"
fi

# ── Cache TTL — inferred, not a real API field ──────────────────────────────
# TTL window: 60min if rate_limits is present in the payload (subscription
# plans expose it), else 5min (API key / pay-as-you-go) — matches
# Anthropic's documented prompt-cache TTLs. Not gated by $LAYOUT (see note
# above); the "power" default segment list is still the only one that shows
# it unless overridden by `segments`.
CACHE_TTL_SEG=""
if [ -n "$LAST_ACTIVITY_TS" ]; then
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
if [ "$BURN_ON" = "true" ] && [ -n "$SESSION_ID" ] \
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

# ── Background-agent segment (opt-in) ───────────────────────────────────────
# Two-speed design: `claude agents --json` is authoritative but spawns a
# full CLI process (~0.4s observed) — throttled to bgAgentPollSeconds. If
# hookCounterEnabled, a much cheaper hook-maintained counter (see
# hooks/agent-count.sh) fills the gaps between polls, marked with "~" since
# it can drift if a subagent is killed without firing SubagentStop.
AGENTS_SEG=""
if [ "$BG_SEGMENT_ON" = "true" ] && command -v claude >/dev/null 2>&1; then
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

# ── Rate-limit segments (5h/7d) — standalone pieces, not line-specific ─────
RATE5H_SEG=""; RATE7D_SEG=""
if [ -n "$RATE_5H" ] || [ -n "$RATE_7D" ]; then
    if [ "$ASCII" = "true" ]; then ROT='^'; else ROT='↻'; fi
    if [ -n "$RATE_5H" ]; then
        R5_BAR=$(rate_bar "$RATE_5H")
        R5_TIME=$(fmt_ts "$RATE_5H_AT")
        RATE5H_SEG="5h:${R5_BAR}${R5_TIME:+ (${ROT} ${R5_TIME})}"
    fi
    if [ -n "$RATE_7D" ]; then
        R7_BAR=$(rate_bar "$RATE_7D")
        R7_TIME=$(fmt_ts "$RATE_7D_AT")
        RATE7D_SEG="7d:${R7_BAR}${R7_TIME:+ (${ROT} ${R7_TIME})}"
    fi
fi

# ── Cost / PR / session name / thinking — standalone pieces ────────────────
COST_SEG=""
if [ -n "$COST_USD" ]; then
    COST_DISPLAY=$(awk -v c="$COST_USD" 'BEGIN{printf "%.2f", c}' 2>/dev/null)
    [ -z "$COST_DISPLAY" ] && COST_DISPLAY="$COST_USD"
    COST_SEG=$(printf '$%s' "$COST_DISPLAY")
fi

PR_SEG=""
if [ -n "$PR_NUM" ]; then
    PR_DISPLAY="PR #${PR_NUM}"
    if [ "$CLICKABLE_ON" = "true" ] && [[ "$PR_NUM" =~ ^[0-9]+$ ]] \
       && is_url_safe_token "$REPO_HOST" && is_url_safe_token "$REPO_OWNER" && is_url_safe_token "$REPO_NAME"; then
        PR_URL="https://${REPO_HOST}/${REPO_OWNER}/${REPO_NAME}/pull/${PR_NUM}"
        PR_DISPLAY=$(osc8_link "$PR_URL" "PR #${PR_NUM}")
    fi
    PR_SEG="${CYAN}${PR_DISPLAY}${RESET}"
    [ -n "$PR_REVIEW" ] && PR_SEG="${PR_SEG} ${GREEN}(review: ${PR_REVIEW})${RESET}"
fi

SESSIONNAME_SEG=""
[ -n "$SESSION_NAME" ] && SESSIONNAME_SEG="${DIM}session:${RESET}${SESSION_NAME}"

THINKING_SEG=""
if [ -n "$THINKING" ] && [ "$THINKING" != "null" ]; then
    if [ "$THINKING" = "true" ]; then THINKING_SEG="${DIM}thinking:on${RESET}"; else THINKING_SEG="${DIM}thinking:off${RESET}"; fi
fi

# ── Segment registry + line assembly ────────────────────────────────────────
# Every renderable piece gets a short id here. `segments` in the config, when
# present, is a FLAT ordered array of these ids — modeled after
# powerlevel10k's POWERLEVEL9K_LEFT_PROMPT_ELEMENTS — with one reserved
# sentinel, "newline", marking where to break to the next rendered line; no
# sentinel means everything renders on one line. This is what lets `segments`
# reposition or hide any single piece, and define however many lines you
# want, independent of layout. Width-aware truncation (fit_line) drops from
# the END of each line's resolved list, so position also doubles as
# priority — leftmost survives longest.
segment_value() {
    case "$1" in
        worktree)     printf '%s' "$WT_PART" ;;
        model)        printf '%s' "$MODEL_PART" ;;
        context)      printf '%s' "$CTX_PART" ;;
        linesChanged) printf '%s' "$LINES_PART" ;;
        git)          printf '%s' "$GIT_PART" ;;
        addDir)       printf '%s' "$ADDDIR_SEG" ;;
        outputStyle)  printf '%s' "$OUTSTYLE_SEG" ;;
        vim)          printf '%s' "$VIM_SEG" ;;
        idle)         printf '%s' "$IDLE_SEG" ;;
        rate5h)       printf '%s' "$RATE5H_SEG" ;;
        rate7d)       printf '%s' "$RATE7D_SEG" ;;
        burnRate)     printf '%s' "$BURN_SEG" ;;
        cost)         printf '%s' "$COST_SEG" ;;
        pr)           printf '%s' "$PR_SEG" ;;
        sessionName)  printf '%s' "$SESSIONNAME_SEG" ;;
        thinking)     printf '%s' "$THINKING_SEG" ;;
        agents)       printf '%s' "$AGENTS_SEG" ;;
        cacheTtl)     printf '%s' "$CACHE_TTL_SEG" ;;
        *)            printf '' ;;
    esac
}

# $DEFAULT_LINES holds one entry per line the layout renders by default,
# each entry a space-separated id list (order = render order). Used only
# when the config has no `segments` array at all — see below.
case "$LAYOUT" in
    minimal)
        DEFAULT_LINES=("model context git")
        ;;
    hardened)
        DEFAULT_LINES=(
            "worktree model context linesChanged git addDir outputStyle vim idle"
            "rate5h rate7d burnRate"
        )
        ;;
    power)
        DEFAULT_LINES=(
            "worktree model context linesChanged git addDir outputStyle vim idle"
            "rate5h rate7d burnRate"
            "cost pr sessionName thinking agents cacheTtl"
        )
        ;;
esac

# ── Segment separator — configurable glyph between pieces on a line ────────
# `separator.preset` picks a built-in glyph (each with an ASCII fallback for
# asciiMode); `separator.preset: "custom"` uses `separator.custom` verbatim
# instead. Sanitized like any other config-derived text even though the
# config file isn't session-derived — cheap insurance, not a real threat
# model change.
SEP_PRESET=$(cfg '.separator.preset // "pipe"')
SEP_CUSTOM=$(sanitize "$(cfg '.separator.custom // ""')")
case "$SEP_PRESET" in
    dot)     SEP_UNICODE='·'; SEP_ASCII_CH='.' ;;
    chevron) SEP_UNICODE='›'; SEP_ASCII_CH='>' ;;
    bar)     SEP_UNICODE='│'; SEP_ASCII_CH='|' ;;
    diamond) SEP_UNICODE='◆'; SEP_ASCII_CH='*' ;;
    custom)  SEP_UNICODE="$SEP_CUSTOM"; SEP_ASCII_CH="$SEP_CUSTOM" ;;
    *)       SEP_UNICODE='|'; SEP_ASCII_CH='|' ;;
esac
if [ "$ASCII" = "true" ]; then SEP_CHAR="$SEP_ASCII_CH"; else SEP_CHAR="$SEP_UNICODE"; fi
[ -z "$SEP_CHAR" ] && SEP_CHAR='|'
LINE_SEP=" ${DIM}${SEP_CHAR}${RESET} "

# Renders one line from a space-separated id list: looks up each id via
# segment_value(), drops empties, joins with $LINE_SEP (width-aware). $ids
# is deliberately word-split unquoted — every id is a plain identifier (no
# spaces), never user-facing rendered text.
render_line() {
    local ids="$1" id val
    LINE_PIECES=()
    for id in $ids; do
        val=$(segment_value "$id")
        [ -n "$val" ] && LINE_PIECES+=("$val")
    done
    fit_line "$LINE_SEP" "${LINE_PIECES[@]}"
}

# `segments`, when present at all (even `[]`), replaces the layout's default
# lines *entirely* — there's no per-line partial override once it's set.
# `[]` means "render nothing"; that's distinct from the key being absent
# (jq emits the literal "null" only for the absent/non-array case, so a
# plain `-z` check on the joined id string can't tell "absent" from
# "present but empty" apart — both join to "").
SEGMENTS_IDS=$(printf '%s' "$CFG" | jq -r \
    'if (.segments // null) == null or ((.segments|type) != "array") then "null" else (.segments | join(" ")) end' 2>/dev/null)

if [ "$SEGMENTS_IDS" != "null" ]; then
    CURRENT_LINE_IDS=""
    for id in $SEGMENTS_IDS; do
        if [ "$id" = "newline" ]; then
            LINE=$(render_line "$CURRENT_LINE_IDS")
            [ -n "$LINE" ] && printf '%s\n' "$LINE"
            CURRENT_LINE_IDS=""
        else
            CURRENT_LINE_IDS="${CURRENT_LINE_IDS} ${id}"
        fi
    done
    LINE=$(render_line "$CURRENT_LINE_IDS")
    [ -n "$LINE" ] && printf '%s\n' "$LINE"
else
    for IDS in "${DEFAULT_LINES[@]}"; do
        LINE=$(render_line "$IDS")
        [ -n "$LINE" ] && printf '%s\n' "$LINE"
    done
fi

exit 0
