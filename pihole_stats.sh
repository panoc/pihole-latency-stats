#!/bin/bash
VERSION="1.4"

# --- 1. CONFIGURATION MANAGEMENT ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
CONFIG_FILE="$SCRIPT_DIR/pihole_stats.conf"

# Function to create default config if missing
create_default_config() {
    echo "Config file not found. Creating default at: $CONFIG_FILE"
    cat <<EOF > "$CONFIG_FILE"
# ================= PI-HOLE STATS CONFIGURATION =================
# Database Path
DBfile="/etc/pihole/pihole-FTL.db"

# Default Save Directory
SAVE_DIR=""

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
    chmod 644 "$CONFIG_FILE"
}

if [ ! -f "$CONFIG_FILE" ]; then
    create_default_config
fi
source "$CONFIG_FILE"

# --- 2. ARGUMENT PARSING ---
MIN_TIMESTAMP=0
TIME_LABEL="All Time"
MODE="DEFAULT"
EXCLUDE_NX=false
OUTPUT_FILE=""
JSON_OUTPUT=false
DOMAIN_FILTER=""
SQL_DOMAIN_CLAUSE=""
SEQUENTIAL=false

while [[ $# -gt 0 ]]; do
    case $1 in
        -up) MODE="UPSTREAM"; shift ;;
        -pi) MODE="PIHOLE"; shift ;;
        -nx) EXCLUDE_NX=true; shift ;;
        -j|--json) JSON_OUTPUT=true; shift ;;
        -seq) SEQUENTIAL=true; shift ;;
        -db) shift; DBfile="$1"; shift ;;
        
        # PARTIAL MATCH (Broad search, e.g. "google" finds all TLDs)
        -dm|--domain)
            shift
            if [ -z "$1" ]; then echo "Error: -dm requires a domain name."; exit 1; fi
            DOMAIN_FILTER="$1"
            SQL_DOMAIN_CLAUSE="AND domain LIKE '%$DOMAIN_FILTER%'"
            shift
            ;;
            
        # EXACT MATCH (Specific TLD, e.g. "google.gr" finds only .gr)
        -edm|--exact-domain)
            shift
            if [ -z "$1" ]; then echo "Error: -edm requires a specific domain."; exit 1; fi
            DOMAIN_FILTER="$1"
            # Matches exact domain OR subdomains ending in .domain
            SQL_DOMAIN_CLAUSE="AND (domain = '$DOMAIN_FILTER' OR domain LIKE '%.$DOMAIN_FILTER')"
            shift
            ;;

        -f) shift; OUTPUT_FILE="$1"; shift ;;
        -*)
            INPUT="${1#-}"
            UNIT="${INPUT: -1}"
            VALUE="${INPUT:0:${#INPUT}-1}"
            if [[ "$UNIT" == "h" ]]; then
                OFFSET=$((VALUE * 3600))
                TIME_LABEL="Last $VALUE Hours"
                MIN_TIMESTAMP=$(( $(date +%s) - OFFSET ))
            elif [[ "$UNIT" == "d" ]]; then
                OFFSET=$((VALUE * 86400))
                TIME_LABEL="Last $VALUE Days"
                MIN_TIMESTAMP=$(( $(date +%s) - OFFSET ))
            fi
            shift 
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# --- 3. CONSTRUCT SQL FILTERS ---
SQL_BLOCKED_DEF="status IN (1, 4, 5, 9, 10, 11)"
BASE_DEFAULT="2, 3, 6, 7, 8, 12, 13, 14, 15"
BASE_UPSTREAM="2, 6, 7, 8"
BASE_PIHOLE="3, 12, 13, 14, 15"

if [[ "$MODE" == "UPSTREAM" ]]; then
    CURRENT_LIST="$BASE_UPSTREAM"
    MODE_LABEL="Upstream Only (Forwarded)"
elif [[ "$MODE" == "PIHOLE" ]]; then
    CURRENT_LIST="$BASE_PIHOLE"
    MODE_LABEL="Pi-hole Only (Cache & Optimizer)"
else
    CURRENT_LIST="$BASE_DEFAULT"
    MODE_LABEL="All Normal Queries (Upstream + Cache)"
fi

if [ "$EXCLUDE_NX" = true ]; then
    MODE_LABEL="$MODE_LABEL [Excl. Upstream Blocks]"
    SQL_STATUS_FILTER="status IN ($CURRENT_LIST)"
else
    if [[ "$MODE" != "PIHOLE" ]]; then
        SQL_STATUS_FILTER="status IN ($CURRENT_LIST, 16, 17)"
    else
        SQL_STATUS_FILTER="status IN ($CURRENT_LIST)"
    fi
fi

if [ -n "$DOMAIN_FILTER" ]; then
    MODE_LABEL="$MODE_LABEL [Domain: $DOMAIN_FILTER]"
fi

if ! command -v sqlite3 &> /dev/null; then
    echo "Error: sqlite3 is not installed."
    exit 1
fi

# --- 4. MAIN GENERATION FUNCTION ---
generate_report() {
    CURRENT_DATE=$(date "+%Y-%m-%d %H:%M:%S")

    # Sort Tiers
    raw_limits=("$L01" "$L02" "$L03" "$L04" "$L05" "$L06" "$L07" "$L08" "$L09" "$L10" \
                "$L11" "$L12" "$L13" "$L14" "$L15" "$L16" "$L17" "$L18" "$L19" "$L20")
    IFS=$'\n' sorted_limits=($(printf "%s\n" "${raw_limits[@]}" | grep -v '^$' | sort -n))
    unset IFS

    # Dynamic SQL Generation
    sql_case_columns=""
    sql_text_rows=""
    sql_json_rows=""
    prev_limit_ms="0"
    prev_limit_sec="0"
    tier_index=0
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
        sql_case_columns="${sql_case_columns} SUM(CASE WHEN ${sql_logic} THEN 1 ELSE 0 END) as t${tier_index},"
        prev_limit_ms="$limit_ms"
        prev_limit_sec="$limit_sec"
        ((tier_index++))
    done

    labels[$tier_index]="Tier ${tier_index} (> ${prev_limit_ms}ms)"
    sql_case_columns="${sql_case_columns} SUM(CASE WHEN reply_time > $prev_limit_sec THEN 1 ELSE 0 END) as t${tier_index}"

    # Calculate Alignment & Build Rows
    max_len=0
    for lbl in "${labels[@]}"; do
        len=${#lbl}
        if [ $len -gt $max_len ]; then max_len=$len; fi
    done
    max_len=$((max_len + 2))

    for i in "${!labels[@]}"; do
        # Text Mode
        sql_text_rows="${sql_text_rows} SELECT printf(\"%-${max_len}s : \", \"${labels[$i]}\") || printf(\"%6.2f%%\", (t${i} * 100.0 / analyzed_count)) || \"  (\" || t${i} || \")\" FROM tiers;"
        
        # JSON Mode
        this_json_select="SELECT '{\"label\": \"${labels[$i]}\", \"count\": ' || t${i} || ', \"percentage\": ' || printf(\"%.2f\", (t${i} * 100.0 / analyzed_count)) || '}' FROM tiers"
        
        if [ -z "$sql_json_rows" ]; then
            sql_json_rows="$this_json_select"
        else
            sql_json_rows="${sql_json_rows} UNION ALL SELECT ',' UNION ALL $this_json_select"
        fi
    done

    # --- SQL EXECUTION ---
    if [ "$JSON_OUTPUT" = false ]; then
        echo "========================================================="
        echo "              Pi-hole Latency Analysis v$VERSION"
        echo "========================================================="
        echo "Analysis Date : $CURRENT_DATE"
        echo "Time Period   : $TIME_LABEL"
        echo "Query Mode    : $MODE_LABEL"
        echo "---------------------------------------------------------"
        
        OUTPUT_SQL="
        SELECT \"Total Queries         : \" || total_queries FROM math_check;
        SELECT \"Unsuccessful Queries  : \" || invalid_count || \" (\" || printf(\"%.1f\", (invalid_count * 100.0 / total_queries)) || \"%) \" FROM math_check;
        SELECT \"Total Valid Queries   : \" || valid_count FROM math_check;
        SELECT \"Blocked Queries       : \" || blocked_count || \" (\" || printf(\"%.1f\", (blocked_count * 100.0 / valid_count)) || \"%) \" FROM math_check;
        SELECT \"Other/Ignored Queries : \" || ignored_count || \" (\" || printf(\"%.1f\", (ignored_count * 100.0 / valid_count)) || \"%) \" FROM math_check WHERE ignored_count > 0;
        SELECT \"Analyzed Queries      : \" || analyzed_count || \" (\" || printf(\"%.1f\", (analyzed_count * 100.0 / valid_count)) || \"%) \" FROM math_check;
        SELECT \"Average Latency       : \" || printf(\"%.2f ms\", (total_duration * 1000.0 / analyzed_count)) FROM math_check WHERE analyzed_count > 0;
        SELECT \"Median  Latency       : \" || printf(\"%.2f ms\", (reply_time * 1000.0)) FROM analyzed_times LIMIT 1 OFFSET (SELECT (COUNT(*) - 1) / 2 FROM analyzed_times);
        SELECT \"95th Percentile       : \" || printf(\"%.2f ms\", (reply_time * 1000.0)) FROM analyzed_times LIMIT 1 OFFSET (SELECT CAST((COUNT(*) * 0.95) - 1 AS INT) FROM analyzed_times);
        SELECT \"\";
        SELECT \"--- Latency Distribution of Analyzed Queries ---\";
        $sql_text_rows
        SELECT \"\";"
    else
        OUTPUT_SQL="
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
        FROM math_check;
        
        $sql_json_rows ; 
        
        SELECT ']}' ;"
    fi

    sqlite3 "$DBfile" <<EOF
.mode list
.headers off
CREATE TEMP TABLE raw_data AS
    SELECT status, reply_time 
    FROM queries 
    WHERE timestamp >= $MIN_TIMESTAMP $SQL_DOMAIN_CLAUSE; 

CREATE TEMP TABLE stats AS
    SELECT 
        COUNT(*) as total_queries,
        SUM(CASE WHEN reply_time IS NULL THEN 1 ELSE 0 END) as invalid_count,
        SUM(CASE WHEN reply_time IS NOT NULL THEN 1 ELSE 0 END) as valid_count,
        SUM(CASE WHEN reply_time IS NOT NULL AND $SQL_BLOCKED_DEF THEN 1 ELSE 0 END) as blocked_count,
        SUM(CASE WHEN reply_time IS NOT NULL AND $SQL_STATUS_FILTER THEN 1 ELSE 0 END) as analyzed_count,
        SUM(CASE WHEN reply_time IS NOT NULL AND $SQL_STATUS_FILTER THEN reply_time ELSE 0.0 END) as total_duration
    FROM raw_data;

CREATE TEMP TABLE analyzed_times AS
    SELECT reply_time 
    FROM raw_data 
    WHERE reply_time IS NOT NULL AND $SQL_STATUS_FILTER
    ORDER BY reply_time ASC;

CREATE TEMP TABLE math_check AS
    SELECT 
        total_queries, invalid_count, valid_count, blocked_count, analyzed_count, total_duration,
        (valid_count - blocked_count - analyzed_count) as ignored_count
    FROM stats;

CREATE TEMP TABLE tiers AS
    SELECT analyzed_count, $sql_case_columns
    FROM raw_data, stats
    WHERE reply_time IS NOT NULL AND $SQL_STATUS_FILTER;

$OUTPUT_SQL
EOF
}

# --- 5. OUTPUT HANDLING ---
if [ -n "$OUTPUT_FILE" ]; then
    
    # 1. Handle SAVE_DIR from config
    if [[ "$OUTPUT_FILE" != /* ]] && [ -n "$SAVE_DIR" ]; then
        mkdir -p "$SAVE_DIR"
        OUTPUT_FILE="${SAVE_DIR}/${OUTPUT_FILE}"
    fi

    # 2. Handle Sequential Naming (-seq)
    if [ "$SEQUENTIAL" = true ] && [ -f "$OUTPUT_FILE" ]; then
        if [[ "$OUTPUT_FILE" == *.* ]]; then
            extension="${OUTPUT_FILE##*.}"
            base="${OUTPUT_FILE%.*}"
            ext_str=".$extension"
        else
            base="$OUTPUT_FILE"
            ext_str=""
        fi

        counter=1
        while [ -f "${base}_${counter}${ext_str}" ]; do
            ((counter++))
        done
        OUTPUT_FILE="${base}_${counter}${ext_str}"
    fi

    # 3. Execute
    generate_report | tee "$OUTPUT_FILE"
    if [ "$JSON_OUTPUT" = false ]; then echo "Results saved to: $OUTPUT_FILE"; fi
else
    generate_report
fi