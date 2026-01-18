#!/bin/bash
VERSION="2.6.1"
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
DEFAULT_FROM="" # New in v2.9.1
DEFAULT_TO=""   # New in v2.9.1

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

# Apply Config Defaults for Date Ranges (v2.9.1)
if [ -n "$DEFAULT_FROM" ]; then
    if TS=$(date -d "$DEFAULT_FROM" +%s 2>/dev/null); then
        QUERY_START="$TS"
        TIME_LABEL="Custom Range"
    else
        echo "⚠️ Warning: Invalid DEFAULT_FROM in config: '$DEFAULT_FROM'" >&2
    fi
fi

if [ -n "$DEFAULT_TO" ]; then
    if TS=$(date -d "$DEFAULT_TO" +%s 2>/dev/null); then
        QUERY_END="$TS"
        TIME_LABEL="Custom Range"
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
            # If user uses quick flags (-24h), reset End Time to Now (in case config set a static end time)
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
    # Force Disable Check
    if [ "$SHOW_UNBOUND" == "no" ]; then return; fi

    # Check Requirements
    if ! command -v unbound-control &> /dev/null; then
        [ "$SHOW_UNBOUND" == "only" ] && echo "Error: unbound-control not found." && exit 1
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
        sql_tier_columns="${sql_tier_columns} SUM(CASE WHEN ${sql_logic} AND $SQL_STATUS_FILTER THEN 1 ELSE 0 END) as t${tier_index},"
        prev_limit_ms="$limit_ms"; prev_limit_sec="$limit_sec"; ((tier_index++))
    done

    labels[$tier_index]="Tier ${tier_index} (> ${prev_limit_ms}ms)"
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
        SELECT 'Blocked Queries       : ' || blocked_count || ' (' || printf('%.1f', (blocked_count * 100.0 / valid_count)) || '%) ' FROM combined_metrics;
        SELECT 'Other/Ignored Queries : ' || ignored_count || ' (' || printf('%.1f', (ignored_count * 100.0 / valid_count)) || '%) ' FROM combined_metrics WHERE ignored_count > 0;
        SELECT 'Analyzed Queries      : ' || analyzed_count || ' (' || printf('%.1f', (analyzed_count * 100.0 / valid_count)) || '%) ' FROM combined_metrics;
        SELECT 'Average Latency       : ' || printf('%.2f ms', (total_duration * 1000.0 / analyzed_count)) FROM combined_metrics WHERE analyzed_count > 0;
        SELECT 'Median  Latency       : ' || printf('%.2f ms', (reply_time * 1000.0)) FROM analyzed_times LIMIT 1 OFFSET (SELECT (COUNT(*) - 1) / 2 FROM analyzed_times);
        SELECT '95th Percentile       : ' || printf('%.2f ms', (reply_time * 1000.0)) FROM analyzed_times LIMIT 1 OFFSET (SELECT CAST((COUNT(*) * 0.95) - 1 AS INT) FROM analyzed_times);
        SELECT '';
        SELECT '--- Latency Distribution of Analyzed Queries ---';
        $sql_text_rows
        SELECT '';
        $UNBOUND_SQL_BLOCK"

    JSON_REPORT_SQL=""
    if [ "$JSON_OUTPUT" = true ]; then
        JSON_REPORT_SQL="
        SELECT '___JSON_START___';
        SELECT '{' ||
            '\"version\": \"$VERSION\", ' ||
            '\"date\": \"$CURRENT_DATE\", ' ||
            '\"time_period\": \"$TIME_LABEL\", ' ||
            '\"mode\": \"$MODE_LABEL\", ' ||
            $JSON_DOMAIN_ROW
            '\"stats\": {' ||
                '\"total_queries\": ' || total_queries || ', ' ||
                '\"unsuccessful\": ' || invalid_count || ', ' ||
                '\"total_valid\": ' || valid_count || ', ' ||
                '\"blocked\": ' || blocked_count || ', ' ||
                '\"analyzed\": ' || analyzed_count || 
            '}, ' ||
            '\"latency\": {' ||
                '\"average\": ' || printf('%.2f', (total_duration * 1000.0 / analyzed_count)) || ', ' ||
                '\"median\": ' || (SELECT printf('%.2f', reply_time * 1000.0) FROM analyzed_times LIMIT 1 OFFSET (SELECT (COUNT(*) - 1) / 2 FROM analyzed_times)) || ', ' ||
                '\"p95\": ' || (SELECT printf('%.2f', reply_time * 1000.0) FROM analyzed_times LIMIT 1 OFFSET (SELECT CAST((COUNT(*) * 0.95) - 1 AS INT) FROM analyzed_times)) ||
            '}, ' ||
            '\"tiers\": [' 
        FROM combined_metrics;
        $sql_json_rows ; 
        SELECT '], \"unbound\": null' ;
        SELECT '}' ;
        SELECT '___JSON_END___';"
    fi

    # Execute SQLite
    sqlite3 "$DBfile" <<EOF
.mode list
.headers off
.timeout 30000
.output /dev/null
PRAGMA temp_store = MEMORY;
PRAGMA journal_mode = OFF;
PRAGMA synchronous = OFF;

CREATE TEMP TABLE raw_data AS SELECT status, reply_time FROM queries WHERE timestamp >= $QUERY_START AND timestamp <= $QUERY_END $SQL_DOMAIN_CLAUSE; 
CREATE TEMP TABLE combined_metrics AS
    SELECT COUNT(*) as total_queries,
        SUM(CASE WHEN reply_time IS NULL THEN 1 ELSE 0 END) as invalid_count,
        SUM(CASE WHEN reply_time IS NOT NULL THEN 1 ELSE 0 END) as valid_count,
        SUM(CASE WHEN reply_time IS NOT NULL AND $SQL_BLOCKED_DEF THEN 1 ELSE 0 END) as blocked_count,
        SUM(CASE WHEN reply_time IS NOT NULL AND $SQL_STATUS_FILTER THEN 1 ELSE 0 END) as analyzed_count,
        SUM(CASE WHEN reply_time IS NOT NULL AND $SQL_STATUS_FILTER THEN reply_time ELSE 0.0 END) as total_duration,
        (SUM(CASE WHEN reply_time IS NOT NULL THEN 1 ELSE 0 END) - SUM(CASE WHEN reply_time IS NOT NULL AND $SQL_BLOCKED_DEF THEN 1 ELSE 0 END) - SUM(CASE WHEN reply_time IS NOT NULL AND $SQL_STATUS_FILTER THEN 1 ELSE 0 END)) as ignored_count,
        $sql_tier_columns
    FROM raw_data;
CREATE TEMP TABLE analyzed_times AS SELECT reply_time FROM raw_data WHERE reply_time IS NOT NULL AND $SQL_STATUS_FILTER ORDER BY reply_time ASC;

.output stdout
$JSON_REPORT_SQL
$TEXT_REPORT_SQL
EOF
}

# --- 10. EXECUTION & OUTPUT ---

if [ -n "$OUTPUT_FILE" ]; then
    [[ "$OUTPUT_FILE" != /* ]] && [ -n "$SAVE_DIR" ] && mkdir -p "$SAVE_DIR" && OUTPUT_FILE="${SAVE_DIR}/${OUTPUT_FILE}"
    [ "$ADD_TIMESTAMP" = true ] && TS=$(date "+%Y-%m-%d_%H%M") && OUTPUT_FILE="${OUTPUT_FILE%.*}_${TS}.${OUTPUT_FILE##*.}"
    if [ "$SEQUENTIAL" = true ] && [ -f "$OUTPUT_FILE" ]; then
        BASE="${OUTPUT_FILE%.*}"; EXT="${OUTPUT_FILE##*.}"; CNT=1
        while [ -f "${BASE}_${CNT}.${EXT}" ]; do ((CNT++)); done
        OUTPUT_FILE="${BASE}_${CNT}.${EXT}"
    fi
fi

# Visual Feedback
if [ "$SILENT_MODE" = false ] && [ "$SHOW_UNBOUND" != "only" ]; then
    echo "📊 Analyzing Pi-hole database... (This may wait if FTL is busy)" >&2
fi

# Generate
if [ "$SHOW_UNBOUND" == "only" ]; then
    # Unbound Only: Run bash function directly (No SQLite shell needed for this part)
    RAW_UNB=$(generate_unbound_report)
    
    # Robust text extraction using sed to simulate SQLite string printing
    FULL_OUTPUT=$(echo "$RAW_UNB" | grep "SELECT" | sed -e "s/^SELECT '//" -e "s/';$//" -e "s/' || '//")
else
    # Full Report: Run SQLite safely
    if ! FULL_OUTPUT=$(generate_report); then
        echo "❌ Error: Database query failed (Locked or Corrupt). No file saved." >&2
        exit 1
    fi
fi

# Format JSON/Text
if [ "$JSON_OUTPUT" = true ]; then
    # JSON Cleanup: Merge Pihole + Unbound JSON blocks
    JSON_CONTENT=$(echo "$FULL_OUTPUT" | sed -n '/___JSON_START___/,/___JSON_END___/p' | grep -v "___JSON_")
    
    # Handle Unbound JSON insertion
    UNB_JSON_PART=$(echo "$FULL_OUTPUT" | sed -n '/___JSON_UNB_START___/,/___JSON_UNB_END___/p' | grep -v "___JSON_")
    
    if [ -n "$UNB_JSON_PART" ]; then
        JSON_CONTENT=$(echo "$JSON_CONTENT" | sed -e "s/___JSON_UNB_START___//g" -e "s/___JSON_UNB_END___//g" | tr -d '\n' | sed 's/  / /g')
        JSON_CONTENT=$(echo "$JSON_CONTENT" | sed "s/\"unbound\": null/\"unbound\": $UNB_JSON_PART/")
    fi
    
    TEXT_CONTENT=$(echo "$FULL_OUTPUT" | sed -e '/___JSON_START___/,/___JSON_END___/d' -e '/___JSON_UNB_START___/,/___JSON_UNB_END___/d' | grep -v "SELECT" | grep -v "___JSON_")
else
    JSON_CONTENT=""
    TEXT_CONTENT="$FULL_OUTPUT"
fi

# Save & Display
if [ -n "$OUTPUT_FILE" ]; then
    if [ "$JSON_OUTPUT" = true ]; then echo "$JSON_CONTENT" > "$OUTPUT_FILE"
    else echo "$TEXT_CONTENT" > "$OUTPUT_FILE"; fi
    if [ "$SILENT_MODE" = false ]; then echo "Results saved to: $OUTPUT_FILE"; fi
fi

if [ "$SILENT_MODE" = false ]; then
    if [ -n "$OUTPUT_FILE" ] && [ "$JSON_OUTPUT" = true ]; then echo "$TEXT_CONTENT"
    elif [ -z "$OUTPUT_FILE" ] && [ "$JSON_OUTPUT" = true ]; then echo "$JSON_CONTENT"
    else echo "$TEXT_CONTENT"; fi
fi

# Auto-Delete
if [ -n "$SAVE_DIR" ] && [ -d "$SAVE_DIR" ] && [ -n "$MAX_LOG_AGE" ] && [[ "$MAX_LOG_AGE" =~ ^[0-9]+$ ]]; then
    find "$SAVE_DIR" -maxdepth 1 -type f -mtime +$MAX_LOG_AGE -delete
    if [ "$SILENT_MODE" = false ]; then
        echo "Auto-Clean : Deleted reports older than $MAX_LOG_AGE days from $SAVE_DIR"
    fi
fi

# Execution Timer (v2.9.1)
END_TS=$(date +%s.%N 2>/dev/null)
if [[ "$END_TS" == *N* ]] || [ -z "$END_TS" ]; then END_TS=$(date +%s); fi

DURATION=$(awk "BEGIN {printf \"%.2f\", $END_TS - $START_TS}" 2>/dev/null)
if [ -z "$DURATION" ]; then DURATION=$(( ${END_TS%.*} - ${START_TS%.*} )); fi

if [ "$SILENT_MODE" = false ]; then
    echo "Total Execution Time: ${DURATION}s" >&2
fi

exit 0
