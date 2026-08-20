#!/usr/bin/env bash
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
