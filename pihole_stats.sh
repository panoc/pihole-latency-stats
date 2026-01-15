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

# --- 1. ARGUMENT PARSING (TIME FILTER) ---
MIN_TIMESTAMP=0
TIME_LABEL="All Time"

if [ -n "$1" ]; then
    # Remove the leading hyphen if user typed "-24h" -> "24h"
    INPUT="${1#-}"
    
    # Extract the unit (last character) and value (everything else)
    UNIT="${INPUT: -1}"
    VALUE="${INPUT:0:${#INPUT}-1}"

    # Calculate the timestamp offset
    if [[ "$UNIT" == "h" ]]; then
        OFFSET=$((VALUE * 3600))
        TIME_LABEL="Last $VALUE Hours"
    elif [[ "$UNIT" == "d" ]]; then
        OFFSET=$((VALUE * 86400))
        TIME_LABEL="Last $VALUE Days"
    else
        echo "Error: Invalid time format. Use -24h (hours) or -7d (days)."
        exit 1
    fi

    # Calculate the Cutoff Timestamp (Current Epoch - Offset)
    CURRENT_EPOCH=$(date +%s)
    MIN_TIMESTAMP=$((CURRENT_EPOCH - OFFSET))
fi


if ! command -v sqlite3 &> /dev/null; then
    echo "Error: sqlite3 is not installed. Please install it with: sudo apt install sqlite3"
    exit 1
fi

echo "========================================================"
echo "      Pi-hole Latency Analysis"
echo "========================================================"
echo "Analyzing : $TIME_LABEL"
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

/* 1. FILTER DATA BY TIME HERE */
CREATE TEMP TABLE clean_data AS
    SELECT status, reply_time 
    FROM queries 
    WHERE reply_time IS NOT NULL
    AND timestamp >= $MIN_TIMESTAMP; 

CREATE TEMP TABLE totals AS
    SELECT 
        COUNT(*) as total_queries,
        SUM(CASE WHEN status IN (1, 4, 5, 6, 7, 8, 9, 10, 11) THEN 1 ELSE 0 END) as blocked_count,
        SUM(CASE WHEN status NOT IN (1, 4, 5, 6, 7, 8, 9, 10, 11) THEN 1 ELSE 0 END) as normal_count
    FROM clean_data;

CREATE TEMP TABLE tiers AS
    SELECT normal_count, $sql_case_columns
    FROM clean_data, totals
    WHERE status NOT IN (1, 4, 5, 6, 7, 8, 9, 10, 11);

SELECT "Total Valid Queries   : " || total_queries FROM totals;
SELECT "Blocked Queries       : " || blocked_count || " (" || printf("%.1f", (blocked_count * 100.0 / total_queries)) || "%)" FROM totals;
SELECT "Normal Queries        : " || normal_count || " (" || printf("%.1f", (normal_count * 100.0 / total_queries)) || "%)" FROM totals;

SELECT "";
SELECT "--- Latency Distribution of Normal Queries ---";

$sql_select_rows

DROP TABLE clean_data;
DROP TABLE totals;
DROP TABLE tiers;
EOF