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

VERSION="v4.2.0"
UPSTREAM_DIST_MIN_CUTOFF="3"  # Minimum latency (ms) for the Upstream Graph
UPDATE_MSG=""

# --- 0. CRITICAL LOCALE FIX ---
export LC_ALL=C

# Capture start time
START_TS=$(date +%s.%N 2>/dev/null || date +%s)

# --- TRAP: CUSTOM ABORT MESSAGE ---
trap 'echo -e "\n\nProgram aborted by user." >&2; rm -f /dev/shm/phls_*_$$.tmp; exit 1' INT

# --- LOCKING MECHANISM ---
check_lock() {
    local profile="${1:-default}"
    local lock_file="/tmp/phls_${profile}.lock"
    
    if [ -f "$lock_file" ]; then
        local pid=$(cat "$lock_file")
        if kill -0 "$pid" 2>/dev/null; then
            if [ "$SILENT_MODE" = false ]; then
                echo "⚠️  Locked by PID $pid (Profile: $profile). Exiting." >&2
            fi
            exit 1
        else
            rm -f "$lock_file"
        fi
    fi
    
    echo $$ > "$lock_file"
    trap 'rm -f "'"$lock_file"'"' EXIT
}

# --- PRE-FLIGHT CHECK ---
for cmd in sqlite3 awk grep; do
    if ! command -v $cmd &> /dev/null; then
        echo "❌ Error: Required command '$cmd' not found." >&2
        exit 1
    fi
done

# --- 1. SETUP & DEFAULTS ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
V_LOCAL_FILE="$SCRIPT_DIR/version"
DEFAULT_CONFIG="$SCRIPT_DIR/pihole_stats.conf"
PROFILES_DB="$SCRIPT_DIR/profiles.db"
CONFIG_TO_LOAD="$DEFAULT_CONFIG"

# Internal Defaults
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
MIN_LATENCY_CUTOFF=""
MAX_LATENCY_CUTOFF=""
MAX_DB_DAYS="91"

# --- GLOBAL STATUS DEFINITIONS ---
BASE_DEFAULT="2, 3, 6, 7, 8, 12, 13, 14, 15"
BASE_UPSTREAM="2, 6, 7, 8"
BASE_PIHOLE="3, 12, 13, 14, 15"
SQL_BLOCKED_DEF="status IN (1, 4, 5, 9, 10, 11)"

# Granular Math Toggles
ENABLE_MATH_ALL_TIME="true"
ENABLE_MATH_12H="true"
ENABLE_MATH_24H="true"
ENABLE_MATH_7D="true"
ENABLE_MATH_30D="true"

# NEW: Dashboard Config Defaults
ENABLE_UPSTREAM_DIST="true"
ENABLE_UPSTREAM_MATH_ALL_TIME="true"

MAX_HISTORY_ENTRIES="8640"
DASH_DIR="/var/www/html/admin/img/dash"

# --- ANIMATION SETTINGS ---
target_time=4.0
width_divider=3
char="|"

L01="0.009"; L02="0.1"; L03="0.5"; L04="1"; L05="16"
L06="32";    L07="64"; L08="128"; L09="256"; L10="512"
L11="";      L12="";    L13="";    L14="";    L15=""
L16="";      L17="";    L18="";    L19="";    L20=""

TS_NOW=$(date +%s)
QUERY_START=0
QUERY_END=$TS_NOW
TIME_LABEL="All Time"
IS_FILTERED=false

# --- HELPER FUNCTIONS ---
fix_perms() {
    local target="$1"
    local mode="$2"
    
    if [ ! -e "$target" ]; then return; fi
    
    if [[ "$mode" == "dash" ]] || [[ "$target" == "$DASH_DIR"* ]]; then
        chown www-data:www-data "$target" 2>/dev/null
        chmod 664 "$target" 2>/dev/null
    elif [ -n "$SUDO_UID" ] && [ -n "$SUDO_GID" ]; then
        chown "$SUDO_UID:$SUDO_GID" "$target"
        chmod 644 "$target"
    fi
}

to_mb() { 
    local val=${1:-0}
    awk "BEGIN {printf \"%.2f\", $val / 1024 / 1024}" 
}

# --- 2. CONFIGURATION WRITER ---
write_config() {
    local target_file="$1"
    cat <<EOF > "$target_file"
# ================= PI-HOLE STATS CONFIGURATION =================
# This file controls both the CLI behavior and the Dashboard generation.

# ------------------------------------------------------------------
# --- SHARED SETTINGS (Affects BOTH CLI & Dashboard) ---
# ------------------------------------------------------------------

# Path to Pi-hole's FTL database
DBfile="$DBfile"

# Unbound Integration
# auto  : Check if Unbound is installed & used by Pi-hole.
# true  : Always append Unbound stats.
# false : Never show Unbound stats (unless -unb is used).
ENABLE_UNBOUND="$ENABLE_UNBOUND"

# --- GLOBAL PERFORMANCE ---
# Max Database Days to Query
# Limits "All Time" queries to X days to prevent crashes on slow hardware.
# Default: 91 (Matches Pi-hole v6 default)
MAX_DB_DAYS="$MAX_DB_DAYS"

# ENABLE_MATH_ALL_TIME:
#   true  : Calculates Median & P95 for the main report (Slower ~14s on Pi Zero).
#   false : Fast mode. Shows Avg/StdDev only (Fast ~2s).
#   This affects both the Text Report and the Dashboard's "All Time" tab and depends on MAX_DB_DAY.
ENABLE_MATH_ALL_TIME="$ENABLE_MATH_ALL_TIME"

# Latency Tiers (Upper Limits in Milliseconds)
# Add more values (L09, L10...) to create granular buckets for analysis.
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

# Latency Cutoffs (Optional)
# Ignore queries faster than MIN or slower than MAX (in ms).
MIN_LATENCY_CUTOFF="$MIN_LATENCY_CUTOFF"
MAX_LATENCY_CUTOFF="$MAX_LATENCY_CUTOFF"

# ------------------------------------------------------------------
# --- DASHBOARD-ONLY SETTINGS (Used only with -dash flag) ---
# ------------------------------------------------------------------

# Dashboard Directory (Where dash.html lives)
# Default: /var/www/html/admin/img/dash
DASH_DIR="$DASH_DIR"

# Max History Entries for Dashboard Graph
# 8640 entries = 30 days @ 5 min interval.
MAX_HISTORY_ENTRIES="$MAX_HISTORY_ENTRIES"

# --- DASHBOARD PERFORMANCE (Windowed Math) ---
# Enable/Disable Median & P95 calculation for specific time buttons.
# Disabling these saves CPU time during dashboard generation.
# These settings have NO EFFECT on the manual CLI report.
ENABLE_MATH_12H="$ENABLE_MATH_12H"
ENABLE_MATH_24H="$ENABLE_MATH_24H"
ENABLE_MATH_7D="$ENABLE_MATH_7D"
ENABLE_MATH_30D="$ENABLE_MATH_30D"

# --- UPSTREAM HISTORY GRAPH ---
# Master Switch: Enable/Disable the calculation of upstream-specific stats.
# If false, no data is generated, math is skipped, and the card is hidden.
ENABLE_UPSTREAM_DIST="$ENABLE_UPSTREAM_DIST"

# Enable "All Time" Median/P95 for Upstream graph (CPU Intensive).
# Set to false to see All-Time bars/average but skip the heavy sorting.
ENABLE_UPSTREAM_MATH_ALL_TIME="$ENABLE_UPSTREAM_MATH_ALL_TIME"

# ------------------------------------------------------------------
# --- CLI-ONLY SETTINGS (Used only when running manually) ---
# ------------------------------------------------------------------

# Visual Layout
# auto       : Detects terminal width. >100 columns = Horizontal, else Vertical.
# vertical   : Forces standard vertical list view.
# horizontal : Forces split-pane dashboard view.
LAYOUT="$LAYOUT"

# Default Save Directories (REQUIRED for Auto-Deletion to work)
# Separate directories for Text and JSON reports.
# If left empty, files are saved in the current directory.
SAVE_DIR_TXT="$SAVE_DIR_TXT"
SAVE_DIR_JSON="$SAVE_DIR_JSON"

# Default Filenames (If set, the -f/-j flag is no longer required)
TXT_NAME="$TXT_NAME"
JSON_NAME="$JSON_NAME"

# Auto-Delete Old Reports (Retention Policy)
# Delete files in SAVE_DIR_TXT and SAVE_DIR_JSON older than X days.
MAX_LOG_AGE="$MAX_LOG_AGE"

# [OPTIONAL] Default Arguments
# If set, these arguments will REPLACE any CLI flags.
CONFIG_ARGS='$CONFIG_ARGS'
EOF
    chmod 644 "$target_file"
    fix_perms "$target_file" "user"
}

create_or_update_config() {
    local input_name="$1"
    
    if [[ "$input_name" == */* ]] || [[ "$input_name" == *.conf ]]; then
        local target_file="$input_name"
        if [ -f "$target_file" ]; then source "$target_file"; fi
        write_config "$target_file"
        echo "✅ Config updated at: $target_file"
    else
        local profile_dir="$SCRIPT_DIR/$input_name"
        local target_file="$profile_dir/pihole_stats.conf"
        
        if [ ! -d "$profile_dir" ]; then mkdir -p "$profile_dir"; fi
        
        fix_perms "$profile_dir" "user"
        SAVE_DIR_TXT="$profile_dir"
        SAVE_DIR_JSON="$profile_dir"
        TXT_NAME="${input_name}.txt"
        JSON_NAME="${input_name}.json"
        
        write_config "$target_file"
        touch "$PROFILES_DB"
        fix_perms "$PROFILES_DB" "user"
        
        if ! grep -q "^$input_name|" "$PROFILES_DB"; then
            echo "$input_name|$target_file" >> "$PROFILES_DB"
        fi
        
        echo "✅ Profile '$input_name' created in $profile_dir"
    fi
}

# --- 3. PRE-SCAN FLAGS ---
args_preserve=("$@") 
while [[ $# -gt 0 ]]; do
    case $1 in
        -c|--config)
            shift
            if [ -z "$1" ]; then
                echo "❌ Error: Missing config."
                exit 1
            fi
            if [ -f "$1" ]; then
                CONFIG_TO_LOAD="$1"
            elif [ -f "$PROFILES_DB" ]; then
                DB_PATH=$(grep "^$1|" "$PROFILES_DB" | cut -d'|' -f2 | head -n 1)
                if [ -n "$DB_PATH" ] && [ -f "$DB_PATH" ]; then
                    CONFIG_TO_LOAD="$DB_PATH"
                else
                    echo "❌ Profile '$1' not found" >&2
                    exit 1
                fi
            else
                echo "❌ Config file '$1' not found." >&2
                exit 1
            fi
            shift
            ;;
        -mc|--make-config)
            shift
            create_or_update_config "$1"
            exit 0
            ;;
        *)
            shift
            ;;
    esac
done

# --- 4. LOAD CONFIG ---
if [ -f "$CONFIG_TO_LOAD" ]; then 
    source "$CONFIG_TO_LOAD"
    # Auto-inject new Dashboard settings if missing
    if ! grep -q "ENABLE_UPSTREAM_DIST=" "$CONFIG_TO_LOAD"; then
        write_config "$CONFIG_TO_LOAD"
    fi
elif [ "$CONFIG_TO_LOAD" == "$DEFAULT_CONFIG" ]; then 
    write_config "$DEFAULT_CONFIG" > /dev/null
    source "$DEFAULT_CONFIG"
fi

if [ -n "$DEFAULT_FROM" ]; then
    if TS=$(date -d "$DEFAULT_FROM" +%s 2>/dev/null); then
        QUERY_START="$TS"
        TIME_LABEL="Custom Range"
    fi
fi

if [ -n "$DEFAULT_TO" ]; then
    if TS=$(date -d "$DEFAULT_TO" +%s 2>/dev/null); then
        QUERY_END="$TS"
        TIME_LABEL="Custom Range"
    fi
fi

if [ -n "$CONFIG_ARGS" ]; then
    eval set -- "$CONFIG_ARGS"
else
    set -- "${args_preserve[@]}"
fi

# --- 5. CONFIG SANITIZATION ---
ENABLE_MATH_ALL_TIME=$(echo "${ENABLE_MATH_ALL_TIME:-true}" | tr '[:upper:]' '[:lower:]')
ENABLE_MATH_12H=$(echo "${ENABLE_MATH_12H:-true}" | tr '[:upper:]' '[:lower:]')
ENABLE_MATH_24H=$(echo "${ENABLE_MATH_24H:-true}" | tr '[:upper:]' '[:lower:]')
ENABLE_MATH_7D=$(echo "${ENABLE_MATH_7D:-true}" | tr '[:upper:]' '[:lower:]')
ENABLE_MATH_30D=$(echo "${ENABLE_MATH_30D:-true}" | tr '[:upper:]' '[:lower:]')
ENABLE_UNBOUND=$(echo "${ENABLE_UNBOUND:-auto}" | tr '[:upper:]' '[:lower:]')
ENABLE_UPSTREAM_DIST=$(echo "${ENABLE_UPSTREAM_DIST:-true}" | tr '[:upper:]' '[:lower:]')
ENABLE_UPSTREAM_MATH_ALL_TIME=$(echo "${ENABLE_UPSTREAM_MATH_ALL_TIME:-true}" | tr '[:upper:]' '[:lower:]')
LAYOUT=$(echo "${LAYOUT:-auto}" | tr '[:upper:]' '[:lower:]')

# --- 6. ARGUMENTS & HELP ---
show_help() {
    echo "Pi-hole Latency Stats $VERSION"
    echo "Usage: sudo ./pihole_stats.sh [MODE] [OPTIONS]"
    echo ""
    echo "--- MODES (Pick One) ---"
    echo "  (default)          : Runs standard CLI report (prints to screen)"
    echo "  -dash [name]       : Run in DASHBOARD Mode (Silent, JSON output only)"
    echo "                       Updates the web interface data files."
    echo "                       [name] = Profile name (default: 'default')"
    echo ""
    echo "--- CONFIGURATION ---"
    echo "  -c [file/profile]  : Load specific config file or user profile"
    echo "  -mc [name]         : Create/Update a User Profile or Config file"
    echo ""
    echo "--- FILTERS (Apply to both CLI & Dashboard) ---"
    echo "  -24h, -7d, -30d    : Quick time filters (relative to now)"
    echo "  -from, -to         : Custom date range (e.g. 'yesterday', '2023-01-01')"
    echo "  -up                : Upstream Only (Status 2, 6, 7, 8)"
    echo "  -pi                : Pi-hole Only (Status 3, 12, 13, 14, 15)"
    echo "  -nx                : Exclude Blocked Queries"
    echo "  -dm [string]       : Filter by domain (wildcards: * = %, ? = _)"
    echo "  -edm [string]      : Exact domain match (subdomains included)"
    echo ""
    echo "--- CLI OUTPUT OPTIONS ---"
    echo "  -j, --json [file]  : Save output to JSON file"
    echo "  -f [file]          : Save output to Text file"
    echo "  -s, --silent       : Suppress terminal output"
    echo ""
    echo "--- DASHBOARD OPTIONS ---"
    echo "  -nh                : No History (Do not update dashboard history graph)"
    echo "  -clear             : Clear dashboard history for selected profile"
    echo ""
    echo "--- EXTRAS ---"
    echo "  -unb, -no-unb      : Force Enable/Disable Unbound stats"
    echo "  -ucc               : Include Unbound Cache Count (msg/rrset)"
    echo "  -snap              : Use RAM Snapshot (Faster, uses memory)"
    echo "  -hor, -ver         : Force Horizontal or Vertical layout"
    echo "  -debug             : Enable debug logging to file"
    exit 0
}

MODE="DEFAULT"
EXCLUDE_NX=false
SILENT_MODE=false
DOMAIN_FILTER=""
SQL_DOMAIN_CLAUSE=""
SEQUENTIAL=false
ADD_TIMESTAMP=false
SHOW_UNBOUND="default"
USE_SNAPSHOT=false
ENABLE_UCC=false
DEBUG_MODE=false
DEBUG_LOG="$SCRIPT_DIR/pihole_stats_debug.log"
DO_JSON=false
JSON_FILE=""
DO_TXT=false
TXT_FILE=""
DASH_MODE=false
DASH_PROFILE="default"
DASH_HISTORY=true
DASH_CLEAR=false

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help) show_help ;;
        -c|--config|-mc|--make-config) shift; shift ;;
        -dash)
            DASH_MODE=true
            DO_JSON=true
            SILENT_MODE=true
            if [[ -n "$2" && "$2" != -* ]]; then
                DASH_PROFILE="$2"
                shift
            fi
            check_lock "$DASH_PROFILE"
            shift
            ;;
        -nh) DASH_HISTORY=false; shift ;;
        -clear) DASH_CLEAR=true; shift ;;
        -up) [ "$DASH_MODE" = false ] && MODE="UPSTREAM"; shift ;;
        -pi) [ "$DASH_MODE" = false ] && MODE="PIHOLE"; shift ;;
        -nx) [ "$DASH_MODE" = false ] && EXCLUDE_NX=true; shift ;;
        -j|--json)
            DO_JSON=true
            if [[ -n "$2" && "$2" != -* ]]; then
                JSON_FILE="$2"
                shift
            fi
            shift
            ;;
        -f)
            DO_TXT=true
            if [[ -n "$2" && "$2" != -* ]]; then
                TXT_FILE="$2"
                shift
            fi
            shift
            ;;
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
        -debug) DEBUG_MODE=true; ENABLE_UCC=true; shift ;;
        -hor|--horizontal) LAYOUT="horizontal"; shift ;;
        -ver|--vertical) LAYOUT="vertical"; shift ;;
        -from)
            if [ "$DASH_MODE" = false ]; then
                shift
                QUERY_START=$(date -d "$1" +%s)
                TIME_LABEL="Custom"
            else
                shift
            fi
            shift
            ;;
        -to)
            if [ "$DASH_MODE" = false ]; then
                shift
                QUERY_END=$(date -d "$1" +%s)
                TIME_LABEL="Custom"
            else
                shift
            fi
            shift
            ;;
        -dm|--domain)
            shift
            DOMAIN_FILTER="$1"
            SANITIZED="${1//\*/%}"
            SANITIZED="${SANITIZED//\?/_}"
            SQL_DOMAIN_CLAUSE="AND domain LIKE '%$SANITIZED%'"
            shift
            ;;
        -edm|--exact-domain)
            shift
            DOMAIN_FILTER="$1"
            SANITIZED="${1//\*/%}"
            SANITIZED="${SANITIZED//\?/_}"
            SQL_DOMAIN_CLAUSE="AND (domain LIKE '$SANITIZED' OR domain LIKE '%.$SANITIZED')"
            shift
            ;;
        -[0-9]*[hd])
            if [ "$DASH_MODE" = false ]; then
                INPUT="${1#-}"
                UNIT="${INPUT: -1}"
                VALUE="${INPUT%?}"
                if [[ "$VALUE" =~ ^[0-9]+$ ]]; then
                    if [ "$UNIT" == "h" ]; then
                        OFFSET=$((VALUE * 3600))
                    else
                        OFFSET=$((VALUE * 86400))
                    fi
                    QUERY_START=$((TS_NOW - OFFSET))
                    IS_FILTERED=true
                    if [ "$VALUE" -eq 1 ]; then
                        [ "$UNIT" == "h" ] && TIME_LABEL="Last Hour" || TIME_LABEL="Last Day"
                    else
                        [ "$UNIT" == "h" ] && TIME_LABEL="Last $VALUE Hours" || TIME_LABEL="Last $VALUE Days"
                    fi
                fi
            fi
            shift
            ;;
        *)
            echo "❌ Error: Unknown argument '$1'"
            exit 1
            ;;
    esac
done

if [ "$DASH_MODE" = false ]; then
    if [ -n "$JSON_FILE" ]; then
        if [ -d "$JSON_FILE" ] || [[ "$JSON_FILE" == */ ]]; then
            JSON_FILE="${JSON_FILE%/}/${JSON_NAME:-pihole_stats.json}"
        fi
    fi
    if [ -n "$TXT_FILE" ]; then
        if [ -d "$TXT_FILE" ] || [[ "$TXT_FILE" == */ ]]; then
            TXT_FILE="${TXT_FILE%/}/${TXT_NAME:-pihole_stats.txt}"
        fi
    fi
    
    if [ "$DO_JSON" = true ] && [ -z "$JSON_FILE" ]; then
        if [ -n "$TXT_FILE" ]; then
            JSON_FILE="${TXT_FILE%.*}.json"
        elif [ -n "$JSON_NAME" ]; then
            JSON_FILE="$JSON_NAME"
        else
            JSON_FILE="$PWD/pihole_stats.json"
        fi
    fi
    
    if [ "$DO_TXT" = true ] && [ -z "$TXT_FILE" ]; then
        if [ -n "$JSON_FILE" ]; then
            TXT_FILE="${JSON_FILE%.*}.txt"
        elif [ -n "$TXT_NAME" ]; then
            TXT_FILE="$TXT_NAME"
        else
            TXT_FILE="$PWD/pihole_stats.txt"
        fi
    fi
    
    if [ -n "$JSON_FILE" ] && [[ "$JSON_FILE" != /* ]] && [ -n "$SAVE_DIR_JSON" ]; then
        mkdir -p "$SAVE_DIR_JSON"
        JSON_FILE="$SAVE_DIR_JSON/$JSON_FILE"
    fi
    
    if [ -n "$TXT_FILE" ] && [[ "$TXT_FILE" != /* ]] && [ -n "$SAVE_DIR_TXT" ]; then
        mkdir -p "$SAVE_DIR_TXT"
        TXT_FILE="$SAVE_DIR_TXT/$TXT_FILE"
    fi
    
    if [ "$TIME_LABEL" == "Custom Range" ]; then
        TIME_LABEL="$(date -d @$QUERY_START "+%Y-%m-%d %H:%M") to $(date -d @$QUERY_END "+%Y-%m-%d %H:%M")"
    fi
    
    if [ "$LAYOUT" == "auto" ]; then
        COLS=$(tput cols 2>/dev/null || echo 80)
        if [ "$COLS" -ge 100 ]; then
            LAYOUT="horizontal"
        else
            LAYOUT="vertical"
        fi
    fi
    
    if [ "$SHOW_UNBOUND" == "only" ]; then
        LAYOUT="vertical"
    fi
fi

if [ "$DASH_MODE" = true ]; then
    HIST_PATH="${DASH_DIR}/dash_${DASH_PROFILE}.h.json"
    SNAP_PATH="${DASH_DIR}/dash_${DASH_PROFILE}.json"
    
    if [ "$DASH_CLEAR" = true ]; then
        rm -f "$HIST_PATH" "$SNAP_PATH"
        echo "✅ Cleared history."
        exit 0
    fi
fi

if [ "$DEBUG_MODE" = true ]; then
    CONF_DIR="$(dirname "$CONFIG_TO_LOAD")"
    if [[ "$CONF_DIR" != "$SCRIPT_DIR" ]] && [[ "$CONF_DIR" != "/etc/pihole" ]]; then
        DEBUG_LOG="$CONF_DIR/phls_${DASH_PROFILE:-custom}_debug.log"
    else
        DEBUG_LOG="$SCRIPT_DIR/pihole_stats_debug.log"
    fi
    fix_perms "$DEBUG_LOG" "user"
fi

start_spinner() {
    (
        term_cols=$(tput cols 2>/dev/null || echo 80)
        width=$(( term_cols / width_divider ))
        [ "$width" -lt 5 ] && width=5
        start_len=$(( width % 2 == 0 ? 2 : 1 ))
        frames=()
        
        for (( len=start_len; len<=width; len+=2 )); do
            padding=$(( (width - len) / 2 ))
            pad=$(printf "%${padding}s")
            printf -v bar_raw "%*s" "$len" ""
            bar="${bar_raw// /$char}"
            frames+=("|$pad$bar$pad|")
        done
        
        for (( len=width-2; len>=start_len; len-=2 )); do
            padding=$(( (width - len) / 2 ))
            pad=$(printf "%${padding}s")
            printf -v bar_raw "%*s" "$len" ""
            bar="${bar_raw// /$char}"
            frames+=("|$pad$bar$pad|")
        done
        
        interval=$(awk "BEGIN {print $target_time / ${#frames[@]}}")
        tput civis >&2
        
        while true; do
            for frame in "${frames[@]}"; do
                tput rc >&2
                printf "%s" "$frame" >&2
                sleep "$interval"
            done
        done
    ) &
    SPINNER_PID=$!
    trap 'kill $SPINNER_PID 2>/dev/null; [ -t 1 ] && tput cnorm >&2 2>/dev/null' EXIT
}

stop_spinner() {
    if [ -n "$SPINNER_PID" ]; then
        kill "$SPINNER_PID" 2>/dev/null
        wait "$SPINNER_PID" 2>/dev/null
        if [ -t 1 ]; then
            tput rc >&2
            tput el >&2
            echo "Finished!" >&2
            tput cnorm >&2
        else
            echo "Finished!" >&2
        fi
        SPINNER_PID=""
        trap - EXIT
    fi
}

# --- 8. PARALLEL WORKERS ---

# Worker 1: Unbound
collect_unbound_async() {
    local TMP_OUT="/dev/shm/phls_unbound_$$.tmp"
    local u_stat="Disabled"; local u_hits="0"; local u_miss="0"; local u_pre="0"; local u_total="0"
    local u_mem_msg="0"; local u_mem_rr="0"; local u_lim_msg="0"; local u_lim_rr="0"
    local ucc_msg="0"; local ucc_rr="0"; local has_unbound="false"
    local h_b1="0"; local h_b2="0"; local h_b3="0"; local h_b4="0"; local h_b5="0"; local h_b6="0"; local h_b7="0"; local h_b8="0"; local h_b9="0"
    local u_avg_raw="0"; local u_med_raw="0"; local u_est_p95="0.00"; local u_est_std="0.00"

    if [ "$SHOW_UNBOUND" != "no" ]; then
        local proceed="true"
        if ! command -v unbound-control &> /dev/null; then proceed="false"; fi
        if [ "$proceed" == "true" ] && [ "$SHOW_UNBOUND" == "default" ]; then
            if [ "$ENABLE_UNBOUND" == "false" ]; then proceed="false"; fi
            if [ "$ENABLE_UNBOUND" == "auto" ]; then
                if ! systemctl is-active --quiet unbound 2>/dev/null && ! pgrep -x unbound >/dev/null; then proceed="false"; fi
            fi
        fi
        
        if [ "$proceed" == "true" ]; then
            local raw_stats=$(sudo /usr/sbin/unbound-control -c /etc/unbound/unbound.conf stats_noreset 2>&1)
            if [ -n "$raw_stats" ] && ! echo "$raw_stats" | grep -iEq "^error:|connection refused|permission denied|failed"; then
                has_unbound="true"; u_stat="Active (Integrated)"
                u_hits=$(echo "$raw_stats" | grep '^total.num.cachehits=' | cut -d= -f2); u_hits=${u_hits:-0}
                u_miss=$(echo "$raw_stats" | grep '^total.num.cachemiss=' | cut -d= -f2); u_miss=${u_miss:-0}
                u_pre=$(echo "$raw_stats" | grep '^total.num.prefetch=' | cut -d= -f2); u_pre=${u_pre:-0}
                u_total=$((u_hits + u_miss))
                u_mem_msg=$(echo "$raw_stats" | grep '^mem.cache.message=' | cut -d= -f2); u_mem_msg=${u_mem_msg:-0}
                u_mem_rr=$(echo "$raw_stats" | grep '^mem.cache.rrset=' | cut -d= -f2); u_mem_rr=${u_mem_rr:-0}
                u_lim_msg=$(sudo /usr/sbin/unbound-checkconf -o msg-cache-size 2>/dev/null || echo "4194304")
                u_lim_rr=$(sudo /usr/sbin/unbound-checkconf -o rrset-cache-size 2>/dev/null || echo "8388608")
                ucc_msg=$(echo "$raw_stats" | grep '^msg.cache.count=' | cut -d= -f2); ucc_msg=${ucc_msg:-0}
                ucc_rr=$(echo "$raw_stats" | grep '^rrset.cache.count=' | cut -d= -f2); ucc_rr=${ucc_rr:-0}
                u_avg_raw=$(echo "$raw_stats" | grep '^total.recursion.time.avg=' | cut -d= -f2); u_avg_raw=${u_avg_raw:-0}
                u_med_raw=$(echo "$raw_stats" | grep '^total.recursion.time.median=' | cut -d= -f2); u_med_raw=${u_med_raw:-0}

                if echo "$raw_stats" | grep -q "^histogram\."; then
                    h_b1=$(echo "$raw_stats" | grep -E '^histogram\.000000\.(000000|000001|000002|000004|000008|000016|000032|000064|000128|000256|000512|001024|002048|004096)\.to' | cut -d= -f2 | paste -sd+ - | bc)
                    h_b2=$(echo "$raw_stats" | grep '^histogram\.000000\.008192\.to' | cut -d= -f2); h_b3=$(echo "$raw_stats" | grep '^histogram\.000000\.016384\.to' | cut -d= -f2)
                    h_b4=$(echo "$raw_stats" | grep '^histogram\.000000\.032768\.to' | cut -d= -f2); h_b5=$(echo "$raw_stats" | grep '^histogram\.000000\.065536\.to' | cut -d= -f2)
                    h_b6=$(echo "$raw_stats" | grep '^histogram\.000000\.131072\.to' | cut -d= -f2); h_b7=$(echo "$raw_stats" | grep '^histogram\.000000\.262144\.to' | cut -d= -f2)
                    h_b8=$(echo "$raw_stats" | grep '^histogram\.000000\.524288\.to' | cut -d= -f2); h_b9=$(echo "$raw_stats" | grep -E '^histogram\.(000001|000002|000004|000008|000016|000032)\.000000\.to' | cut -d= -f2 | paste -sd+ - | bc)
                fi
                h_b1=${h_b1:-0}; h_b2=${h_b2:-0}; h_b3=${h_b3:-0}; h_b4=${h_b4:-0}; h_b5=${h_b5:-0}; h_b6=${h_b6:-0}; h_b7=${h_b7:-0}; h_b8=${h_b8:-0}; h_b9=${h_b9:-0}
                
                if [ "$u_miss" -gt 0 ]; then
                    u_est_stats=$(awk -v b1="$h_b1" -v b2="$h_b2" -v b3="$h_b3" -v b4="$h_b4" -v b5="$h_b5" -v b6="$h_b6" -v b7="$h_b7" -v b8="$h_b8" -v b9="$h_b9" -v avg_sec="$u_avg_raw" 'BEGIN {
                        total = b1+b2+b3+b4+b5+b6+b7+b8+b9; if(total==0) {print "0.00 0.00"; exit}
                        avg_ms = avg_sec * 1000;
                        sq_sum = (b1*(4-avg_ms)^2) + (b2*(12-avg_ms)^2) + (b3*(24-avg_ms)^2) + (b4*(48-avg_ms)^2) + (b5*(96-avg_ms)^2) + (b6*(192-avg_ms)^2) + (b7*(384-avg_ms)^2) + (b8*(768-avg_ms)^2) + (b9*(1500-avg_ms)^2);
                        stddev = sqrt(sq_sum / total);

			# P95 Estimation (With Symbols)
                        target = total * 0.95; cum = 0; p95 = "0";
                        if((cum+=b1) >= target) p95="< 8";
                        else if((cum+=b2) >= target) p95="< 16";
                        else if((cum+=b3) >= target) p95="< 32";
                        else if((cum+=b4) >= target) p95="< 64";
                        else if((cum+=b5) >= target) p95="< 128";
                        else if((cum+=b6) >= target) p95="< 256";
                        else if((cum+=b7) >= target) p95="< 512";
                        else if((cum+=b8) >= target) p95="< 1024";
                        else p95="> 1000";
                        
                        # Use pipe | delimiter to handle spaces in "< 512"
                        printf "%.2f|%s", stddev, p95
                    }')
                    u_est_std=$(echo "$u_est_stats" | cut -d'|' -f1)
                    u_est_p95=$(echo "$u_est_stats" | cut -d'|' -f2)
                fi
            else has_unbound="true"; u_stat="Error (Check Perms)"; fi
        fi
    fi
    cat <<EOF > "$TMP_OUT"
U_STATUS="$u_stat"; U_TOTAL="$u_total"; U_HITS="$u_hits"; U_MISS="$u_miss"; U_PRE="$u_pre"
U_MEM_MSG="$u_mem_msg"; U_MEM_RR="$u_mem_rr"; U_LIM_MSG="$u_lim_msg"; U_LIM_RR="$u_lim_rr"
UCC_MSG="$ucc_msg"; UCC_RR="$ucc_rr"; HAS_UNBOUND="$has_unbound"
H_B1="$h_b1"; H_B2="$h_b2"; H_B3="$h_b3"; H_B4="$h_b4"; H_B5="$h_b5"; H_B6="$h_b6"; H_B7="$h_b7"; H_B8="$h_b8"; H_B9="$h_b9"
U_AVG="$u_avg_raw"; U_MED="$u_med_raw"; U_STD="$u_est_std"; U_P95="$u_est_p95"
EOF
}

# Worker 2: Main Aggregation (Global Tiers Only for CLI)
worker_main_stats() {
    local db="$1"; local out="$2"; local t_start="$3"; local t_end="$4"; local sql_tiers="$5"; local sql_blk="$6"; local sql_met="$7"; local sql_dom="$8"
    sqlite3 "$db" <<EOF > "$out"
.mode list
.headers off
PRAGMA temp_store = MEMORY; PRAGMA synchronous = OFF;
CREATE TEMP TABLE raw AS SELECT timestamp, status, reply_time FROM queries WHERE timestamp >= $t_start AND timestamp <= $t_end $sql_dom;
SELECT 
    COUNT(*), SUM(CASE WHEN reply_time IS NULL THEN 1 ELSE 0 END), SUM(CASE WHEN reply_time IS NOT NULL THEN 1 ELSE 0 END),
    SUM(CASE WHEN reply_time IS NOT NULL AND $sql_blk THEN 1 ELSE 0 END), 
    SUM(CASE WHEN reply_time IS NOT NULL AND $sql_met THEN 1 ELSE 0 END),
    SUM(CASE WHEN reply_time IS NOT NULL AND $sql_met THEN reply_time ELSE 0.0 END), 
    SUM(CASE WHEN reply_time IS NOT NULL AND $sql_met THEN reply_time * reply_time ELSE 0.0 END),
    $sql_tiers
FROM raw;
EOF
}

# Worker 3: Global Sorter
worker_global_sorter() {
    local db="$1"; local out="$2"; local t_start="$3"; local t_end="$4"; local metric="$5"; local sql_dom="$6"; local sql_met="$7"
    local limit_logic=""
    if [ "$metric" == "MED" ]; then limit_logic="LIMIT 1 OFFSET (SELECT (COUNT(*) - 1) / 2 FROM t_glob_s)"; else limit_logic="LIMIT 1 OFFSET (SELECT CAST((COUNT(*) * 0.95) - 1 AS INT) FROM t_glob_s)"; fi
    sqlite3 "$db" <<EOF > "$out"
.mode list
.headers off
PRAGMA temp_store = MEMORY; PRAGMA synchronous = OFF;
CREATE TEMP TABLE t_glob_s AS SELECT reply_time FROM queries WHERE timestamp >= $t_start AND timestamp <= $t_end $sql_dom AND reply_time IS NOT NULL AND $sql_met;
SELECT reply_time FROM t_glob_s ORDER BY reply_time ASC $limit_logic;
EOF
}

# --- NEW: SPLIT WINDOW PROCESSORS ---

# Worker 4: Window Global
worker_window_global() {
    local db="$1"; local out="$2"; local t_start="$3"; local t_end="$4"; local sql_tiers="$5"; local do_math="$6"; local sql_dom="$7"; local sql_met="$8"
    local math_select="SELECT 0; SELECT 0;"
    if [ "$do_math" = "true" ]; then math_select="SELECT reply_time FROM t_win ORDER BY reply_time ASC LIMIT 1 OFFSET (SELECT (COUNT(*) - 1) / 2 FROM t_win); SELECT reply_time FROM t_win ORDER BY reply_time ASC LIMIT 1 OFFSET (SELECT CAST((COUNT(*) * 0.95) - 1 AS INT) FROM t_win);"; fi
    sqlite3 "$db" <<EOF > "$out"
.mode list
.headers off
PRAGMA temp_store = MEMORY; PRAGMA synchronous = OFF;
CREATE TEMP TABLE t_win AS SELECT reply_time FROM queries WHERE timestamp >= $t_start AND timestamp <= $t_end $sql_dom AND reply_time IS NOT NULL AND $sql_met;
SELECT COUNT(*), SUM(reply_time), SUM(reply_time * reply_time), $sql_tiers FROM t_win;
$math_select
EOF
}

# Worker 5: Window Upstream (Optimized Filter)
worker_window_upstream() {
    local db="$1"; local out="$2"; local t_start="$3"; local t_end="$4"; local sql_tiers="$5"; local do_math="$6"; local up_cond="$7"
    local math_select="SELECT 0; SELECT 0;"
    if [ "$do_math" = "true" ]; then math_select="SELECT reply_time FROM t_win_up ORDER BY reply_time ASC LIMIT 1 OFFSET (SELECT (COUNT(*) - 1) / 2 FROM t_win_up); SELECT reply_time FROM t_win_up ORDER BY reply_time ASC LIMIT 1 OFFSET (SELECT CAST((COUNT(*) * 0.95) - 1 AS INT) FROM t_win_up);"; fi
    sqlite3 "$db" <<EOF > "$out"
.mode list
.headers off
PRAGMA temp_store = MEMORY; PRAGMA synchronous = OFF;
/* Filter directly in CREATE TABLE to save RAM */
CREATE TEMP TABLE t_win_up AS SELECT reply_time FROM queries WHERE timestamp >= $t_start AND timestamp <= $t_end AND $up_cond;
SELECT COUNT(*), SUM(reply_time), SUM(reply_time * reply_time), $sql_tiers FROM t_win_up;
$math_select
EOF
}

# --- 9. ORCHESTRATOR ---
P_TOTAL=0; P_INVALID=0; P_VALID=0; P_BLOCKED=0; P_ANALYZED=0; P_IGNORED=0; P_AVG="0.00"; P_MED="0.00"; P_95="0.00"; P_STD="0.00"

declare -a TIER_LABELS; declare -a TIER_COUNTS; declare -a TIER_PCTS
declare -a W12_TIERS; declare -a W24_TIERS; declare -a W7D_TIERS; declare -a W30_TIERS
declare -a W12_STATS; declare -a W24_STATS; declare -a W7D_STATS; declare -a W30_STATS
declare -a UP_TIERS_12H; declare -a UP_TIERS_24H; declare -a UP_TIERS_7D; declare -a UP_TIERS_30D; declare -a UP_TIERS_ALL
declare -a UP_STATS_12H; declare -a UP_STATS_24H; declare -a UP_STATS_7D; declare -a UP_STATS_30D; declare -a UP_STATS_ALL

collect_pihole_stats() {

    if [ "$SHOW_UNBOUND" == "only" ]; then
        MODE_LABEL="Unbound Only"
        P_TOTAL=0; P_INVALID=0; P_VALID=0; P_BLOCKED=0; P_ANALYZED=0; P_IGNORED=0
        P_AVG="0.00"; P_MED="0.00"; P_95="0.00"; P_STD="0.00"
        wait "$PID_UNB" 2>/dev/null
        T_UNB="/dev/shm/phls_unbound_$$.tmp"
        if [ -f "$T_UNB" ]; then source "$T_UNB"; rm -f "$T_UNB"; fi
        U_TOTAL=${U_TOTAL:-0}; U_HITS=${U_HITS:-0}; U_MISS=${U_MISS:-0}; U_PRE=${U_PRE:-0}
        U_MEM_MSG=${U_MEM_MSG:-0}; U_LIM_MSG=${U_LIM_MSG:-0}
        U_MEM_RR=${U_MEM_RR:-0}; U_LIM_RR=${U_LIM_RR:-0}
        UCC_MSG=${UCC_MSG:-0}; UCC_RR=${UCC_RR:-0}
        if [ "$HAS_UNBOUND" != "true" ]; then HAS_UNBOUND="true"; U_STATUS="Error: Service Down"; fi
        if [ "$U_TOTAL" -gt 0 ]; then U_PCT_HIT=$(awk "BEGIN {printf \"%.2f\", ($U_HITS / $U_TOTAL) * 100}"); U_PCT_MISS=$(awk "BEGIN {printf \"%.2f\", ($U_MISS / $U_TOTAL) * 100}"); fi
        if [ "$U_HITS" -gt 0 ]; then U_PCT_PRE=$(awk "BEGIN {printf \"%.2f\", ($U_PRE / $U_HITS) * 100}"); fi
        if [ "$U_LIM_MSG" -gt 0 ]; then U_PCT_MEM_MSG=$(awk "BEGIN {printf \"%.2f\", ($U_MEM_MSG / $U_LIM_MSG) * 100}"); fi
        if [ "$U_LIM_RR" -gt 0 ]; then U_PCT_MEM_RR=$(awk "BEGIN {printf \"%.2f\", ($U_MEM_RR / $U_LIM_RR) * 100}"); fi
        U_AVG_F=$(awk "BEGIN {printf \"%.2f\", ${U_AVG:-0} * 1000}"); U_MED_F=$(awk "BEGIN {printf \"%.2f\", ${U_MED:-0} * 1000}")
        return
    fi

    if [ ! -r "$DBfile" ] && [ "$USE_SNAPSHOT" = false ]; then echo "❌ Error: Cannot read database '$DBfile'." >&2; return; fi

    SQL_LATENCY_COND=""
    if [ -n "$MIN_LATENCY_CUTOFF" ]; then MIN_SEC=$(awk "BEGIN {print $MIN_LATENCY_CUTOFF / 1000}"); SQL_LATENCY_COND="AND reply_time >= $MIN_SEC"; fi
    if [ -n "$MAX_LATENCY_CUTOFF" ]; then MAX_SEC=$(awk "BEGIN {print $MAX_LATENCY_CUTOFF / 1000}"); SQL_LATENCY_COND="$SQL_LATENCY_COND AND reply_time <= $MAX_SEC"; fi
    
    if [[ "$MODE" == "UPSTREAM" ]]; then CURRENT_LIST="$BASE_UPSTREAM"; MODE_LABEL="Upstream Only";
    elif [[ "$MODE" == "PIHOLE" ]]; then CURRENT_LIST="$BASE_PIHOLE"; MODE_LABEL="Pi-hole Only";
    else CURRENT_LIST="$BASE_DEFAULT"; MODE_LABEL="All Normal Queries"; fi
    
    if [ "$EXCLUDE_NX" = true ]; then MODE_LABEL="$MODE_LABEL [Excl. Blocks]"; SQL_STATUS_FILTER="status IN ($CURRENT_LIST)";
    else [[ "$MODE" != "PIHOLE" ]] && SQL_STATUS_FILTER="status IN ($CURRENT_LIST, 16, 17)" || SQL_STATUS_FILTER="status IN ($CURRENT_LIST)"; fi
    SQL_METRIC_FILTER="$SQL_STATUS_FILTER $SQL_LATENCY_COND"

    TS_NOW=$(date +%s); TS_12H=$((TS_NOW - 43200)); TS_24H=$((TS_NOW - 86400)); TS_7D=$((TS_NOW - 604800)); TS_30D=$((TS_NOW - 2592000))
    if [ "$DASH_MODE" = true ]; then 
        QUERY_END="$TS_NOW"
        if [ -n "$MAX_DB_DAYS" ] && [ "$MAX_DB_DAYS" -gt 0 ]; then DAYS_SEC=$((MAX_DB_DAYS * 86400)); QUERY_START=$((TS_NOW - DAYS_SEC)); TIME_LABEL="Last $MAX_DB_DAYS Days"
        else QUERY_START=0; TIME_LABEL="All Time (Full DB)"; fi
    fi

    # Global Tiers
    raw_limits=("$L01" "$L02" "$L03" "$L04" "$L05" "$L06" "$L07" "$L08" "$L09" "$L10" "$L11" "$L12" "$L13" "$L14" "$L15" "$L16" "$L17" "$L18" "$L19" "$L20")
    IFS=$'\n' sorted_limits=($(printf "%s\n" "${raw_limits[@]}" | grep -v '^$' | sort -n)); unset IFS
    global_tier_sql=""; window_tier_sql=""
    prev_ms="0"; prev_sec="0"; idx=0
    for ms in "${sorted_limits[@]}"; do
        sec=$(awk "BEGIN {print $ms / 1000}")
        if [ "$idx" -eq 0 ]; then logic="reply_time <= $sec"; lbl="Tier $((idx+1)) (< ${ms}ms)"; else logic="reply_time > $prev_sec AND reply_time <= $sec"; lbl="Tier $((idx+1)) (${prev_ms} - ${ms}ms)"; fi
        global_tier_sql="${global_tier_sql} SUM(CASE WHEN ${logic} AND $SQL_METRIC_FILTER THEN 1 ELSE 0 END),"
        window_tier_sql="${window_tier_sql} SUM(CASE WHEN ${logic} THEN 1 ELSE 0 END),"
        TIER_LABELS[$idx]="$lbl"; prev_ms="$ms"; prev_sec="$sec"; ((idx++))
    done
    lbl="Tier $((idx+1)) (> ${prev_ms}ms)"; global_tier_sql="${global_tier_sql} SUM(CASE WHEN reply_time > $prev_sec AND $SQL_METRIC_FILTER THEN 1 ELSE 0 END)"; window_tier_sql="${window_tier_sql} SUM(CASE WHEN reply_time > $prev_sec THEN 1 ELSE 0 END)"; TIER_LABELS[$idx]="$lbl"

    # Upstream Tiers (Condition is "1=0" unless DASH_MODE)
    local UP_COND="1=0"; local window_tier_sql_up=""
    if [ "$ENABLE_UPSTREAM_DIST" = "true" ] && [ "$DASH_MODE" = "true" ]; then
        local up_min_sec=$(awk "BEGIN {print ${UPSTREAM_DIST_MIN_CUTOFF:-3} / 1000}")
        UP_COND="status IN (2,6,7,8) AND reply_time >= $up_min_sec"
        local up_limits=("8" "16" "32" "64" "128" "256" "512" "1000")
        prev_ms="0"; prev_sec="0"; idx=0
        for ms in "${up_limits[@]}"; do
            sec=$(awk "BEGIN {print $ms / 1000}")
            if [ "$idx" -eq 0 ]; then logic="reply_time <= $sec"; else logic="reply_time > $prev_sec AND reply_time <= $sec"; fi
            window_tier_sql_up="${window_tier_sql_up} SUM(CASE WHEN ${logic} THEN 1 ELSE 0 END),"
            prev_ms="$ms"; prev_sec="$sec"; ((idx++))
        done
        window_tier_sql_up="${window_tier_sql_up} SUM(CASE WHEN reply_time > $prev_sec THEN 1 ELSE 0 END)"
    else
        for ((i=0; i<9; i++)); do window_tier_sql_up="${window_tier_sql_up} 0,"; done; window_tier_sql_up="${window_tier_sql_up%?}"
    fi

    ACTIVE_DB="$DBfile"; SNAP_FILE="/dev/shm/pi_snap_$$.db"
    if [ "$USE_SNAPSHOT" = true ]; then
        DB_SZ=$(du -k "$DBfile" | awk '{print $1}')
        FREE_RAM=$(free -k | awk '/^Mem:/{print $7}')
        [ -z "$FREE_RAM" ] && FREE_RAM=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
        if [ "$FREE_RAM" -lt "$((DB_SZ + 51200))" ]; then SNAP_FILE="$HOME/pi_snap_$$.db"; [ "$SILENT_MODE" = false ] && echo "⚠️  Low RAM: Snapshot falling back to Disk" >&2; fi
        sqlite3 "$DBfile" ".backup '$SNAP_FILE'" || exit 1
        ACTIVE_DB="$SNAP_FILE"
    fi

    T_UNB="/dev/shm/phls_unbound_$$.tmp"
    collect_unbound_async & PID_UNB=$!

    T_MAIN="/dev/shm/phls_main_$$.tmp"
    worker_main_stats "$ACTIVE_DB" "$T_MAIN" "$QUERY_START" "$QUERY_END" "$global_tier_sql" "$SQL_BLOCKED_DEF" "$SQL_METRIC_FILTER" "$SQL_DOMAIN_CLAUSE" & PID_MAIN=$!

    if [ "$ENABLE_MATH_ALL_TIME" = true ]; then
        T_GLOB_M="/dev/shm/phls_gm_$$.tmp"; worker_global_sorter "$ACTIVE_DB" "$T_GLOB_M" "$QUERY_START" "$QUERY_END" "MED" "$SQL_DOMAIN_CLAUSE" "$SQL_METRIC_FILTER" & PID_GM=$!
        T_GLOB_P="/dev/shm/phls_gp_$$.tmp"; worker_global_sorter "$ACTIVE_DB" "$T_GLOB_P" "$QUERY_START" "$QUERY_END" "P95" "$SQL_DOMAIN_CLAUSE" "$SQL_METRIC_FILTER" & PID_GP=$!
    fi

    if [ "$DASH_MODE" = true ]; then
        # Launch Global Windows
        T12_G="/dev/shm/phls_12_g_$$.tmp"; worker_window_global "$ACTIVE_DB" "$T12_G" "$TS_12H" "$QUERY_END" "$window_tier_sql" "$ENABLE_MATH_12H" "$SQL_DOMAIN_CLAUSE" "$SQL_METRIC_FILTER" & PID12_G=$!
        T24_G="/dev/shm/phls_24_g_$$.tmp"; worker_window_global "$ACTIVE_DB" "$T24_G" "$TS_24H" "$QUERY_END" "$window_tier_sql" "$ENABLE_MATH_24H" "$SQL_DOMAIN_CLAUSE" "$SQL_METRIC_FILTER" & PID24_G=$!
        T7D_G="/dev/shm/phls_7d_g_$$.tmp"; worker_window_global "$ACTIVE_DB" "$T7D_G" "$TS_7D" "$QUERY_END" "$window_tier_sql" "$ENABLE_MATH_7D" "$SQL_DOMAIN_CLAUSE" "$SQL_METRIC_FILTER" & PID7D_G=$!
        T30_G="/dev/shm/phls_30_g_$$.tmp"; worker_window_global "$ACTIVE_DB" "$T30_G" "$TS_30D" "$QUERY_END" "$window_tier_sql" "$ENABLE_MATH_30D" "$SQL_DOMAIN_CLAUSE" "$SQL_METRIC_FILTER" & PID30_G=$!

        # Launch Upstream Windows (If Enabled)
        if [ "$ENABLE_UPSTREAM_DIST" = "true" ]; then
            T12_U="/dev/shm/phls_12_u_$$.tmp"; worker_window_upstream "$ACTIVE_DB" "$T12_U" "$TS_12H" "$QUERY_END" "$window_tier_sql_up" "$ENABLE_MATH_12H" "$UP_COND" & PID12_U=$!
            T24_U="/dev/shm/phls_24_u_$$.tmp"; worker_window_upstream "$ACTIVE_DB" "$T24_U" "$TS_24H" "$QUERY_END" "$window_tier_sql_up" "$ENABLE_MATH_24H" "$UP_COND" & PID24_U=$!
            T7D_U="/dev/shm/phls_7d_u_$$.tmp"; worker_window_upstream "$ACTIVE_DB" "$T7D_U" "$TS_7D" "$QUERY_END" "$window_tier_sql_up" "$ENABLE_MATH_7D" "$UP_COND" & PID7D_U=$!
            T30_U="/dev/shm/phls_30_u_$$.tmp"; worker_window_upstream "$ACTIVE_DB" "$T30_U" "$TS_30D" "$QUERY_END" "$window_tier_sql_up" "$ENABLE_MATH_30D" "$UP_COND" & PID30_U=$!
        fi
        
        # Launch Upstream All Time
        if [ "$ENABLE_UPSTREAM_DIST" = "true" ]; then
             T_UP_HIST="/dev/shm/phls_uph_$$.tmp"
             sqlite3 "$ACTIVE_DB" <<EOF > "$T_UP_HIST"
.mode list
.headers off
PRAGMA temp_store = MEMORY; PRAGMA synchronous = OFF;
SELECT COUNT(*), SUM(reply_time), SUM(reply_time * reply_time), $window_tier_sql_up FROM queries WHERE timestamp >= $QUERY_START AND timestamp <= $QUERY_END AND $UP_COND;
EOF
             PID_UPH=$!
             
             if [ "$ENABLE_UPSTREAM_MATH_ALL_TIME" = "true" ]; then
                T_UP_MATH="/dev/shm/phls_upm_$$.tmp"
                sqlite3 "$ACTIVE_DB" <<EOF > "$T_UP_MATH"
.mode list
.headers off
PRAGMA temp_store = MEMORY; PRAGMA synchronous = OFF;
CREATE TEMP TABLE t_up_all AS SELECT reply_time FROM queries WHERE timestamp >= $QUERY_START AND timestamp <= $QUERY_END AND $UP_COND;
SELECT reply_time FROM t_up_all ORDER BY reply_time ASC LIMIT 1 OFFSET (SELECT (COUNT(*) - 1) / 2 FROM t_up_all);
SELECT reply_time FROM t_up_all ORDER BY reply_time ASC LIMIT 1 OFFSET (SELECT CAST((COUNT(*) * 0.95) - 1 AS INT) FROM t_up_all);
EOF
                PID_UPM=$!
             fi
        fi
    fi

    wait $PID_MAIN; wait $PID_UNB
    if [ -n "$PID_GM" ]; then wait $PID_GM; fi
    if [ -n "$PID_GP" ]; then wait $PID_GP; fi
    if [ "$DASH_MODE" = true ]; then 
        wait $PID12_G; wait $PID24_G; wait $PID7D_G; wait $PID30_G
        if [ "$ENABLE_UPSTREAM_DIST" = "true" ]; then
             wait $PID12_U; wait $PID24_U; wait $PID7D_U; wait $PID30_U; wait $PID_UPH
             if [ -n "$PID_UPM" ]; then wait $PID_UPM; fi
        fi
    fi

    IFS='|' read -r -a METS <<< "$(cat "$T_MAIN")"; rm -f "$T_MAIN"
    P_TOTAL=${METS[0]:-0}; P_INVALID=${METS[1]:-0}; P_VALID=${METS[2]:-0}; P_BLOCKED=${METS[3]:-0}; P_ANALYZED=${METS[4]:-0}; P_DUR=${METS[5]:-0}; P_SQ_SUM=${METS[6]:-0}
    P_IGNORED=$((P_VALID - P_BLOCKED - P_ANALYZED))

    base_idx=7
    for i in "${!TIER_LABELS[@]}"; do
        TIER_COUNTS[$i]=${METS[$base_idx]:-0}
        if [ "$P_ANALYZED" -gt 0 ]; then TIER_PCTS[$i]=$(awk "BEGIN {printf \"%.2f\", (${TIER_COUNTS[$i]} / $P_ANALYZED) * 100}")
        else TIER_PCTS[$i]="0.00"; fi
        ((base_idx++))
    done

    if [ "$P_ANALYZED" -gt 0 ]; then 
        P_AVG=$(awk "BEGIN {printf \"%.2f\", ($P_DUR * 1000) / $P_ANALYZED}")
        P_STD=$(awk "BEGIN {mean = $P_DUR / $P_ANALYZED; sq_mean = $P_SQ_SUM / $P_ANALYZED; var = sq_mean - (mean * mean); if (var < 0) var = 0; printf \"%.2f\", sqrt(var) * 1000;}")
    fi
    
    read_val() { if [ -f "$1" ]; then local v=$(cat "$1"); echo $(awk "BEGIN {printf \"%.2f\", ${v:-0} * 1000}"); rm "$1"; else echo "0.00"; fi }
    if [ "$ENABLE_MATH_ALL_TIME" = true ]; then P_MED=$(read_val "$T_GLOB_M"); P_95=$(read_val "$T_GLOB_P"); fi

    # --- DASHBOARD PARSING ---
    if [ "$DASH_MODE" = true ]; then
        parse_window_output() {
            local file_g=$1; local file_u=$2
            local -n tiers_ref=$3; local -n stats_ref=$4; local -n up_tiers_ref=$5; local -n up_stats_ref=$6
            
            # Global
            if [ -f "$file_g" ]; then
                mapfile -t FG < "$file_g"; rm -f "$file_g"
                IFS='|' read -r -a WG <<< "${FG[0]}"
                local cnt=${WG[0]:-0}; local sum=${WG[1]:-0}; local sq=${WG[2]:-0}
                local t_idx=3
                for i in "${!TIER_LABELS[@]}"; do tiers_ref[$i]=${WG[$t_idx]:-0}; ((t_idx++)); done
                local avg="0.00"; local std="0.00"
                if [ "$cnt" -gt 0 ]; then avg=$(awk "BEGIN {printf \"%.2f\", ($sum * 1000) / $cnt}"); std=$(awk "BEGIN {mean = $sum / $cnt; sq_mean = $sq / $cnt; var = sq_mean - (mean * mean); if (var < 0) var=0; printf \"%.2f\", sqrt(var) * 1000}"); fi
                local med=$(awk "BEGIN {printf \"%.2f\", ${FG[1]:-0} * 1000}")
                local p95=$(awk "BEGIN {printf \"%.2f\", ${FG[2]:-0} * 1000}")
                stats_ref=("$avg" "$std" "$med" "$p95")
            fi

            # Upstream (If enabled and file exists)
            if [ -f "$file_u" ]; then
                mapfile -t FU < "$file_u"; rm -f "$file_u"
                IFS='|' read -r -a WU <<< "${FU[0]}"
                local u_cnt=${WU[0]:-0}; local u_sum=${WU[1]:-0}; local u_sq=${WU[2]:-0}
                local u_idx=3
                for ((j=0; j<9; j++)); do up_tiers_ref[$j]=${WU[$u_idx]:-0}; ((u_idx++)); done
                local u_avg="0.00"; local u_std="0.00"
                if [ "$u_cnt" -gt 0 ]; then u_avg=$(awk "BEGIN {printf \"%.2f\", ($u_sum * 1000) / $u_cnt}"); u_std=$(awk "BEGIN {mean = $u_sum / $u_cnt; sq_mean = $u_sq / $u_cnt; var = sq_mean - (mean * mean); if (var < 0) var=0; printf \"%.2f\", sqrt(var) * 1000}"); fi
                local u_med=$(awk "BEGIN {printf \"%.2f\", ${FU[1]:-0} * 1000}")
                local u_p95=$(awk "BEGIN {printf \"%.2f\", ${FU[2]:-0} * 1000}")
                up_stats_ref=("$u_avg" "$u_std" "$u_med" "$u_p95")
            fi
        }
        
        parse_window_output "$T12_G" "$T12_U" W12_TIERS W12_STATS UP_TIERS_12H UP_STATS_12H
        parse_window_output "$T24_G" "$T24_U" W24_TIERS W24_STATS UP_TIERS_24H UP_STATS_24H
        parse_window_output "$T7D_G" "$T7D_U" W7D_TIERS W7D_STATS UP_TIERS_7D UP_STATS_7D
        parse_window_output "$T30_G" "$T30_U" W30_TIERS W30_STATS UP_TIERS_30D UP_STATS_30D
        
        if [ "$ENABLE_UPSTREAM_DIST" = "true" ]; then
             if [ -f "$T_UP_HIST" ]; then
                 IFS='|' read -r -a UH_RAW <<< "$(cat "$T_UP_HIST")"; rm -f "$T_UP_HIST"
                 local u_all_cnt=${UH_RAW[0]:-0}; local u_all_sum=${UH_RAW[1]:-0}; local u_all_sq=${UH_RAW[2]:-0}
                 local u_idx=3
                 for ((j=0; j<9; j++)); do UP_TIERS_ALL[$j]=${UH_RAW[$u_idx]:-0}; ((u_idx++)); done
                 local u_all_avg="0.00"; local u_all_std="0.00"
                 if [ "$u_all_cnt" -gt 0 ]; then u_all_avg=$(awk "BEGIN {printf \"%.2f\", ($u_all_sum * 1000) / $u_all_cnt}"); u_all_std=$(awk "BEGIN {mean = $u_all_sum / $u_all_cnt; sq_mean = $u_all_sq / $u_all_cnt; var = sq_mean - (mean * mean); if (var < 0) var=0; printf \"%.2f\", sqrt(var) * 1000}"); fi
                 UP_STATS_ALL[0]="$u_all_avg"; UP_STATS_ALL[1]="$u_all_std"
             fi
             if [ -f "$T_UP_MATH" ]; then
                 mapfile -t UM_LINES < "$T_UP_MATH"; rm -f "$T_UP_MATH"
                 UP_STATS_ALL[2]=$(awk "BEGIN {printf \"%.2f\", ${UM_LINES[0]:-0} * 1000}")
                 UP_STATS_ALL[3]=$(awk "BEGIN {printf \"%.2f\", ${UM_LINES[1]:-0} * 1000}")
             else UP_STATS_ALL[2]="0.00"; UP_STATS_ALL[3]="0.00"; fi
        fi
    fi

    if [ -f "$T_UNB" ]; then source "$T_UNB"; rm -f "$T_UNB"; fi
    if [ "$U_TOTAL" -gt 0 ]; then U_PCT_HIT=$(awk "BEGIN {printf \"%.2f\", ($U_HITS / $U_TOTAL) * 100}"); U_PCT_MISS=$(awk "BEGIN {printf \"%.2f\", ($U_MISS / $U_TOTAL) * 100}"); fi
    if [ "$U_HITS" -gt 0 ]; then U_PCT_PRE=$(awk "BEGIN {printf \"%.2f\", ($U_PRE / $U_HITS) * 100}"); fi
    if [ "$U_LIM_MSG" -gt 0 ]; then U_PCT_MEM_MSG=$(awk "BEGIN {printf \"%.2f\", ($U_MEM_MSG / $U_LIM_MSG) * 100}"); fi
    if [ "$U_LIM_RR" -gt 0 ]; then U_PCT_MEM_RR=$(awk "BEGIN {printf \"%.2f\", ($U_MEM_RR / $U_LIM_RR) * 100}"); fi
    U_AVG_F=$(awk "BEGIN {printf \"%.2f\", ${U_AVG:-0} * 1000}"); U_MED_F=$(awk "BEGIN {printf \"%.2f\", ${U_MED:-0} * 1000}")

    # ==============================================================================
    # 4. SURGICAL REFINEMENT: Precision Metrics (Stats Only)
    # ==============================================================================
    if [ "$DASH_MODE" = true ] && [ "$HAS_UNBOUND" = true ] && [ "$SHOW_UNBOUND" != "only" ]; then
        local ENABLE_MANUAL_REFINEMENT="no"
        local MANUAL_MIN_MS="3"
        if [ "$ENABLE_MANUAL_REFINEMENT" == "yes" ]; then
            local refine_start=0
            if [ -n "$MAX_DB_DAYS" ]; then refine_start=$((TS_NOW - (MAX_DB_DAYS * 86400))); fi
            local min_sec=$(awk "BEGIN {print ${MANUAL_MIN_MS:-0} / 1000}")
            local sql_up_filter="status IN (2, 6, 7, 8) AND reply_time >= $min_sec"
            if [ -n "$SQL_DOMAIN_CLAUSE" ]; then sql_up_filter="$sql_up_filter $SQL_DOMAIN_CLAUSE"; fi
            
            local T_REFINE="/dev/shm/phls_refine_$$.tmp"
            sqlite3 "$ACTIVE_DB" <<EOF > "$T_REFINE"
.mode list
.headers off
PRAGMA temp_store = MEMORY; PRAGMA synchronous = OFF;
CREATE TEMP TABLE t_up AS SELECT reply_time FROM queries WHERE timestamp >= $refine_start AND timestamp <= $QUERY_END AND $sql_up_filter;
SELECT COUNT(*), AVG(reply_time), AVG(reply_time * reply_time) FROM t_up;
SELECT reply_time FROM t_up ORDER BY reply_time ASC LIMIT 1 OFFSET (SELECT (COUNT(*) - 1) / 2 FROM t_up);
SELECT reply_time FROM t_up ORDER BY reply_time ASC LIMIT 1 OFFSET (SELECT CAST((COUNT(*) * 0.95) - 1 AS INT) FROM t_up);
EOF
            if [ -s "$T_REFINE" ]; then
                mapfile -t REF_LINES < "$T_REFINE"
                IFS='|' read -r -a R_DATA <<< "${REF_LINES[0]}"
                local r_count=${R_DATA[0]}; local r_avg=${R_DATA[1]}; local r_avg_sq=${R_DATA[2]}
                if [ "$r_count" -gt 0 ]; then
                    U_STD=$(awk -v avg="$r_avg" -v avg_sq="$r_avg_sq" 'BEGIN {var = avg_sq - (avg * avg); if (var < 0) var = 0; printf "%.2f", sqrt(var) * 1000}')
                    U_AVG_F=$(awk "BEGIN {printf \"%.2f\", ${r_avg:-0} * 1000}")
                    U_MED_F=$(awk "BEGIN {printf \"%.2f\", ${REF_LINES[1]:-0} * 1000}")
                    U_P95=$(awk "BEGIN {printf \"%.2f\", ${REF_LINES[2]:-0} * 1000}")
                fi
            fi
            rm -f "$T_REFINE"
        fi
    fi
    
    if [ "$USE_SNAPSHOT" = true ] && [ -f "$SNAP_FILE" ]; then rm "$SNAP_FILE"; fi
}

# --- 10. REPORTERS ---
print_text_report() {
    CURRENT_DATE=$(date "+%Y-%m-%d %H:%M:%S")
    declare -a L_LINES
    L_LINES+=("Time Period   : $TIME_LABEL")
    L_LINES+=("Query Mode    : $MODE_LABEL")
    L_LINES+=("-----------------------------------------------------")
    L_LINES+=("Total Queries        : $P_TOTAL")
    if [ "$P_TOTAL" -gt 0 ]; then PCT=$(awk "BEGIN {printf \"%.1f\", ($P_INVALID/$P_TOTAL)*100}"); L_LINES+=("Unsuccessful Queries : $P_INVALID ($PCT%)"); else L_LINES+=("Unsuccessful Queries : 0 (0.0%)"); fi
    L_LINES+=("Total Valid Queries  : $P_VALID")
    if [ "$P_VALID" -gt 0 ]; then
        SUM_BI=$((P_BLOCKED + P_IGNORED))
        if [ "$P_TOTAL" -gt 0 ]; then
            PCT=$(awk "BEGIN {printf \"%.1f\", ($SUM_BI/$P_TOTAL)*100}")
            L_LINES+=("Blocked / Ignored    : $P_BLOCKED / $P_IGNORED ($PCT%)")
            PCT=$(awk "BEGIN {printf \"%.1f\", ($P_ANALYZED/$P_TOTAL)*100}")
            L_LINES+=("Analyzed Queries     : $P_ANALYZED ($PCT%)")
        else L_LINES+=("Blocked / Ignored    : $P_BLOCKED / $P_IGNORED (0.0%)"); L_LINES+=("Analyzed Queries     : $P_ANALYZED (0.0%)"); fi
    else L_LINES+=("Blocked / Ignored    : 0 / 0"); L_LINES+=("Analyzed Queries     : 0"); fi
    L_LINES+=("Average Latency      : $P_AVG ms")
    L_LINES+=("Standard Deviation   : $P_STD ms")
    L_LINES+=("Median  Latency      : $P_MED ms")
    L_LINES+=("95th Percentile      : $P_95 ms")
    
    declare -a R_LINES
    if [ "$HAS_UNBOUND" = true ]; then
        R_LINES+=("Server Status : $U_STATUS")
        if [[ "$U_STATUS" != *"Error"* ]]; then
            R_LINES+=("Config File   : /etc/unbound/unbound.conf")
            R_LINES+=("---------------------------------------------") 
            R_LINES+=("Total Queries : $U_TOTAL")
            R_LINES+=("Cache Hits    : $U_HITS ($U_PCT_HIT%)")
            R_LINES+=("Cache Misses  : $U_MISS ($U_PCT_MISS%)")
            R_LINES+=("Prefetch Jobs : $U_PRE ($U_PCT_PRE% of Hits)")
            R_LINES+=("----- Cache Memory Usage (Used / Limit) -----")
            R_LINES+=("Msg Cache   : $(to_mb $U_MEM_MSG)MB / $(to_mb $U_LIM_MSG)MB  ($U_PCT_MEM_MSG%)")
            R_LINES+=("RRset Cache : $(to_mb $U_MEM_RR)MB / $(to_mb $U_LIM_RR)MB ($U_PCT_MEM_RR%)")
            if [ "$ENABLE_UCC" = true ]; then R_LINES+=("----- Cache Item Count (Msg / RRset) ------"); R_LINES+=("Items       : $UCC_MSG / $UCC_RR"); fi
            R_LINES+=("------- Unbound Latency (Cumulative) --------")
            R_LINES+=("Average: $U_AVG_F ms")
            R_LINES+=("Std Dev: ${U_STD:-0.00} ms")
            R_LINES+=("Median : $U_MED_F ms")
            R_LINES+=("P95    : ${U_P95:-0.00} ms")
        else R_LINES+=(""); R_LINES+=("⚠️  Permission Denied or Service Down"); fi
    fi
    
    declare -a DL_LINES; declare -a DR_LINES
    MAX_LEN_P=0; for lbl in "${TIER_LABELS[@]}"; do [ ${#lbl} -gt $MAX_LEN_P ] && MAX_LEN_P=${#lbl}; done; MAX_LEN_P=$((MAX_LEN_P + 2))
    for i in "${!TIER_LABELS[@]}"; do DL_LINES+=("$(printf "%-${MAX_LEN_P}s : %6s%% (%s)" "${TIER_LABELS[$i]}" "${TIER_PCTS[$i]}" "${TIER_COUNTS[$i]}")"); done

    if [ "$HAS_UNBOUND" = true ] && [ "${H_B1:-0}" != "0" ]; then
        declare -a U_TIER_LABS=("< 8ms" "8-16ms" "16-32ms" "32-64ms" "64-128ms" "128-256ms" "256-512ms" "512ms-1s" "> 1s")
        declare -a U_TIER_VALS=($H_B1 $H_B2 $H_B3 $H_B4 $H_B5 $H_B6 $H_B7 $H_B8 $H_B9)
        U_DIST_TOTAL=0; for v in "${U_TIER_VALS[@]}"; do U_DIST_TOTAL=$((U_DIST_TOTAL + v)); done
        MAX_LEN_U=0; for lbl in "${U_TIER_LABS[@]}"; do [ ${#lbl} -gt $MAX_LEN_U ] && MAX_LEN_U=${#lbl}; done; MAX_LEN_U=$((MAX_LEN_U + 2))
        for i in "${!U_TIER_LABS[@]}"; do
             if [ "$U_DIST_TOTAL" -gt 0 ]; then PCT=$(awk "BEGIN {printf \"%.2f\", (${U_TIER_VALS[$i]} / $U_DIST_TOTAL) * 100}"); else PCT="0.00"; fi
             DR_LINES+=("$(printf "%-${MAX_LEN_U}s : %6s%% (%s)" "${U_TIER_LABS[$i]}" "$PCT" "${U_TIER_VALS[$i]}")")
        done
    else DR_LINES+=("No Unbound distribution available"); fi

    if [ "$LAYOUT" == "horizontal" ]; then
        echo "===================================================================================================="
        TITLE="Pi-hole Latency Stats $VERSION"; PAD=$(( (100 - ${#TITLE}) / 2 )); printf "%${PAD}s%s\n" "" "$TITLE"
        echo "===================================================================================================="
        DATE_STR="Analysis Date : $CURRENT_DATE"; PAD_DATE=$(( (100 - ${#DATE_STR}) / 2 )); printf "%${PAD_DATE}s%s\n" "" "$DATE_STR"
        echo "---------------- Pi-hole Performance ----------------||---------- Unbound DNS Performance ----------"
        MAX=${#L_LINES[@]}; [ ${#R_LINES[@]} -gt $MAX ] && MAX=${#R_LINES[@]}
        for ((i=0; i<MAX; i++)); do printf "%-53s||%s\n" "${L_LINES[$i]}" "${R_LINES[$i]}"; done
        if [ "$SHOW_UNBOUND" != "only" ]; then
            echo "----------- Pi-hole Latency Distribution ------------||------- Unbound Response Distribution -------"
            MAX_D=${#DL_LINES[@]}; [ ${#DR_LINES[@]} -gt $MAX_D ] && MAX_D=${#DR_LINES[@]}
            for ((i=0; i<MAX_D; i++)); do printf "%-53s||%s\n" "${DL_LINES[$i]}" "${DR_LINES[$i]}"; done
        fi
        echo "===================================================================================================="
    else
        echo "========================================================"
        echo "              Pi-hole Latency Stats $VERSION"
        echo "========================================================"
        echo "Analysis Date : $CURRENT_DATE"
        if [ "$SHOW_UNBOUND" != "only" ]; then 
            echo "Time Period   : $TIME_LABEL"; echo "Query Mode    : $MODE_LABEL"; echo "--------------------------------------------------------"
            for line in "${L_LINES[@]}"; do if [[ "$line" != Time* ]] && [[ "$line" != Query* ]] && [[ "$line" != ---* ]]; then echo "$line"; fi; done; echo ""
        fi
        if [ "$HAS_UNBOUND" = true ]; then
             echo "----------- Unbound DNS Performance -----------"; for line in "${R_LINES[@]}"; do echo "$line"; done; echo "-----------------------------------------------"
        fi
        if [ "$SHOW_UNBOUND" != "only" ]; then
            echo "--- Latency Distribution of Pi-Hole Analyzed Queries ---"; for line in "${DL_LINES[@]}"; do echo "$line"; done
        fi
        if [ "$HAS_UNBOUND" = true ] && [ "${H_B1:-0}" != "0" ]; then
            if [ "$SHOW_UNBOUND" != "only" ]; then echo ""; fi
            echo "--- Unbound Response Time Distribution ---"; for line in "${DR_LINES[@]}"; do echo "$line"; done
        fi
        echo "========================================================"
    fi
}

print_json_report() {
    CURRENT_DATE=$(date "+%Y-%m-%d %H:%M:%S")
    JSTR="{\"version\": \"$VERSION\", \"date\": \"$CURRENT_DATE\", \"time_period\": \"$TIME_LABEL\", \"mode\": \"$MODE_LABEL\""
    if [ -n "$DOMAIN_FILTER" ]; then JSTR="$JSTR, \"domain_filter\": \"$DOMAIN_FILTER\""; fi
    JSTR="$JSTR, \"stats\": {\"total_queries\": $P_TOTAL, \"unsuccessful\": $P_INVALID, \"total_valid\": $P_VALID, \"blocked\": $P_BLOCKED, \"ignored\": $P_IGNORED, \"analyzed\": $P_ANALYZED}"
    JSTR="$JSTR, \"latency\": {\"average\": $P_AVG, \"median\": $P_MED, \"p95\": $P_95, \"stddev\": $P_STD}"
    JSTR="$JSTR, \"tiers\": ["
    FIRST=true
    for i in "${!TIER_LABELS[@]}"; do
        if [ "$FIRST" = true ]; then FIRST=false; else JSTR="$JSTR, "; fi
        JSTR="$JSTR{\"label\": \"${TIER_LABELS[$i]}\", \"count\": ${TIER_COUNTS[$i]}, \"percentage\": ${TIER_PCTS[$i]}}"
    done
    JSTR="$JSTR]"
    
    if [ "$DASH_MODE" = true ]; then
        build_arr() { local -n arr=$1; local out="["; local f=true; for k in "${!arr[@]}"; do [ "$f" = true ] && f=false || out="$out,"; out="$out${arr[$k]}"; done; echo "$out]"; }
        
        # Standard Global Stats
        JSTR="$JSTR, \"tiers_12h\": $(build_arr W12_TIERS), \"tiers_24h\": $(build_arr W24_TIERS), \"tiers_7d\": $(build_arr W7D_TIERS), \"tiers_30d\": $(build_arr W30_TIERS)"
        JSTR="$JSTR, \"stats_12h\": {\"average\": ${W12_STATS[0]:-0}, \"stddev\": ${W12_STATS[1]:-0}, \"median\": ${W12_STATS[2]:-0}, \"p95\": ${W12_STATS[3]:-0}}"
        JSTR="$JSTR, \"stats_24h\": {\"average\": ${W24_STATS[0]:-0}, \"stddev\": ${W24_STATS[1]:-0}, \"median\": ${W24_STATS[2]:-0}, \"p95\": ${W24_STATS[3]:-0}}"
        JSTR="$JSTR, \"stats_7d\": {\"average\": ${W7D_STATS[0]:-0}, \"stddev\": ${W7D_STATS[1]:-0}, \"median\": ${W7D_STATS[2]:-0}, \"p95\": ${W7D_STATS[3]:-0}}"
        JSTR="$JSTR, \"stats_30d\": {\"average\": ${W30_STATS[0]:-0}, \"stddev\": ${W30_STATS[1]:-0}, \"median\": ${W30_STATS[2]:-0}, \"p95\": ${W30_STATS[3]:-0}}"
        
        # New Upstream Stats (Simulated Unbound)
        if [ "$ENABLE_UPSTREAM_DIST" = "true" ]; then
            JSTR="$JSTR, \"up_tiers_12h\": $(build_arr UP_TIERS_12H), \"up_tiers_24h\": $(build_arr UP_TIERS_24H), \"up_tiers_7d\": $(build_arr UP_TIERS_7D), \"up_tiers_30d\": $(build_arr UP_TIERS_30D), \"up_tiers_all\": $(build_arr UP_TIERS_ALL)"
            JSTR="$JSTR, \"up_stats_12h\": {\"average\": ${UP_STATS_12H[0]:-0}, \"stddev\": ${UP_STATS_12H[1]:-0}, \"median\": ${UP_STATS_12H[2]:-0}, \"p95\": ${UP_STATS_12H[3]:-0}}"
            JSTR="$JSTR, \"up_stats_24h\": {\"average\": ${UP_STATS_24H[0]:-0}, \"stddev\": ${UP_STATS_24H[1]:-0}, \"median\": ${UP_STATS_24H[2]:-0}, \"p95\": ${UP_STATS_24H[3]:-0}}"
            JSTR="$JSTR, \"up_stats_7d\": {\"average\": ${UP_STATS_7D[0]:-0}, \"stddev\": ${UP_STATS_7D[1]:-0}, \"median\": ${UP_STATS_7D[2]:-0}, \"p95\": ${UP_STATS_7D[3]:-0}}"
            JSTR="$JSTR, \"up_stats_30d\": {\"average\": ${UP_STATS_30D[0]:-0}, \"stddev\": ${UP_STATS_30D[1]:-0}, \"median\": ${UP_STATS_30D[2]:-0}, \"p95\": ${UP_STATS_30D[3]:-0}}"
            JSTR="$JSTR, \"up_stats_all\": {\"average\": ${UP_STATS_ALL[0]:-0}, \"stddev\": ${UP_STATS_ALL[1]:-0}, \"median\": ${UP_STATS_ALL[2]:-0}, \"p95\": ${UP_STATS_ALL[3]:-0}}"
        fi
    fi
    
    JSTR="$JSTR, \"unbound\": " 
    if [ "$HAS_UNBOUND" = true ] && [[ "$U_STATUS" != *"Error"* ]]; then 
        U_JSON="{\"status\": \"active\", \"total_hits\": $U_HITS, \"total_miss\": $U_MISS, \"prefetch\": $U_PRE, \"ratio\": $U_PCT_HIT, \"memory\": { \"msg\": { \"used_mb\": $(to_mb $U_MEM_MSG), \"limit_mb\": $(to_mb $U_LIM_MSG), \"percent\": $U_PCT_MEM_MSG }, \"rrset\": { \"used_mb\": $(to_mb $U_MEM_RR), \"limit_mb\": $(to_mb $U_LIM_RR), \"percent\": $U_PCT_MEM_RR } }, \"cache_count\": { \"messages\": ${UCC_MSG:-0}, \"rrsets\": ${UCC_RR:-0} }"
        
        # --- FIXED LINE BELOW ---
        U_JSON="$U_JSON, \"stats\": {\"avg\": $U_AVG_F, \"med\": $U_MED_F, \"std\": ${U_STD:-0.00}, \"p95\": \"${U_P95:-0.00}\"}"
        # ------------------------

        if [ "${H_B1:-0}" != "0" ] || [ "${H_B9:-0}" != "0" ]; then H_JSON=", \"histogram\": {\"b1\": $H_B1, \"b2\": $H_B2, \"b3\": $H_B3, \"b4\": $H_B4, \"b5\": $H_B5, \"b6\": $H_B6, \"b7\": $H_B7, \"b8\": $H_B8, \"b9\": $H_B9 }"; U_JSON="$U_JSON$H_JSON"; fi
        U_JSON="$U_JSON}"; JSTR="$JSTR$U_JSON"
    else JSTR="${JSTR}null"; fi
    
    JSTR="$JSTR}"; echo "$JSTR"
}


# --- 11. EXECUTION ---
if [ "$DEBUG_MODE" = true ]; then
    echo "[$(date)] --- DEBUG SESSION START $VERSION ---" > "$DEBUG_LOG"
    fix_perms "$DEBUG_LOG" "user"
fi

if [ "$SILENT_MODE" = false ] && [ "$SHOW_UNBOUND" != "only" ]; then
    if [ -t 1 ]; then echo -n "📊 Analyzing Pi-hole database... " >&2; tput sc >&2 2>/dev/null; start_spinner; else echo "📊 Analyzing Pi-hole database..." >&2; fi
fi

collect_unbound_async
collect_pihole_stats

if [ "$SILENT_MODE" = false ] && [ "$SHOW_UNBOUND" != "only" ] && [ -n "$SPINNER_PID" ]; then stop_spinner; fi

TEXT_REPORT=$(print_text_report)
if [ "$DO_JSON" = true ]; then JSON_REPORT=$(print_json_report); fi

if [ "$DASH_MODE" = true ] && [ "$DASH_HISTORY" = true ] && [ "$SHOW_UNBOUND" != "only" ]; then
    DIFF_HITS=0; DIFF_MISS=0
    if [ -f "$SNAP_PATH" ]; then
        PREV_HITS=$(grep -o '"total_hits":[[:space:]]*[0-9]\+' "$SNAP_PATH" | tr -d -c 0-9)
        PREV_MISS=$(grep -o '"total_miss":[[:space:]]*[0-9]\+' "$SNAP_PATH" | tr -d -c 0-9)
        if [ -n "$PREV_HITS" ] && [ -n "$PREV_MISS" ]; then
            DIFF_HITS=$((U_HITS - PREV_HITS)); DIFF_MISS=$((U_MISS - PREV_MISS))
            if [ "$DIFF_HITS" -lt 0 ]; then DIFF_HITS=0; fi; if [ "$DIFF_MISS" -lt 0 ]; then DIFF_MISS=0; fi
        fi
    fi
    NEW_ENTRY=$(printf '{"version":"%s","date":"%s","average":%s,"median":%s,"p95":%s,"stddev":%s,"messages":%d,"rrsets":%d,"cache_mb_msg":%s,"cache_mb_rr":%s,"diff_hits":%d,"diff_miss":%d}' "$VERSION" "$(date "+%Y-%m-%d %H:%M:%S")" "$P_AVG" "$P_MED" "$P_95" "$P_STD" "${UCC_MSG:-0}" "${UCC_RR:-0}" "$(to_mb $U_MEM_MSG)" "$(to_mb $U_MEM_RR)" "$DIFF_HITS" "$DIFF_MISS")
    TMP_H=$(mktemp)
    if [ ! -f "$HIST_PATH" ] || [ ! -s "$HIST_PATH" ]; then echo "[$NEW_ENTRY]" > "$TMP_H"
    else (grep -o '{[^}]*}' "$HIST_PATH" 2>/dev/null; echo "$NEW_ENTRY") | tail -n "$MAX_HISTORY_ENTRIES" | tr '\n' ',' | sed 's/,$//; s/^/[/; s/$/]/' > "$TMP_H"; fi
    cat "$TMP_H" > "$HIST_PATH"; rm -f "$TMP_H"; fix_perms "$HIST_PATH" "dash"
fi

if [ "$DASH_MODE" = true ]; then
    if [ ! -d "$(dirname "$SNAP_PATH")" ]; then mkdir -p "$(dirname "$SNAP_PATH")"; fi
    echo "$JSON_REPORT" > "$SNAP_PATH"; fix_perms "$SNAP_PATH" "dash"
else
    if [ "$DO_TXT" = true ] && [ -n "$TXT_FILE" ]; then
        [ "$ADD_TIMESTAMP" = true ] && TS=$(date "+%Y-%m-%d_%H%M") && TXT_FILE="${TXT_FILE%.*}_${TS}.${TXT_FILE##*.}"
        if [ "$SEQUENTIAL" = true ] && [ -f "$TXT_FILE" ]; then
            BASE="${TXT_FILE%.*}"; EXT="${TXT_FILE##*.}"
            CNT=1; while [ -f "${BASE}_${CNT}.${EXT}" ]; do ((CNT++)); done; TXT_FILE="${BASE}_${CNT}.${EXT}"
        fi
        echo "$TEXT_REPORT" > "$TXT_FILE"; fix_perms "$TXT_FILE" "user"
    fi
    if [ "$DO_JSON" = true ] && [ -n "$JSON_FILE" ]; then
        [ "$ADD_TIMESTAMP" = true ] && TS=$(date "+%Y-%m-%d_%H%M") && JSON_FILE="${JSON_FILE%.*}_${TS}.${JSON_FILE##*.}"
        if [ "$SEQUENTIAL" = true ] && [ -f "$JSON_FILE" ]; then
            BASE="${JSON_FILE%.*}"; EXT="${JSON_FILE##*.}"
            CNT=1; while [ -f "${BASE}_${CNT}.${EXT}" ]; do ((CNT++)); done; JSON_FILE="${BASE}_${CNT}.${EXT}"
        fi
        echo "$JSON_REPORT" > "$JSON_FILE"; fix_perms "$JSON_FILE" "user"
    fi
    if [ "$SILENT_MODE" = false ]; then
        if [ "$DO_JSON" = true ] && [ -z "$JSON_FILE" ]; then echo "$JSON_REPORT"
        else echo "$TEXT_REPORT"; fi
    fi
fi

if [ -n "$MAX_LOG_AGE" ] && [[ "$MAX_LOG_AGE" =~ ^[0-9]+$ ]]; then
    CLEANED=false
    if [ -n "$SAVE_DIR_TXT" ] && [ -d "$SAVE_DIR_TXT" ]; then find "$SAVE_DIR_TXT" -maxdepth 1 -type f -mtime +$MAX_LOG_AGE -delete; CLEANED=true; fi
    if [ -n "$SAVE_DIR_JSON" ] && [ -d "$SAVE_DIR_JSON" ]; then find "$SAVE_DIR_JSON" -maxdepth 1 -type f -mtime +$MAX_LOG_AGE -delete; CLEANED=true; fi
    if [ "$CLEANED" = true ] && [ "$SILENT_MODE" = false ]; then echo "Auto-Clean : Checked reports older than $MAX_LOG_AGE days"; fi
fi

if [ "$SILENT_MODE" = false ] && [ "$DASH_MODE" = false ]; then
    if [ "$DO_TXT" = true ] && [ -n "$TXT_FILE" ]; then echo -e "\033[1;36mText Report saved to: $TXT_FILE\033[0m" >&2; fi
    if [ "$DO_JSON" = true ] && [ -n "$JSON_FILE" ]; then echo -e "\033[1;36mJSON Report saved to: $JSON_FILE\033[0m" >&2; fi
fi

END_TS=$(date +%s.%N 2>/dev/null); if [[ "$END_TS" == *N* ]] || [ -z "$END_TS" ]; then END_TS=$(date +%s); fi
DUR=$(awk "BEGIN {printf \"%.2f\", $END_TS - $START_TS}" 2>/dev/null); [ -z "$DUR" ] && DUR=$(( ${END_TS%.*} - ${START_TS%.*} ))
if [ "$SILENT_MODE" = false ]; then echo "Total Execution Time: ${DUR}s" >&2; fi

if [[ -f "$V_LOCAL_FILE" ]]; then
    REMOTE_V=$(grep "^s=" "$V_LOCAL_FILE" | cut -d'=' -f2)
    CLEAN_CUR=$(echo "$VERSION" | sed 's/[^0-9.]//g'); CLEAN_REM=$(echo "$REMOTE_V" | sed 's/[^0-9.]//g')
    if [ "$(printf '%s\n' "$CLEAN_REM" "$CLEAN_CUR" | sort -V | head -n1)" != "$CLEAN_REM" ]; then
        YELLOW='\033[1;33m'; NC='\033[0m'
        UPDATE_MSG=$(printf "${YELLOW}************************************************************${NC}\n${YELLOW}NEW UPDATE AVAILABLE: v${REMOTE_V}${NC}\n${YELLOW}Please visit: https://panoc.github.io/pihole-latency-stats/${NC}\n${YELLOW}************************************************************${NC}\n")
    fi
    if [ "$DEBUG_MODE" = true ]; then echo "Version Check: Local=$CLEAN_CUR, Remote=$CLEAN_REM" >> "$DEBUG_LOG"; fi
fi

if [ "$SILENT_MODE" = false ]; then [ -n "$UPDATE_MSG" ] && printf "\n$UPDATE_MSG" >&2; echo "" >&2; fi
