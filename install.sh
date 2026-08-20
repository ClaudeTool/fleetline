#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║  claude-statusline — one-line installer (no plugin marketplace)  ║
# ║  Chạy: curl -fsSL <raw-url>/install.sh | bash                    ║
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
printf "${C}  claude-statusline — Installer                 ${Z}\n"
printf "${C}═══════════════════════════════════════════════${Z}\n\n"

# ── Kiểm tra prerequisites ───────────────────────────────────────────────────
info "Kiểm tra prerequisites..."

command -v jq  >/dev/null 2>&1 || die "jq chưa được cài. Cài bằng: brew install jq  hoặc  apt install jq"
command -v git >/dev/null 2>&1 || warn "git chưa cài — thông tin git branch sẽ không hiển thị"
ok "jq có sẵn"

# ── Tạo thư mục ~/.claude nếu chưa có ───────────────────────────────────────
mkdir -p "$HOME/.claude"

# ── Ghi statusline script (bản đã hardened bảo mật + 3 layout preset) ──────
info "Cài statusline script vào $SCRIPT_DEST ..."

cat > "$SCRIPT_DEST" << 'STATUSLINE_EOF'
#!/usr/bin/env bash
# claude-statusline — pluggable Claude Code statusline.
#
# Reads the session JSON Claude Code pipes on stdin, plus a user config file
# (outside this plugin's own directory, so plugin updates never wipe it), and
# prints 1-3 rendered lines. Three layout presets: minimal / hardened / power.

input=$(cat)

# ── Preflight ─────────────────────────────────────────────────────────────
if ! command -v jq >/dev/null 2>&1; then
    printf '%s\n' "[statusline: thiếu lệnh 'jq' — cài rồi thử lại (xem README)]"
    exit 0
fi
GIT_OK=1
command -v git >/dev/null 2>&1 || GIT_OK=0

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

# git: never let a repo's own config run arbitrary commands (core.fsmonitor),
# and never let a status check take a lock that races a concurrent git op —
# this fires on every statusline refresh (every 30s by default).
GITOPTS=(-c core.fsmonitor= --no-optional-locks)

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

rate_bar() {
    local raw="$1" p
    p=$(printf '%.0f' "$raw" 2>/dev/null) || p=0
    p=$(clamp_pct "$p")
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
    printf '%s' "${color}[${f_str}${e_str}]${RESET} ${color}${p}%${RESET}"
}

join_with() {
    local sep="$1"; shift
    local out="" first=1 p
    for p in "$@"; do
        if [ "$first" -eq 1 ]; then out="$p"; first=0; else out="${out}${sep}${p}"; fi
    done
    printf '%s' "$out"
}

# ── Load config (lives outside this plugin's dir — survives plugin updates) ─
CONFIG_FILE="${STATUSLINE_CONFIG:-$HOME/.claude/statusline-claude-statusline.config.json}"
if [ -f "$CONFIG_FILE" ] && jq empty "$CONFIG_FILE" >/dev/null 2>&1; then
    CFG=$(cat "$CONFIG_FILE")
else
    CFG='{}'
fi
cfg() { printf '%s' "$CFG" | jq -r "$1" 2>/dev/null; }

LAYOUT=$(cfg '.layout // "hardened"')
case "$LAYOUT" in minimal|hardened|power) ;; *) LAYOUT="hardened" ;; esac
ASCII=$(cfg '.asciiMode // false')
[ "$ASCII" = "true" ] || ASCII="false"
WARN_T=$(clamp_pct "$(cfg '.thresholds.warn // 70')")
CRIT_T=$(clamp_pct "$(cfg '.thresholds.crit // 90')")
COMPACT_HINT=$(cfg '.hints.compactHint // true')
[ "$COMPACT_HINT" = "false" ] || COMPACT_HINT="true"

# ── Extract fields from stdin ────────────────────────────────────────────────
MODEL=$(sanitize "$(echo "$input"        | jq -r '.model.display_name // "?"')")
VERSION=$(sanitize "$(echo "$input"      | jq -r '.version // ""')")
CWD=$(echo "$input"                      | jq -r '.workspace.current_dir // .cwd // ""')
GIT_WORKTREE=$(sanitize "$(echo "$input" | jq -r '.workspace.git_worktree // empty')")

PCT=$(clamp_pct "$(echo "$input" | jq -r '.context_window.used_percentage // 0' | cut -d. -f1)")
CTX_SIZE=$(echo "$input"    | jq -r '.context_window.context_window_size // 200000')
EXCEEDS=$(echo "$input"     | jq -r '.exceeds_200k_tokens // false')

LINES_ADD=$(echo "$input"   | jq -r '.cost.total_lines_added // 0')
LINES_REM=$(echo "$input"   | jq -r '.cost.total_lines_removed // 0')
COST_USD=$(echo "$input"    | jq -r '.cost.total_cost_usd // empty')

SESSION_ID=$(echo "$input"                | jq -r '.session_id // empty')
SESSION_NAME=$(sanitize "$(echo "$input"  | jq -r '.session_name // empty')")
PROMPT_ID=$(echo "$input"                 | jq -r '.prompt_id // empty')
EFFORT=$(sanitize "$(echo "$input"        | jq -r '.effort.level // empty')")
THINKING=$(echo "$input"                  | jq -r '.thinking.enabled // empty')
PR_NUM=$(echo "$input"                    | jq -r '.pr.number // empty')
PR_REVIEW=$(sanitize "$(echo "$input"     | jq -r '.pr.review_state // empty')")

RATE_5H=$(echo "$input"     | jq -r '.rate_limits.five_hour.used_percentage // empty')
RATE_5H_AT=$(echo "$input"  | jq -r '.rate_limits.five_hour.resets_at // empty')
RATE_7D=$(echo "$input"     | jq -r '.rate_limits.seven_day.used_percentage // empty')
RATE_7D_AT=$(echo "$input"  | jq -r '.rate_limits.seven_day.resets_at // empty')

# ── Context bar + optional "/compact?" hint ─────────────────────────────────
if   [ "$PCT" -ge "$CRIT_T" ]; then BAR_COLOR="$RED"
elif [ "$PCT" -ge "$WARN_T" ]; then BAR_COLOR="$YELLOW"
else                                BAR_COLOR="$GREEN"; fi
FILLED=$((PCT * 10 / 100)); EMPTY=$((10 - FILLED))
if [ "$ASCII" = "true" ]; then FILLCH='#'; EMPTYCH='-'; else FILLCH='█'; EMPTYCH='░'; fi
printf -v F_STR "%${FILLED}s" 2>/dev/null; BAR_F="${F_STR// /$FILLCH}"
printf -v E_STR "%${EMPTY}s"  2>/dev/null; BAR_E="${E_STR// /$EMPTYCH}"
CTX_K=$((CTX_SIZE / 1000))
EXCEEDS_LABEL=""
if [ "$EXCEEDS" = "true" ]; then
    if [ "$ASCII" = "true" ]; then EXCEEDS_LABEL="${RED}!${RESET} "; else EXCEEDS_LABEL="${RED}⚠${RESET} "; fi
fi
CTX_PART="${EXCEEDS_LABEL}Ctx ${BAR_COLOR}[${BAR_F}${BAR_E}]${RESET} ${PCT}%/${CTX_K}k"
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
    if [ "$ASCII" = "true" ]; then GIT_PART="git:${GREEN}${BRANCH}${RESET} ${CHANGES}"
    else                           GIT_PART="🌿 ${GREEN}${BRANCH}${RESET} ${CHANGES}"; fi
fi

# ── Cache TTL (power layout only) — inferred, not a real API field ─────────
# Tracks wall-clock time since the last distinct prompt_id per session, in a
# small state file outside the plugin dir. TTL window: 60min if rate_limits
# is present in the payload (subscription plans expose it), else 5min (API
# key / pay-as-you-go) — matches Anthropic's documented prompt-cache TTLs.
CACHE_TTL_SEG=""
if [ "$LAYOUT" = "power" ] && [ -n "$SESSION_ID" ]; then
    STATE_DIR="$HOME/.claude/cache-state"
    mkdir -p "$STATE_DIR" 2>/dev/null
    STATE_FILE="$STATE_DIR/${SESSION_ID}.state"
    NOW=$(date +%s)
    LAST_PROMPT_ID=""
    LAST_TS="$NOW"
    if [ -f "$STATE_FILE" ]; then
        LAST_PROMPT_ID=$(cut -d' ' -f1 "$STATE_FILE" 2>/dev/null)
        LAST_TS=$(cut -d' ' -f2 "$STATE_FILE" 2>/dev/null)
        case "$LAST_TS" in ''|*[!0-9]*) LAST_TS="$NOW" ;; esac
    fi
    if [ -z "$PROMPT_ID" ] || [ "$PROMPT_ID" != "$LAST_PROMPT_ID" ]; then
        LAST_TS="$NOW"
        printf '%s %s\n' "$PROMPT_ID" "$NOW" > "$STATE_FILE" 2>/dev/null
    fi
    if [ -n "$RATE_5H" ] || [ -n "$RATE_7D" ]; then TTL_MIN=60; else TTL_MIN=5; fi
    ELAPSED=$(( NOW - LAST_TS ))
    REMAINING=$(( TTL_MIN * 60 - ELAPSED ))
    if [ "$REMAINING" -le 0 ]; then
        if [ "$ASCII" = "true" ]; then CACHE_TTL_SEG="${RED}TTL het${RESET}"
        else                           CACHE_TTL_SEG="${RED}❄ TTL hết${RESET}"; fi
    elif [ "$REMAINING" -le 600 ]; then
        CACHE_TTL_SEG="${YELLOW}TTL:$(( REMAINING / 60 ))m${RESET}"
    else
        CACHE_TTL_SEG="${GREEN}TTL:$(( REMAINING / 60 ))m${RESET}"
    fi
fi

# ── Assemble line 1 by layout ────────────────────────────────────────────────
case "$LAYOUT" in
    minimal)
        L1="${MODEL_PART} | ${CTX_PART}"
        [ -n "$GIT_PART" ] && L1="${L1} | ${GIT_PART}"
        ;;
    hardened|power)
        L1="${MODEL_PART} | ${CTX_PART} | ${LINES_PART}"
        [ -n "$WT_PART" ]  && L1="${L1} | ${WT_PART}"
        [ -n "$GIT_PART" ] && L1="${L1} | ${GIT_PART}"
        ;;
esac
printf '%s\n' "$L1"

# ── Line 2 — rate limits (hardened/power, only when the plan exposes them) ─
if [ "$LAYOUT" != "minimal" ] && { [ -n "$RATE_5H" ] || [ -n "$RATE_7D" ]; }; then
    if [ "$ASCII" = "true" ]; then ROT='^'; else ROT='↻'; fi
    L2="Rate:"
    if [ -n "$RATE_5H" ]; then
        R5_BAR=$(rate_bar "$RATE_5H")
        R5_TIME=$(fmt_ts "$RATE_5H_AT")
        L2="${L2} 5h:${R5_BAR}${R5_TIME:+ (${ROT} ${R5_TIME})}"
    fi
    if [ -n "$RATE_7D" ]; then
        R7_BAR=$(rate_bar "$RATE_7D")
        R7_TIME=$(fmt_ts "$RATE_7D_AT")
        L2="${L2} | 7d:${R7_BAR}${R7_TIME:+ (${ROT} ${R7_TIME})}"
    fi
    printf '%s\n' "$L2"
fi

# ── Line 3 — power extras (only fields actually present in the payload) ────
if [ "$LAYOUT" = "power" ]; then
    PARTS=()
    [ -n "$COST_USD" ]     && PARTS+=("$(printf '$%s' "$COST_USD")")
    [ -n "$SESSION_NAME" ] && PARTS+=("${DIM}session:${RESET}${SESSION_NAME}")
    if [ -n "$PR_NUM" ]; then
        SEG="${CYAN}PR #${PR_NUM}${RESET}"
        [ -n "$PR_REVIEW" ] && SEG="${SEG} ${GREEN}(review: ${PR_REVIEW})${RESET}"
        PARTS+=("$SEG")
    fi
    [ -n "$EFFORT" ] && PARTS+=("${MAGENTA}effort:${EFFORT}${RESET}")
    if [ -n "$THINKING" ] && [ "$THINKING" != "null" ]; then
        if [ "$THINKING" = "true" ]; then PARTS+=("${DIM}thinking:on${RESET}"); else PARTS+=("${DIM}thinking:off${RESET}"); fi
    fi
    [ -n "$CACHE_TTL_SEG" ] && PARTS+=("$CACHE_TTL_SEG")
    if [ "${#PARTS[@]}" -gt 0 ]; then
        L3=$(join_with " ${DIM}|${RESET} " "${PARTS[@]}")
        printf '%s\n' "$L3"
    fi
fi
STATUSLINE_EOF

chmod +x "$SCRIPT_DEST"
ok "Script đã ghi vào $SCRIPT_DEST"

# ── Cập nhật settings.json ───────────────────────────────────────────────────
info "Cập nhật $SETTINGS_FILE ..."

STATUSLINE_JSON='{"type":"command","command":"bash '"$SCRIPT_DEST"'","refreshInterval":30}'

if [ -f "$SETTINGS_FILE" ]; then
    TMP=$(mktemp)
    jq --argjson sl "$STATUSLINE_JSON" '.statusLine = $sl' "$SETTINGS_FILE" > "$TMP" \
        && mv "$TMP" "$SETTINGS_FILE"
    ok "settings.json đã cập nhật (các settings khác được giữ nguyên)"
    warn "Nếu bạn đã có statusLine tuỳ biến riêng, nó vừa bị ghi đè — settings.json KHÔNG được backup tự động ở đường cài này. Dùng plugin (+/statusline-setup) nếu muốn có backup tự động."
else
    printf '{\n  "statusLine": %s\n}\n' "$STATUSLINE_JSON" > "$SETTINGS_FILE"
    ok "settings.json đã tạo mới"
fi

# ── Config mặc định (layout hardened, ascii off) ────────────────────────────
CONFIG_FILE="$HOME/.claude/statusline-claude-statusline.config.json"
if [ ! -f "$CONFIG_FILE" ]; then
    cat > "$CONFIG_FILE" << 'CONFIG_EOF'
{
  "layout": "hardened",
  "asciiMode": false,
  "thresholds": { "warn": 70, "crit": 90 },
  "hints": { "compactHint": true }
}
CONFIG_EOF
    ok "Config mặc định đã tạo: $CONFIG_FILE"
else
    ok "Đã có config từ trước, giữ nguyên: $CONFIG_FILE"
fi

# ── Tổng kết ─────────────────────────────────────────────────────────────────
echo ""
printf "${G}═══════════════════════════════════════════════${Z}\n"
printf "${G}  Cài đặt hoàn tất!                            ${Z}\n"
printf "${G}═══════════════════════════════════════════════${Z}\n\n"

printf "  Script : ${D}%s${Z}\n" "$SCRIPT_DEST"
printf "  Config : ${D}%s${Z}\n" "$CONFIG_FILE"
printf "  Layout : ${D}hardened (đổi bằng cách sửa \"layout\" trong config: minimal | hardened | power)${Z}\n"
echo ""
printf "  Status line sẽ hiển thị sau lượt tiếp theo trong Claude Code — không cần khởi động lại.\n"
echo ""
