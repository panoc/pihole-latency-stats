#!/bin/bash
# ==============================================================================
# Script:      Pi-hole Latency Stats
# Description: Lightweight dashboard for Pi-hole latency & Unbound DNS cache stats.
# Author:      panoc
# GitHub:      https://github.com/panoc/pihole-latency-stats
# License:     GPLv3
# ==============================================================================
# Copyright (C) 2026 panoc <https://github.com/panoc>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.
# ==============================================================================

VERSION="3.3.1"

# --- 0. CRITICAL LOCALE FIX ---
# Force C locale to prevent decimal errors (comma vs dot) in math operations
export LC_ALL=C

# Capture start time
START_TS=$(date +%s.%N 2>/dev/null)
if [[ "$START_TS" == *N* ]] || [ -z "$START_TS" ]; then START_TS=$(date +%s); fi

# --- TRAP: CUSTOM ABORT MESSAGE ---
# Catches Ctrl+C (INT), prints message, and exits (which triggers the cleanup trap)
trap 'echo -e "\n\nProgram aborted by user." >&2; exit 1' INT

# --- 1. SETUP & DEFAULTS ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
DEFAULT_CONFIG="$SCRIPT_DIR/pihole_stats.conf"
CONFIG_TO_LOAD="$DEFAULT_CONFIG"

# Internal Defaults (used if config is missing or empty)
DBfile="/etc/pihole/pihole-FTL.db"
SAVE_DIR_TXT=""
SAVE_DIR_JSON=""
TXT_NAME=""
JSON_NAME=""
CONFIG_ARGS=""
MAX_LOG_AGE=""
ENABLE_UNBOUND="auto"
LAYOUT="auto"
DEFAULT_FROM="" 
DEFAULT_TO=""

# --- ANIMATION SETTINGS (Hardcoded) ---
target_time=4.0      # Seconds for one full cycle
width_divider=3      # 1/3 of screen width
char="|"             # Character for the bar

# Default Tiers
L01="0.009"; L02="0.1"; L03="1"; L04="10"; L05="50"
L06="100"; L07="300"; L08="1000"
L09=""; L10=""; L11=""; L12=""; L13=""; L14=""; L15=""; L16=""; L17=""; L18=""; L19=""; L20=""

# Default Time Range
QUERY_START=0
QUERY_END=$(date +%s)
TIME_LABEL="All Time"

# --- HELPER: FIX PERMISSIONS ---
fix_perms() {
    local target="$1"
    # If run via sudo, SUDO_UID and SUDO_GID are set. Transfer ownership back to the user.
    if [ -n "$SUDO_UID" ] && [ -n "$SUDO_GID" ] && [ -f "$target" ]; then
        chown "$SUDO_UID:$SUDO_GID" "$target"
    fi
}

# --- 2. CONFIGURATION WRITER ---
write_config() {
    local target_file="$1"
    
    # We use cat to write the file, injecting current variable values
    cat <<EOF > "$target_file"
# ================= PI-HOLE STATS CONFIGURATION =================
DBfile="$DBfile"

# Default Save Directories (REQUIRED for Auto-Deletion to work)
# Separate directories for Text and JSON reports.
# If left empty, files are saved in the current directory.

# Text Reports (.txt)
# Example: SAVE_DIR_TXT="/home/pi/pihole_reports/text"
SAVE_DIR_TXT="$SAVE_DIR_TXT"

# JSON Reports (.json)
# Example: SAVE_DIR_JSON="/home/pi/pihole_reports/json"
SAVE_DIR_JSON="$SAVE_DIR_JSON"

# Default Filenames (If set, the -f flag is no longer required)
# Example: TXT_NAME="daily_report.txt"
# Example: JSON_NAME="dash_default.json"
TXT_NAME="$TXT_NAME"
JSON_NAME="$JSON_NAME"

# Auto-Delete Old Reports (Retention Policy)
# Delete files in SAVE_DIR_TXT and SAVE_DIR_JSON older than X days.
# Example: MAX_LOG_AGE="30"
MAX_LOG_AGE="$MAX_LOG_AGE"

# Unbound Integration
# auto  : Check if Unbound is installed & used by Pi-hole.
# true  : Always append Unbound stats.
# false : Never show Unbound stats (unless -unb is used).
ENABLE_UNBOUND="$ENABLE_UNBOUND"

# Visual Layout
# auto       : Detects terminal width. >100 columns = Horizontal, else Vertical.
# vertical   : Forces standard vertical list view.
# horizontal : Forces split-pane dashboard view.
LAYOUT="$LAYOUT"

# Custom Date Range Defaults (Optional)
# Use natural language (e.g. "yesterday", "today 00:00") or dates.
# CLI flags (-24h, -from) will OVERRIDE these settings.
DEFAULT_FROM="$DEFAULT_FROM"
DEFAULT_TO="$DEFAULT_TO"

# [OPTIONAL] Default Arguments
# If set, these arguments will REPLACE any CLI flags.
# Use single quotes if your arguments contain filenames with spaces.
# Example: CONFIG_ARGS='-up -24h -j -f "my stats.json"'
CONFIG_ARGS='$CONFIG_ARGS'

# Latency Tiers (Upper Limits in Milliseconds)
# Add more values (L09, L10...) to create granular buckets.
L01="$L01"
L02="$L02"
L03="$L03"
L04="$L04"
L05="$L05"
L06="$L06"
L07="$L07"
L08="$L08"
L09="$L09"
L10="$L10"
L11="$L11"
L12="$L12"
L13="$L13"
L14="$L14"
L15="$L15"
L16="$L16"
L17="$L17"
L18="$L18"
L19="$L19"
L20="$L20"
EOF
    chmod 644 "$target_file"
    fix_perms "$target_file"
}

create_or_update_config() {
    local target_file="$1"
    if [ -f "$target_file" ]; then source "$target_file"; fi
    write_config "$target_file"
}

# --- 3. PRE-SCAN FLAGS ---
args_preserve=("$@") 
while [[ $# -gt 0 ]]; do
    case $1 in
        -c|--config) shift; CONFIG_TO_LOAD="$1"; shift ;;
        -mc|--make-config) shift; create_or_update_config "$1"; exit 0 ;;
        *) shift ;;
    esac
done

# --- 4. LOAD CONFIG ---
if [ -f "$CONFIG_TO_LOAD" ]; then 
    source "$CONFIG_TO_LOAD"
    
    # Backward Compatibility: Map old SAVE_DIR to SAVE_DIR_TXT if needed
    if [ -n "$SAVE_DIR" ] && [ -z "$SAVE_DIR_TXT" ]; then
        SAVE_DIR_TXT="$SAVE_DIR"
    fi
    
    # Auto-Repair/Update Config: If new variables are missing OR old animation vars exist, rewrite the file
    if ! grep -q "JSON_NAME=" "$CONFIG_TO_LOAD" || grep -q "target_time=" "$CONFIG_TO_LOAD"; then
        write_config "$CONFIG_TO_LOAD"
    fi
elif [ "$CONFIG_TO_LOAD" == "$DEFAULT_CONFIG" ]; then
    write_config "$DEFAULT_CONFIG" > /dev/null; source "$DEFAULT_CONFIG"
fi

if [ -n "$DEFAULT_FROM" ]; then if TS=$(date -d "$DEFAULT_FROM" +%s 2>/dev/null); then QUERY_START="$TS"; TIME_LABEL="Custom Range"; fi; fi
if [ -n "$DEFAULT_TO" ]; then if TS=$(date -d "$DEFAULT_TO" +%s 2>/dev/null); then QUERY_END="$TS"; TIME_LABEL="Custom Range"; fi; fi
if [ -n "$CONFIG_ARGS" ]; then eval set -- "$CONFIG_ARGS"; else set -- "${args_preserve[@]}"; fi

# --- 5. HELP ---
show_help() {
    echo "Pi-hole Latency Stats v$VERSION"
    echo "Usage: sudo ./pihole_stats.sh [OPTIONS]"
    echo "  -24h, -7d        : Quick time filter"
    echo "  -from, -to       : Custom date range"
    echo "  -up, -pi, -nx    : Query modes"
    echo "  -dm, -edm        : Domain filter"
    echo "  -f <file>        : Save to file (Overrides config default)"
    echo "  -j               : JSON output"
    echo "  -s               : Silent mode"
    echo "  -seq, -ts        : Naming options"
    echo "  -rt <days>       : Auto-delete old reports"
    echo "  -unb, -unb-only  : Unbound Stats"
    echo "  -ucc             : Unbound Cache Count"
    echo "  -hor, -ver       : Force Layout"
    echo "  -snap            : Snapshot Mode"
    echo "  -c, -mc          : Config (Load/Make)"
    exit 0
}

# --- 6. ARGUMENTS ---
MODE="DEFAULT"; EXCLUDE_NX=false; OUTPUT_FILE=""; JSON_OUTPUT=false; SILENT_MODE=false
DOMAIN_FILTER=""; SQL_DOMAIN_CLAUSE=""; SEQUENTIAL=false; ADD_TIMESTAMP=false
SHOW_UNBOUND="default"; USE_SNAPSHOT=false; ENABLE_UCC=false

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help) show_help ;;
        -c|--config|-mc|--make-config) shift; shift ;;
        -up) MODE="UPSTREAM"; shift ;;
        -pi) MODE="PIHOLE"; shift ;;
        -nx) EXCLUDE_NX=true; shift ;;
        -j|--json) JSON_OUTPUT=true; shift ;;
        -s|--silent) SILENT_MODE=true; shift ;;
        -seq) SEQUENTIAL=true; shift ;;
        -ts|--timestamp) ADD_TIMESTAMP=true; shift ;;
        -db) shift; DBfile="$1"; shift ;;
        -rt|--retention) shift; MAX_LOG_AGE="$1"; shift ;;
        -unb) SHOW_UNBOUND="yes"; shift ;;
        -unb-only) SHOW_UNBOUND="only"; shift ;;
        -no-unb) SHOW_UNBOUND="no"; shift ;;
        -snap) USE_SNAPSHOT=true; shift ;;
        -ucc) ENABLE_UCC=true; shift ;;
        -hor|--horizontal) LAYOUT="horizontal"; shift ;;
        -ver|--vertical) LAYOUT="vertical"; shift ;;
        -from|--start) shift; QUERY_START=$(date -d "$1" +%s); TIME_LABEL="Custom Range"; shift ;;
        -to|--end) shift; QUERY_END=$(date -d "$1" +%s); TIME_LABEL="Custom Range"; shift ;;
        -dm|--domain) shift; DOMAIN_FILTER="$1"; SANITIZED="${1//\*/%}"; SANITIZED="${SANITIZED//\?/_}"; SQL_DOMAIN_CLAUSE="AND domain LIKE '%$SANITIZED%'"; shift ;;
        -edm|--exact-domain) shift; DOMAIN_FILTER="$1"; SANITIZED="${1//\*/%}"; SANITIZED="${SANITIZED//\?/_}"; SQL_DOMAIN_CLAUSE="AND (domain LIKE '$SANITIZED' OR domain LIKE '%.$SANITIZED')"; shift ;;
        -f) shift; OUTPUT_FILE="$1"; shift ;;
        -*)
            INPUT="${1#-}"
            if [[ ! "$INPUT" =~ ^[0-9]+[hd]$ ]]; then echo "❌ Error: Invalid arg '$1'" >&2; exit 1; fi
            UNIT="${INPUT: -1}"; VALUE="${INPUT:0:${#INPUT}-1}"
            if [[ "$UNIT" == "h" ]]; then OFFSET=$((VALUE * 3600)); TIME_LABEL="Last $VALUE Hours"; fi
            if [[ "$UNIT" == "d" ]]; then OFFSET=$((VALUE * 86400)); TIME_LABEL="Last $VALUE Days"; fi
            QUERY_START=$(( $(date +%s) - OFFSET )); QUERY_END=$(date +%s); shift ;;
        *) echo "❌ Error: Unknown argument '$1'"; exit 1 ;;
    esac
done

if [ "$TIME_LABEL" == "Custom Range" ]; then TIME_LABEL="$(date -d @$QUERY_START "+%Y-%m-%d %H:%M") to $(date -d @$QUERY_END "+%Y-%m-%d %H:%M")"; fi
if [ "$LAYOUT" == "auto" ]; then COLS=$(tput cols 2>/dev/null || echo 80); if [ "$COLS" -ge 100 ]; then LAYOUT="horizontal"; else LAYOUT="vertical"; fi; fi
if [ "$SHOW_UNBOUND" == "only" ]; then LAYOUT="vertical"; fi

# --- 7. ANIMATION LOGIC ---
start_spinner() {
    # Run in background
    (
        term_cols=$(tput cols 2>/dev/null || echo 80)
        width=$(( term_cols / width_divider ))
        # Ensure min width for visual sanity
        [ "$width" -lt 5 ] && width=5
        
        start_len=$(( width % 2 == 0 ? 2 : 1 ))
        frames=()

        # Phase A: Grow
        for (( len=start_len; len<=width; len+=2 )); do
            padding=$(( (width - len) / 2 ))
            pad=$(printf "%${padding}s")
            
            # SAFE BAR GENERATION (Bash replace): Works even in LC_ALL=C
            printf -v bar_raw "%*s" "$len" ""
            bar="${bar_raw// /$char}"
            
            frames+=("|$pad$bar$pad|")
        done

        # Phase B: Shrink
        for (( len=width-2; len>=start_len; len-=2 )); do
            padding=$(( (width - len) / 2 ))
            pad=$(printf "%${padding}s")
            
            printf -v bar_raw "%*s" "$len" ""
            bar="${bar_raw// /$char}"
            
            frames+=("|$pad$bar$pad|")
        done

        interval=$(awk "BEGIN {print $target_time / ${#frames[@]}}")
        
        tput civis >&2 # Hide cursor
        
        while true; do
            for frame in "${frames[@]}"; do
                tput rc >&2   # Return to saved position
                printf "%s" "$frame" >&2
                sleep "$interval"
            done
        done
    ) &
    SPINNER_PID=$!
    # Trap only EXIT (fixes double Ctrl+C issue)
    trap 'kill $SPINNER_PID 2>/dev/null; echo "" >&2; tput cnorm >&2' EXIT
}

stop_spinner() {
    if [ -n "$SPINNER_PID" ]; then
        kill "$SPINNER_PID" 2>/dev/null
        wait "$SPINNER_PID" 2>/dev/null
        tput rc >&2    # Restore cursor to start of spinner
        tput el >&2    # Clear line to right
        echo "Finished!" >&2
        tput cnorm >&2 # Show cursor
        SPINNER_PID=""
        # Reset trap to default
        trap - EXIT
    fi
}
# --- 8. DATA COLLECTION (UNBOUND) ---
U_STATUS="Disabled"; U_TOTAL="0"; U_HITS="0"; U_MISS="0"; U_PRE="0"; 
U_PCT_HIT="0.00"; U_PCT_MISS="0.00"; U_PCT_PRE="0.00"
U_MEM_MSG="0"; U_MEM_RR="0"; U_LIM_MSG="0"; U_LIM_RR="0"
U_PCT_MEM_MSG="0.00"; U_PCT_MEM_RR="0.00"; UCC_MSG="0"; UCC_RR="0"; HAS_UNBOUND=false

collect_unbound_stats() {
    if [ "$SHOW_UNBOUND" == "no" ]; then return; fi
    if ! command -v unbound-control &> /dev/null; then [ "$SHOW_UNBOUND" == "yes" ] || [ "$SHOW_UNBOUND" == "only" ] && echo "Error: unbound-control not found" >&2; return; fi
    
    if [ "$SHOW_UNBOUND" == "default" ]; then
        if [ "$ENABLE_UNBOUND" == "false" ]; then return; fi
        if [ "$ENABLE_UNBOUND" == "auto" ]; then
            IS_RUNNING=false
            if systemctl is-active --quiet unbound 2>/dev/null || pgrep -x unbound >/dev/null; then IS_RUNNING=true; fi
            if [ "$IS_RUNNING" = false ]; then return; fi
            if ! grep -qE "PIHOLE_DNS_.*=(127\.0\.0\.1|::1)" /etc/pihole/setupVars.conf 2>/dev/null && \
               ! grep -qE "^server=(127\.0\.0\.1|::1)" /etc/dnsmasq.d/*.conf 2>/dev/null && \
               ! grep -F "127.0.0.1" /etc/pihole/pihole.toml >/dev/null 2>&1; then return; fi
        fi
    fi

    RAW_STATS=$(unbound-control -c /etc/unbound/unbound.conf stats_noreset 2>&1)
    if [ -z "$RAW_STATS" ] || echo "$RAW_STATS" | grep -iEq "^error:|connection refused"; then
         HAS_UNBOUND=true; U_STATUS="Error (Check Perms)"; return
    fi

    HAS_UNBOUND=true; U_STATUS="Active (Integrated)"
    U_HITS=$(echo "$RAW_STATS" | grep '^total.num.cachehits=' | cut -d= -f2); U_HITS=${U_HITS:-0}
    U_MISS=$(echo "$RAW_STATS" | grep '^total.num.cachemiss=' | cut -d= -f2); U_MISS=${U_MISS:-0}
    U_PRE=$(echo "$RAW_STATS" | grep '^total.num.prefetch=' | cut -d= -f2); U_PRE=${U_PRE:-0}
    U_TOTAL=$((U_HITS + U_MISS))

    if [ "$U_TOTAL" -gt 0 ]; then
        U_PCT_HIT=$(awk "BEGIN {printf \"%.2f\", ($U_HITS / $U_TOTAL) * 100}")
        U_PCT_MISS=$(awk "BEGIN {printf \"%.2f\", ($U_MISS / $U_TOTAL) * 100}")
    fi
    if [ "$U_HITS" -gt 0 ]; then U_PCT_PRE=$(awk "BEGIN {printf \"%.2f\", ($U_PRE / $U_HITS) * 100}"); fi

    U_MEM_MSG=$(echo "$RAW_STATS" | grep '^mem.cache.message=' | cut -d= -f2); U_MEM_MSG=${U_MEM_MSG:-0}
    U_MEM_RR=$(echo "$RAW_STATS" | grep '^mem.cache.rrset=' | cut -d= -f2); U_MEM_RR=${U_MEM_RR:-0}
    U_LIM_MSG=$(unbound-checkconf -o msg-cache-size 2>/dev/null || echo "4194304")
    U_LIM_RR=$(unbound-checkconf -o rrset-cache-size 2>/dev/null || echo "8388608")
    U_PCT_MEM_MSG=$(awk "BEGIN {printf \"%.2f\", ($U_MEM_MSG / $U_LIM_MSG) * 100}")
    U_PCT_MEM_RR=$(awk "BEGIN {printf \"%.2f\", ($U_MEM_RR / $U_LIM_RR) * 100}")

    if [ "$ENABLE_UCC" = true ]; then
        eval $(sudo unbound-control dump_cache 2>/dev/null | awk '/^msg/ {m++} /^;rrset/ {r++} END {print "UCC_MSG="m+0; print "UCC_RR="r+0}')
        UCC_MSG=${UCC_MSG:-0}; UCC_RR=${UCC_RR:-0}
    fi
}

to_mb() { awk "BEGIN {printf \"%.2f\", $1 / 1024 / 1024}"; }

# --- 9. DATA COLLECTION (PI-HOLE) ---
P_TOTAL=0; P_INVALID=0; P_VALID=0; P_BLOCKED=0; P_ANALYZED=0; P_IGNORED=0
P_AVG="0.00"; P_MED="0.00"; P_95="0.00"
declare -a TIER_LABELS; declare -a TIER_COUNTS; declare -a TIER_PCTS

collect_pihole_stats() {
    if [ "$SHOW_UNBOUND" == "only" ]; then return; fi
    if [ ! -r "$DBfile" ] && [ "$USE_SNAPSHOT" = false ]; then
        if [ "$SILENT_MODE" = false ]; then echo "❌ Error: Cannot read database '$DBfile'. (Permission Denied - Try sudo)" >&2; fi
        for ((i=0; i<15; i++)); do TIER_COUNTS[$i]=0; TIER_PCTS[$i]="0.00"; done; return
    fi
    
    SQL_BLOCKED_DEF="status IN (1, 4, 5, 9, 10, 11)"
    BASE_DEFAULT="2, 3, 6, 7, 8, 12, 13, 14, 15"; BASE_UPSTREAM="2, 6, 7, 8"; BASE_PIHOLE="3, 12, 13, 14, 15"

    if [[ "$MODE" == "UPSTREAM" ]]; then CURRENT_LIST="$BASE_UPSTREAM"; MODE_LABEL="Upstream Only"
    elif [[ "$MODE" == "PIHOLE" ]]; then CURRENT_LIST="$BASE_PIHOLE"; MODE_LABEL="Pi-hole Only"
    else CURRENT_LIST="$BASE_DEFAULT"; MODE_LABEL="All Normal Queries"; fi

    if [ "$EXCLUDE_NX" = true ]; then MODE_LABEL="$MODE_LABEL [Excl. Blocks]"; SQL_STATUS_FILTER="status IN ($CURRENT_LIST)";
    else [[ "$MODE" != "PIHOLE" ]] && SQL_STATUS_FILTER="status IN ($CURRENT_LIST, 16, 17)" || SQL_STATUS_FILTER="status IN ($CURRENT_LIST)"; fi

    raw_limits=("$L01" "$L02" "$L03" "$L04" "$L05" "$L06" "$L07" "$L08" "$L09" "$L10" "$L11" "$L12" "$L13" "$L14" "$L15" "$L16" "$L17" "$L18" "$L19" "$L20")
    IFS=$'\n' sorted_limits=($(printf "%s\n" "${raw_limits[@]}" | grep -v '^$' | sort -n)); unset IFS
    if [ ${#sorted_limits[@]} -eq 0 ]; then sorted_limits=("0.009" "0.1" "1" "10" "50" "100" "300" "1000"); fi

    sql_tier_cols=""; prev_ms="0"; prev_sec="0"; idx=0
    for ms in "${sorted_limits[@]}"; do
        sec=$(awk "BEGIN {print $ms / 1000}")
        if [ "$idx" -eq 0 ]; then logic="reply_time <= $sec"; lbl="Tier $((idx+1)) (< ${ms}ms)"
        else logic="reply_time > $prev_sec AND reply_time <= $sec"; lbl="Tier $((idx+1)) (${prev_ms} - ${ms}ms)"; fi
        [ -n "$sql_tier_cols" ] && sql_tier_cols="${sql_tier_cols}, "
        sql_tier_cols="${sql_tier_cols} SUM(CASE WHEN ${logic} AND $SQL_STATUS_FILTER THEN 1 ELSE 0 END)"
        TIER_LABELS[$idx]="$lbl"; prev_ms="$ms"; prev_sec="$sec"; ((idx++))
    done
    lbl="Tier $((idx+1)) (> ${prev_ms}ms)"; sql_tier_cols="${sql_tier_cols}, SUM(CASE WHEN reply_time > $prev_sec AND $SQL_STATUS_FILTER THEN 1 ELSE 0 END)"; TIER_LABELS[$idx]="$lbl"

    ACTIVE_DB="$DBfile"; SNAP_FILE="/tmp/pi_snap_$$.db"
    if [ "$USE_SNAPSHOT" = true ]; then
        DB_SZ=$(du -k "$DBfile" | awk '{print $1}')
        FREE_RAM=$(free -k | awk '/^Mem:/{print $7}')
        [ -z "$FREE_RAM" ] && FREE_RAM=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
        if [ "$FREE_RAM" -lt "$((DB_SZ + 51200))" ]; then SNAP_FILE="$HOME/pi_snap_$$.db"; fi
        sqlite3 "$DBfile" ".backup '$SNAP_FILE'" || exit 1
        ACTIVE_DB="$SNAP_FILE"
    fi

    # --- ERROR SUPPRESSION TRICK ---
    ERR_TMP=$(mktemp)
    SQL_OUT=$(sqlite3 "$ACTIVE_DB" <<EOF 2> "$ERR_TMP"
.mode list
.headers off
.timeout 30000
PRAGMA temp_store = MEMORY; PRAGMA synchronous = OFF;
CREATE TEMP TABLE raw AS SELECT status, reply_time FROM queries WHERE timestamp >= $QUERY_START AND timestamp <= $QUERY_END $SQL_DOMAIN_CLAUSE;
CREATE TEMP TABLE mets AS SELECT 
    COUNT(*), SUM(CASE WHEN reply_time IS NULL THEN 1 ELSE 0 END), SUM(CASE WHEN reply_time IS NOT NULL THEN 1 ELSE 0 END),
    SUM(CASE WHEN reply_time IS NOT NULL AND $SQL_BLOCKED_DEF THEN 1 ELSE 0 END), SUM(CASE WHEN reply_time IS NOT NULL AND $SQL_STATUS_FILTER THEN 1 ELSE 0 END),
    SUM(CASE WHEN reply_time IS NOT NULL AND $SQL_STATUS_FILTER THEN reply_time ELSE 0.0 END), $sql_tier_cols
FROM raw;
SELECT * FROM mets;
SELECT reply_time FROM raw WHERE reply_time IS NOT NULL AND $SQL_STATUS_FILTER ORDER BY reply_time ASC LIMIT 1 OFFSET (SELECT (COUNT(*) - 1) / 2 FROM raw WHERE reply_time IS NOT NULL AND $SQL_STATUS_FILTER);
SELECT reply_time FROM raw WHERE reply_time IS NOT NULL AND $SQL_STATUS_FILTER ORDER BY reply_time ASC LIMIT 1 OFFSET (SELECT CAST((COUNT(*) * 0.95) - 1 AS INT) FROM raw WHERE reply_time IS NOT NULL AND $SQL_STATUS_FILTER);
EOF
)
    # Check stderr: Discard "interrupted" messages but show real errors
    if [ -s "$ERR_TMP" ]; then
        ERR_MSG=$(cat "$ERR_TMP")
        if [[ "$ERR_MSG" != *"interrupted"* ]]; then echo "$ERR_MSG" >&2; fi
    fi
    rm -f "$ERR_TMP"

    IFS='|' read -r -a METS <<< "$(echo "$SQL_OUT" | head -n 1)"
    P_TOTAL=${METS[0]:-0}; P_INVALID=${METS[1]:-0}; P_VALID=${METS[2]:-0}; P_BLOCKED=${METS[3]:-0}; P_ANALYZED=${METS[4]:-0}; P_DUR=${METS[5]:-0}
    P_IGNORED=$((P_VALID - P_BLOCKED - P_ANALYZED))
    for i in "${!TIER_LABELS[@]}"; do
        TIER_COUNTS[$i]=${METS[$((6+i))]:-0}
        if [ "$P_ANALYZED" -gt 0 ]; then TIER_PCTS[$i]=$(awk "BEGIN {printf \"%.2f\", (${TIER_COUNTS[$i]} / $P_ANALYZED) * 100}"); else TIER_PCTS[$i]="0.00"; fi
    done
    if [ "$P_ANALYZED" -gt 0 ]; then P_AVG=$(awk "BEGIN {printf \"%.2f\", ($P_DUR * 1000) / $P_ANALYZED}"); fi
    RAW_MED=$(echo "$SQL_OUT" | sed -n '2p'); RAW_95=$(echo "$SQL_OUT" | sed -n '3p')
    if [ -n "$RAW_MED" ]; then P_MED=$(awk "BEGIN {printf \"%.2f\", $RAW_MED * 1000}"); fi
    if [ -n "$RAW_95" ]; then P_95=$(awk "BEGIN {printf \"%.2f\", $RAW_95 * 1000}"); fi
    if [ "$USE_SNAPSHOT" = true ] && [ -f "$SNAP_FILE" ]; then rm "$SNAP_FILE"; fi
}

# --- 10. RENDERERS ---
print_text_report() {
    CURRENT_DATE=$(date "+%Y-%m-%d %H:%M:%S")
    declare -a L_LINES
    L_LINES+=("Time Period   : $TIME_LABEL"); L_LINES+=("Query Mode    : $MODE_LABEL"); L_LINES+=("-----------------------------------------------------")
    L_LINES+=("Total Queries        : $P_TOTAL")
    if [ "$P_TOTAL" -gt 0 ]; then PCT=$(awk "BEGIN {printf \"%.1f\", ($P_INVALID/$P_TOTAL)*100}"); L_LINES+=("Unsuccessful Queries : $P_INVALID ($PCT%)"); else L_LINES+=("Unsuccessful Queries : 0 (0.0%)"); fi
    L_LINES+=("Total Valid Queries  : $P_VALID")
    if [ "$P_VALID" -gt 0 ]; then
        PCT=$(awk "BEGIN {printf \"%.1f\", ($P_BLOCKED/$P_VALID)*100}"); L_LINES+=("Blocked Queries      : $P_BLOCKED ($PCT%)")
        if [ "$P_IGNORED" -gt 0 ]; then PCT=$(awk "BEGIN {printf \"%.1f\", ($P_IGNORED/$P_VALID)*100}"); L_LINES+=("Other/Ignored Queries: $P_IGNORED ($PCT%)"); fi
        PCT=$(awk "BEGIN {printf \"%.1f\", ($P_ANALYZED/$P_VALID)*100}"); L_LINES+=("Analyzed Queries     : $P_ANALYZED ($PCT%)")
    else L_LINES+=("Blocked Queries      : 0"); L_LINES+=("Analyzed Queries     : 0"); fi
    L_LINES+=("Average Latency      : $P_AVG ms"); L_LINES+=("Median  Latency      : $P_MED ms"); L_LINES+=("95th Percentile      : $P_95 ms")

    declare -a R_LINES
    if [ "$HAS_UNBOUND" = true ]; then
        R_LINES+=("Server Status : $U_STATUS")
        if [[ "$U_STATUS" != *"Error"* ]]; then
            R_LINES+=("Config File   : /etc/unbound/unbound.conf"); R_LINES+=("---------------------------------------------") 
            R_LINES+=("Total Queries : $U_TOTAL"); R_LINES+=("Cache Hits    : $U_HITS ($U_PCT_HIT%)")
            R_LINES+=("Cache Misses  : $U_MISS ($U_PCT_MISS%)"); R_LINES+=("Prefetch Jobs : $U_PRE ($U_PCT_PRE% of Hits)")
            R_LINES+=(""); R_LINES+=("----- Cache Memory Usage (Used / Limit) -----")
            R_LINES+=("Msg Cache   : $(to_mb $U_MEM_MSG)MB / $(to_mb $U_LIM_MSG)MB  ($U_PCT_MEM_MSG%)")
            R_LINES+=("RRset Cache : $(to_mb $U_MEM_RR)MB / $(to_mb $U_LIM_RR)MB ($U_PCT_MEM_RR%)")
            if [ "$ENABLE_UCC" = true ]; then R_LINES+=("Messages (Queries): $UCC_MSG"); R_LINES+=("RRsets (Records)  : $UCC_RR"); fi
        else R_LINES+=(""); R_LINES+=("⚠️  Permission Denied or Service Down"); R_LINES+=("   Try running with 'sudo'"); fi
    fi

    if [ "$LAYOUT" == "horizontal" ]; then
        echo "===================================================================================================="
        TITLE="Pi-hole Latency Stats v$VERSION"
        PAD=$(( (100 - ${#TITLE}) / 2 )); printf "%${PAD}s%s\n" "" "$TITLE"
        echo "===================================================================================================="
        DATE_STR="Analysis Date : $CURRENT_DATE"; PAD_DATE=$(( (100 - ${#DATE_STR}) / 2 )); printf "%${PAD_DATE}s%s\n" "" "$DATE_STR"
        echo "---------------- Pi-hole Performance ----------------||---------- Unbound DNS Performance ----------"
    else
        echo "========================================================"; echo "              Pi-hole Latency Stats v$VERSION"; echo "========================================================"
        echo "Analysis Date : $CURRENT_DATE"
        if [ "$SHOW_UNBOUND" != "only" ]; then echo "Time Period   : $TIME_LABEL"; echo "Query Mode    : $MODE_LABEL"; fi
    fi

    if [ "$LAYOUT" == "horizontal" ]; then
        MAX=${#L_LINES[@]}; [ ${#R_LINES[@]} -gt $MAX ] && MAX=${#R_LINES[@]}
        for ((i=0; i<MAX; i++)); do printf "%-53s||%s\n" "${L_LINES[$i]}" "${R_LINES[$i]}"; done
        echo "----------------------------------------------------------------------------------------------------"
    else
        if [ "$SHOW_UNBOUND" != "only" ]; then
            echo "--------------------------------------------------------"
            for line in "${L_LINES[@]}"; do if [[ "$line" != Time* ]] && [[ "$line" != Query* ]] && [[ "$line" != ---* ]]; then echo "$line"; fi; done; echo ""
        fi
    fi

    if [ "$SHOW_UNBOUND" != "only" ]; then
        echo "--- Latency Distribution of Pi-Hole Analyzed Queries ---"
        MAX_LEN=0; for lbl in "${TIER_LABELS[@]}"; do [ ${#lbl} -gt $MAX_LEN ] && MAX_LEN=${#lbl}; done; MAX_LEN=$((MAX_LEN + 2))
        for i in "${!TIER_LABELS[@]}"; do printf "%-${MAX_LEN}s : %6s%%  (%s)\n" "${TIER_LABELS[$i]}" "${TIER_PCTS[$i]}" "${TIER_COUNTS[$i]}"; done
        if [ "$LAYOUT" == "horizontal" ]; then echo "===================================================================================================="; else echo "========================================================"; fi
    fi

    if [ "$LAYOUT" != "horizontal" ] && [ "$HAS_UNBOUND" = true ]; then
        if [ "$SHOW_UNBOUND" != "only" ]; then echo "              Unbound DNS Performance"; echo "========================================================"; fi
        for line in "${R_LINES[@]}"; do echo "$line"; done; echo "========================================================"
    fi
}

print_json_report() {
    CURRENT_DATE=$(date "+%Y-%m-%d %H:%M:%S")
    JSTR="{\"version\": \"$VERSION\", \"date\": \"$CURRENT_DATE\", \"time_period\": \"$TIME_LABEL\", \"mode\": \"$MODE_LABEL\""
    if [ -n "$DOMAIN_FILTER" ]; then JSTR="$JSTR, \"domain_filter\": \"$DOMAIN_FILTER\""; fi
    JSTR="$JSTR, \"stats\": {\"total_queries\": $P_TOTAL, \"unsuccessful\": $P_INVALID, \"total_valid\": $P_VALID, \"blocked\": $P_BLOCKED, \"analyzed\": $P_ANALYZED}"
    JSTR="$JSTR, \"latency\": {\"average\": $P_AVG, \"median\": $P_MED, \"p95\": $P_95}"
    JSTR="$JSTR, \"tiers\": ["; FIRST=true
    for i in "${!TIER_LABELS[@]}"; do
        if [ "$FIRST" = true ]; then FIRST=false; else JSTR="$JSTR, "; fi
        JSTR="$JSTR{\"label\": \"${TIER_LABELS[$i]}\", \"count\": ${TIER_COUNTS[$i]}, \"percentage\": ${TIER_PCTS[$i]}}"
    done
    JSTR="$JSTR], \"unbound\": "
    if [ "$HAS_UNBOUND" = true ] && [[ "$U_STATUS" != *"Error"* ]]; then
        U_JSON="{\"status\": \"active\", \"total\": $U_TOTAL, \"hits\": $U_HITS, \"miss\": $U_MISS, \"prefetch\": $U_PRE, \"ratio\": $U_PCT_HIT, \"memory\": { \"msg\": { \"used_mb\": $(to_mb $U_MEM_MSG), \"limit_mb\": $(to_mb $U_LIM_MSG), \"percent\": $U_PCT_MEM_MSG }, \"rrset\": { \"used_mb\": $(to_mb $U_MEM_RR), \"limit_mb\": $(to_mb $U_LIM_RR), \"percent\": $U_PCT_MEM_RR } }, \"cache_count\": "
        if [ "$ENABLE_UCC" = true ]; then U_JSON="$U_JSON{ \"messages\": $UCC_MSG, \"rrsets\": $UCC_RR }"; else U_JSON="${U_JSON}null"; fi
        U_JSON="$U_JSON}"; JSTR="$JSTR$U_JSON"
    else JSTR="${JSTR}null"; fi
    JSTR="$JSTR}"; echo "$JSTR"
}

# --- 11. EXECUTION ---
if [ "$SILENT_MODE" = false ] && [ "$SHOW_UNBOUND" != "only" ]; then
    # Start Animation
    echo -n "📊 Analyzing Pi-hole database... " >&2
    tput sc >&2  # Save Cursor position at the end of the text
    start_spinner
fi

collect_unbound_stats
collect_pihole_stats

# Stop Animation
if [ "$SILENT_MODE" = false ] && [ "$SHOW_UNBOUND" != "only" ]; then
    stop_spinner
fi

TEXT_REPORT=$(print_text_report)
if [ "$JSON_OUTPUT" = true ]; then JSON_REPORT=$(print_json_report); fi

# SMART OUTPUT FILENAME LOGIC
if [ -z "$OUTPUT_FILE" ]; then
    if [ "$JSON_OUTPUT" = true ]; then OUTPUT_FILE="$JSON_NAME"; else OUTPUT_FILE="$TXT_NAME"; fi
fi

if [ -n "$OUTPUT_FILE" ]; then
    # Select Target Directory
    TARGET_DIR=""
    if [ "$JSON_OUTPUT" = true ]; then TARGET_DIR="$SAVE_DIR_JSON"; else TARGET_DIR="$SAVE_DIR_TXT"; fi

    # Prep Output path
    if [[ "$OUTPUT_FILE" != /* ]] && [ -n "$TARGET_DIR" ] && mkdir -p "$TARGET_DIR"; then 
        OUTPUT_FILE="${TARGET_DIR}/${OUTPUT_FILE}"
    fi
    
    [ "$ADD_TIMESTAMP" = true ] && TS=$(date "+%Y-%m-%d_%H%M") && OUTPUT_FILE="${OUTPUT_FILE%.*}_${TS}.${OUTPUT_FILE##*.}"
    if [ "$SEQUENTIAL" = true ] && [ -f "$OUTPUT_FILE" ]; then
        BASE="${OUTPUT_FILE%.*}"; EXT="${OUTPUT_FILE##*.}"; CNT=1
        while [ -f "${BASE}_${CNT}.${EXT}" ]; do ((CNT++)); done
        OUTPUT_FILE="${BASE}_${CNT}.${EXT}"
    fi

    if [ "$JSON_OUTPUT" = true ]; then echo "$JSON_REPORT" > "$OUTPUT_FILE"; else echo "$TEXT_REPORT" > "$OUTPUT_FILE"; fi
    fix_perms "$OUTPUT_FILE"
fi

if [ "$SILENT_MODE" = false ]; then
    if [ "$JSON_OUTPUT" = true ] && [ -n "$OUTPUT_FILE" ] && [ "$OUTPUT_FILE" != "$JSON_NAME" ]; then echo "$TEXT_REPORT"
    elif [ "$JSON_OUTPUT" = true ] && [ -z "$OUTPUT_FILE" ]; then echo "$JSON_REPORT"
    elif [ "$JSON_OUTPUT" = true ] && [ "$OUTPUT_FILE" == "$JSON_NAME" ]; then echo "$TEXT_REPORT"
    else echo "$TEXT_REPORT"; fi
fi

# AUTO-CLEAN LOGIC
if [ -n "$MAX_LOG_AGE" ] && [[ "$MAX_LOG_AGE" =~ ^[0-9]+$ ]]; then
    CLEANED=false
    if [ -n "$SAVE_DIR_TXT" ] && [ -d "$SAVE_DIR_TXT" ]; then
        find "$SAVE_DIR_TXT" -maxdepth 1 -type f -mtime +$MAX_LOG_AGE -delete; CLEANED=true
    fi
    if [ -n "$SAVE_DIR_JSON" ] && [ -d "$SAVE_DIR_JSON" ]; then
        find "$SAVE_DIR_JSON" -maxdepth 1 -type f -mtime +$MAX_LOG_AGE -delete; CLEANED=true
    fi
    if [ "$CLEANED" = true ] && [ "$SILENT_MODE" = false ]; then echo "Auto-Clean : Checked reports older than $MAX_LOG_AGE days"; fi
fi

END_TS=$(date +%s.%N 2>/dev/null)
if [[ "$END_TS" == *N* ]] || [ -z "$END_TS" ]; then END_TS=$(date +%s); fi
DUR=$(awk "BEGIN {printf \"%.2f\", $END_TS - $START_TS}" 2>/dev/null)
[ -z "$DUR" ] && DUR=$(( ${END_TS%.*} - ${START_TS%.*} ))
if [ "$SILENT_MODE" = false ]; then 
    echo "Total Execution Time: ${DUR}s" >&2
    if [ -n "$OUTPUT_FILE" ]; then echo -e "\033[1;36mResults saved to: $OUTPUT_FILE\033[0m" >&2; fi
    echo "" 
fi