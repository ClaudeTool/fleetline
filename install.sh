#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║  fleetline — one-line installer (no plugin marketplace)          ║
# ║  Run: curl -fsSL <raw-url>/install.sh | bash                     ║
# ╚══════════════════════════════════════════════════════════════════╝

set -e

SCRIPT_DEST="$HOME/.claude/statusline-command.sh"
SETTINGS_FILE="$HOME/.claude/settings.json"

# ── Colors ───────────────────────────────────────────────────────────────────
G='\033[32m'; Y='\033[33m'; R='\033[31m'; C='\033[36m'; D='\033[2m'; Z='\033[0m'
ok()   { printf "${G}✓${Z} %s\n" "$1"; }
info() { printf "${C}→${Z} %s\n" "$1"; }
warn() { printf "${Y}!${Z} %s\n" "$1"; }
die()  { printf "${R}✗ %s${Z}\n" "$1" >&2; exit 1; }

echo ""
printf "${C}═══════════════════════════════════════════════${Z}\n"
printf "${C}  fleetline — Installer                 ${Z}\n"
printf "${C}═══════════════════════════════════════════════${Z}\n\n"

# ── Check prerequisites ──────────────────────────────────────────────────────
info "Checking prerequisites..."

command -v jq  >/dev/null 2>&1 || die "jq is not installed. Install with: brew install jq  or  apt install jq"
command -v git >/dev/null 2>&1 || warn "git is not installed — the git branch segment won't render"
ok "jq is available"

# ── Create ~/.claude if it doesn't exist ─────────────────────────────────────
mkdir -p "$HOME/.claude"

# ── Write the statusline script (security-hardened, 3 layout presets) ──────
info "Installing statusline script to $SCRIPT_DEST ..."

cat > "$SCRIPT_DEST" << 'STATUSLINE_EOF'
#!/usr/bin/env bash
# fleetline — pluggable Claude Code statusline (curl-install build: lib.sh
# inlined below since this installer writes a single self-contained file).

# fleetline — shared helpers for bin/statusline.sh and
# bin/subagent-statusline.sh. Sourced, not executed directly.

# ── Colors — real escape bytes, never re-interpreted via printf '%b' ───────
CYAN=$'\033[36m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RED=$'\033[31m'
MAGENTA=$'\033[35m'; DIM=$'\033[2m'; RESET=$'\033[0m'

# Strip control bytes (incl. ESC/0x1B, DEL/0x7F) from any value that came
# from session JSON or a subprocess, so it can never smuggle a terminal
# escape or OSC sequence into the rendered line.
sanitize() { printf '%s' "$1" | tr -d '\000-\037\177'; }

# Clamp to an integer in [0,100]; anything unparsable becomes 0.
clamp_pct() {
    local v="$1"
    case "$v" in ''|*[!0-9]*) v=0 ;; esac
    [ "$v" -gt 100 ] && v=100
    printf '%s' "$v"
}

join_with() {
    local sep="$1"; shift
    local out="" first=1 p
    for p in "$@"; do
        if [ "$first" -eq 1 ]; then out="$p"; first=0; else out="${out}${sep}${p}"; fi
    done
    printf '%s' "$out"
}

# Strip ANSI SGR color codes and OSC-8 hyperlink wrappers so remaining text
# length reflects what a terminal actually renders.
strip_ansi() {
    printf '%s' "$1" | sed -E $'s/\x1b\\[[0-9;]*m//g; s/\x1b\\]8;;[^\x07]*\x07//g; s/\x1b\\]8;;\x1b\\\\//g'
}

visible_len() {
    strip_ansi "$1" | wc -m | tr -d ' '
}

# Terminal width: $COLUMNS (rarely exported to subprocesses) → `tput cols`
# (often unavailable — the statusline command has no controlling tty) →
# 120-column fallback.
term_cols() {
    local c="${COLUMNS:-}"
    [ -z "$c" ] && c=$(tput cols 2>/dev/null)
    case "$c" in ''|*[!0-9]*) c=120 ;; esac
    printf '%s' "$c"
}

# fit_line SEP PIECE1 PIECE2 ... — pass pieces most-important-first. Drops
# from the END (least important) until the joined line fits the terminal
# width, or only the first piece remains. No-op (just joins) if
# WIDTH_AWARE != "true".
fit_line() {
    local sep="$1"; shift
    local pieces=("$@")
    if [ "${#pieces[@]}" -eq 0 ]; then printf ''; return; fi
    if [ "$WIDTH_AWARE" != "true" ]; then join_with "$sep" "${pieces[@]}"; return; fi
    local cols; cols=$(term_cols)
    while [ "${#pieces[@]}" -gt 1 ]; do
        local joined; joined=$(join_with "$sep" "${pieces[@]}")
        local vlen; vlen=$(visible_len "$joined")
        case "$vlen" in *[!0-9]*|'') break ;; esac
        if [ "$vlen" -le "$cols" ]; then printf '%s' "$joined"; return; fi
        unset 'pieces[${#pieces[@]}-1]'
        pieces=("${pieces[@]}")
    done
    join_with "$sep" "${pieces[@]}"
}

# OSC-8 hyperlink wrapper. Only call this with a URL you have already
# validated against a strict charset (see build_url_safe) — never with raw
# session-derived text, since the escape sequence itself would otherwise be
# an injection vector identical in spirit to the printf '%b' issue this
# plugin's main script was hardened against.
osc8_link() {
    local url="$1" text="$2"
    printf '\033]8;;%s\033\\%s\033]8;;\033\\' "$url" "$text"
}

# Returns 0 (safe) only if every arg matches [A-Za-z0-9._-]+; used to gate
# building a URL out of workspace.repo.host/owner/name before it's ever
# concatenated into an OSC-8 sequence.
is_url_safe_token() {
    case "$1" in
        '') return 1 ;;
        *[!A-Za-z0-9._-]*) return 1 ;;
        *) return 0 ;;
    esac
}

# Looser variant for a git branch/path segment (allows /), used only for the
# path component of a URL already anchored to a validated host/owner/repo.
is_path_safe_token() {
    case "$1" in
        '') return 1 ;;
        *[!A-Za-z0-9._/-]*) return 1 ;;
        *) return 0 ;;
    esac
}

# ── Config (lives outside this plugin's dir — survives plugin updates) ─────
CONFIG_FILE="${STATUSLINE_CONFIG:-$HOME/.claude/statusline-fleetline.config.json}"
if [ -f "$CONFIG_FILE" ] && jq empty "$CONFIG_FILE" >/dev/null 2>&1; then
    CFG=$(cat "$CONFIG_FILE")
else
    CFG='{}'
fi
cfg() { printf '%s' "$CFG" | jq -r "$1" 2>/dev/null; }

# jq's `//` treats a stored `false` as falsy too, same as null/missing — so
# `.features.foo // true` SILENTLY DISCARDS an explicit `false` in the
# config and substitutes the default. Every boolean flag in this plugin
# must be read through this helper instead, which only falls back to
# $default on an actually-missing (null) value.
cfg_bool() {
    local path="$1" default="$2" raw
    raw=$(printf '%s' "$CFG" | jq -r "$path" 2>/dev/null)
    case "$raw" in
        null|"") printf '%s' "$default" ;;
        true)    printf 'true' ;;
        *)       printf 'false' ;;
    esac
}

ASCII=$(cfg_bool '.asciiMode' false)
WARN_T=$(clamp_pct "$(cfg '.thresholds.warn // 70')")
CRIT_T=$(clamp_pct "$(cfg '.thresholds.crit // 90')")
WIDTH_AWARE=$(cfg_bool '.features.widthAwareTruncate' true)

fmt_ts() {
    [ -z "$1" ] && return
    local today_day target_day
    today_day=$(date '+%Y%m%d' 2>/dev/null)
    target_day=$(date -d "@$1" '+%Y%m%d' 2>/dev/null || date -r "$1" '+%Y%m%d' 2>/dev/null)
    if [ -n "$target_day" ] && [ "$target_day" = "$today_day" ]; then
        date -d "@$1" '+%H:%M' 2>/dev/null || date -r "$1" '+%H:%M' 2>/dev/null
    else
        date -d "@$1" '+%a %d/%m %H:%M' 2>/dev/null || date -r "$1" '+%a %d/%m %H:%M' 2>/dev/null
    fi
}

# Draws just "[███░░░░░░░]" (colored by $WARN_T/$CRIT_T, ASCII-aware), no
# percentage suffix — the one place the 10-cell width and fill-character
# logic lives, shared by the main script's context bar and rate_bar below
# (and, via rate_bar, the per-task context bars in the subagent renderer).
draw_bar() {
    local p="$1"
    local filled=$(( p * 10 / 100 )) empty=$(( 10 - p * 10 / 100 ))
    local color
    if   [ "$p" -ge "$CRIT_T" ]; then color="$RED"
    elif [ "$p" -ge "$WARN_T" ]; then color="$YELLOW"
    else                               color="$GREEN"; fi
    local fillch emptych
    if [ "$ASCII" = "true" ]; then fillch='#'; emptych='-'; else fillch='█'; emptych='░'; fi
    local f_str e_str
    [ "$filled" -gt 0 ] && printf -v f_str "%${filled}s" && f_str="${f_str// /$fillch}" || f_str=""
    [ "$empty"  -gt 0 ] && printf -v e_str "%${empty}s"  && e_str="${e_str// /$emptych}" || e_str=""
    printf '%s' "${color}[${f_str}${e_str}]${RESET}"
}

# Renders "[bar] p%" colored by $WARN_T/$CRIT_T. Used for rate-limit bars in
# the main script and per-task context bars in the subagent renderer.
rate_bar() {
    local raw="$1" p
    p=$(printf '%.0f' "$raw" 2>/dev/null) || p=0
    p=$(clamp_pct "$p")
    local color
    if   [ "$p" -ge "$CRIT_T" ]; then color="$RED"
    elif [ "$p" -ge "$WARN_T" ]; then color="$YELLOW"
    else                               color="$GREEN"; fi
    printf '%s %s' "$(draw_bar "$p")" "${color}${p}%${RESET}"
}

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
STATUSLINE_EOF

chmod +x "$SCRIPT_DEST"
ok "Script written to $SCRIPT_DEST"

# ── Update settings.json ─────────────────────────────────────────────────────
info "Updating $SETTINGS_FILE ..."

STATUSLINE_JSON='{"type":"command","command":"bash '"$SCRIPT_DEST"'","refreshInterval":30}'

if [ -f "$SETTINGS_FILE" ]; then
    TMP=$(mktemp)
    jq --argjson sl "$STATUSLINE_JSON" '.statusLine = $sl' "$SETTINGS_FILE" > "$TMP" \
        && mv "$TMP" "$SETTINGS_FILE"
    ok "settings.json updated (other settings left untouched)"
    warn "If you already had a custom statusLine, it was just overwritten — settings.json is NOT backed up automatically by this install path. Use the plugin (/statusline-setup) if you want that safety net."
else
    printf '{\n  "statusLine": %s\n}\n' "$STATUSLINE_JSON" > "$SETTINGS_FILE"
    ok "settings.json created"
fi

# ── Default config (full set from config/schema.json) ───────────────────────
CONFIG_FILE="$HOME/.claude/statusline-fleetline.config.json"
if [ ! -f "$CONFIG_FILE" ]; then
    cat > "$CONFIG_FILE" << 'CONFIG_EOF'
{
  "layout": "hardened",
  "asciiMode": false,
  "thresholds": { "warn": 70, "crit": 90 },
  "hints": { "compactHint": true, "idleThresholdMin": 5 },
  "features": {
    "burnRate": true,
    "idleIndicator": true,
    "widthAwareTruncate": true,
    "outputStyleSegment": true,
    "vimModeSegment": true,
    "addDirSegment": true,
    "clickableLinks": false
  },
  "agents": {
    "bgAgentSegment": false,
    "bgAgentPollSeconds": 60,
    "hookCounterEnabled": false
  }
}
CONFIG_EOF
    ok "Default config created: $CONFIG_FILE"
else
    ok "Existing config found, left untouched: $CONFIG_FILE"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
printf "${G}═══════════════════════════════════════════════${Z}\n"
printf "${G}  Install complete!                            ${Z}\n"
printf "${G}═══════════════════════════════════════════════${Z}\n\n"

printf "  Script : ${D}%s${Z}\n" "$SCRIPT_DEST"
printf "  Config : ${D}%s${Z}\n" "$CONFIG_FILE"
printf "  Layout : ${D}hardened (change by editing \"layout\" in the config: minimal | hardened | power)${Z}\n"
echo ""
printf "  The status line will show up on your next turn in Claude Code — no restart needed.\n"
printf "  ${D}Note: the background-agent hook counter and the subagentStatusLine surface (fleet view)${Z}\n"
printf "  ${D}are plugin-only (/plugin install) — not available through this curl installer.${Z}\n"
echo ""
