#!/bin/bash
VERSION="2.6.4"
# Capture start time immediately
START_TS=$(date +%s.%N 2>/dev/null)
# Fallback for systems without nanosecond support
if [[ "$START_TS" == *N* ]] || [ -z "$START_TS" ]; then START_TS=$(date +%s); fi

# --- 1. SETUP & DEFAULTS ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
DEFAULT_CONFIG="$SCRIPT_DIR/pihole_stats.conf"
CONFIG_TO_LOAD="$DEFAULT_CONFIG"

# Default Internal Values
DBfile="/etc/pihole/pihole-FTL.db"
SAVE_DIR=""
CONFIG_ARGS=""
MAX_LOG_AGE=""  # Default: Disabled
ENABLE_UNBOUND="auto" # Options: auto, true, false
DEFAULT_FROM="" 
DEFAULT_TO=""

# Default Time Range (0 to Now)
QUERY_START=0
QUERY_END=$(date +%s)
TIME_LABEL="All Time"

# Default Tiers
L01="0.009"; L02="0.1"; L03="1"; L04="10"; L05="50"
L06="100"; L07="300"; L08="1000"

# --- 2. CONFIGURATION GENERATOR ---
create_config() {
    local target_file="$1"
    if [ -f "$target_file" ]; then
        echo "Error: File '$target_file' already exists."
        exit 1
    fi
    echo "Creating configuration file at: $target_file"
    cat <<EOF > "$target_file"
# ================= PI-HOLE STATS CONFIGURATION =================
DBfile="/etc/pihole/pihole-FTL.db"

# Default Save Directory (REQUIRED for Auto-Deletion to work)
# Example: SAVE_DIR="/home/pi/pihole_reports"
SAVE_DIR=""

# Auto-Delete Old Reports (Retention Policy)
# Delete files in SAVE_DIR older than X days.
# Example: MAX_LOG_AGE="30"
MAX_LOG_AGE=""

# Unbound Integration
# auto  : Check if Unbound is installed & used by Pi-hole.
# true  : Always append Unbound stats.
# false : Never show Unbound stats (unless -unb is used).
ENABLE_UNBOUND="auto"

# Custom Date Range Defaults (Optional)
# Use natural language (e.g. "yesterday", "today 00:00") or dates.
# CLI flags (-24h, -from) will OVERRIDE these settings.
DEFAULT_FROM=""
DEFAULT_TO=""

# [OPTIONAL] Default Arguments
# If set, these arguments will REPLACE any CLI flags.
# Use single quotes if your arguments contain filenames with spaces.
# Example: CONFIG_ARGS='-up -24h -j -f "my stats.json"'
CONFIG_ARGS=""

# Latency Tiers (Upper Limits in Milliseconds)
L01="0.009"
L02="0.1"
L03="1"
L04="10"
L05="50"
L06="100"
L07="300"
L08="1000"
L09=""
L10=""
L11=""
L12=""
L13=""
L14=""
L15=""
L16=""
L17=""
L18=""
L19=""
L20=""
EOF
    chmod 644 "$target_file"
    echo "Done. Use with: -c \"$target_file\""
}

# --- 3. PRE-SCAN FLAGS ---
args_preserve=("$@") 
while [[ $# -gt 0 ]]; do
    case $1 in
        -c|--config) shift; CONFIG_TO_LOAD="$1"; shift ;;
        -mc|--make-config) shift; create_config "$1"; exit 0 ;;
        *) shift ;;
    esac
done

# --- 4. LOAD CONFIG & APPLY PROFILE ---
if [ -f "$CONFIG_TO_LOAD" ]; then 
    source "$CONFIG_TO_LOAD"
elif [ "$CONFIG_TO_LOAD" == "$DEFAULT_CONFIG" ]; then
    create_config "$DEFAULT_CONFIG" > /dev/null; source "$DEFAULT_CONFIG"
else 
    echo "Error: Config not found: $CONFIG_TO_LOAD"; exit 1; 
fi

# Apply Config Defaults for Date Ranges
if [ -n "$DEFAULT_FROM" ]; then
    if TS=$(date -d "$DEFAULT_FROM" +%s 2>/dev/null); then
        QUERY_START="$TS"; TIME_LABEL="Custom Range"
    else
        echo "⚠️ Warning: Invalid DEFAULT_FROM in config: '$DEFAULT_FROM'" >&2
    fi
fi

if [ -n "$DEFAULT_TO" ]; then
    if TS=$(date -d "$DEFAULT_TO" +%s 2>/dev/null); then
        QUERY_END="$TS"; TIME_LABEL="Custom Range"
    else
        echo "⚠️ Warning: Invalid DEFAULT_TO in config: '$DEFAULT_TO'" >&2
    fi
fi

if [ -n "$CONFIG_ARGS" ]; then
    eval set -- "$CONFIG_ARGS"
else
    set -- "${args_preserve[@]}"
fi

# --- 5. HELP ---
show_help() {
    echo "Pi-hole Latency Analysis v$VERSION"
    echo "Usage: sudo ./pihole_stats.sh [OPTIONS]"
    echo "  -24h, -7d        : Quick time filter"
    echo "  -from, -to       : Custom date range (e.g. -from 'yesterday')"
    echo "  -up, -pi, -nx    : Query modes (Upstream/Pihole/NoBlock)"
    echo "  -dm, -edm        : Domain filter (Partial/Exact)"
    echo "  -f <file>        : Save to file"
    echo "  -j               : Enable JSON output"
    echo "  -s, --silent     : No screen output"
    echo "  -seq, -ts        : Naming (Sequential/Timestamp)"
    echo "  -rt <days>       : Auto-delete files older than <days>"
    echo "  -unb, -unb-only  : Unbound Stats (Append / Standalone)"
    echo "  -no-unb          : Disable Unbound Stats (Override auto/config)"
    echo "  -snap            : Snapshot Mode (Safe copy of DB to /tmp)"
    echo "  -c, -mc          : Config (Load/Make)"
    echo "  -db              : Custom DB path"
    exit 0
}

# --- 6. ARGUMENTS ---
MODE="DEFAULT"
EXCLUDE_NX=false
OUTPUT_FILE=""
JSON_OUTPUT=false
SILENT_MODE=false
DOMAIN_FILTER=""
SQL_DOMAIN_CLAUSE=""
SEQUENTIAL=false
ADD_TIMESTAMP=false
SHOW_UNBOUND="default" # default, yes, only, no
USE_SNAPSHOT=false

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
        
        # --- DATE PARSING ---
        -from|--start)
            shift; [ -z "$1" ] && echo "❌ Error: Missing value for -from" >&2 && exit 1
            if ! TS=$(date -d "$1" +%s 2>/dev/null); then
                echo "❌ Error: Invalid date format '$1'" >&2; exit 1
            fi
            QUERY_START="$TS"; TIME_LABEL="Custom Range"
            shift ;;
        -to|--end)
            shift; [ -z "$1" ] && echo "❌ Error: Missing value for -to" >&2 && exit 1
            if ! TS=$(date -d "$1" +%s 2>/dev/null); then
                echo "❌ Error: Invalid date format '$1'" >&2; exit 1
            fi
            QUERY_END="$TS"; TIME_LABEL="Custom Range"
            shift ;;

        -dm|--domain)
            shift; [ -z "$1" ] && exit 1
            RAW_INPUT="$1"; DOMAIN_FILTER="$RAW_INPUT"
            SANITIZED="${RAW_INPUT//\*/%}"; SANITIZED="${SANITIZED//\?/_}"
            SQL_DOMAIN_CLAUSE="AND domain LIKE '%$SANITIZED%'"
            shift ;;
        -edm|--exact-domain)
            shift; [ -z "$1" ] && exit 1
            RAW_INPUT="$1"; DOMAIN_FILTER="$RAW_INPUT"
            SANITIZED="${RAW_INPUT//\*/%}"; SANITIZED="${SANITIZED//\?/_}"
            SQL_DOMAIN_CLAUSE="AND (domain LIKE '$SANITIZED' OR domain LIKE '%.$SANITIZED')"
            shift ;;
        -f) shift; OUTPUT_FILE="$1"; shift ;;
        -*)
            # ARGUMENT VALIDATION
            INPUT="${1#-}"
            if [[ ! "$INPUT" =~ ^[0-9]+[hd]$ ]]; then
                echo "❌ Error: Unknown or invalid argument '$1'" >&2
                exit 1
            fi

            # Proceed if valid time filter
            UNIT="${INPUT: -1}"; VALUE="${INPUT:0:${#INPUT}-1}"
            if [[ "$UNIT" == "h" ]]; then OFFSET=$((VALUE * 3600)); TIME_LABEL="Last $VALUE Hours"
            elif [[ "$UNIT" == "d" ]]; then OFFSET=$((VALUE * 86400)); TIME_LABEL="Last $VALUE Days"
            fi
            # Set Start Time relative to Now
            QUERY_START=$(( $(date +%s) - OFFSET ))
            # If user uses quick flags (-24h), reset End Time to Now
            QUERY_END=$(date +%s)
            shift ;;
        *) echo "❌ Error: Unknown argument '$1'"; exit 1 ;;
    esac
done

# Update Label if Custom Date was used
if [ "$TIME_LABEL" == "Custom Range" ]; then
    readable_start=$(date -d @$QUERY_START "+%Y-%m-%d %H:%M")
    readable_end=$(date -d @$QUERY_END "+%Y-%m-%d %H:%M")
    TIME_LABEL="$readable_start to $readable_end"
fi

# --- 7. SQL FILTERS ---
SQL_BLOCKED_DEF="status IN (1, 4, 5, 9, 10, 11)"
BASE_DEFAULT="2, 3, 6, 7, 8, 12, 13, 14, 15"
BASE_UPSTREAM="2, 6, 7, 8"
BASE_PIHOLE="3, 12, 13, 14, 15"

if [[ "$MODE" == "UPSTREAM" ]]; then CURRENT_LIST="$BASE_UPSTREAM"; MODE_LABEL="Upstream Only"
elif [[ "$MODE" == "PIHOLE" ]]; then CURRENT_LIST="$BASE_PIHOLE"; MODE_LABEL="Pi-hole Only"
else CURRENT_LIST="$BASE_DEFAULT"; MODE_LABEL="All Normal Queries"; fi

if [ "$EXCLUDE_NX" = true ]; then
    MODE_LABEL="$MODE_LABEL [Excl. Blocks]"
    SQL_STATUS_FILTER="status IN ($CURRENT_LIST)"
else
    [[ "$MODE" != "PIHOLE" ]] && SQL_STATUS_FILTER="status IN ($CURRENT_LIST, 16, 17)" || SQL_STATUS_FILTER="status IN ($CURRENT_LIST)"
fi

[ ! -x "$(command -v sqlite3)" ] && echo "Error: sqlite3 required" && exit 1

# --- 8. UNBOUND STATS GENERATOR ---
generate_unbound_report() {
    if [ "$SHOW_UNBOUND" == "no" ]; then return; fi

    # Check Requirements
    if ! command -v unbound-control &> /dev/null; then
        if [ "$SHOW_UNBOUND" == "only" ]; then
             echo "Error: unbound-control not found." && exit 1
        elif [ "$SHOW_UNBOUND" == "yes" ]; then
             echo "SELECT '=========================================================';"
             echo "SELECT '              Unbound DNS Performance';"
             echo "SELECT '=========================================================';"
             echo "SELECT '❌ Error: Unbound requested (-unb) but unbound-control not found.';"
             echo "SELECT '=========================================================';"
        fi
        return
    fi
    
    # Auto-Detection Logic
    if [ "$SHOW_UNBOUND" == "default" ]; then
        if [ "$ENABLE_UNBOUND" == "false" ]; then return; fi
        if [ "$ENABLE_UNBOUND" == "auto" ]; then
            IS_RUNNING=false
            if systemctl is-active --quiet unbound 2>/dev/null; then IS_RUNNING=true;
            elif pgrep -x unbound >/dev/null; then IS_RUNNING=true; fi
            if [ "$IS_RUNNING" = false ]; then return; fi

            IS_CONFIGURED=false
            if grep -qE "PIHOLE_DNS_.*=(127\.0\.0\.1|::1)" /etc/pihole/setupVars.conf 2>/dev/null; then IS_CONFIGURED=true; fi
            if grep -qE "^server=(127\.0\.0\.1|::1)" /etc/dnsmasq.d/*.conf 2>/dev/null; then IS_CONFIGURED=true; fi
            if [ -f "/etc/pihole/pihole.toml" ]; then
                if grep -F "127.0.0.1" /etc/pihole/pihole.toml >/dev/null 2>&1; then IS_CONFIGURED=true; fi
                if grep -F "::1" /etc/pihole/pihole.toml >/dev/null 2>&1; then IS_CONFIGURED=true; fi
            fi

            if [ "$IS_CONFIGURED" = false ]; then return; fi
        fi
    fi

    # Retrieve Stats
    # Explicit config path to avoid missing SSL cert errors
    RAW_STATS=$(unbound-control -c /etc/unbound/unbound.conf stats_noreset 2>&1)
    
    if [ -z "$RAW_STATS" ] || echo "$RAW_STATS" | grep -q "error"; then
         if [ "$SHOW_UNBOUND" == "only" ]; then
             echo "Error: Could not retrieve Unbound stats."
             echo "Unbound Output: $RAW_STATS"
             exit 1
         elif [ "$SHOW_UNBOUND" == "yes" ]; then
             CLEAN_ERR=$(echo "$RAW_STATS" | tr -d "'")
             echo "SELECT '=========================================================';"
             echo "SELECT '              Unbound DNS Performance';"
             echo "SELECT '=========================================================';"
             echo "SELECT '❌ Error: Could not retrieve stats.';"
             echo "SELECT 'Detail: $CLEAN_ERR';"
             echo "SELECT '=========================================================';"
         fi
         return
    fi

    # Parse Metrics
    U_HITS=$(echo "$RAW_STATS" | grep '^total.num.cachehits=' | cut -d= -f2)
    U_MISS=$(echo "$RAW_STATS" | grep '^total.num.cachemiss=' | cut -d= -f2)
    U_PREFETCH=$(echo "$RAW_STATS" | grep '^total.num.prefetch=' | cut -d= -f2)
    
    U_HITS=${U_HITS:-0}
    U_MISS=${U_MISS:-0}
    U_PREFETCH=${U_PREFETCH:-0}
    
    U_TOTAL=$((U_HITS + U_MISS))

    if [ "$U_TOTAL" -gt 0 ]; then
        PCT_HIT=$(awk "BEGIN {printf \"%.2f\", ($U_HITS / $U_TOTAL) * 100}")
        PCT_MISS=$(awk "BEGIN {printf \"%.2f\", ($U_MISS / $U_TOTAL) * 100}")
    else
        PCT_HIT="0.00"
        PCT_MISS="0.00"
    fi

    if [ "$U_HITS" -gt 0 ]; then
        PCT_PREFETCH=$(awk "BEGIN {printf \"%.2f\", ($U_PREFETCH / $U_HITS) * 100}")
    else
        PCT_PREFETCH="0.00"
    fi

    U_MEM_MSG=$(echo "$RAW_STATS" | grep '^mem.cache.message=' | cut -d= -f2)
    U_MEM_RR=$(echo "$RAW_STATS" | grep '^mem.cache.rrset=' | cut -d= -f2)
    U_MEM_MSG=${U_MEM_MSG:-0}
    U_MEM_RR=${U_MEM_RR:-0}

    CONF_LIMIT_MSG=$(unbound-checkconf -o msg-cache-size 2>/dev/null || echo "4194304")
    CONF_LIMIT_RR=$(unbound-checkconf -o rrset-cache-size 2>/dev/null || echo "8388608")

    to_mb() {
        awk "BEGIN {printf \"%.2f\", $1 / 1024 / 1024}"
    }
    
    MEM_MSG_PCT=$(awk "BEGIN {printf \"%.2f\", ($U_MEM_MSG / $CONF_LIMIT_MSG) * 100}")
    MEM_RR_PCT=$(awk "BEGIN {printf \"%.2f\", ($U_MEM_RR / $CONF_LIMIT_RR) * 100}")

    # --- OUTPUT BUILDER ---
    
    echo "SELECT '=========================================================';"
    echo "SELECT '              Unbound DNS Performance';"
    echo "SELECT '=========================================================';"
    echo "SELECT 'Server Status     : Active (Integrated)';"
    echo "SELECT 'Config File       : /etc/unbound/unbound.conf';"
    echo "SELECT '---------------------------------------------------------';"
    echo "SELECT 'Total Queries     : ' || '$U_TOTAL';"
    echo "SELECT 'Cache Hits        : ' || '$U_HITS ($PCT_HIT%)';"
    echo "SELECT 'Cache Misses      : ' || '$U_MISS ($PCT_MISS%)';"
    echo "SELECT 'Prefetch Jobs     : ' || '$U_PREFETCH ($PCT_PREFETCH% of Hits)';"
    echo "SELECT '';"
    echo "SELECT '       --- Cache Memory Usage (Used / Limit) ---';"
    echo "SELECT 'Message Cache     : ' || '$(to_mb $U_MEM_MSG) MB / $(to_mb $CONF_LIMIT_MSG) MB   ($MEM_MSG_PCT%)';"
    echo "SELECT 'RRset Cache       : ' || '$(to_mb $U_MEM_RR) MB / $(to_mb $CONF_LIMIT_RR) MB  ($MEM_RR_PCT%)';"
    echo "SELECT '=========================================================';"

    if [ "$JSON_OUTPUT" = true ]; then
        echo "SELECT '___JSON_UNB_START___';"
        echo "SELECT '{ \"status\": \"active\", \"total\": $U_TOTAL, \"hits\": $U_HITS, \"miss\": $U_MISS, \"prefetch\": $U_PREFETCH, \"ratio\": $PCT_HIT, \"memory\": { \"msg\": { \"used_mb\": $(to_mb $U_MEM_MSG), \"limit_mb\": $(to_mb $CONF_LIMIT_MSG), \"percent\": $MEM_MSG_PCT }, \"rrset\": { \"used_mb\": $(to_mb $U_MEM_RR), \"limit_mb\": $(to_mb $CONF_LIMIT_RR), \"percent\": $MEM_RR_PCT } } }';"
        echo "SELECT '___JSON_UNB_END___';"
    fi
}

# --- 9. PIHOLE STATS GENERATOR ---
generate_report() {
    # Skip if Unbound-Only mode
    if [ "$SHOW_UNBOUND" == "only" ]; then
        generate_unbound_report
        return
    fi

    CURRENT_DATE=$(date "+%Y-%m-%d %H:%M:%S")

    # Sort Tiers
    raw_limits=("$L01" "$L02" "$L03" "$L04" "$L05" "$L06" "$L07" "$L08" "$L09" "$L10" \
                "$L11" "$L12" "$L13" "$L14" "$L15" "$L16" "$L17" "$L18" "$L19" "$L20")
    IFS=$'\n' sorted_limits=($(printf "%s\n" "${raw_limits[@]}" | grep -v '^$' | sort -n))
    unset IFS

    # Build Dynamic SQL for Tiers
    # FIX v2.7.2: Logic changed to prevent trailing commas in SQL syntax for older SQLite versions
    sql_tier_columns=""
    sql_text_rows=""
    sql_json_rows=""
    prev_limit_ms="0"; prev_limit_sec="0"; tier_index=0
    declare -a labels

    for limit_ms in "${sorted_limits[@]}"; do
        limit_sec=$(awk "BEGIN {print $limit_ms / 1000}")
        if [ "$tier_index" -eq 0 ]; then
            labels[$tier_index]="Tier ${tier_index} (< ${limit_ms}ms)"
            sql_logic="reply_time <= $limit_sec"
        else
            labels[$tier_index]="Tier ${tier_index} (${prev_limit_ms} - ${limit_ms}ms)"
            sql_logic="reply_time > $prev_limit_sec AND reply_time <= $limit_sec"
        fi
        
        # Append comma only if list is not empty
        [ -n "$sql_tier_columns" ] && sql_tier_columns="${sql_tier_columns}, "
        sql_tier_columns="${sql_tier_columns} SUM(CASE WHEN ${sql_logic} AND $SQL_STATUS_FILTER THEN 1 ELSE 0 END) as t${tier_index}"
        
        prev_limit_ms="$limit_ms"; prev_limit_sec="$limit_sec"; ((tier_index++))
    done

    labels[$tier_index]="Tier ${tier_index} (> ${prev_limit_ms}ms)"
    # Append final column
    [ -n "$sql_tier_columns" ] && sql_tier_columns="${sql_tier_columns}, "
    sql_tier_columns="${sql_tier_columns} SUM(CASE WHEN reply_time > $prev_limit_sec AND $SQL_STATUS_FILTER THEN 1 ELSE 0 END) as t${tier_index}"

    max_len=0
    for lbl in "${labels[@]}"; do len=${#lbl}; [ $len -gt $max_len ] && max_len=$len; done
    max_len=$((max_len + 2))

    for i in "${!labels[@]}"; do
        sql_text_rows="${sql_text_rows} SELECT printf('%-${max_len}s : ', '${labels[$i]}') || printf('%6.2f%%', (t${i} * 100.0 / analyzed_count)) || '  (' || t${i} || ')' FROM combined_metrics;"
        this_json="SELECT '{\"label\": \"${labels[$i]}\", \"count\": ' || t${i} || ', \"percentage\": ' || printf('%.2f', (t${i} * 100.0 / analyzed_count)) || '}' FROM combined_metrics"
        [ -z "$sql_json_rows" ] && sql_json_rows="$this_json" || sql_json_rows="${sql_json_rows} UNION ALL SELECT ',' UNION ALL $this_json"
    done

    # SQL Strings
    TEXT_DOMAIN_ROW=""
    JSON_DOMAIN_ROW=""
    if [ -n "$DOMAIN_FILTER" ]; then
        TEXT_DOMAIN_ROW="SELECT 'Domain Filter : $DOMAIN_FILTER';"
        JSON_DOMAIN_ROW="'\"domain_filter\": \"$DOMAIN_FILTER\", ' ||"
    fi

    # Capture Unbound SQL (if needed)
    UNBOUND_SQL_BLOCK=$(generate_unbound_report)

    TEXT_REPORT_SQL="
        SELECT '=========================================================';
        SELECT '              Pi-hole Latency Analysis v$VERSION';
        SELECT '=========================================================';
        SELECT 'Analysis Date : $CURRENT_DATE';
        SELECT 'Time Period   : $TIME_LABEL';
        SELECT 'Query Mode    : $MODE_LABEL';
        $TEXT_DOMAIN_ROW
        SELECT '---------------------------------------------------------';
        SELECT 'Total Queries         : ' || total_queries FROM combined_metrics;
        SELECT 'Unsuccessful Queries  : ' || invalid_count || ' (' || printf('%.1f', (invalid_count * 100.0 / total_queries)) || '%) ' FROM combined_metrics;
        SELECT 'Total Valid Queries   : ' || valid_count FROM combined_metrics;
        SELECT 'Blocked Queries       : ' ||