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

# --- 1. ARGUMENT PARSING (LOOP) ---
MIN_TIMESTAMP=0
TIME_LABEL="All Time"
MODE_LABEL="All Normal Queries (Upstream + Cache)"
# Default SQL Filter: Forwarded (2) + Cached (3) + Retried/Optimized (12,13,14)
SQL_STATUS_FILTER="status IN (2, 3, 12, 13, 14)"

while [[ $# -gt 0 ]]; do
    case $1 in
        -up)
            MODE_LABEL="Upstream Only (Forwarded)"
            SQL_STATUS_FILTER="status = 2"
            shift # past argument
            ;;
        -pi)
            MODE_LABEL="Pi-hole Only (Cache & Optimizer)"
            SQL_STATUS_FILTER="status IN (3, 12, 13, 14)"
            shift # past argument
            ;;
        -*)
            # Handle Time Arguments (e.g., -24h, -7d)
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
                echo "Usage: sudo ./pihole_stats.sh [-24h] [-up|-pi]"
                exit 1
            fi
            shift # past argument
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

if ! command -v sqlite3 &> /dev/null; then
    echo "Error: sqlite3 is not installed. Please install it with: sudo apt install sqlite3"
    exit 1
fi

echo "========================================================"
echo "      Pi-hole Latency Analysis"
echo "========================================================"
echo "Time Period : $TIME_LABEL"
echo "Query Mode  : $MODE_LABEL"
echo "--------------------------------------------------------"

# --- 2. SORT VARIABLES ---
raw_limits=("$L01" "$L02" "$L03" "$L04" "$L05" "$L06" "$L07" "$L08" "$L09" "$L10" \
            "$L11" "$L12" "$L13" "$L14" "$L15" "$L16" "$L17" "$L18" "$L19" "$L20")

IFS=$'\n' sorted_limits=($(printf "%s\n" "${raw_limits[@]}" | grep -v '^$' | sort -n))
unset IFS

# --- 3. DYNAMIC SQL GENERATION ---
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

# --- 4. CALCULATE ALIGNMENT ---
max_len=0
for lbl in "${labels[@]}"; do
    len=${#lbl}
    if [ $len -gt $max_len ]; then max_len=$len; fi
done
max_len=$((max_len + 2))

# --- 5. BUILD OUTPUT ROWS ---
for i in "${!labels[@]}"; do
    sql_select_rows="${sql_select_rows} SELECT printf(\"%-${max_len}s : \", \"${labels[$i]}\") || printf(\"%6.2f%%\", (t${i} * 100.0 / normal_count)) || \"  (\" || t${i} || \")\" FROM tiers;"
done

# --- 6. RUN SQL ---
sqlite3 "$DBfile" <<EOF
.mode column
.headers off

/* 1. FILTER DATA (Time & Status Mode) */
CREATE TEMP TABLE clean_data AS
    SELECT status, reply_time 
    FROM queries 
    WHERE reply_time IS NOT NULL
    AND timestamp >= $MIN_TIMESTAMP; 

CREATE TEMP TABLE totals AS
    SELECT 
        COUNT(*) as total_queries,
        SUM(CASE WHEN status IN (1, 4, 5, 6, 7, 8, 9, 10, 11) THEN 1 ELSE 0 END) as blocked_count,
        /* The 'Normal' count now depends on the user flag (-up or -pi) */
        SUM(CASE WHEN $SQL_STATUS_FILTER THEN 1 ELSE 0 END) as normal_count
    FROM clean_data;

CREATE TEMP TABLE tiers AS
    SELECT normal_count, $sql_case_columns
    FROM clean_data, totals
    WHERE $SQL_STATUS_FILTER;

SELECT "Total Valid Queries   : " || total_queries FROM totals;
SELECT "Blocked Queries       : " || blocked_count || " (" || printf("%.1f", (blocked_count * 100.0 / total_queries)) || "%)" FROM totals;
SELECT "Analyzed Queries      : " || normal_count || " (" || printf("%.1f", (normal_count * 100.0 / total_queries)) || "%)" FROM totals;

SELECT "";
SELECT "--- Latency Distribution of Selected Queries ---";

$sql_select_rows
SELECT "";

DROP TABLE clean_data;
DROP TABLE totals;
DROP TABLE tiers;
EOF