#!/bin/bash

# ================= CONFIGURATION =================
DBfile="/etc/pihole/pihole-FTL.db"

# DEFINE YOUR TIERS (Upper Limits in Milliseconds)
# Put them in ANY order. The script will sort them automatically.
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
# =================================================

# --- 1. ARGUMENT PARSING ---
MIN_TIMESTAMP=0
TIME_LABEL="All Time"

# Flags to control logic
MODE="DEFAULT"   # Options: DEFAULT, UPSTREAM, PIHOLE
EXCLUDE_NX=false # If true, removes status 16/17
OUTPUT_FILE=""   # File to save results to

while [[ $# -gt 0 ]]; do
    case $1 in
        -up)
            MODE="UPSTREAM"
            shift 
            ;;
        -pi)
            MODE="PIHOLE"
            shift 
            ;;
        -nx)
            EXCLUDE_NX=true
            shift
            ;;
        -f)
            shift
            if [ -z "$1" ]; then
                echo "Error: -f requires a filename."
                exit 1
            fi
            OUTPUT_FILE="$1"
            shift
            ;;
        -*)
            INPUT="${1#-}"
            UNIT="${INPUT: -1}"
            VALUE="${INPUT:0:${#INPUT}-1}"

            if [[ "$UNIT" == "h" ]]; then
                OFFSET=$((VALUE * 3600))
                TIME_LABEL="Last $VALUE Hours"
                CURRENT_EPOCH=$(date +%s)
                MIN_TIMESTAMP=$((CURRENT_EPOCH - OFFSET))
            elif [[ "$UNIT" == "d" ]]; then
                OFFSET=$((VALUE * 86400))
                TIME_LABEL="Last $VALUE Days"
                CURRENT_EPOCH=$(date +%s)
                MIN_TIMESTAMP=$((CURRENT_EPOCH - OFFSET))
            else
                echo "Unknown argument: $1"
                exit 1
            fi
            shift 
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# --- 2. CONSTRUCT SQL FILTERS BASED ON FLAGS ---

# A. Strict Blocked Definition (Gravity, Regex, Blacklist)
SQL_BLOCKED_DEF="status IN (1, 4, 5, 9, 10, 11)"

# B. Build the Analysis Filter
# Base Statuses (Without 16/17)
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

# C. Handle -nx Logic (Include or Exclude 16/17)
if [ "$EXCLUDE_NX" = true ]; then
    # Do NOT add 16/17. They will be ignored.
    MODE_LABEL="$MODE_LABEL [Excl. Upstream Blocks]"
    SQL_STATUS_FILTER="status IN ($CURRENT_LIST)"
else
    # ADD 16/17 to the list (unless we are in Pi-hole mode where they don't apply)
    if [[ "$MODE" != "PIHOLE" ]]; then
        SQL_STATUS_FILTER="status IN ($CURRENT_LIST, 16, 17)"
    else
        SQL_STATUS_FILTER="status IN ($CURRENT_LIST)"
    fi
fi

# --- 3. CHECK REQUIREMENTS ---
if ! command -v sqlite3 &> /dev/null; then
    echo "Error: sqlite3 is not installed. Please install it with: sudo apt install sqlite3"
    exit 1
fi

# --- 4. MAIN GENERATION FUNCTION ---
generate_report() {
    
    CURRENT_DATE=$(date "+%Y-%m-%d %H:%M:%S")

    echo "========================================================"
    echo "      Pi-hole Latency Analysis"
    echo "========================================================"
    echo "Analysis Date : $CURRENT_DATE"
    echo "Time Period   : $TIME_LABEL"
    echo "Query Mode    : $MODE_LABEL"
    echo "--------------------------------------------------------"

    # --- SORT VARIABLES ---
    raw_limits=("$L01" "$L02" "$L03" "$L04" "$L05" "$L06" "$L07" "$L08" "$L09" "$L10" \
                "$L11" "$L12" "$L13" "$L14" "$L15" "$L16" "$L17" "$L18" "$L19" "$L20")

    IFS=$'\n' sorted_limits=($(printf "%s\n" "${raw_limits[@]}" | grep -v '^$' | sort -n))
    unset IFS

    # --- DYNAMIC SQL GENERATION ---
    sql_case_columns=""
    sql_select_rows=""
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

    # --- CALCULATE ALIGNMENT ---
    max_len=0
    for lbl in "${labels[@]}"; do
        len=${#lbl}
        if [ $len -gt $max_len ]; then max_len=$len; fi
    done
    max_len=$((max_len + 2))

    # --- BUILD OUTPUT ROWS ---
    for i in "${!labels[@]}"; do
        sql_select_rows="${sql_select_rows} SELECT printf(\"%-${max_len}s : \", \"${labels[$i]}\") || printf(\"%6.2f%%\", (t${i} * 100.0 / analyzed_count)) || \"  (\" || t${i} || \")\" FROM tiers;"
    done

    # --- RUN SQL ---
    sqlite3 "$DBfile" <<EOF
.mode column
.headers off

/* 1. RAW DATA FETCH */
CREATE TEMP TABLE raw_data AS
    SELECT status, reply_time 
    FROM queries 
    WHERE timestamp >= $MIN_TIMESTAMP; 

/* 2. STATS CALCULATION */
CREATE TEMP TABLE stats AS
    SELECT 
        COUNT(*) as total_queries,
        SUM(CASE WHEN reply_time IS NULL THEN 1 ELSE 0 END) as invalid_count,
        SUM(CASE WHEN reply_time IS NOT NULL THEN 1 ELSE 0 END) as valid_count,
        /* Strict Blocked: Gravity, Regex, Blacklist Only */
        SUM(CASE WHEN reply_time IS NOT NULL AND $SQL_BLOCKED_DEF THEN 1 ELSE 0 END) as blocked_count,
        /* Analyzed: Dependent on -up, -pi, and -nx flags */
        SUM(CASE WHEN reply_time IS NOT NULL AND $SQL_STATUS_FILTER THEN 1 ELSE 0 END) as analyzed_count,
        /* Total Duration: Sum of reply_time (seconds) for Analyzed queries only */
        SUM(CASE WHEN reply_time IS NOT NULL AND $SQL_STATUS_FILTER THEN reply_time ELSE 0.0 END) as total_duration
    FROM raw_data;

/* 3. ORDERED DATA FOR MEDIAN & P95 */
CREATE TEMP TABLE analyzed_times AS
    SELECT reply_time 
    FROM raw_data 
    WHERE reply_time IS NOT NULL AND $SQL_STATUS_FILTER
    ORDER BY reply_time ASC;

/* 4. MATH CHECK */
CREATE TEMP TABLE math_check AS
    SELECT 
        total_queries, invalid_count, valid_count, blocked_count, analyzed_count, total_duration,
        (valid_count - blocked_count - analyzed_count) as ignored_count
    FROM stats;

/* 5. TIERS CALCULATION */
CREATE TEMP TABLE tiers AS
    SELECT analyzed_count, $sql_case_columns
    FROM raw_data, stats
    WHERE reply_time IS NOT NULL AND $SQL_STATUS_FILTER;

/* 6. DISPLAY OUTPUT */
SELECT "Total Queries         : " || total_queries FROM math_check;
SELECT "Unsuccessful Queries  : " || invalid_count || " (" || printf("%.1f", (invalid_count * 100.0 / total_queries)) || "%)" FROM math_check;
SELECT "Total Valid Queries   : " || valid_count FROM math_check;
SELECT "Blocked Queries       : " || blocked_count || " (" || printf("%.1f", (blocked_count * 100.0 / valid_count)) || "%)" FROM math_check;

/* Only show Ignored if significant */
SELECT "Other/Ignored Queries : " || ignored_count || " (" || printf("%.1f", (ignored_count * 100.0 / valid_count)) || "%)" FROM math_check WHERE ignored_count > 0;

SELECT "Analyzed Queries      : " || analyzed_count || " (" || printf("%.1f", (analyzed_count * 100.0 / valid_count)) || "%)" FROM math_check;

/* Show Average Response Time */
SELECT "Average Latency       : " || printf("%.2f ms", (total_duration * 1000.0 / analyzed_count)) FROM math_check WHERE analyzed_count > 0;

/* Show Median Response Time (P50) */
SELECT "Median  Latency       : " || printf("%.2f ms", (reply_time * 1000.0)) 
FROM analyzed_times 
LIMIT 1 OFFSET (SELECT (COUNT(*) - 1) / 2 FROM analyzed_times);

/* Show 95th Percentile (P95) */
SELECT "95th Percentile       : " || printf("%.2f ms", (reply_time * 1000.0)) 
FROM analyzed_times 
LIMIT 1 OFFSET (SELECT CAST((COUNT(*) * 0.95) - 1 AS INT) FROM analyzed_times);

SELECT "";
SELECT "--- Latency Distribution of Analyzed Queries ---";

$sql_select_rows
SELECT "";

DROP TABLE raw_data;
DROP TABLE stats;
DROP TABLE math_check;
DROP TABLE tiers;
DROP TABLE analyzed_times;
EOF
}

# --- 5. EXECUTION ---
# If Output File is set, pipe output to tee (screen + file). Otherwise just run.
if [ -n "$OUTPUT_FILE" ]; then
    generate_report | tee "$OUTPUT_FILE"
    echo "Results saved to: $OUTPUT_FILE"
else
    generate_report
fi