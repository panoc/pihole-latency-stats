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

VERSION="v4.0"
UPDATE_MSG=""

# --- 0. CRITICAL LOCALE FIX ---
# Force C locale to prevent decimal errors (comma vs dot) in math operations
export LC_ALL=C

# Capture start time
START_TS=$(date +%s.%N 2>/dev/null)
if [[ "$START_TS" == *N* ]] || [ -z "$START_TS" ]; then START_TS=$(date +%s); fi

# --- TRAP: CUSTOM ABORT MESSAGE ---
trap 'echo -e "\n\nProgram aborted by user." >&2; exit 1' INT

# --- LOCKING MECHANISM (Stale Lock Protection) ---
# Defined early to be available globally
check_lock() {
    local profile="${1:-default}"
    local lock_file="/tmp/phls_${profile}.lock"
    
    if [ -f "$lock_file" ]; then
        local pid=$(cat "$lock_file")
        # Check if process is actually running
        if kill -0 "$pid" 2>/dev/null; then
            # Process is alive, this is a real lock
            if [ "$SILENT_MODE" = false ]; then echo "⚠️  Locked by PID $pid (Profile: $profile). Exiting." >&2; fi
            exit 1
        else
            # Process is dead, remove stale lock
            if [ "$DEBUG_MODE" = true ]; then echo "Removing stale lock file for PID $pid" >> "$DEBUG_LOG"; fi
            rm -f "$lock_file"
        fi
    fi
    echo $$ > "$lock_file"
    # Ensure lock is removed on exit
    trap 'rm -f "'"$lock_file"'"' EXIT
}

# --- 1. SETUP & DEFAULTS ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
V_LOCAL_FILE="$(dirname "$0")/version"
DEFAULT_CONFIG="$SCRIPT_DIR/pihole_stats.conf"
PROFILES_DB="$SCRIPT_DIR/profiles.db"
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
MIN_LATENCY_CUTOFF=""
MAX_LATENCY_CUTOFF=""

# Dashboard History Defaults
MAX_HISTORY_ENTRIES="8640"
DASH_DIR="/var/www/html/admin/img/dash"

# --- ANIMATION SETTINGS (Hardcoded) ---
target_time=4.0      # Seconds for one full cycle
width_divider=3      # 1/3 of screen width
char="|"             # Character for the bar

# Default Tiers
L01="0.009"; L02="0.1"; L03="0.5"; L04="1"; L05="10"
L06="50"; L07="120"; L08="300"
L09="600"; L10="1000"; L11=""; L12=""; L13=""; L14=""; L15=""; L16=""; L17=""; L18=""; L19=""; L20=""

# Default Time Range
QUERY_START=0
QUERY_END=$(date +%s)
TIME_LABEL="All Time"

# --- HELPER: FIX PERMISSIONS ---
fix_perms() {
    local target="$1"
    local mode="$2" # Optional: "dash" (force www-data) or "user" (force real user)

    if [ ! -e "$target" ]; then return; fi

    # Mode 1: Dashboard Files (Strictly www-data for web server access)
    if [[ "$mode" == "dash" ]] || [[ "$target" == "$DASH_DIR"* ]]; then
        chown www-data:www-data "$target" 2>/dev/null
        chmod 664 "$target" 2>/dev/null

    # Mode 2: User Files (Strictly SUDO_USER for CLI usability)
    elif [ -n "$SUDO_UID" ] && [ -n "$SUDO_GID" ]; then
        chown "$SUDO_UID:$SUDO_GID" "$target"
        chmod 644 "$target"
    fi
}

# --- 2. CONFIGURATION WRITER ---
write_config() {
    local target_file="$1"

    cat <<EOF > "$target_file"
# ================= PI-HOLE STATS CONFIGURATION =================
DBfile="$DBfile"
SAVE_DIR_TXT="$SAVE_DIR_TXT"
SAVE_DIR_JSON="$SAVE_DIR_JSON"
DASH_DIR="$DASH_DIR"
MAX_HISTORY_ENTRIES="$MAX_HISTORY_ENTRIES"
TXT_NAME="$TXT_NAME"
JSON_NAME="$JSON_NAME"
MAX_LOG_AGE="$MAX_LOG_AGE"
ENABLE_UNBOUND="$ENABLE_UNBOUND"
LAYOUT="$LAYOUT"
DEFAULT_FROM="$DEFAULT_FROM"
DEFAULT_TO="$DEFAULT_TO"
CONFIG_ARGS='$CONFIG_ARGS'
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
MIN_LATENCY_CUTOFF="$MIN_LATENCY_CUTOFF"
MAX_LATENCY_CUTOFF="$MAX_LATENCY_CUTOFF"
EOF
    chmod 644 "$target_file"
    fix_perms "$target_file" "user"
}

create_or_update_config() {
    local input_name="$1"
    
    # Check if this is a path or a profile name
    if [[ "$input_name" == */* ]] || [[ "$input_name" == *.conf ]]; then
        # It's a direct file path
        local target_file="$input_name"
        if [ -f "$target_file" ]; then source "$target_file"; fi
        write_config "$target_file"
        echo "✅ Config updated at: $target_file"
    else
        # It's a profile name -> Create Folder Structure
        local profile_dir="$SCRIPT_DIR/$input_name"
        local target_file="$profile_dir/pihole_stats.conf"
        
        if [ ! -d "$profile_dir" ]; then mkdir -p "$profile_dir"; fi
        fix_perms "$profile_dir" "user"
        
        # Set defaults specific to this profile folder
        SAVE_DIR_TXT="$profile_dir"
        SAVE_DIR_JSON="$profile_dir"
        TXT_NAME="${input_name}.txt"
        JSON_NAME="${input_name}.json"
        
        write_config "$target_file"
        
        # Register in Database
        touch "$PROFILES_DB"
        fix_perms "$PROFILES_DB" "user"
        if ! grep -q "^$input_name|" "$PROFILES_DB"; then
            echo "$input_name|$target_file" >> "$PROFILES_DB"
        fi
        
        echo "✅ Profile '$input_name' created."
        echo "   Folder: $profile_dir"
        echo "   Config: $target_file"
    fi
}

# --- 3. PRE-SCAN FLAGS ---
args_preserve=("$@") 
while [[ $# -gt 0 ]]; do
    case $1 in
        -c|--config) 
            shift
            if [ -z "$1" ]; then echo "❌ Error: Missing config file or profile name."; exit 1; fi
            # DB LOOKUP LOGIC
            if [ -f "$1" ]; then
                CONFIG_TO_LOAD="$1"
            elif [ -f "$PROFILES_DB" ]; then
                # Try to find profile in DB
                DB_PATH=$(grep "^$1|" "$PROFILES_DB" | cut -d'|' -f2 | head -n 1)
                if [ -n "$DB_PATH" ] && [ -f "$DB_PATH" ]; then
                    CONFIG_TO_LOAD="$DB_PATH"
                else
                    echo "❌ Config file or Profile '$1' not found in $PROFILES_DB" >&2; exit 1
                fi
            else
                echo "❌ Config file '$1' not found." >&2; exit 1
            fi
            shift ;;
        -mc|--make-config) shift; create_or_update_config "$1"; exit 0 ;;
        *) shift ;;
    esac
done

# --- 4. LOAD CONFIG ---
if [ -f "$CONFIG_TO_LOAD" ]; then 
    source "$CONFIG_TO_LOAD"
    # Auto-Repair/Update Config
    if ! grep -q "JSON_NAME=" "$CONFIG_TO_LOAD" || ! grep -q "MAX_LATENCY_CUTOFF=" "$CONFIG_TO_LOAD"; then
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
    echo "Pi-hole Latency Stats $VERSION"
    echo "Usage: sudo ./pihole_stats.sh [OPTIONS]"
    echo "  -dash [name]       : Run in Dashboard Mode (Snapshot + History)"
    echo "  -c [file/profile]  : Load config from file OR registered profile name"
    echo "  -mc [name]         : Create new User Profile (creates folder + config)"
    echo "  -nh                : No History (use with -dash)"
    echo "  -clear             : Clear history files for profile"
    echo "  -24h, -7d          : Quick time filter"
    echo "  -from, -to         : Custom date range"
    echo "  -up, -pi, -nx      : Query modes"
    echo "  -dm, -edm          : Domain filter"
    echo "  -j, -f             : Save JSON/Text output"
    echo "  -s                 : Silent mode"
    echo "  -unb, -ucc         : Unbound Stats / Cache Count"
    echo "  -debug             : Enable debug logging"
    exit 0
}

# --- 6. ARGUMENTS ---
MODE="DEFAULT"; EXCLUDE_NX=false; SILENT_MODE=false
DOMAIN_FILTER=""; SQL_DOMAIN_CLAUSE=""; SEQUENTIAL=false; ADD_TIMESTAMP=false
SHOW_UNBOUND="default"; USE_SNAPSHOT=false; ENABLE_UCC=false; DEBUG_MODE=false
DEBUG_LOG="$SCRIPT_DIR/pihole_stats_debug.log"

# Output Logic Variables
DO_JSON=false; JSON_FILE=""
DO_TXT=false; TXT_FILE=""

# Dashboard Specific Flags
DASH_MODE=false; DASH_PROFILE="default"; DASH_HISTORY=true; DASH_CLEAR=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help) show_help ;;
        -c|--config|-mc|--make-config) shift; shift ;;

        # Dashboard Flags
        -dash) 
            DASH_MODE=true; DO_JSON=true; SILENT_MODE=true
            if [[ -n "$2" && "$2" != -* ]]; then DASH_PROFILE="$2"; shift; fi
            # Trigger Lock Check immediately for Dash Mode
            check_lock "$DASH_PROFILE"
            shift ;;
        -nh) DASH_HISTORY=false; shift ;;
        -clear) DASH_CLEAR=true; shift ;;

        # Standard Flags
        -up) [ "$DASH_MODE" = false ] && MODE="UPSTREAM"; shift ;;
        -pi) [ "$DASH_MODE" = false ] && MODE="PIHOLE"; shift ;;
        -nx) [ "$DASH_MODE" = false ] && EXCLUDE_NX=true; shift ;;

        # New Output Logic (-j and -f)
        -j|--json)
            DO_JSON=true
            if [[ -n "$2" && "$2" != -* ]]; then JSON_FILE="$2"; shift; fi
            shift ;;
        -f)
            DO_TXT=true
            if [[ -n "$2" && "$2" != -* ]]; then TXT_FILE="$2"; shift; fi
            shift ;;

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
        -from|--start) 
            if [ "$DASH_MODE" = false ]; then
                shift; QUERY_START=$(date -d "$1" +%s); TIME_LABEL="Custom Range"
            else shift; fi
            shift ;;
        -to|--end) 
            if [ "$DASH_MODE" = false ]; then
                shift; QUERY_END=$(date -d "$1" +%s); TIME_LABEL="Custom Range"
            else shift; fi
            shift ;;
        -dm|--domain) shift; DOMAIN_FILTER="$1"; SANITIZED="${1//\*/%}"; SANITIZED="${SANITIZED//\?/_}"; SQL_DOMAIN_CLAUSE="AND domain LIKE '%$SANITIZED%'"; shift ;;
        -edm|--exact-domain) shift; DOMAIN_FILTER="$1"; SANITIZED="${1//\*/%}"; SANITIZED="${SANITIZED//\?/_}"; SQL_DOMAIN_CLAUSE="AND (domain LIKE '$SANITIZED' OR domain LIKE '%.$SANITIZED')"; shift ;;

        -*)
            if [ "$DASH_MODE" = false ]; then
                INPUT="${1#-}"
                if [[ "$INPUT" =~ ^[0-9]+[hd]$ ]]; then
                    UNIT="${INPUT: -1}"; VALUE="${INPUT:0:${#INPUT}-1}"
                    if [[ "$UNIT" == "h" ]]; then OFFSET=$((VALUE * 3600)); TIME_LABEL="Last $VALUE Hours"; fi
                    if [[ "$UNIT" == "d" ]]; then OFFSET=$((VALUE * 86400)); TIME_LABEL="Last $VALUE Days"; fi
                    QUERY_START=$(( $(date +%s) - OFFSET )); QUERY_END=$(date +%s)
                else echo "❌ Error: Invalid arg '$1'" >&2; exit 1; fi
            fi
            shift ;;
        *) echo "❌ Error: Unknown argument '$1'"; exit 1 ;;
    esac
done

# --- RESOLVE OUTPUT FILENAMES (Inheritance Logic) ---
if [ "$DASH_MODE" = false ]; then
    # 0. Handle Directory Inputs (User provided a folder via -j or -f)
    if [ -n "$JSON_FILE" ]; then
        if [ -d "$JSON_FILE" ] || [[ "$JSON_FILE" == */ ]]; then
            FNAME="${JSON_NAME:-pihole_stats.json}"
            JSON_FILE="${JSON_FILE%/}/$FNAME"
        fi
    fi
    if [ -n "$TXT_FILE" ]; then
        if [ -d "$TXT_FILE" ] || [[ "$TXT_FILE" == */ ]]; then
            FNAME="${TXT_NAME:-pihole_stats.txt}"
            TXT_FILE="${TXT_FILE%/}/$FNAME"
        fi
    fi

    # 1. If -j provided but no file, try to inherit from -f or use default
    if [ "$DO_JSON" = true ] && [ -z "$JSON_FILE" ]; then
        if [ -n "$TXT_FILE" ]; then JSON_FILE="${TXT_FILE%.*}.json"
        elif [ -n "$JSON_NAME" ]; then JSON_FILE="$JSON_NAME"
        else JSON_FILE="$PWD/pihole_stats.json"; fi
    fi

    # 2. If -f provided but no file, try to inherit from -j or use default
    if [ "$DO_TXT" = true ] && [ -z "$TXT_FILE" ]; then
        if [ -n "$JSON_FILE" ]; then TXT_FILE="${JSON_FILE%.*}.txt"
        elif [ -n "$TXT_NAME" ]; then TXT_FILE="$TXT_NAME"
        else TXT_FILE="$PWD/pihole_stats.txt"; fi
    fi

    # 3. Apply Directory Prefixes if path is not absolute
    if [ -n "$JSON_FILE" ] && [[ "$JSON_FILE" != /* ]] && [ -n "$SAVE_DIR_JSON" ]; then 
        mkdir -p "$SAVE_DIR_JSON"; JSON_FILE="$SAVE_DIR_JSON/$JSON_FILE"
    fi
    if [ -n "$TXT_FILE" ] && [[ "$TXT_FILE" != /* ]] && [ -n "$SAVE_DIR_TXT" ]; then 
        mkdir -p "$SAVE_DIR_TXT"; TXT_FILE="$SAVE_DIR_TXT/$TXT_FILE"
    fi
fi
if [ "$DASH_MODE" = false ]; then
    if [ "$TIME_LABEL" == "Custom Range" ]; then TIME_LABEL="$(date -d @$QUERY_START "+%Y-%m-%d %H:%M") to $(date -d @$QUERY_END "+%Y-%m-%d %H:%M")"; fi
    if [ "$LAYOUT" == "auto" ]; then COLS=$(tput cols 2>/dev/null || echo 80); if [ "$COLS" -ge 100 ]; then LAYOUT="horizontal"; else LAYOUT="vertical"; fi; fi
    if [ "$SHOW_UNBOUND" == "only" ]; then LAYOUT="vertical"; fi
fi

# --- 7. DASHBOARD SPECIAL COMMANDS & LOG FIX ---
if [ "$DASH_MODE" = true ]; then
    HIST_PATH="${DASH_DIR}/dash_${DASH_PROFILE}.h.json"
    SNAP_PATH="${DASH_DIR}/dash_${DASH_PROFILE}.json"

    if [ "$DASH_CLEAR" = true ]; then
        echo -n "⚠️  Clear history for profile '$DASH_PROFILE'? [y/N]: "
        read -r confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            rm -f "$HIST_PATH" "$SNAP_PATH"
            echo "✅ Cleared: $SNAP_PATH"
            echo "✅ Cleared: $HIST_PATH"
        else
            echo "Aborted."
        fi
        exit 0
    fi
    # Lock is handled by check_lock()
fi

# DEBUG LOG LOCATION: If running a named profile (custom config), save debug there
if [ "$DEBUG_MODE" = true ]; then
    CONF_DIR="$(dirname "$CONFIG_TO_LOAD")"
    if [[ "$CONF_DIR" != "$SCRIPT_DIR" ]] && [[ "$CONF_DIR" != "/etc/pihole" ]]; then
        # We are in a custom profile folder
        DEBUG_LOG="$CONF_DIR/phls_${DASH_PROFILE:-custom}_debug.log"
    else
        DEBUG_LOG="$SCRIPT_DIR/pihole_stats_debug.log"
    fi
    fix_perms "$DEBUG_LOG" "user"
fi

# --- 8. ANIMATION LOGIC ---
start_spinner() {
    (
        term_cols=$(tput cols 2>/dev/null || echo 80)
        width=$(( term_cols / width_divider ))
        [ "$width" -lt 5 ] && width=5
        start_len=$(( width % 2 == 0 ? 2 : 1 ))
        frames=()
        for (( len=start_len; len<=width; len+=2 )); do
            padding=$(( (width - len) / 2 )); pad=$(printf "%${padding}s")
            printf -v bar_raw "%*s" "$len" ""; bar="${bar_raw// /$char}"
            frames+=("|$pad$bar$pad|")
        done
        for (( len=width-2; len>=start_len; len-=2 )); do
            padding=$(( (width - len) / 2 )); pad=$(printf "%${padding}s")
            printf -v bar_raw "%*s" "$len" ""; bar="${bar_raw// /$char}"
            frames+=("|$pad$bar$pad|")
        done
        interval=$(awk "BEGIN {print $target_time / ${#frames[@]}}")
        tput civis >&2 
        while true; do
            for frame in "${frames[@]}"; do
                tput rc >&2; printf "%s" "$frame" >&2; sleep "$interval"
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
        if [ -t 1 ]; then tput rc >&2; tput el >&2; echo "Finished!" >&2; tput cnorm >&2; else echo "Finished!" >&2; fi
        SPINNER_PID=""
        trap - EXIT
    fi
}

# --- 9. DATA COLLECTION (UNBOUND) ---
U_STATUS="Disabled"; U_TOTAL="0"; U_HITS="0"; U_MISS="0"; U_PRE="0"; 
U_PCT_HIT="0.00"; U_PCT_MISS="0.00"; U_PCT_PRE="0.00"
U_MEM_MSG="0"; U_MEM_RR="0"; U_LIM_MSG="0"; U_LIM_RR="0"
U_PCT_MEM_MSG="0.00"; U_PCT_MEM_RR="0.00"; UCC_MSG="0"; UCC_RR="0"; HAS_UNBOUND=false

collect_unbound_stats() {
    # Initialize safe defaults (0 instead of empty) to prevent JSON errors
    U_HITS="0"; U_MISS="0"; U_PRE="0"; U_TOTAL="0"
    U_PCT_HIT="0.00"; U_PCT_MISS="0.00"; U_PCT_PRE="0.00"
    U_MEM_MSG="0"; U_MEM_RR="0"; U_LIM_MSG="0"; U_LIM_RR="0"
    U_PCT_MEM_MSG="0.00"; U_PCT_MEM_RR="0.00"; UCC_MSG="0"; UCC_RR="0"
    HAS_UNBOUND=false; U_STATUS="Disabled"

    if [ "$SHOW_UNBOUND" == "no" ]; then return; fi

    # 1. Check if binary exists
    if ! command -v unbound-control &> /dev/null; then 
        [ "$SHOW_UNBOUND" == "yes" ] || [ "$SHOW_UNBOUND" == "only" ] && echo "Error: unbound-control not found" >&2
        [ "$DEBUG_MODE" = true ] && echo "[$(date)] Error: unbound-control not found" >> "$DEBUG_LOG"
        return
    fi

    # 2. Check if Auto-Detection is enabled
    if [ "$SHOW_UNBOUND" == "default" ]; then
        if [ "$ENABLE_UNBOUND" == "false" ]; then return; fi
        if [ "$ENABLE_UNBOUND" == "auto" ]; then
            IS_RUNNING=false
            if systemctl is-active --quiet unbound 2>/dev/null || pgrep -x unbound >/dev/null; then IS_RUNNING=true; fi
            if [ "$IS_RUNNING" = false ]; then return; fi
            # Verify Pi-hole is actually using Localhost/Unbound
            if ! grep -qE "PIHOLE_DNS_.*=(127\.0\.0\.1|::1)" /etc/pihole/setupVars.conf 2>/dev/null && \
               ! grep -qE "^server=(127\.0\.0\.1|::1)" /etc/dnsmasq.d/*.conf 2>/dev/null && \
               ! grep -F "127.0.0.1" /etc/pihole/pihole.toml >/dev/null 2>&1; then return; fi
        fi
    fi

    # 3. Attempt to get stats
    RAW_STATS=$(sudo /usr/sbin/unbound-control -c /etc/unbound/unbound.conf stats_noreset 2>&1)
    
    if [ "$DEBUG_MODE" = true ]; then echo "[$(date)] RAW UNBOUND OUTPUT: $RAW_STATS" >> "$DEBUG_LOG"; fi
    
    # 4. SAFETY CHECK: Did it fail?
    if [ -z "$RAW_STATS" ] || echo "$RAW_STATS" | grep -iEq "^error:|connection refused|permission denied|failed"; then
         # It failed, but we keep HAS_UNBOUND=true so the dashboard knows we *tried*.
         # Since values are already init to 0, we just set status.
         HAS_UNBOUND=true
         U_STATUS="Error (Check Perms)"
         [ "$DEBUG_MODE" = true ] && echo "[$(date)] Unbound stats error: $RAW_STATS" >> "$DEBUG_LOG"
         return
    fi

    # 5. Success - Parse Data
    HAS_UNBOUND=true; U_STATUS="Active (Integrated)"
    
    # Extract values safely (default to 0 if grep fails)
    U_HITS=$(echo "$RAW_STATS" | grep '^total.num.cachehits=' | cut -d= -f2); U_HITS=${U_HITS:-0}
    U_MISS=$(echo "$RAW_STATS" | grep '^total.num.cachemiss=' | cut -d= -f2); U_MISS=${U_MISS:-0}
    U_PRE=$(echo "$RAW_STATS" | grep '^total.num.prefetch=' | cut -d= -f2); U_PRE=${U_PRE:-0}
    U_TOTAL=$((U_HITS + U_MISS))

    # Calculate Percentages (avoid division by zero)
    if [ "$U_TOTAL" -gt 0 ]; then
        U_PCT_HIT=$(awk "BEGIN {printf \"%.2f\", ($U_HITS / $U_TOTAL) * 100}")
        U_PCT_MISS=$(awk "BEGIN {printf \"%.2f\", ($U_MISS / $U_TOTAL) * 100}")
    fi
    if [ "$U_HITS" -gt 0 ]; then 
        U_PCT_PRE=$(awk "BEGIN {printf \"%.2f\", ($U_PRE / $U_HITS) * 100}")
    fi

    # Memory Stats
    U_MEM_MSG=$(echo "$RAW_STATS" | grep '^mem.cache.message=' | cut -d= -f2); U_MEM_MSG=${U_MEM_MSG:-0}
    U_MEM_RR=$(echo "$RAW_STATS" | grep '^mem.cache.rrset=' | cut -d= -f2); U_MEM_RR=${U_MEM_RR:-0}
    
    # Limits (Try to fetch, default to safe values if failed)
    U_LIM_MSG=$(sudo /usr/sbin/unbound-checkconf -o msg-cache-size 2>/dev/null || echo "4194304")
    U_LIM_RR=$(sudo /usr/sbin/unbound-checkconf -o rrset-cache-size 2>/dev/null || echo "8388608")
    
    # Calculate Memory Percentages
    if [ "$U_LIM_MSG" -gt 0 ]; then U_PCT_MEM_MSG=$(awk "BEGIN {printf \"%.2f\", ($U_MEM_MSG / $U_LIM_MSG) * 100}"); fi
    if [ "$U_LIM_RR" -gt 0 ]; then U_PCT_MEM_RR=$(awk "BEGIN {printf \"%.2f\", ($U_MEM_RR / $U_LIM_RR) * 100}"); fi

    # 6. UCC (Unbound Cache Count) - Heavy Operation
    if [ "$ENABLE_UCC" = true ]; then
        UCC_ERR_TMP=$(mktemp)
        # Dump cache and count (redirect stderr to temp file)
        eval $(sudo /usr/sbin/unbound-control dump_cache 2> "$UCC_ERR_TMP" | awk '/^msg/ {m++} /^;rrset/ {r++} END {print "UCC_MSG="m+0; print "UCC_RR="r+0}')
        
        if [ "$DEBUG_MODE" = true ] && [ -s "$UCC_ERR_TMP" ]; then
            echo "[$(date)] UCC dump error:" >> "$DEBUG_LOG"; cat "$UCC_ERR_TMP" >> "$DEBUG_LOG"
        fi
        rm -f "$UCC_ERR_TMP"
        # Ensure variables are numbers
        UCC_MSG=${UCC_MSG:-0}; UCC_RR=${UCC_RR:-0}
    fi
}
to_mb() { awk "BEGIN {printf \"%.2f\", $1 / 1024 / 1024}"; }

# --- 10. DATA COLLECTION (PI-HOLE) ---
P_TOTAL=0; P_INVALID=0; P_VALID=0; P_BLOCKED=0; P_ANALYZED=0; P_IGNORED=0
P_AVG="0.00"; P_MED="0.00"; P_95="0.00"; P_STD="0.00"
declare -a TIER_LABELS; declare -a TIER_COUNTS; declare -a TIER_PCTS
declare -a DASH_TIERS_12H; declare -a DASH_TIERS_24H; declare -a DASH_TIERS_7D; declare -a DASH_TIERS_30D

collect_pihole_stats() {
    if [ "$SHOW_UNBOUND" == "only" ]; then return; fi
    if [ ! -r "$DBfile" ] && [ "$USE_SNAPSHOT" = false ]; then
        if [ "$SILENT_MODE" = false ]; then echo "❌ Error: Cannot read database '$DBfile'. (Permission Denied - Try sudo)" >&2; fi
        [ "$DEBUG_MODE" = true ] && echo "[$(date)] DB Access Error: Cannot read $DBfile" >> "$DEBUG_LOG"
        for ((i=0; i<15; i++)); do TIER_COUNTS[$i]=0; TIER_PCTS[$i]="0.00"; done; return
    fi

    # Build Latency Cutoff Condition
    SQL_LATENCY_COND=""
    if [ -n "$MIN_LATENCY_CUTOFF" ]; then MIN_SEC=$(awk "BEGIN {print $MIN_LATENCY_CUTOFF / 1000}"); SQL_LATENCY_COND="AND reply_time >= $MIN_SEC"; fi
    if [ -n "$MAX_LATENCY_CUTOFF" ]; then MAX_SEC=$(awk "BEGIN {print $MAX_LATENCY_CUTOFF / 1000}"); SQL_LATENCY_COND="$SQL_LATENCY_COND AND reply_time <= $MAX_SEC"; fi

    SQL_BLOCKED_DEF="status IN (1, 4, 5, 9, 10, 11)"
    BASE_DEFAULT="2, 3, 6, 7, 8, 12, 13, 14, 15"; BASE_UPSTREAM="2, 6, 7, 8"; BASE_PIHOLE="3, 12, 13, 14, 15"

    if [[ "$MODE" == "UPSTREAM" ]]; then CURRENT_LIST="$BASE_UPSTREAM"; MODE_LABEL="Upstream Only"
    elif [[ "$MODE" == "PIHOLE" ]]; then CURRENT_LIST="$BASE_PIHOLE"; MODE_LABEL="Pi-hole Only"
    else CURRENT_LIST="$BASE_DEFAULT"; MODE_LABEL="All Normal Queries"; fi

    if [ "$EXCLUDE_NX" = true ]; then MODE_LABEL="$MODE_LABEL [Excl. Blocks]"; SQL_STATUS_FILTER="status IN ($CURRENT_LIST)";
    else [[ "$MODE" != "PIHOLE" ]] && SQL_STATUS_FILTER="status IN ($CURRENT_LIST, 16, 17)" || SQL_STATUS_FILTER="status IN ($CURRENT_LIST)"; fi
    SQL_METRIC_FILTER="$SQL_STATUS_FILTER $SQL_LATENCY_COND"

    raw_limits=("$L01" "$L02" "$L03" "$L04" "$L05" "$L06" "$L07" "$L08" "$L09" "$L10" "$L11" "$L12" "$L13" "$L14" "$L15" "$L16" "$L17" "$L18" "$L19" "$L20")
    IFS=$'\n' sorted_limits=($(printf "%s\n" "${raw_limits[@]}" | grep -v '^$' | sort -n)); unset IFS
    if [ ${#sorted_limits[@]} -eq 0 ]; then sorted_limits=("0.009" "0.1" "1" "10" "50" "100" "300" "1000"); fi

    sql_tier_cols=""; prev_ms="0"; prev_sec="0"; idx=0
    TS_NOW=$(date +%s)
    TS_12H=$((TS_NOW - 43200)); TS_24H=$((TS_NOW - 86400)); TS_7D=$((TS_NOW - 604800)); TS_30D=$((TS_NOW - 2592000))

    if [ "$DASH_MODE" = true ]; then QUERY_START="$TS_30D"; QUERY_END="$TS_NOW"; fi

    for ms in "${sorted_limits[@]}"; do
        sec=$(awk "BEGIN {print $ms / 1000}")
        if [ "$idx" -eq 0 ]; then logic="reply_time <= $sec"; lbl="Tier $((idx+1)) (< ${ms}ms)"
        else logic="reply_time > $prev_sec AND reply_time <= $sec"; lbl="Tier $((idx+1)) (${prev_ms} - ${ms}ms)"; fi
        [ -n "$sql_tier_cols" ] && sql_tier_cols="${sql_tier_cols}, "
        sql_tier_cols="${sql_tier_cols} SUM(CASE WHEN ${logic} AND $SQL_METRIC_FILTER THEN 1 ELSE 0 END)"
        if [ "$DASH_MODE" = true ]; then
            sql_tier_cols="${sql_tier_cols}, SUM(CASE WHEN timestamp >= $TS_12H AND ${logic} AND $SQL_METRIC_FILTER THEN 1 ELSE 0 END)"
            sql_tier_cols="${sql_tier_cols}, SUM(CASE WHEN timestamp >= $TS_24H AND ${logic} AND $SQL_METRIC_FILTER THEN 1 ELSE 0 END)"
            sql_tier_cols="${sql_tier_cols}, SUM(CASE WHEN timestamp >= $TS_7D  AND ${logic} AND $SQL_METRIC_FILTER THEN 1 ELSE 0 END)"
            sql_tier_cols="${sql_tier_cols}, SUM(CASE WHEN timestamp >= $TS_30D AND ${logic} AND $SQL_METRIC_FILTER THEN 1 ELSE 0 END)"
        fi
        TIER_LABELS[$idx]="$lbl"; prev_ms="$ms"; prev_sec="$sec"; ((idx++))
    done

    lbl="Tier $((idx+1)) (> ${prev_ms}ms)"
    sql_tier_cols="${sql_tier_cols}, SUM(CASE WHEN reply_time > $prev_sec AND $SQL_METRIC_FILTER THEN 1 ELSE 0 END)"
    if [ "$DASH_MODE" = true ]; then
        sql_tier_cols="${sql_tier_cols}, SUM(CASE WHEN timestamp >= $TS_12H AND reply_time > $prev_sec AND $SQL_METRIC_FILTER THEN 1 ELSE 0 END)"
        sql_tier_cols="${sql_tier_cols}, SUM(CASE WHEN timestamp >= $TS_24H AND reply_time > $prev_sec AND $SQL_METRIC_FILTER THEN 1 ELSE 0 END)"
        sql_tier_cols="${sql_tier_cols}, SUM(CASE WHEN timestamp >= $TS_7D  AND reply_time > $prev_sec AND $SQL_METRIC_FILTER THEN 1 ELSE 0 END)"
        sql_tier_cols="${sql_tier_cols}, SUM(CASE WHEN timestamp >= $TS_30D AND reply_time > $prev_sec AND $SQL_METRIC_FILTER THEN 1 ELSE 0 END)"
    fi
    TIER_LABELS[$idx]="$lbl"

    ACTIVE_DB="$DBfile"; SNAP_FILE="/tmp/pi_snap_$$.db"
    if [ "$USE_SNAPSHOT" = true ]; then
        DB_SZ=$(du -k "$DBfile" | awk '{print $1}')
        FREE_RAM=$(free -k | awk '/^Mem:/{print $7}')
        [ -z "$FREE_RAM" ] && FREE_RAM=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
        if [ "$FREE_RAM" -lt "$((DB_SZ + 51200))" ]; then SNAP_FILE="$HOME/pi_snap_$$.db"; fi
        sqlite3 "$DBfile" ".backup '$SNAP_FILE'" || exit 1
        ACTIVE_DB="$SNAP_FILE"
    fi

    ERR_TMP=$(mktemp)
    SQL_OUT=$(sqlite3 "$ACTIVE_DB" <<EOF 2> "$ERR_TMP"
.mode list
.headers off
.timeout 30000
PRAGMA temp_store = MEMORY; PRAGMA synchronous = OFF;
CREATE TEMP TABLE raw AS SELECT timestamp, status, reply_time FROM queries WHERE timestamp >= $QUERY_START AND timestamp <= $QUERY_END $SQL_DOMAIN_CLAUSE;
CREATE TEMP TABLE mets AS SELECT 
    COUNT(*), SUM(CASE WHEN reply_time IS NULL THEN 1 ELSE 0 END), SUM(CASE WHEN reply_time IS NOT NULL THEN 1 ELSE 0 END),
    SUM(CASE WHEN reply_time IS NOT NULL AND $SQL_BLOCKED_DEF THEN 1 ELSE 0 END), 
    SUM(CASE WHEN reply_time IS NOT NULL AND $SQL_METRIC_FILTER THEN 1 ELSE 0 END),
    SUM(CASE WHEN reply_time IS NOT NULL AND $SQL_METRIC_FILTER THEN reply_time ELSE 0.0 END), 
    SUM(CASE WHEN reply_time IS NOT NULL AND $SQL_METRIC_FILTER THEN reply_time * reply_time ELSE 0.0 END),
    $sql_tier_cols
FROM raw;
SELECT * FROM mets;
SELECT reply_time FROM raw WHERE reply_time IS NOT NULL AND $SQL_METRIC_FILTER ORDER BY reply_time ASC LIMIT 1 OFFSET (SELECT (COUNT(*) - 1) / 2 FROM raw WHERE reply_time IS NOT NULL AND $SQL_METRIC_FILTER);
SELECT reply_time FROM raw WHERE reply_time IS NOT NULL AND $SQL_METRIC_FILTER ORDER BY reply_time ASC LIMIT 1 OFFSET (SELECT CAST((COUNT(*) * 0.95) - 1 AS INT) FROM raw WHERE reply_time IS NOT NULL AND $SQL_METRIC_FILTER);
EOF
)
    if [ -s "$ERR_TMP" ]; then
        ERR_MSG=$(cat "$ERR_TMP")
        if [[ "$ERR_MSG" != *"interrupted"* ]]; then 
            echo "$ERR_MSG" >&2
            [ "$DEBUG_MODE" = true ] && echo "[$(date)] SQLite Error: $ERR_MSG" >> "$DEBUG_LOG"
        fi
    fi
    rm -f "$ERR_TMP"

    IFS='|' read -r -a METS <<< "$(echo "$SQL_OUT" | head -n 1)"
    P_TOTAL=${METS[0]:-0}; P_INVALID=${METS[1]:-0}; P_VALID=${METS[2]:-0}; P_BLOCKED=${METS[3]:-0}; P_ANALYZED=${METS[4]:-0}; P_DUR=${METS[5]:-0}; P_SQ_SUM=${METS[6]:-0}
    P_IGNORED=$((P_VALID - P_BLOCKED - P_ANALYZED))

    if [ "$DASH_MODE" = true ]; then stride=5; else stride=1; fi
    base_idx=7
    for i in "${!TIER_LABELS[@]}"; do
        TIER_COUNTS[$i]=${METS[$base_idx]:-0}
        if [ "$DASH_MODE" = true ]; then
            DASH_TIERS_12H[$i]=${METS[$((base_idx+1))]:-0}; DASH_TIERS_24H[$i]=${METS[$((base_idx+2))]:-0}
            DASH_TIERS_7D[$i]=${METS[$((base_idx+3))]:-0}; DASH_TIERS_30D[$i]=${METS[$((base_idx+4))]:-0}
        fi
        if [ "$P_ANALYZED" -gt 0 ]; then TIER_PCTS[$i]=$(awk "BEGIN {printf \"%.2f\", (${TIER_COUNTS[$i]} / $P_ANALYZED) * 100}"); else TIER_PCTS[$i]="0.00"; fi
        base_idx=$((base_idx + stride))
    done

    if [ "$P_ANALYZED" -gt 0 ]; then 
        P_AVG=$(awk "BEGIN {printf \"%.2f\", ($P_DUR * 1000) / $P_ANALYZED}")
        P_STD=$(awk "BEGIN {mean = $P_DUR / $P_ANALYZED; sq_mean = $P_SQ_SUM / $P_ANALYZED; var = sq_mean - (mean * mean); if (var < 0) var = 0; printf \"%.2f\", sqrt(var) * 1000;}")
    fi

    RAW_MED=$(echo "$SQL_OUT" | sed -n '2p'); RAW_95=$(echo "$SQL_OUT" | sed -n '3p')
    if [ -n "$RAW_MED" ]; then P_MED=$(awk "BEGIN {printf \"%.2f\", $RAW_MED * 1000}"); fi
    if [ -n "$RAW_95" ]; then P_95=$(awk "BEGIN {printf \"%.2f\", $RAW_95 * 1000}"); fi
    if [ "$USE_SNAPSHOT" = true ] && [ -f "$SNAP_FILE" ]; then rm "$SNAP_FILE"; fi
}

# --- 11. RENDERERS ---
print_text_report() {
    CURRENT_DATE=$(date "+%Y-%m-%d %H:%M:%S")
    declare -a L_LINES
    L_LINES+=("Time Period   : $TIME_LABEL"); L_LINES+=("Query Mode    : $MODE_LABEL"); L_LINES+=("-----------------------------------------------------")
    L_LINES+=("Total Queries        : $P_TOTAL")
    if [ "$P_TOTAL" -gt 0 ]; then PCT=$(awk "BEGIN {printf \"%.1f\", ($P_INVALID/$P_TOTAL)*100}"); L_LINES+=("Unsuccessful Queries : $P_INVALID ($PCT%)"); else L_LINES+=("Unsuccessful Queries : 0 (0.0%)"); fi
    L_LINES+=("Total Valid Queries  : $P_VALID")
    if [ "$P_VALID" -gt 0 ]; then
        SUM_BI=$((P_BLOCKED + P_IGNORED))
        if [ "$P_TOTAL" -gt 0 ]; then
            PCT=$(awk "BEGIN {printf \"%.1f\", ($SUM_BI/$P_TOTAL)*100}"); L_LINES+=("Blocked / Ignored    : $P_BLOCKED / $P_IGNORED ($PCT%)")
            PCT=$(awk "BEGIN {printf \"%.1f\", ($P_ANALYZED/$P_TOTAL)*100}"); L_LINES+=("Analyzed Queries     : $P_ANALYZED ($PCT%)")
        else L_LINES+=("Blocked / Ignored    : $P_BLOCKED / $P_IGNORED (0.0%)"); L_LINES+=("Analyzed Queries     : $P_ANALYZED (0.0%)"); fi
    else L_LINES+=("Blocked / Ignored    : 0 / 0"); L_LINES+=("Analyzed Queries     : 0"); fi
    L_LINES+=("Average Latency      : $P_AVG ms"); L_LINES+=("Standard Deviation   : $P_STD ms"); L_LINES+=("Median  Latency      : $P_MED ms"); L_LINES+=("95th Percentile      : $P_95 ms")

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
        TITLE="Pi-hole Latency Stats $VERSION"; PAD=$(( (100 - ${#TITLE}) / 2 )); printf "%${PAD}s%s\n" "" "$TITLE"
        echo "===================================================================================================="
        DATE_STR="Analysis Date : $CURRENT_DATE"; PAD_DATE=$(( (100 - ${#DATE_STR}) / 2 )); printf "%${PAD_DATE}s%s\n" "" "$DATE_STR"
        echo "---------------- Pi-hole Performance ----------------||---------- Unbound DNS Performance ----------"
        MAX=${#L_LINES[@]}; [ ${#R_LINES[@]} -gt $MAX ] && MAX=${#R_LINES[@]}
        for ((i=0; i<MAX; i++)); do printf "%-53s||%s\n" "${L_LINES[$i]}" "${R_LINES[$i]}"; done
        echo "----------------------------------------------------------------------------------------------------"
    else
        echo "========================================================"; echo "              Pi-hole Latency Stats $VERSION"; echo "========================================================"
        echo "Analysis Date : $CURRENT_DATE"
        if [ "$SHOW_UNBOUND" != "only" ]; then echo "Time Period   : $TIME_LABEL"; echo "Query Mode    : $MODE_LABEL"; echo "--------------------------------------------------------"; for line in "${L_LINES[@]}"; do if [[ "$line" != Time* ]] && [[ "$line" != Query* ]] && [[ "$line" != ---* ]]; then echo "$line"; fi; done; echo ""; fi
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
    JSTR="$JSTR, \"stats\": {\"total_queries\": $P_TOTAL, \"unsuccessful\": $P_INVALID, \"total_valid\": $P_VALID, \"blocked\": $P_BLOCKED, \"ignored\": $P_IGNORED, \"analyzed\": $P_ANALYZED}"
    JSTR="$JSTR, \"latency\": {\"average\": $P_AVG, \"median\": $P_MED, \"p95\": $P_95, \"stddev\": $P_STD}"
    JSTR="$JSTR, \"tiers\": ["; FIRST=true
    for i in "${!TIER_LABELS[@]}"; do if [ "$FIRST" = true ]; then FIRST=false; else JSTR="$JSTR, "; fi; JSTR="$JSTR{\"label\": \"${TIER_LABELS[$i]}\", \"count\": ${TIER_COUNTS[$i]}, \"percentage\": ${TIER_PCTS[$i]}}"; done
    JSTR="$JSTR]"

    if [ "$DASH_MODE" = true ]; then
        build_tier_arr() { local -n arr=$1; local out="["; local f=true; for k in "${!arr[@]}"; do [ "$f" = true ] && f=false || out="$out,"; out="$out${arr[$k]}"; done; echo "$out]"; }
        JSTR="$JSTR, \"tiers_12h\": $(build_tier_arr DASH_TIERS_12H)"; JSTR="$JSTR, \"tiers_24h\": $(build_tier_arr DASH_TIERS_24H)"
        JSTR="$JSTR, \"tiers_7d\": $(build_tier_arr DASH_TIERS_7D)"; JSTR="$JSTR, \"tiers_30d\": $(build_tier_arr DASH_TIERS_30D)"
    fi

    JSTR="$JSTR, \"unbound\": "
    if [ "$HAS_UNBOUND" = true ] && [[ "$U_STATUS" != *"Error"* ]]; then
        U_JSON="{\"status\": \"active\", \"total_hits\": $U_HITS, \"total_miss\": $U_MISS, \"prefetch\": $U_PRE, \"ratio\": $U_PCT_HIT, \"memory\": { \"msg\": { \"used_mb\": $(to_mb $U_MEM_MSG), \"limit_mb\": $(to_mb $U_LIM_MSG), \"percent\": $U_PCT_MEM_MSG }, \"rrset\": { \"used_mb\": $(to_mb $U_MEM_RR), \"limit_mb\": $(to_mb $U_LIM_RR), \"percent\": $U_PCT_MEM_RR } }, \"cache_count\": "
        if [ "$ENABLE_UCC" = true ]; then U_JSON="$U_JSON{ \"messages\": $UCC_MSG, \"rrsets\": $UCC_RR }"; else U_JSON="${U_JSON}null"; fi
        U_JSON="$U_JSON}"; JSTR="$JSTR$U_JSON"
    else JSTR="${JSTR}null"; fi
    JSTR="$JSTR}"; echo "$JSTR"
}

# --- 12. EXECUTION ---
if [ "$DEBUG_MODE" = true ]; then echo "[$(date)] --- DEBUG SESSION START $VERSION ---" > "$DEBUG_LOG"; fix_perms "$DEBUG_LOG" "user"; fi

if [ "$SILENT_MODE" = false ] && [ "$SHOW_UNBOUND" != "only" ]; then
    if [ -t 1 ]; then echo -n "📊 Analyzing Pi-hole database... " >&2; tput sc >&2 2>/dev/null; start_spinner; else echo "📊 Analyzing Pi-hole database..." >&2; fi
fi

collect_unbound_stats
collect_pihole_stats

if [ "$SILENT_MODE" = false ] && [ "$SHOW_UNBOUND" != "only" ] && [ -n "$SPINNER_PID" ]; then stop_spinner; fi

TEXT_REPORT=$(print_text_report)
if [ "$DO_JSON" = true ]; then JSON_REPORT=$(print_json_report); fi

if [ "$DASH_MODE" = true ] && [ "$DASH_HISTORY" = true ] && [ "$SHOW_UNBOUND" != "only" ]; then
    DIFF_HITS=0; DIFF_MISS=0
    if [ -f "$SNAP_PATH" ]; then
        PREV_HITS=$(grep -o '"total_hits":[[:space:]]*[0-9]\+' "$SNAP_PATH" | tr -d -c 0-9)
        PREV_MISS=$(grep -o '"total_miss":[[:space:]]*[0-9]\+' "$SNAP_PATH" | tr -d -c 0-9)
        if [ -n "$PREV_HITS" ] && [ -n "$PREV_MISS" ]; then DIFF_HITS=$((U_HITS - PREV_HITS)); DIFF_MISS=$((U_MISS - PREV_MISS)); if [ "$DIFF_HITS" -lt 0 ]; then DIFF_HITS=0; fi; if [ "$DIFF_MISS" -lt 0 ]; then DIFF_MISS=0; fi; fi
    fi
    NEW_ENTRY=$(printf '{"version":"%s","date":"%s","average":%s,"median":%s,"p95":%s,"stddev":%s,"messages":%d,"rrsets":%d,"cache_mb_msg":%s,"cache_mb_rr":%s,"diff_hits":%d,"diff_miss":%d}' "$VERSION" "$(date "+%Y-%m-%d %H:%M:%S")" "$P_AVG" "$P_MED" "$P_95" "$P_STD" "$UCC_MSG" "$UCC_RR" "$(to_mb $U_MEM_MSG)" "$(to_mb $U_MEM_RR)" "$DIFF_HITS" "$DIFF_MISS")
    TMP_H=$(mktemp)
    if [ ! -f "$HIST_PATH" ] || [ ! -s "$HIST_PATH" ]; then echo "[$NEW_ENTRY]" > "$TMP_H"; else (grep -o '{[^}]*}' "$HIST_PATH" 2>/dev/null; echo "$NEW_ENTRY") | tail -n "$MAX_HISTORY_ENTRIES" | tr '\n' ',' | sed 's/,$//; s/^/[/; s/$/]/' > "$TMP_H"; fi
    mv "$TMP_H" "$HIST_PATH"; fix_perms "$HIST_PATH" "dash"
fi

if [ "$DASH_MODE" = true ]; then
    echo "$JSON_REPORT" > "$SNAP_PATH"; fix_perms "$SNAP_PATH" "dash"
else
    if [ "$DO_TXT" = true ] && [ -n "$TXT_FILE" ]; then
        [ "$ADD_TIMESTAMP" = true ] && TS=$(date "+%Y-%m-%d_%H%M") && TXT_FILE="${TXT_FILE%.*}_${TS}.${TXT_FILE##*.}"
        if [ "$SEQUENTIAL" = true ] && [ -f "$TXT_FILE" ]; then BASE="${TXT_FILE%.*}"; EXT="${TXT_FILE##*.}"; CNT=1; while [ -f "${BASE}_${CNT}.${EXT}" ]; do ((CNT++)); done; TXT_FILE="${BASE}_${CNT}.${EXT}"; fi
        echo "$TEXT_REPORT" > "$TXT_FILE"; fix_perms "$TXT_FILE" "user"
    fi
    if [ "$DO_JSON" = true ] && [ -n "$JSON_FILE" ]; then
        [ "$ADD_TIMESTAMP" = true ] && TS=$(date "+%Y-%m-%d_%H%M") && JSON_FILE="${JSON_FILE%.*}_${TS}.${JSON_FILE##*.}"
        if [ "$SEQUENTIAL" = true ] && [ -f "$JSON_FILE" ]; then BASE="${JSON_FILE%.*}"; EXT="${JSON_FILE##*.}"; CNT=1; while [ -f "${BASE}_${CNT}.${EXT}" ]; do ((CNT++)); done; JSON_FILE="${BASE}_${CNT}.${EXT}"; fi
        echo "$JSON_REPORT" > "$JSON_FILE"; fix_perms "$JSON_FILE" "user"
    fi
    if [ "$SILENT_MODE" = false ]; then
        if [ "$JSON_OUTPUT" = true ] && [ -z "$JSON_FILE" ]; then echo "$JSON_REPORT"; else echo "$TEXT_REPORT"; fi
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
fi
if [ "$SILENT_MODE" = false ]; then [ -n "$UPDATE_MSG" ] && printf "\n$UPDATE_MSG" >&2; echo "" >&2; fi