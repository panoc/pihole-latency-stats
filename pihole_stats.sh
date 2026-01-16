#!/bin/bash
VERSION="2.2"

# --- 1. SETUP & DEFAULTS ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
DEFAULT_CONFIG="$SCRIPT_DIR/pihole_stats.conf"
CONFIG_TO_LOAD="$DEFAULT_CONFIG"

# Default Internal Values
DBfile="/etc/pihole/pihole-FTL.db"
SAVE_DIR=""
CONFIG_ARGS=""

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
SAVE_DIR=""

# [OPTIONAL] Default Arguments
# If set, these arguments will REPLACE any CLI flags.
# Example: CONFIG_ARGS="-up -24h -j -f stats.json"
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
# We scan for -c or -mc first to load the correct environment.
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

# [NEW] Profile Enforcement Logic
# If the config file contains CONFIG_ARGS, we discard the original CLI args
# and replace them with the ones from the file.
if [ -n "$CONFIG_ARGS" ]; then
    # eval is used here to correctly interpret quotes inside the string
    # e.g., CONFIG_ARGS="-f 'My File.txt'" needs to be split correctly.
    eval set -- "$CONFIG_ARGS"
else
    # Restore original args if no profile is forced
    set -- "${args_preserve[@]}"
fi

# --- 5. HELP ---
show_help() {
    echo "Pi-hole Latency Analysis v$VERSION"
    echo "Usage: sudo ./pihole_stats.sh [OPTIONS]"
    echo "  -24h, -7d        : Time filter"
    echo "  -up, -pi, -nx    : Query modes (Upstream/Pihole/NoBlock)"
    echo "  -dm, -edm        : Domain filter (Partial/Exact)"
    echo "  -f <file>        : Save to file"
    echo "  -j               : Enable JSON output"
    echo "  -s, --silent     : No screen output (for cron)"
    echo "  -seq, -ts        : Naming (Sequential/Timestamp)"
    echo "  -c, -mc          : Config (Load/Make)"
    echo "  -db              : Custom DB path"
    exit 0
}

# --- 6. ARGUMENTS ---
MIN_TIMESTAMP=0
TIME_LABEL="All Time"
MODE="DEFAULT"
EXCLUDE_NX=false
OUTPUT_FILE=""
JSON_OUTPUT=false
SILENT_MODE=false
DOMAIN_FILTER=""
SQL_DOMAIN_CLAUSE=""
SEQUENTIAL=false
ADD_TIMESTAMP=false

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help) show_help ;;
        -c|--config|-mc|--make-config) shift; shift ;; # Already handled
        -up) MODE="UPSTREAM"; shift ;;
        -pi) MODE="PIHOLE"; shift ;;
        -nx) EXCLUDE_NX=true; shift ;;
        -j|--json) JSON_OUTPUT=true; shift ;;
        -s|--silent) SILENT_MODE=true; shift ;;
        -seq) SEQUENTIAL=true; shift ;;
        -ts|--timestamp) ADD_TIMESTAMP=true; shift ;;
        -db) shift; DBfile="$1"; shift ;;
        -dm|--domain)
            shift; [ -z "$1" ] && exit 1
            RAW_INPUT="$1"; SANITIZED="${RAW_INPUT//\*/%}"; SANITIZED="${SANITIZED//\?/_}"
            SQL_DOMAIN_CLAUSE="AND domain LIKE '%$SANITIZED%'"
            shift ;;
        -edm|--exact-domain)
            shift; [ -z "$1" ] && exit 1
            RAW_INPUT="$1"; SANITIZED="${RAW_INPUT//\*/%}"; SANITIZED="${SANITIZED//\?/_}"
            SQL_DOMAIN_CLAUSE="AND (domain LIKE '$SANITIZED' OR domain LIKE '%.$SANITIZED')"
            shift ;;
        -f) shift; OUTPUT_FILE="$1"; shift ;;
        -*)
            INPUT="${1#-}"; UNIT="${INPUT: -1}"; VALUE="${INPUT:0:${#INPUT}-1}"
            if [[ "$UNIT" == "h" ]]; then OFFSET=$((VALUE * 3600)); TIME_LABEL="Last $VALUE Hours"
            elif [[ "$UNIT" == "d" ]]; then OFFSET=$((VALUE * 86400)); TIME_LABEL="Last $VALUE Days"
            fi
            MIN_TIMESTAMP=$(( $(date +%s) - OFFSET )); shift ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

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
[ -n "$DOMAIN_FILTER" ] && MODE_LABEL="$MODE_LABEL [Domain: $RAW_INPUT]"

[ ! -x "$(command -v sqlite3)" ] && echo "Error: sqlite3 required" && exit 1

# --- 8. GENERATE REPORT ---
generate_report() {
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
        sql_tier_columns="${sql_tier_columns} SUM(CASE WHEN ${sql_logic} THEN 1 ELSE 0 END) as t${tier_index},"
        prev_limit_ms="$limit_ms"; prev_limit_sec="$limit_sec"; ((tier_index++))
    done

    labels[$tier_index]="Tier ${tier_index} (> ${prev_limit_ms}ms)"
    sql_tier_columns="${sql_tier_columns} SUM(CASE WHEN reply_time > $prev_limit_sec THEN 1 ELSE 0 END) as t${tier_index}"

    # Generate Output Rows
    max_len=0
    for lbl in "${labels[@]}"; do len=${#lbl}; [ $len -gt $max_len ] && max_len=$len; done
    max_len=$((max_len + 2))

    for i in "${!labels[@]}"; do
        sql_text_rows="${sql_text_rows} SELECT printf(\"%-${max_len}s : \", \"${labels[$i]}\") || printf(\"%6.2f%%\", (t${i} * 100.0 / analyzed_count)) || \"  (\" || t${i} || \")\" FROM combined_metrics;"
        this_json="SELECT '{\"label\": \"${labels[$i]}\", \"count\": ' || t${i} || ', \"percentage\": ' || printf(\"%.2f\", (t${i} * 100.0 / analyzed_count)) || '}' FROM combined_metrics"
        [ -z "$sql_json_rows" ] && sql_json_rows="$this_json" || sql_json_rows="${sql_json_rows} UNION ALL SELECT ',' UNION ALL $this_json"
    done

    # --- SQL BLOCK BUILDER ---
    
    TEXT_REPORT_SQL="
        SELECT \"=========================================================\";
        SELECT \"              Pi-hole Latency Analysis v$VERSION\";
        SELECT \"=========================================================\";
        SELECT \"Analysis Date : $CURRENT_DATE\";
        SELECT \"Time Period   : $TIME_LABEL\";
        SELECT \"Query Mode    : $MODE_LABEL\";
        SELECT \"---------------------------------------------------------\";
        SELECT \"Total Queries         : \" || total_queries FROM combined_metrics;
        SELECT \"Unsuccessful Queries  : \" || invalid_count || \" (\" || printf(\"%.1f\", (invalid_count * 100.0 / total_queries)) || \"%) \" FROM combined_metrics;
        SELECT \"Total Valid Queries   : \" || valid_count FROM combined_metrics;
        SELECT \"Blocked Queries       : \" || blocked_count || \" (\" || printf(\"%.1f\", (blocked_count * 100.0 / valid_count)) || \"%) \" FROM combined_metrics;
        SELECT \"Other/Ignored Queries : \" || ignored_count || \" (\" || printf(\"%.1f\", (ignored_count * 100.0 / valid_count)) || \"%) \" FROM combined_metrics WHERE ignored_count > 0;
        SELECT \"Analyzed Queries      : \" || analyzed_count || \" (\" || printf(\"%.1f\", (analyzed_count * 100.0 / valid_count)) || \"%) \" FROM combined_metrics;
        SELECT \"Average Latency       : \" || printf(\"%.2f ms\", (total_duration * 1000.0 / analyzed_count)) FROM combined_metrics WHERE analyzed_count > 0;
        SELECT \"Median  Latency       : \" || printf(\"%.2f ms\", (reply_time * 1000.0)) FROM analyzed_times LIMIT 1 OFFSET (SELECT (COUNT(*) - 1) / 2 FROM analyzed_times);
        SELECT \"95th Percentile       : \" || printf(\"%.2f ms\", (reply_time * 1000.0)) FROM analyzed_times LIMIT 1 OFFSET (SELECT CAST((COUNT(*) * 0.95) - 1 AS INT) FROM analyzed_times);
        SELECT \"\";
        SELECT \"--- Latency Distribution of Analyzed Queries ---\";
        $sql_text_rows
        SELECT \"\";"

    JSON_REPORT_SQL=""
    if [ "$JSON_OUTPUT" = true ]; then
        JSON_REPORT_SQL="
        SELECT '___JSON_START___';
        SELECT '{' ||
            '\"version\": \"$VERSION\", ' ||
            '\"date\": \"$CURRENT_DATE\", ' ||
            '\"time_period\": \"$TIME_LABEL\", ' ||
            '\"mode\": \"$MODE_LABEL\", ' ||
            '\"stats\": {' ||
                '\"total_queries\": ' || total_queries || ', ' ||
                '\"unsuccessful\": ' || invalid_count || ', ' ||
                '\"total_valid\": ' || valid_count || ', ' ||
                '\"blocked\": ' || blocked_count || ', ' ||
                '\"analyzed\": ' || analyzed_count || 
            '}, ' ||
            '\"latency\": {' ||
                '\"average\": ' || printf(\"%.2f\", (total_duration * 1000.0 / analyzed_count)) || ', ' ||
                '\"median\": ' || (SELECT printf(\"%.2f\", reply_time * 1000.0) FROM analyzed_times LIMIT 1 OFFSET (SELECT (COUNT(*) - 1) / 2 FROM analyzed_times)) || ', ' ||
                '\"p95\": ' || (SELECT printf(\"%.2f\", reply_time * 1000.0) FROM analyzed_times LIMIT 1 OFFSET (SELECT CAST((COUNT(*) * 0.95) - 1 AS INT) FROM analyzed_times)) ||
            '}, ' ||
            '\"tiers\": [' 
        FROM combined_metrics;
        $sql_json_rows ; 
        SELECT ']}' ;
        SELECT '___JSON_END___';"
    fi

    # --- EXECUTE ---
    sqlite3 "$DBfile" <<EOF
.mode list
.headers off
.output /dev/null
PRAGMA temp_store = MEMORY;
PRAGMA journal_mode = OFF;
PRAGMA synchronous = OFF;

CREATE TEMP TABLE raw_data AS SELECT status, reply_time FROM queries WHERE timestamp >= $MIN_TIMESTAMP $SQL_DOMAIN_CLAUSE; 
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

# --- 9. OUTPUT HANDLING ---
if [ -n "$OUTPUT_FILE" ]; then
    [[ "$OUTPUT_FILE" != /* ]] && [ -n "$SAVE_DIR" ] && mkdir -p "$SAVE_DIR" && OUTPUT_FILE="${SAVE_DIR}/${OUTPUT_FILE}"
    [ "$ADD_TIMESTAMP" = true ] && TS=$(date "+%Y-%m-%d_%H%M") && OUTPUT_FILE="${OUTPUT_FILE%.*}_${TS}.${OUTPUT_FILE##*.}"
    if [ "$SEQUENTIAL" = true ] && [ -f "$OUTPUT_FILE" ]; then
        BASE="${OUTPUT_FILE%.*}"; EXT="${OUTPUT_FILE##*.}"; CNT=1
        while [ -f "${BASE}_${CNT}.${EXT}" ]; do ((CNT++)); done
        OUTPUT_FILE="${BASE}_${CNT}.${EXT}"
    fi
fi

FULL_OUTPUT=$(generate_report)

if [ "$JSON_OUTPUT" = true ]; then
    JSON_CONTENT=$(echo "$FULL_OUTPUT" | sed -n '/___JSON_START___/,/___JSON_END___/p' | grep -v "___JSON_")
    TEXT_CONTENT=$(echo "$FULL_OUTPUT" | sed '/___JSON_START___/,/___JSON_END___/d')
else
    JSON_CONTENT=""
    TEXT_CONTENT="$FULL_OUTPUT"
fi

# FILE SAVING
if [ -n "$OUTPUT_FILE" ]; then
    if [ "$JSON_OUTPUT" = true ]; then
        echo "$JSON_CONTENT" > "$OUTPUT_FILE"
    else
        echo "$TEXT_CONTENT" > "$OUTPUT_FILE"
    fi
    if [ "$SILENT_MODE" = false ]; then
        echo "Results saved to: $OUTPUT_FILE"
    fi
fi

# SCREEN DISPLAY
if [ "$SILENT_MODE" = false ]; then
    if [ -n "$OUTPUT_FILE" ] && [ "$JSON_OUTPUT" = true ]; then
        echo "$TEXT_CONTENT"
    elif [ -z "$OUTPUT_FILE" ] && [ "$JSON_OUTPUT" = true ]; then
        echo "$JSON_CONTENT"
    else
        echo "$TEXT_CONTENT"
    fi
fi