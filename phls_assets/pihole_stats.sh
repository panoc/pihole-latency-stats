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

VERSION="v5.0.0"
UPSTREAM_DIST_MIN_CUTOFF="4"  # Minimum latency (ms) for the Upstream Graph
UPDATE_MSG=""

# --- 0. CRITICAL LOCALE FIX ---
export LC_ALL=C

# Capture start time
START_TS=$(date +%s.%N 2>/dev/null || date +%s)
PHLS_T0="${EPOCHREALTIME:-}"; PHLS_T=()
# -debug only: records how long each step takes (written to the debug log at the end)
phls_mark() { [ "$DEBUG_MODE" = true ] && [ -n "$PHLS_T0" ] && PHLS_T+=("$1 $EPOCHREALTIME"); return 0; }

# --- PRIVATE RAM WORK DIRECTORY (no SD-card writes for temp data) ---
WORK_DIR=$(mktemp -d /dev/shm/phls.XXXXXX 2>/dev/null || mktemp -d)
SPINNER_PID=""
LOCK_FILE_FALLBACK=""

cleanup() {
    if [ -n "$SPINNER_PID" ]; then kill "$SPINNER_PID" 2>/dev/null; [ -t 1 ] && tput cnorm >&2 2>/dev/null; fi
    [ -n "$WORK_DIR" ] && [ -d "$WORK_DIR" ] && rm -rf "$WORK_DIR"
    [ -n "$LOCK_FILE_FALLBACK" ] && rm -f "$LOCK_FILE_FALLBACK"
}
trap cleanup EXIT
trap 'echo -e "\n\nProgram aborted by user." >&2; exit 1' INT TERM

# --- LOCKING MECHANISM ---
# flock on a RAM-backed lock file: atomic, released automatically if the process dies.
check_lock() {
    local profile="${1:-default}"
    profile="${profile//[^a-zA-Z0-9_-]/_}"
    local lock_dir="/run/lock"
    { [ -d "$lock_dir" ] && [ -w "$lock_dir" ]; } || lock_dir="/dev/shm"
    { [ -d "$lock_dir" ] && [ -w "$lock_dir" ]; } || lock_dir="/tmp"
    local lock_file="$lock_dir/phls_${profile}.lock"

    if command -v flock &> /dev/null; then
        # A lock file left by another user (e.g. root's cron job) cannot be opened for writing, but flock
        # works on a read-only descriptor too, so manual and cron runs still exclude each other
        { exec 9>> "$lock_file"; } 2>/dev/null || { exec 9< "$lock_file"; } 2>/dev/null || return 0
        chmod 666 "$lock_file" 2>/dev/null
        if ! flock -n 9; then
            [ "$SILENT_MODE" = false ] && echo "⚠️  Already running (Profile: $profile). Exiting." >&2
            exit 1
        fi
        return 0
    fi

    # Fallback without flock: PID file
    if [ -f "$lock_file" ]; then
        local pid; pid=$(< "$lock_file")
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            [ "$SILENT_MODE" = false ] && echo "⚠️  Locked by PID $pid (Profile: $profile). Exiting." >&2
            exit 1
        fi
        rm -f "$lock_file"
    fi
    echo $$ > "$lock_file"
    LOCK_FILE_FALLBACK="$lock_file"
}

# --- SAFE CONFIG LOADER ---
# Config files are parsed, never executed: only known KEY="value" lines are accepted.
# (They used to be 'source'd as root, which let anyone able to edit them run code as root.)
CONFIG_KEYS=" DBfile ENABLE_UNBOUND MAX_DB_DAYS ENABLE_MATH_ALL_TIME L01 L02 L03 L04 L05 L06 L07 L08 L09 L10 L11 L12 L13 L14 L15 L16 L17 L18 L19 L20 MIN_LATENCY_CUTOFF MAX_LATENCY_CUTOFF DASH_DIR MAX_HISTORY_ENTRIES ENABLE_MATH_12H ENABLE_MATH_24H ENABLE_MATH_7D ENABLE_MATH_30D ENABLE_UPSTREAM_DIST ENABLE_UPSTREAM_MATH_ALL_TIME LAYOUT SAVE_DIR_TXT SAVE_DIR_JSON TXT_NAME JSON_NAME MAX_LOG_AGE CONFIG_ARGS DEFAULT_FROM DEFAULT_TO ENABLE_MANUAL_REFINEMENT UPSTREAM_DIST_MIN_CUTOFF ENABLE_CACHE EXCLUDE_PTR UPSTREAM_BY_PROVIDER "
load_config() {
    local file="$1" line key val
    [ -r "$file" ] || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line#"${line%%[![:space:]]*}"}"
        [[ -z "$line" || "$line" == \#* ]] && continue
        [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue
        key="${BASH_REMATCH[1]}"; val="${BASH_REMATCH[2]}"
        [[ "$CONFIG_KEYS" == *" $key "* ]] || continue
        if [[ "$val" =~ ^\"([^\"]*)\"[[:space:]]*(#.*)?$ ]]; then val="${BASH_REMATCH[1]}"
        elif [[ "$val" =~ ^\'([^\']*)\'[[:space:]]*(#.*)?$ ]]; then val="${BASH_REMATCH[1]}"
        else val="${val%%#*}"; val="${val%"${val##*[![:space:]]}"}"; fi
        printf -v "$key" '%s' "$val"
    done < "$file"
    return 0
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
# Where the cache and debug logs go. The system install (/opt/phls, managed by the `phls` command) keeps
# them in /var/lib/phls and /var/log/phls; a standalone copy keeps them next to the script, as before.
if [ -z "$PHLS_STATE_DIR" ]; then
    if [ "$SCRIPT_DIR" = "/opt/phls" ] && [ -d /var/lib/phls ]; then PHLS_STATE_DIR="/var/lib/phls"; else PHLS_STATE_DIR="$SCRIPT_DIR"; fi
fi
if [ -z "$PHLS_LOG_DIR" ] && [ "$SCRIPT_DIR" = "/opt/phls" ] && [ -d /var/log/phls ]; then PHLS_LOG_DIR="/var/log/phls"; fi
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
ENABLE_CACHE="true"
EXCLUDE_PTR="true"
UPSTREAM_BY_PROVIDER="false"

MAX_HISTORY_ENTRIES="8640"
DASH_DIR="/var/www/html/admin/img/dash"

# --- ANIMATION SETTINGS ---
target_time=4.0
width_divider=3
char="|"

L01="0.1"; L02="1"; L03="16"; L04="32"; L05="64"
L06="128";    L07="256"; L08="512"; L09=""; L10=""
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

# --- Upstream servers ---------------------------------------------------------------------------
# Which forwarded replies are upstream lookups, and which of them went to a local Unbound
# (whose fastest replies come from Unbound's own cache and are not counted as lookups).
PHLS_PIHOLE_TOML="${PHLS_PIHOLE_TOML:-/etc/pihole/pihole.toml}"
PHLS_UNBOUND_DIR="${PHLS_UNBOUND_DIR:-/etc/unbound}"

toml_dns_list() {   # toml_dns_list <key>: the strings of the array  <key> = [ ... ]  in section [dns]
    [ -r "$PHLS_PIHOLE_TOML" ] || return 0
    awk -v key="$1" '
        function scan(line,   i, n, ch) {
            n = length(line)
            for (i = 1; i <= n; i++) {
                ch = substr(line, i, 1)
                if (inq) { if (ch == "\"") { print cur; cur = ""; inq = 0 } else cur = cur ch }
                else if (ch == "\"") inq = 1
                else if (ch == "]") { done = 1; return }
                else if (ch == "#") return
            }
        }
        inarr { scan($0); if (done) exit; next }
        /^[[:space:]]*\[/ { sec = $0; gsub(/[][[:space:]]/, "", sec); next }
        sec == "dns" && $0 ~ ("^[[:space:]]*" key "[[:space:]]*=") { inarr = 1; sub(/^[^=]*=/, ""); scan($0); if (done) exit }
    ' "$PHLS_PIHOLE_TOML"
}
unbound_installed() { [ -x /usr/sbin/unbound ] || command -v unbound >/dev/null 2>&1 || [ -e "$PHLS_UNBOUND_DIR/unbound.conf" ]; }
unbound_ports() {   # " 5335 " (ports Unbound listens on), or " any " if its config cannot be read
    if [ -r "$PHLS_UNBOUND_DIR/unbound.conf" ]; then
        local p
        p=" $(awk '{ sub(/#.*/, "") } /^[[:space:]]*port:/ { gsub(/[^0-9]/, ""); if ($0 != "") print }
            /^[[:space:]]*interface:/ && /@[0-9]+/ { match($0, /@[0-9]+/); print substr($0, RSTART + 1, RLENGTH - 1) }' \
            "$PHLS_UNBOUND_DIR/unbound.conf" "$PHLS_UNBOUND_DIR"/unbound.conf.d/*.conf 2>/dev/null | sort -u | tr '\n' ' ')"
        [ "$p" = " " ] && p=" 53 "
        printf '%s' "$p"
    else printf ' any '; fi
}
# Is Unbound (on this machine) one of Pi-hole's upstream servers? Unknown (no readable pihole.toml) = yes.
unbound_used() {
    [ -r "$PHLS_PIHOLE_TOML" ] || return 0
    local ports u n; ports=$(unbound_ports)
    while IFS= read -r u; do
        [ -n "$u" ] || continue; n=$(norm_fwd "$u")
        is_loopback "$n" && { [ "$ports" = " any " ] || [[ "$ports" == *" ${n##*#} "* ]]; } && return 0
    done < <(toml_dns_list upstreams)
    return 1
}
# Public DNS provider of a server address ("1.1.1.1#53" -> Cloudflare), empty if not a known one
dns_provider() {
    local h="${1%#*}"; h="${h,,}"
    case "$h" in
        1.1.1.[123]|1.0.0.[123]|2606:4700:4700::111[123]|2606:4700:4700::100[123]) echo "Cloudflare" ;;
        8.8.8.8|8.8.4.4|2001:4860:4860::8888|2001:4860:4860::8844) echo "Google" ;;
        9.9.9.9|9.9.9.10|9.9.9.11|149.112.112.112|149.112.112.10|149.112.112.11|2620:fe::fe|2620:fe::9|2620:fe::10|2620:fe::fe:10|2620:fe::11|2620:fe::fe:11) echo "Quad9" ;;
        208.67.222.222|208.67.220.220|208.67.222.123|208.67.220.123|2620:119:35::35|2620:119:53::53|2620:119:35::123|2620:119:53::123) echo "OpenDNS" ;;
        94.140.14.14|94.140.15.15|94.140.14.15|94.140.15.16|2a10:50c0::ad1:ff|2a10:50c0::ad2:ff|2a10:50c0::bad1:ff|2a10:50c0::bad2:ff) echo "AdGuard" ;;
        185.228.168.9|185.228.169.9|185.228.168.10|185.228.169.11|185.228.168.168|185.228.169.168) echo "CleanBrowsing" ;;
        8.26.56.26|8.20.247.20) echo "Comodo" ;;
        84.200.69.80|84.200.70.40) echo "DNS.WATCH" ;;
        76.76.2.0|76.76.10.0) echo "ControlD" ;;
    esac
}
norm_fwd() { case "$1" in *"#"*) printf '%s' "$1" ;; *) printf '%s#53' "$1" ;; esac; }
is_loopback() { local h="${1%#*}"; [[ "$h" == 127.* || "$h" == "::1" || "$h" == "localhost" ]]; }

# discover_upstreams <db> <text|id>  ->  FC_CASE (SQL: forward -> code = p * 4 + class), NP, UPS_JSON, UNB_P, HAS_FWD
#   class 0 = upstream, 1 = Unbound on this machine, 2 = not an upstream (conditional forwarding target),
#   p = which upstream (1..14, 15 = other). Code 7 (p 1, class 3) = unknown: the cutoff applies, as before v5.
discover_upstreams() {
    local db="$1" mode="$2" l id name nn c
    NP=1; FC_CASE="7"; UPS_JSON="[]"; UPS_EXCL="[]"; UNB_P=" "; HAS_FWD=false; PNAMES=""
    [ "$(printf '.timeout 30000\nSELECT COUNT(*) FROM sqlite_master WHERE type = %s AND name IN (%s, %s);\n' "'table'" "'query_storage'" "'forward_by_id'" | sqlite3 "$db" 2>/dev/null)" = "2" ] || return 0
    local fw=(); mapfile -t fw < <(printf '.timeout 30000\nSELECT id, forward FROM forward_by_id ORDER BY id;\n' | sqlite3 "$db" 2>/dev/null)
    HAS_FWD=true
    local ups=() revs=() x
    while IFS= read -r x; do [ -n "$x" ] && ups+=("$(norm_fwd "$x")"); done < <(toml_dns_list upstreams)
    while IFS= read -r x; do x=$(cut -d, -f3 <<< "$x"); [ -n "$x" ] && revs+=("$(norm_fwd "$x")"); done < <(toml_dns_list revServers)
    # Unbound: installed, and the port(s) it listens on (Pi-hole's guide uses 5335)
    local ub=false uports=" "
    if unbound_installed; then ub=true; uports=$(unbound_ports); fi
    in_list() { local a="$1" b; shift; for b in "$@"; do [ "$a" = "$b" ] && return 0; done; return 1; }
    # classify every forward destination
    local ids=() names=() cls=() conf=()
    for l in "${fw[@]}"; do
        id="${l%%|*}"; name="${l#*|}"; [[ "$id" =~ ^[0-9]+$ ]] || continue
        [[ "$name" == *[\"\'\\]* ]] && continue
        nn=$(norm_fwd "$name"); c=0
        if [ ${#revs[@]} -gt 0 ] && in_list "$nn" "${revs[@]}" && ! { [ ${#ups[@]} -gt 0 ] && in_list "$nn" "${ups[@]}"; }; then c=2
        elif [ "$ub" = true ] && is_loopback "$nn" && { [ "$uports" = " any " ] || [[ "$uports" == *" ${nn##*#} "* ]]; }; then c=1; fi
        ids+=("$id"); names+=("$name"); cls+=("$c")
        if [ ${#ups[@]} -gt 0 ] && in_list "$nn" "${ups[@]}"; then conf+=(1); else conf+=(0); fi
    done
    # group of each server: the server itself, or its provider when UPSTREAM_BY_PROVIDER is on
    # (Unbound on this machine always stays on its own)
    local -A G=(); local i u k=0 pv
    for i in "${!ids[@]}"; do
        G[$i]="${names[$i]}"
        if [ "$UPSTREAM_BY_PROVIDER" = "true" ] && [ "${cls[$i]}" = 0 ]; then pv=$(dns_provider "${names[$i]}"); [ -n "$pv" ] && G[$i]="$pv"; fi
    done
    # upstream numbers: configured upstreams first (in Pi-hole's order), then older ones by id
    local gorder=() g
    for u in "${ups[@]}"; do for i in "${!ids[@]}"; do
        [ "${cls[$i]}" != 2 ] && [ "$(norm_fwd "${names[$i]}")" = "$u" ] && ! in_list "${G[$i]}" "${gorder[@]}" && gorder+=("${G[$i]}")
    done; done
    for i in "${!ids[@]}"; do [ "${cls[$i]}" = 2 ] && continue; in_list "${G[$i]}" "${gorder[@]}" || gorder+=("${G[$i]}"); done
    local -A GP=() P=(); NP=${#gorder[@]}
    for g in "${gorder[@]}"; do k=$((k + 1)); if [ "$NP" -le 1 ]; then GP[$g]=1; elif [ $k -le 14 ]; then GP[$g]=$k; else GP[$g]=15; fi; done
    for i in "${!ids[@]}"; do [ "${cls[$i]}" = 2 ] || P[$i]=${GP[${G[$i]}]}; done
    local js="" ex="" w case_id="" case_tx="" code
    PNAMES=""
    for i in "${!ids[@]}"; do
        if [ "${cls[$i]}" = 2 ]; then code=2; ex+="${ex:+,}\"${names[$i]}\""
        else
            code=$(( ${P[$i]} * 4 + ${cls[$i]} ))
            [ "${cls[$i]}" = 1 ] && UNB_P+="${P[$i]} "
        fi
        case_id+=" WHEN ${ids[$i]} THEN $code"; case_tx+=" WHEN '${names[$i]}' THEN $code"
    done
    # one entry per upstream (group): name, member servers
    for g in "${gorder[@]}"; do
        [ "${GP[$g]}" -le 14 ] || continue
        local mem="" unb=false cf=false
        for i in "${!ids[@]}"; do
            [ "${cls[$i]}" != 2 ] && [ "${G[$i]}" = "$g" ] || continue
            mem+="${mem:+,}\"${names[$i]}\""; [ "${cls[$i]}" = 1 ] && unb=true; [ "${conf[$i]}" = 1 ] && cf=true
        done
        js+="${js:+,}{\"p\":${GP[$g]},\"name\":\"$g\",\"members\":[$mem],\"unbound\":$unb,\"configured\":$cf}"
        PNAMES+="${GP[$g]}=$g"$'\t'
    done
    [ "$NP" -gt 14 ] && { js+=",{\"p\":15,\"name\":\"other\",\"members\":[],\"unbound\":false,\"configured\":false}"; PNAMES+="15=other"$'\t'; }
    UPS_JSON="[$js]"; UPS_EXCL="[$ex]"
    local els=4; [ "$NP" -gt 1 ] && els=60
    if [ "$mode" = "id" ]; then FC_CASE="CASE WHEN forward IS NULL THEN 7 ELSE CASE forward${case_id} ELSE $els END END"
    else FC_CASE="CASE WHEN forward IS NULL THEN 7 ELSE CASE forward${case_tx} ELSE $els END END"; fi
    [ -z "$case_id" ] && FC_CASE="CASE WHEN forward IS NULL THEN 7 ELSE $els END"
    return 0
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

# --- DAILY CACHE (dashboard runs only) ---
# Finished days are counted once and stored in the cache folder (/var/lib/phls/cache; a few MB, ~1 small write per day).
# Each run then only reads the newest rows, which makes runs much faster on large databases.
# Results are identical with or without the cache. Set to false to always read everything.
ENABLE_CACHE="$ENABLE_CACHE"

# --- REVERSE LOOKUPS ---
# Reverse lookups (PTR: IP -> name, mostly for devices on your network) are left out of the
# latency and upstream statistics; they are still counted in the totals. Set to false to include them.
EXCLUDE_PTR="$EXCLUDE_PTR"

# --- UPSTREAM SERVERS ---
# true = servers of the same public DNS provider (e.g. Cloudflare 1.1.1.1 and 1.0.0.1) are shown as one
# upstream on the dashboard; false = every server separately.
UPSTREAM_BY_PROVIDER="$UPSTREAM_BY_PROVIDER"

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
        if [ -f "$target_file" ]; then load_config "$target_file"; fi
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
    load_config "$CONFIG_TO_LOAD"
    # Auto-inject new Dashboard settings if missing
    if ! grep -q "ENABLE_UPSTREAM_DIST=" "$CONFIG_TO_LOAD"; then
        write_config "$CONFIG_TO_LOAD"
    fi
elif [ "$CONFIG_TO_LOAD" == "$DEFAULT_CONFIG" ]; then 
    write_config "$DEFAULT_CONFIG" > /dev/null
    load_config "$DEFAULT_CONFIG"
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
    # Parse shell-style quoting without executing anything (xargs honours '...' and "...")
    mapfile -t _CFG_ARGS < <(printf '%s' "$CONFIG_ARGS" | xargs printf '%s\n' 2>/dev/null)
    # Keep the command line and ADD the profile's extra args (dashboard and CLI runs alike).
    # (Up to v4.4 they replaced the command line, so profiles with extra args silently ran in CLI mode,
    # and up to 5.0 beta 11 a CLI run ignored its own options, e.g. -24h, when the profile had extra args.)
    set -- "${args_preserve[@]}" "${_CFG_ARGS[@]}"
else
    set -- "${args_preserve[@]}"
fi

# --- 5. CONFIG SANITIZATION ---
ENABLE_MATH_ALL_TIME="${ENABLE_MATH_ALL_TIME:-true}"; ENABLE_MATH_ALL_TIME="${ENABLE_MATH_ALL_TIME,,}"
ENABLE_MATH_12H="${ENABLE_MATH_12H:-true}"; ENABLE_MATH_12H="${ENABLE_MATH_12H,,}"
ENABLE_MATH_24H="${ENABLE_MATH_24H:-true}"; ENABLE_MATH_24H="${ENABLE_MATH_24H,,}"
ENABLE_MATH_7D="${ENABLE_MATH_7D:-true}"; ENABLE_MATH_7D="${ENABLE_MATH_7D,,}"
ENABLE_MATH_30D="${ENABLE_MATH_30D:-true}"; ENABLE_MATH_30D="${ENABLE_MATH_30D,,}"
ENABLE_UNBOUND="${ENABLE_UNBOUND:-auto}"; ENABLE_UNBOUND="${ENABLE_UNBOUND,,}"
ENABLE_UPSTREAM_DIST="${ENABLE_UPSTREAM_DIST:-true}"; ENABLE_UPSTREAM_DIST="${ENABLE_UPSTREAM_DIST,,}"
ENABLE_UPSTREAM_MATH_ALL_TIME="${ENABLE_UPSTREAM_MATH_ALL_TIME:-true}"; ENABLE_UPSTREAM_MATH_ALL_TIME="${ENABLE_UPSTREAM_MATH_ALL_TIME,,}"
ENABLE_CACHE="${ENABLE_CACHE:-true}"; ENABLE_CACHE="${ENABLE_CACHE,,}"
EXCLUDE_PTR="${EXCLUDE_PTR:-true}"; EXCLUDE_PTR="${EXCLUDE_PTR,,}"
UPSTREAM_BY_PROVIDER="${UPSTREAM_BY_PROVIDER:-false}"; UPSTREAM_BY_PROVIDER="${UPSTREAM_BY_PROVIDER,,}"
LAYOUT="${LAYOUT:-auto}"; LAYOUT="${LAYOUT,,}"

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
    echo "  -nx                : Leave out special-domain and stale-cache replies (status 16, 17)"
    echo "  -dm [string]       : Filter by domain (wildcards: * = %, ? = _)"
    echo "  -edm [string]      : Exact domain match (subdomains included)"
    echo "  -xdm [string]      : Exactly this domain (no subdomains)"
    echo "                       Several filters (or a,b,c in one) count queries matching any of them"
    echo ""
    echo "--- CLI OUTPUT OPTIONS ---"
    echo "  -j, --json [file]  : Save output to JSON file"
    echo "  -f [file]          : Save output to Text file"
    echo "  -s, --silent       : Suppress terminal output"
    echo ""
    echo "--- DASHBOARD OPTIONS ---"
    echo "  -nh                : No History (Do not update dashboard history graph)"
    echo "  -clear             : Clear dashboard history (and cache) for selected profile"
    echo ""
    echo "--- EXTRAS ---"
    echo "  -unb, -no-unb      : Force Enable/Disable Unbound stats"
    echo "  -ucc               : Include Unbound Cache Count (msg/rrset)"
    echo "  -snap              : (Deprecated, no effect) Data is always read once into RAM"
    echo "  -hor, -ver         : Force Horizontal or Vertical layout"
    echo "  -debug             : Enable debug logging to file"
    exit 0
}

MODE="DEFAULT"
EXCLUDE_NX=false
SILENT_MODE=false
DOMAIN_FILTER=""
DOM_PARTS=(); DOM_LABELS=()
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
        # Domain filters. Several can be given (or comma-separated in one): a query counts if it
        # matches ANY of them.  -dm = contains (* = any text, ? = one character)
        #                       -edm = this name and its subdomains   -xdm = exactly this name
        -dm|--domain|-edm|--exact-domain|-xdm|--only-domain)
            _dkind="$1"; shift
            IFS=',' read -r -a _dlist <<< "$1"
            for _d in "${_dlist[@]}"; do
                [ -z "$_d" ] && continue
                SANITIZED="${_d//\*/%}"; SANITIZED="${SANITIZED//\?/_}"; SANITIZED="${SANITIZED//\'/\'\'}"
                case "$_dkind" in
                    -dm|--domain) DOM_PARTS+=("domain LIKE '%$SANITIZED%'"); DOM_LABELS+=("$_d") ;;
                    -edm|--exact-domain) DOM_PARTS+=("domain LIKE '$SANITIZED' OR domain LIKE '%.$SANITIZED'"); DOM_LABELS+=("$_d") ;;
                    *) DOM_PARTS+=("domain LIKE '$SANITIZED'"); DOM_LABELS+=("=$_d") ;;
                esac
            done
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

if [ ${#DOM_PARTS[@]} -gt 0 ]; then
    SQL_DOMAIN_CLAUSE="AND ($(printf '(%s) OR ' "${DOM_PARTS[@]}" | sed 's/ OR $//'))"
    DOMAIN_FILTER=$(IFS=','; printf '%s' "${DOM_LABELS[*]}")
fi

# Unbound's own counters (unbound-control) cover every domain: they cannot follow a domain filter
if [ -n "$SQL_DOMAIN_CLAUSE" ] && [ "$SHOW_UNBOUND" == "only" ]; then
    echo "❌ Error: -unb-only cannot be combined with -dm / -edm: Unbound's own stats cover all domains." >&2
    exit 1
fi

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
        rm -f "$HIST_PATH" "$SNAP_PATH" "$PHLS_STATE_DIR/cache/phls_${DASH_PROFILE//[^a-zA-Z0-9_-]/_}.db"
        echo "✅ Cleared history."
        exit 0
    fi
fi

if [ "$DEBUG_MODE" = true ]; then
    CONF_DIR="$(dirname "$CONFIG_TO_LOAD")"
    if [ -n "$PHLS_LOG_DIR" ]; then
        mkdir -p "$PHLS_LOG_DIR" 2>/dev/null; DEBUG_LOG="$PHLS_LOG_DIR/phls_${DASH_PROFILE:-custom}_debug.log"
    elif [[ "$CONF_DIR" != "$SCRIPT_DIR" ]] && [[ "$CONF_DIR" != "/etc/pihole" ]]; then
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
    fi
}

# --- 8. DATA COLLECTION ---
# v4.5.0: Everything is computed in ONE sqlite3 session that reads the Pi-hole
# database exactly once into a RAM working set (only timestamp/status/reply_time).
# All windows, tiers, health buckets and percentiles are then derived from RAM.
# This replaces ~13 parallel sqlite3 processes and the full-database snapshot,
# which saves CPU, RAM and SD-card I/O.

# Worker: Unbound (runs in background while SQLite works)
collect_unbound_async() {
    local TMP_OUT="$WORK_DIR/unbound.vars"
    local proceed="false" raw_stats="" u_lim_msg="0" u_lim_rr="0" state="not_installed"

    # state for the dashboard: not_installed | disabled | not_running | not_used | active | error | filtered
    if [ -n "$SQL_DOMAIN_CLAUSE" ]; then state="filtered"   # domain filter: Unbound's totals would not match
    elif [ "$SHOW_UNBOUND" != "no" ] && command -v unbound-control &> /dev/null; then
        proceed="true"; state="active"
        if [ "$SHOW_UNBOUND" == "default" ]; then
            if [ "$ENABLE_UNBOUND" == "false" ]; then proceed="false"; state="disabled"; fi
            if [ "$ENABLE_UNBOUND" == "auto" ]; then
                if ! systemctl is-active --quiet unbound 2>/dev/null && ! pgrep -x unbound >/dev/null; then proceed="false"; state="not_running"
                elif ! unbound_used; then proceed="false"; state="not_used"; fi
            fi
        fi
    elif [ "$SHOW_UNBOUND" == "no" ]; then state="disabled"; fi

    if [ "$proceed" != "true" ]; then
        printf 'U_STATUS="Disabled"; HAS_UNBOUND="false"; U_STATE="%s"\n' "$state" > "$TMP_OUT"
        return
    fi

    local SUDO=""; [ "$EUID" -ne 0 ] && SUDO="sudo"
    raw_stats=$($SUDO /usr/sbin/unbound-control -c /etc/unbound/unbound.conf stats_noreset 2>&1)
    local lc="${raw_stats,,}"
    if [ -z "$raw_stats" ] || [[ "$lc" =~ (^|$'\n')error:|connection\ refused|permission\ denied|failed ]]; then
        printf 'U_STATUS="Error (Check Perms)"; HAS_UNBOUND="true"; U_STATE="error"\n' > "$TMP_OUT"
        return
    fi
    u_lim_msg=$($SUDO /usr/sbin/unbound-checkconf -o msg-cache-size 2>/dev/null || echo "4194304")
    u_lim_rr=$($SUDO /usr/sbin/unbound-checkconf -o rrset-cache-size 2>/dev/null || echo "8388608")

    # Single awk pass: counters, histogram buckets (>2ms only) and estimated stats
    printf '%s\n' "$raw_stats" | awk -F'=' -v lm="$u_lim_msg" -v lr="$u_lim_rr" '
        function v(k) { return (k in s) ? s[k] : 0 }
        { s[$1] = $2 }
        /^histogram\./ { has_h = 1
            if ($1 ~ /^histogram\.000000\.(002048|004096)\.to/) b[1] += $2
            else if ($1 ~ /^histogram\.000000\.008192\.to/) b[2] = $2
            else if ($1 ~ /^histogram\.000000\.016384\.to/) b[3] = $2
            else if ($1 ~ /^histogram\.000000\.032768\.to/) b[4] = $2
            else if ($1 ~ /^histogram\.000000\.065536\.to/) b[5] = $2
            else if ($1 ~ /^histogram\.000000\.131072\.to/) b[6] = $2
            else if ($1 ~ /^histogram\.000000\.262144\.to/) b[7] = $2
            else if ($1 ~ /^histogram\.000000\.524288\.to/) b[8] = $2
            else if ($1 ~ /^histogram\.(000001|000002|000004|000008|000016|000032)\.000000\.to/) b[9] += $2
        }
        END {
            hits = v("total.num.cachehits"); miss = v("total.num.cachemiss")
            printf "U_STATUS=\"Active (Integrated)\"; HAS_UNBOUND=\"true\"\n"
            printf "U_HITS=\"%s\"; U_MISS=\"%s\"; U_PRE=\"%s\"; U_TOTAL=\"%.0f\"\n", hits, miss, v("total.num.prefetch"), hits + miss
            printf "U_MEM_MSG=\"%s\"; U_MEM_RR=\"%s\"; U_LIM_MSG=\"%s\"; U_LIM_RR=\"%s\"\n", v("mem.cache.message"), v("mem.cache.rrset"), lm, lr
            printf "UCC_MSG=\"%s\"; UCC_RR=\"%s\"\n", v("msg.cache.count"), v("rrset.cache.count")
            for (i = 1; i <= 9; i++) { b[i] += 0; printf "H_B%d=\"%.0f\"; ", i, b[i] } ; printf "\n"

            # Estimated stats based ONLY on valid >2ms buckets (logarithmic interpolation)
            bounds[1]=2; widths[1]=6; bounds[2]=8; widths[2]=8; bounds[3]=16; widths[3]=16
            bounds[4]=32; widths[4]=32; bounds[5]=64; widths[5]=64; bounds[6]=128; widths[6]=128
            bounds[7]=256; widths[7]=256; bounds[8]=512; widths[8]=512; bounds[9]=1024; widths[9]=1000
            total = 0; for (i = 1; i <= 9; i++) total += b[i]
            if (total == 0) { print "U_AVG=\"0.00\"; U_MED=\"0.00\"; U_STD=\"0.00\"; U_P95=\"0.00\""; exit }
            sum = 0; for (i = 1; i <= 9; i++) sum += b[i] * (bounds[i] + widths[i]/2)
            avg_ms = sum / total
            sq = 0; for (i = 1; i <= 9; i++) sq += b[i] * ((bounds[i] + widths[i]/2) - avg_ms)^2
            std_ms = sqrt(sq / total)
            med_ms = interp(0.50); p95_ms = interp(0.95)
            printf "U_AVG=\"%.6f\"; U_MED=\"%.6f\"; U_STD=\"%.2f\"; U_P95=\"%.2f\"\n", avg_ms/1000, med_ms/1000, std_ms, p95_ms
        }
        function interp(q,   target, cum, i, lo, hi) {
            target = total * q; cum = 0
            for (i = 1; i <= 9; i++) {
                if (cum + b[i] >= target) {
                    if (b[i] == 0) return bounds[i]
                    lo = bounds[i]; hi = bounds[i] + widths[i]
                    return exp(log(lo) + ((target - cum) / b[i]) * (log(hi) - log(lo)))
                }
                cum += b[i]
            }
            return bounds[9]
        }' > "$TMP_OUT"
}

# Loads Unbound results and pre-computes all derived values in a single awk call
load_unbound_results() {
    [ -n "$PID_UNB" ] && wait "$PID_UNB" 2>/dev/null
    U_STATUS="Disabled"; HAS_UNBOUND="false"; U_STATE=""
    U_TOTAL=0; U_HITS=0; U_MISS=0; U_PRE=0; U_MEM_MSG=0; U_MEM_RR=0; U_LIM_MSG=0; U_LIM_RR=0
    UCC_MSG=0; UCC_RR=0; H_B1=0; H_B2=0; H_B3=0; H_B4=0; H_B5=0; H_B6=0; H_B7=0; H_B8=0; H_B9=0
    U_AVG="0"; U_MED="0"; U_STD="0.00"; U_P95="0.00"
    if [ -f "$WORK_DIR/unbound.vars" ]; then source "$WORK_DIR/unbound.vars"; rm -f "$WORK_DIR/unbound.vars"; fi
    [ -z "$U_STATE" ] && { [ "$HAS_UNBOUND" = "true" ] && U_STATE="active" || U_STATE="not_installed"; }
    local _k _v
    while IFS='=' read -r _k _v; do [ -n "$_k" ] && printf -v "$_k" '%s' "$_v"; done < <(
        awk -v t="${U_TOTAL:-0}" -v h="${U_HITS:-0}" -v m="${U_MISS:-0}" -v p="${U_PRE:-0}" \
            -v mm="${U_MEM_MSG:-0}" -v lm="${U_LIM_MSG:-0}" -v mr="${U_MEM_RR:-0}" -v lr="${U_LIM_RR:-0}" \
            -v a="${U_AVG:-0}" -v d="${U_MED:-0}" 'BEGIN {
            printf "U_PCT_HIT=%.2f\nU_PCT_MISS=%.2f\n", (t > 0 ? h / t * 100 : 0), (t > 0 ? m / t * 100 : 0)
            printf "U_PCT_PRE=%.2f\n", (h > 0 ? p / h * 100 : 0)
            printf "U_PCT_MEM_MSG=%.2f\nU_PCT_MEM_RR=%.2f\n", (lm > 0 ? mm / lm * 100 : 0), (lr > 0 ? mr / lr * 100 : 0)
            printf "U_MB_MSG=%.2f\nU_MB_LIM_MSG=%.2f\nU_MB_RR=%.2f\nU_MB_LIM_RR=%.2f\n", mm/1048576, lm/1048576, mr/1048576, lr/1048576
            printf "U_AVG_F=%.2f\nU_MED_F=%.2f\n", a * 1000, d * 1000
        }')
}

# --- 9. ORCHESTRATOR ---
P_TOTAL=0; P_INVALID=0; P_VALID=0; P_BLOCKED=0; P_ANALYZED=0; P_IGNORED=0; P_AVG="0.00"; P_MED="0.00"; P_95="0.00"; P_STD="0.00"
P_HEX=0; P_HGD=0; P_HFR=0; P_HPR=0

declare -a TIER_LABELS; declare -a TIER_COUNTS; declare -a TIER_PCTS
declare -a W12_TIERS; declare -a W24_TIERS; declare -a W7D_TIERS; declare -a W30_TIERS
declare -a W12_STATS; declare -a W24_STATS; declare -a W7D_STATS; declare -a W30_STATS
declare -a UP_TIERS_12H; declare -a UP_TIERS_24H; declare -a UP_TIERS_7D; declare -a UP_TIERS_30D; declare -a UP_TIERS_ALL
declare -a UP_STATS_12H; declare -a UP_STATS_24H; declare -a UP_STATS_7D; declare -a UP_STATS_30D; declare -a UP_STATS_ALL

# Emits SQL that sorts-free extracts the median and P95 from a table whose rows
# were inserted in ascending reply_time order (rowid 1..n). Same offsets as v4.4.
pct_from_sorted() {
    local tag="$1" tbl="$2"
    printf "SELECT 'PCT', '%s', (SELECT rt FROM %s WHERE rowid = (SELECT (COUNT(*) - 1) / 2 FROM %s) + 1), (SELECT rt FROM %s WHERE rowid = MAX(CAST((SELECT COUNT(*) FROM %s) * 0.95 - 1 AS INT), 0) + 1);\n" "$tag" "$tbl" "$tbl" "$tbl" "$tbl"
}
# Same, for a filtered subset of a sorted table (copied in rowid order = still sorted, no re-sort)
pct_from_subset() {
    local tag="$1" src="$2" where="$3"
    printf "CREATE TEMP TABLE s_%s AS SELECT rt FROM %s WHERE %s ORDER BY rowid;\n" "$tag" "$src" "$where"
    pct_from_sorted "$tag" "s_$tag"
    printf "DROP TABLE s_%s;\n" "$tag"
}

collect_pihole_stats() {

    if [ "$SHOW_UNBOUND" == "only" ]; then
        MODE_LABEL="Unbound Only"
        P_TOTAL=0; P_INVALID=0; P_VALID=0; P_BLOCKED=0; P_ANALYZED=0; P_IGNORED=0
        P_AVG="0.00"; P_MED="0.00"; P_95="0.00"; P_STD="0.00"
        load_unbound_results
        if [ "$HAS_UNBOUND" != "true" ]; then HAS_UNBOUND="true"; U_STATUS="Error: Service Down"; fi
        return
    fi

    if [ ! -r "$DBfile" ]; then echo "❌ Error: Cannot read database '$DBfile'." >&2; load_unbound_results; return; fi

    if [[ "$MODE" == "UPSTREAM" ]]; then CURRENT_LIST="$BASE_UPSTREAM"; MODE_LABEL="Upstream Only";
    elif [[ "$MODE" == "PIHOLE" ]]; then CURRENT_LIST="$BASE_PIHOLE"; MODE_LABEL="Pi-hole Only";
    else CURRENT_LIST="$BASE_DEFAULT"; MODE_LABEL="All Normal Queries"; fi

    if [ "$EXCLUDE_NX" = true ]; then MODE_LABEL="$MODE_LABEL [Excl. Blocks]"; SQL_STATUS_FILTER="status IN ($CURRENT_LIST)";
    else [[ "$MODE" != "PIHOLE" ]] && SQL_STATUS_FILTER="status IN ($CURRENT_LIST, 16, 17)" || SQL_STATUS_FILTER="status IN ($CURRENT_LIST)"; fi

    TS_NOW=$(date +%s); TS_12H=$((TS_NOW - 43200)); TS_24H=$((TS_NOW - 86400)); TS_7D=$((TS_NOW - 604800)); TS_30D=$((TS_NOW - 2592000))
    if [ "$DASH_MODE" = true ]; then
        QUERY_END="$TS_NOW"
        if [ -n "$MAX_DB_DAYS" ] && [ "$MAX_DB_DAYS" -gt 0 ]; then DAYS_SEC=$((MAX_DB_DAYS * 86400)); QUERY_START=$((TS_NOW - DAYS_SEC)); TIME_LABEL="Last $MAX_DB_DAYS Days"
        else QUERY_START=0; TIME_LABEL="All Time (Full DB)"; fi
    fi

    # --- Seconds conversions: ONE awk call (cutoffs, upstream min, tiers) ---
    local raw_limits=("$L01" "$L02" "$L03" "$L04" "$L05" "$L06" "$L07" "$L08" "$L09" "$L10" "$L11" "$L12" "$L13" "$L14" "$L15" "$L16" "$L17" "$L18" "$L19" "$L20")
    local sorted_limits=() divs=()
    IFS=$'\n' sorted_limits=($(printf "%s\n" "${raw_limits[@]}" | grep -v '^$' | sort -n)); unset IFS
    mapfile -t divs < <(printf '%s\n' "$MIN_LATENCY_CUTOFF" "$MAX_LATENCY_CUTOFF" "${UPSTREAM_DIST_MIN_CUTOFF:-3}" "${sorted_limits[@]}" | awk '{ if ($0 == "") print ""; else print $0 / 1000 }')

    SQL_LATENCY_COND=""
    [ -n "${divs[0]}" ] && SQL_LATENCY_COND="AND reply_time >= ${divs[0]}"
    [ -n "${divs[1]}" ] && SQL_LATENCY_COND="$SQL_LATENCY_COND AND reply_time <= ${divs[1]}"
    SQL_METRIC_FILTER="$SQL_STATUS_FILTER $SQL_LATENCY_COND"
    local up_min_sec="${divs[2]}"
    local UP_FILTER="status IN (2,6,7,8) AND reply_time >= $up_min_sec"

    # Tier logic (identical boundaries to v4.4)
    local tier_logic=() prev_ms="0" prev_sec="0" idx=0 ms sec
    TIER_LABELS=()
    for ms in "${sorted_limits[@]}"; do
        sec="${divs[$((idx + 3))]}"
        if [ "$idx" -eq 0 ]; then tier_logic+=("reply_time <= $sec"); TIER_LABELS[$idx]="Tier $((idx+1)) (< ${ms}ms)"
        else tier_logic+=("reply_time > $prev_sec AND reply_time <= $sec"); TIER_LABELS[$idx]="Tier $((idx+1)) (${prev_ms} - ${ms}ms)"; fi
        prev_ms="$ms"; prev_sec="$sec"; ((idx++))
    done
    tier_logic+=("reply_time > $prev_sec"); TIER_LABELS[$idx]="Tier $((idx+1)) (> ${prev_ms}ms)"
    local NT=${#tier_logic[@]}

    local up_logic=() up_prev="0"
    for sec in 0.008 0.016 0.032 0.064 0.128 0.256 0.512 1; do
        if [ "$up_prev" == "0" ]; then up_logic+=("reply_time <= $sec"); else up_logic+=("reply_time > $up_prev AND reply_time <= $sec"); fi
        up_prev="$sec"
    done
    up_logic+=("reply_time > 1")

    local health_logic=("reply_time < 0.032" "reply_time >= 0.032 AND reply_time < 0.128" "reply_time >= 0.128 AND reply_time < 0.512" "reply_time >= 0.512")

    # --- Plan which pieces are needed ---
    local DO_UP=false DO_REF=false DO_UP_ALL_MATH=false w
    local W_NAMES=(12h 24h 7d 30d) W_TS=("$TS_12H" "$TS_24H" "$TS_7D" "$TS_30D") W_MATH=("$ENABLE_MATH_12H" "$ENABLE_MATH_24H" "$ENABLE_MATH_7D" "$ENABLE_MATH_30D")
    if [ "$DASH_MODE" = true ]; then
        [ "$ENABLE_UPSTREAM_DIST" = "true" ] && DO_UP=true
        [ "$ENABLE_MANUAL_REFINEMENT" == "yes" ] && DO_REF=true
        { [ "$DO_UP" = true ] && [ "$ENABLE_UPSTREAM_MATH_ALL_TIME" = "true" ]; } && DO_UP_ALL_MATH=true
    fi
    local has_dom=0 DOM_EXPR="1"
    if [ -n "$SQL_DOMAIN_CLAUSE" ]; then has_dom=1; DOM_EXPR="${SQL_DOMAIN_CLAUSE#AND }"; fi

    # --- Windows as bits: 1 = 12h, 2 = 24h, 4 = 7d, 8 = 30d, 16 = main range ---
    # Every row (or cached day) carries a mask of the windows it belongs to.
    local WIN_TS=() b
    if [ "$DASH_MODE" = true ]; then WIN_TS=("$TS_12H" "$TS_24H" "$TS_7D" "$TS_30D" "$QUERY_START")
    else WIN_TS=("" "" "" "" "$QUERY_START"); fi
    local R_START="$QUERY_START"
    for b in 0 1 2 3; do [ -n "${WIN_TS[$b]}" ] && [ "${WIN_TS[$b]}" -lt "$R_START" ] && R_START="${WIN_TS[$b]}"; done
    local MASK_RAW="(0"
    for b in 0 1 2 3 4; do [ -n "${WIN_TS[$b]}" ] && MASK_RAW+=" + (timestamp >= ${WIN_TS[$b]}) * $((1 << b))"; done
    MASK_RAW+=")"

    # Upstream servers (dashboard): per-server stats need Pi-hole's numeric forward ids -> read query_storage
    local SRC="queries" FC_CASE="7" NP=1 UPS_JSON="[]" UPS_EXCL="[]" UNB_P=" " HAS_FWD=false PNAMES=""
    if [ "$DASH_MODE" = true ] && { [ "$DO_UP" = true ] || [ "$DO_REF" = true ]; }; then
        if [ "$has_dom" -eq 0 ]; then discover_upstreams "$DBfile" id; [ "$HAS_FWD" = true ] && SRC="query_storage"
        else discover_upstreams "$DBfile" text; NP=1; fi
    fi
    # upstream numbers that occur (per-server stats only with 2 or more servers)
    local PLIST=""
    if [ "$NP" -gt 1 ] && [ "$has_dom" -eq 0 ]; then PLIST=$(seq 1 $(( NP > 14 ? 14 : NP )) | tr '\n' ' '); [ "$NP" -gt 14 ] && PLIST+="15"; fi

    # Percentile targets "tag:set:window-bit"  (g = latency rows, u = upstream-graph rows, r = refinement rows,
    # pN = rows of upstream server N)
    local TARGETS=()
    [ "$ENABLE_MATH_ALL_TIME" = true ] && TARGETS+=("all:g:4")
    if [ "$DASH_MODE" = true ]; then
        for w in 0 1 2 3; do [ "${W_MATH[$w]}" = true ] && TARGETS+=("g${W_NAMES[$w]}:g:$w"); done
        if [ "$DO_UP" = true ]; then
            for w in 0 1 2 3; do [ "${W_MATH[$w]}" = true ] && TARGETS+=("u${W_NAMES[$w]}:u:$w"); done
        fi
        { [ "$DO_UP_ALL_MATH" = true ] || { [ "$DO_REF" = true ] && [ "$has_dom" -eq 0 ]; }; } && TARGETS+=("uall:u:4")
        if [ "$DO_UP" = true ] && [ -n "$PLIST" ]; then
            local pn; for pn in $PLIST; do
                for w in 0 1 2 3; do [ "${W_MATH[$w]}" = true ] && TARGETS+=("u${W_NAMES[$w]}_p$pn:p$pn:$w"); done
                [ "$DO_UP_ALL_MATH" = true ] && TARGETS+=("uall_p$pn:p$pn:4")
            done
        fi
        { [ "$DO_REF" = true ] && [ "$has_dom" -eq 1 ]; } && TARGETS+=("ref:r:4")
    fi

    # --- Per-row classification (evaluated ONCE per row) ---
    local TIER_CASE="CASE" HEALTH_CASE UP_CASE="CASE" sec i
    for i in "${!tier_logic[@]}"; do
        [ "$i" -lt $((NT - 1)) ] && TIER_CASE+=" WHEN reply_time <= ${divs[$((i + 3))]} THEN $i"
    done
    TIER_CASE+=" ELSE $((NT - 1)) END"
    HEALTH_CASE="CASE WHEN reply_time < 0.032 THEN 0 WHEN reply_time < 0.128 THEN 1 WHEN reply_time < 0.512 THEN 2 ELSE 3 END"
    i=0; for sec in 0.008 0.016 0.032 0.064 0.128 0.256 0.512 1; do UP_CASE+=" WHEN reply_time <= $sec THEN $i"; ((i++)); done
    UP_CASE+=" ELSE 8 END"
    # Status sets as bitmasks: ((1 << status) & MASK) != 0 is much cheaper per row than status IN (...)
    local MET_MASK=0 BLK_MASK=0 UP_MASK=0 st
    for st in ${SQL_STATUS_FILTER//[^0-9]/ }; do MET_MASK=$(( MET_MASK | (1 << st) )); done
    for st in ${SQL_BLOCKED_DEF//[^0-9]/ }; do BLK_MASK=$(( BLK_MASK | (1 << st) )); done
    for st in 2 6 7 8; do UP_MASK=$(( UP_MASK | (1 << st) )); done
    local PTR_COND=""; [ "$EXCLUDE_PTR" != "false" ] && PTR_COND="AND type IS NOT 6"   # 6 = PTR (reverse lookup)
    local IS_MET="(reply_time IS NOT NULL AND ((1 << status) & $MET_MASK) != 0 $PTR_COND $SQL_LATENCY_COND)"
    local IS_BLK="(((1 << status) & $BLK_MASK) != 0)"
    # FC = code of the server a forwarded reply came from (p * 4 + class), NULL for other rows
    local FC="(CASE WHEN ((1 << status) & $UP_MASK) != 0 $PTR_COND THEN $FC_CASE END)"
    # counted upstream reply: any server except conditional-forwarding targets; Unbound's only from the cutoff up
    local IS_UP="(reply_time IS NOT NULL AND ($FC % 4 = 0 OR ($FC % 4 IN (1, 3) AND reply_time >= $up_min_sec)))"
    # reply from Unbound's own cache (faster than the cutoff)
    local IS_UC="(reply_time IS NOT NULL AND $FC % 4 = 1 AND reply_time < $up_min_sec)"
    local P_EXPR="($FC / 4)"
    # Fine latency bucket for exact percentiles: 1 us steps below 1 ms, 1 ms steps up to 60 s (monotonic in reply_time)
    local FB_EXPR="(CASE WHEN reply_time < 0.001 THEN CAST(reply_time * 1000000 AS INTEGER) WHEN reply_time < 60 THEN 1000 + CAST(reply_time * 1000 AS INTEGER) ELSE 61000 END)"
    # u = server * 10 + latency bucket (0..8); bucket 9 = answered from Unbound's cache (not counted)
    # (the inner query returns fc once per row; these work on it, so the server lookup runs only once)
    local UP_O="(rt IS NOT NULL AND (fc % 4 = 0 OR (fc % 4 IN (1, 3) AND rt >= $up_min_sec)))"
    local UC_O="(rt IS NOT NULL AND fc % 4 = 1 AND rt < $up_min_sec)"
    local U_ALWAYS="CASE WHEN $UP_O THEN fc / 4 * 10 + ${UP_CASE//reply_time/rt} WHEN $UC_O THEN fc / 4 * 10 + 9 END"
    local UPX="(CASE WHEN u IS NOT NULL AND u % 10 < 9 THEN u / 10 ELSE 0 END)"   # server of a counted row, 0 = none
    local FB_ALWAYS="CASE WHEN m OR $UP_O THEN ${FB_EXPR//reply_time/rt} END"
    local U_COL="NULL" FB_COL="NULL"
    { [ "$DO_UP" = true ] || [ "$DO_REF" = true ]; } && U_COL="$U_ALWAYS"
    [ "${#TARGETS[@]}" -gt 0 ] && FB_COL="$FB_ALWAYS"

    # Inner query computes each flag ONCE per row (OFFSET 0 stops SQLite from re-expanding them per column).
    # $1 = extra column expression (window mask or day), $2 = WHERE condition, $3/$4 = u/fb column
    classified() {
        echo "SELECT rt, x,
 CASE WHEN rt IS NULL THEN 0 WHEN m THEN 2 WHEN b THEN 1 ELSE 3 END AS c,
 CASE WHEN m THEN ${TIER_CASE//reply_time/rt} END AS t,
 CASE WHEN m THEN ${HEALTH_CASE//reply_time/rt} END AS h,
 $3 AS u,
 $4 AS fb
 FROM (SELECT reply_time AS rt, $1 AS x, $IS_MET AS m, $IS_BLK AS b, $FC AS fc
       FROM $SRC WHERE $2 $SQL_DOMAIN_CLAUSE LIMIT -1 OFFSET 0)"
    }

    # --- Probe: a few index seeks only (instant). A COUNT(*) would read the whole timestamp index, which is
    # slow on Pi-hole's never-vacuumed database on an SD card (random reads). The count is only used to
    # choose how to split the work, so an estimate is enough: Pi-hole writes rows in time order, so the id
    # span of the time range ~ the number of rows in it.
    local probe sq_ver rows=0 ID_MIN=0 ID_MAX=0 first_id last_id ts_before _maj=0 _min=0 avail_kb=0 _k _v
    probe=$(printf '.timeout 30000\nSELECT sqlite_version(), (SELECT MIN(id) FROM queries), (SELECT MAX(id) FROM queries), (SELECT id FROM queries WHERE timestamp >= %s ORDER BY timestamp LIMIT 1), (SELECT id FROM queries WHERE timestamp <= %s ORDER BY timestamp DESC LIMIT 1);\n' "$R_START" "$QUERY_END" | sqlite3 "$DBfile" 2>/dev/null)
    IFS='|' read -r sq_ver ID_MIN ID_MAX first_id last_id <<< "$probe"
    [[ "$ID_MIN" =~ ^-?[0-9]+$ && "$ID_MAX" =~ ^-?[0-9]+$ ]] || { ID_MIN=0; ID_MAX=0; }
    if [[ "$first_id" =~ ^-?[0-9]+$ && "$last_id" =~ ^-?[0-9]+$ ]]; then
        rows=$(( ID_MAX - ID_MIN + 1 ))      # default: assume the range covers the table (unordered ids)
        if [ "$first_id" -le "$last_id" ]; then
            # ids in time order? (the row just before the range must be older than the range, 1h tolerance)
            ts_before=$(printf '.timeout 30000\nSELECT timestamp FROM queries WHERE id < %s ORDER BY id DESC LIMIT 1;\n' "$first_id" | sqlite3 "$DBfile" 2>/dev/null)
            ts_before="${ts_before%%.*}"   # Pi-hole v6 stores timestamps with sub-second precision
            if ! [[ "$ts_before" =~ ^[0-9]+$ ]] || [ "$ts_before" -lt $(( R_START + 3600 )) ]; then
                rows=$(( last_id - first_id + 1 ))
            fi
        fi
    fi
    IFS=. read -r _maj _min _ <<< "$sq_ver"
    local HAVE_UPSERT=false
    [[ "$_maj" =~ ^[0-9]+$ && "$_min" =~ ^[0-9]+$ ]] && { [ "$_maj" -gt 3 ] || { [ "$_maj" -eq 3 ] && [ "$_min" -ge 24 ]; }; } && HAVE_UPSERT=true
    while read -r _k _v _; do [ "$_k" = "MemAvailable:" ] && { avail_kb=$_v; break; }; done < /proc/meminfo 2>/dev/null

    phls_mark probe
    # --- Split the work across CPU cores (counts from the slices simply add up) ---
    local cores=1 K=1
    cores=$(nproc 2>/dev/null || echo 1); [ "$cores" -gt 8 ] && cores=8
    if [ "$cores" -gt 1 ] && [ "$rows" -ge 50000 ]; then K=$cores; fi
    if [ "$avail_kb" -gt 0 ] && [ "$avail_kb" -lt $(( K * 32768 )) ]; then K=1; fi
    [ "$HAVE_UPSERT" = false ] && K=1

    # Slice mode:
    #  "id"  - each core reads ONE contiguous block of the table (rowid range). Every page of the database
    #          file is read once in total: best for SD cards / databases larger than RAM. Used when the
    #          time range covers most of the table (the usual dashboard case).
    #  "mod" - core i takes rows with id % K = i through the timestamp index. Used when the range is only
    #          a small part of the table (e.g. -24h on a 91-day database).
    local SLICE_MODE="mod" ID_SPAN=$(( ID_MAX - ID_MIN + 1 )) ID_STEP=1
    if [ "$K" -gt 1 ] && [ "$ID_SPAN" -gt 0 ] && [ $(( rows * 4 )) -ge $(( ID_SPAN * 3 )) ]; then
        SLICE_MODE="id"; ID_STEP=$(( ID_SPAN / K + 1 ))
    fi
    # slice_cond <slice> <from_ts> <to_ts> [<= | <]   (timestamps can be fractional: never leave gaps)
    slice_cond() {
        local op="${4:-<=}"
        if [ "$K" -eq 1 ]; then echo "timestamp >= $2 AND timestamp $op $3"
        elif [ "$SLICE_MODE" = "id" ]; then
            # unary + keeps SQLite on the rowid range instead of the timestamp index
            echo "id >= $(( ID_MIN + $1 * ID_STEP )) AND id < $(( ID_MIN + ($1 + 1) * ID_STEP )) AND +timestamp >= $2 AND +timestamp $op $3"
        else echo "timestamp >= $2 AND timestamp $op $3 AND id % $K = $1"; fi
    }
    run_jobs() {   # run_jobs <parallel true/false> <job names...>
        local par="$1" jb pl=(); shift
        for jb in "$@"; do
            if [ "$par" = true ]; then
                sqlite3 "$DBfile" < "$WORK_DIR/$jb.sql" > "$WORK_DIR/$jb.out" 2>> "$WORK_DIR/sqlite.err" & pl+=($!)
            else
                sqlite3 "$DBfile" < "$WORK_DIR/$jb.sql" > "$WORK_DIR/$jb.out" 2>> "$WORK_DIR/sqlite.err"
            fi
        done
        [ "${#pl[@]}" -gt 0 ] && wait "${pl[@]}"
        return 0
    }

    local HDR=$'.mode list\n.headers off\n.output /dev/null\nPRAGMA busy_timeout = 30000;\nPRAGMA temp_store = MEMORY;\n.output stdout'
    local AGG_TABLE="CREATE TEMP TABLE agg (k INTEGER PRIMARY KEY, x INTEGER, c INTEGER, t INTEGER, h INTEGER, u INTEGER, fb INTEGER, n INTEGER, s REAL, q REAL);"
    # agg_insert <inner select> <x multiplier>: UPSERT into agg (no sort, a few MB of RAM whatever the DB size)
    agg_insert() {
        if [ "$HAVE_UPSERT" = true ]; then
            echo "INSERT INTO agg SELECT (((((IFNULL(fb, 61001) * $2 + x) * 4 + c) * 32 + IFNULL(t, 31)) * 5 + IFNULL(h, 4)) * 161 + IFNULL(u, 160)), x, c, t, h, u, fb, 1, IFNULL(rt, 0.0), IFNULL(rt * rt, 0.0) FROM ($1) WHERE true"
            echo " ON CONFLICT(k) DO UPDATE SET n = n + 1, s = s + excluded.s, q = q + excluded.q;"
        else
            echo "INSERT INTO agg (x, c, t, h, u, fb, n, s, q) SELECT x, c, t, h, u, fb, COUNT(*), SUM(rt), SUM(rt * rt) FROM ($1) GROUP BY x, c, t, h, u, fb;"
        fi
    }
    [ "$HAVE_UPSERT" = false ] && AGG_TABLE="CREATE TEMP TABLE agg (x INTEGER, c INTEGER, t INTEGER, h INTEGER, u INTEGER, fb INTEGER, n INTEGER, s REAL, q REAL);"
    local T_START=${EPOCHREALTIME:-}

    # =====================================================================================
    # DAILY CACHE (dashboard runs): finished days are counted once and stored on disk.
    # Each run then only reads the unfinished tail plus the edge day of each window.
    # =====================================================================================
    local CACHE_ON=false CACHE_STATE="off" CACHE_FILE="" CACHE_WATCH="" use_from=0 use_to=0 built=0
    if [ "$DASH_MODE" = true ] && [ "$has_dom" -eq 0 ] && [ "$ENABLE_CACHE" != "false" ] && [ "$HAVE_UPSERT" = true ]; then
        CACHE_ON=true
        local CACHE_DIR="$PHLS_STATE_DIR/cache"
        CACHE_FILE="$CACHE_DIR/phls_${DASH_PROFILE//[^a-zA-Z0-9_-]/_}.db"
        mkdir -p "$CACHE_DIR" 2>/dev/null || CACHE_ON=false
        # e.g. cache created by root (sudo / root cron job) and this run is a normal user: leave it alone
        if [ "$CACHE_ON" = true ] && { [ ! -w "$CACHE_DIR" ] || { [ -e "$CACHE_FILE" ] && [ ! -w "$CACHE_FILE" ]; }; }; then
            CACHE_ON=false; CACHE_STATE="off (cache not writable by $(id -un))"
        fi
    fi
    if [ "$CACHE_ON" = true ]; then
        local DAY=86400 SETTLE=7200
        local want_from=$(( (R_START + DAY - 1) / DAY ))          # first day fully inside the range
        local settled_to=$(( (QUERY_END - SETTLE) / DAY ))         # days < this are finished (+2h margin)
        # Fingerprint of everything that changes how a row is counted
        local FP
        FP=$(printf '%s\n' "phls-cache-3" "$DBfile" "$IS_MET" "$IS_BLK" "$IS_UP" "$IS_UC" "$U_ALWAYS" "$TIER_CASE" "$HEALTH_CASE" "$UP_CASE" "$FB_EXPR" | md5sum | cut -c1-32)
        local c_fp="" c_cs="" c_ce="" c_watch="" valid=false reason="new"
        if [ -s "$CACHE_FILE" ]; then
            # Read cache state and re-check sample days against the database (index seeks only)
            local chk
            chk=$(printf '.timeout 30000\nATTACH %s AS c;\nSELECT %s, (SELECT value FROM c.meta WHERE key = %s), (SELECT value FROM c.meta WHERE key = %s), (SELECT value FROM c.meta WHERE key = %s), (SELECT value FROM c.meta WHERE key = %s);\nSELECT %s, d.day, IFNULL(d.fid, %s), IFNULL(d.lid, %s), IFNULL((SELECT id FROM queries WHERE timestamp >= d.day * 86400 ORDER BY timestamp LIMIT 1), %s), IFNULL((SELECT id FROM queries WHERE timestamp < (d.day + 1) * 86400 ORDER BY timestamp DESC LIMIT 1), %s) FROM c.day_check d WHERE d.day >= %s AND ((d.day - %s) %% 15 = 0 OR d.day = (SELECT MAX(day) FROM c.day_check));\nSELECT %s, MIN(CAST(+timestamp AS INTEGER) / 86400) FROM queries WHERE id > CAST((SELECT value FROM c.meta WHERE key = %s) AS INTEGER) AND +timestamp >= %s AND +timestamp < CAST((SELECT value FROM c.meta WHERE key = %s) AS INTEGER) * 86400;\n' \
                "'$CACHE_FILE'" "'META'" "'fp'" "'cs'" "'ce'" "'watch'" "'CHK'" "'-'" "'-'" "'-'" "'-'" "$want_from" "$want_from" "'LATE'" "'maxid'" "$(( want_from * DAY ))" "'ce'" | sqlite3 "$DBfile" 2>/dev/null)
            local bad=0 late="" tag d f1 l1 f2 l2
            while IFS='|' read -r tag d f1 l1 f2 l2; do
                if [ "$tag" = "META" ]; then c_fp="$d"; c_cs="$f1"; c_ce="$l1"; c_watch="$f2"
                elif [ "$tag" = "CHK" ] && { [ "$f1" != "$f2" ] || [ "$l1" != "$l2" ]; }; then bad=1
                elif [ "$tag" = "LATE" ]; then late="$d"; fi
            done <<< "$chk"
            if [ "$c_fp" != "$FP" ]; then reason="settings changed"
            elif ! [[ "$c_cs" =~ ^[0-9]+$ && "$c_ce" =~ ^[0-9]+$ ]]; then reason="unreadable"
            elif [ "$c_cs" -gt "$want_from" ]; then reason="range grew"
            elif [ "$bad" -eq 1 ]; then reason="database changed"
            else valid=true; fi
            # Rows written into already-cached days after they were cached (e.g. a Pi without a hardware clock
            # booting with an old time): recount from the earliest affected day
            if [ "$valid" = true ] && [[ "$late" =~ ^[0-9]+$ ]] && [ "$late" -lt "$c_ce" ]; then
                c_ce="$late"; reason="late rows"
            fi
        fi

        # Band of latency buckets whose exact values are kept per day (kept across rebuilds as a good first guess)
        [[ "$c_watch" =~ ^[0-9]+(,[0-9]+)*$ ]] && CACHE_WATCH="$c_watch" || CACHE_WATCH=""
        local b_from b_to
        if [ "$valid" = true ]; then b_from="$c_ce"; else b_from="$want_from"; fi
        [ "$b_from" -lt "$want_from" ] && b_from="$want_from"
        b_to="$settled_to"
        {
            echo ".timeout 30000"
            echo "PRAGMA synchronous = NORMAL;"
            if [ "$valid" != true ]; then
                echo "DROP TABLE IF EXISTS meta; DROP TABLE IF EXISTS day_tot; DROP TABLE IF EXISTS day_hist; DROP TABLE IF EXISTS day_check; DROP TABLE IF EXISTS day_vals;"
                echo "CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);"
                echo "CREATE TABLE day_tot (day INTEGER, c INTEGER, t INTEGER, h INTEGER, u INTEGER, n INTEGER, s REAL, q REAL, PRIMARY KEY (day, c, t, h, u));"
                echo "CREATE TABLE day_hist (day INTEGER, g INTEGER, uf INTEGER, fb INTEGER, n INTEGER, PRIMARY KEY (day, g, uf, fb));"
                echo "CREATE TABLE day_check (day INTEGER PRIMARY KEY, fid INTEGER, lid INTEGER);"
                echo "CREATE TABLE day_vals (day INTEGER, fb INTEGER, g INTEGER, uf INTEGER, rt REAL, n INTEGER, PRIMARY KEY (day, fb, g, uf, rt)) WITHOUT ROWID;"
                echo "INSERT INTO meta VALUES ('fp', '$FP'), ('cs', '$want_from'), ('ce', '$want_from'), ('maxid', '$ID_MAX'), ('watch', '$CACHE_WATCH');"
            else
                # Leftovers of an interrupted run, and days that left the range
                echo "DELETE FROM day_tot WHERE day >= $c_ce OR day < $(( want_from - 1 ));"
                echo "DELETE FROM day_hist WHERE day >= $c_ce OR day < $(( want_from - 1 ));"
                echo "DELETE FROM day_check WHERE day >= $c_ce OR day < $(( want_from - 1 ));"
                echo "DELETE FROM day_vals WHERE day >= $c_ce OR day < $(( want_from - 1 ));"
                # pruned days are gone: move the recorded start so a later larger range triggers a rebuild
                echo "UPDATE meta SET value = CAST(MAX(CAST(value AS INTEGER), $(( want_from - 1 ))) AS TEXT) WHERE key = 'cs';"
            fi
        } | sqlite3 "$CACHE_FILE" 2>> "$WORK_DIR/sqlite.err"
        if [ "$valid" = true ]; then
            CACHE_STATE="used"; [ "$reason" = "late rows" ] && CACHE_STATE="used (late rows: recounted from day $c_ce)"
        else CACHE_STATE="rebuilt ($reason)"; fi
        if [ -s "$WORK_DIR/sqlite.err" ]; then
            rm -f "$CACHE_FILE"; CACHE_ON=false; CACHE_STATE="error (cache dropped)"; b_to="$b_from"
        fi

        # Count the new finished days (usually 0 or 1; all of them on a rebuild)
        if [ "$b_from" -lt "$b_to" ]; then
            built=$(( b_to - b_from ))
            local BK=1 B_JOBS=() bi
            [ "$built" -gt 3 ] && BK=$K
            local KSAVE=$K; K=$BK
            for ((bi = 0; bi < BK; bi++)); do
                {
                    echo "$HDR"
                    echo "$AGG_TABLE"
                    local BINNER
                    BINNER=$(classified "CAST(timestamp AS INTEGER) / 86400 - $b_from" "$(slice_cond "$bi" $(( b_from * DAY )) $(( b_to * DAY )) "<")" "$U_ALWAYS" "$FB_ALWAYS")
                    agg_insert "$BINNER" 4096
                    [ -n "$CACHE_WATCH" ] && echo "CREATE TEMP TABLE v AS SELECT x + $b_from AS day, fb, c = 2 AS g, $UPX AS uf, rt, COUNT(*) AS n FROM ($BINNER) WHERE fb IN ($CACHE_WATCH) GROUP BY 1, 2, 3, 4, 5;"
                    echo "ATTACH '$CACHE_FILE' AS c;"
                    echo "BEGIN IMMEDIATE;"
                    echo "INSERT INTO c.day_tot SELECT * FROM (SELECT x + $b_from, c, IFNULL(t, -1), IFNULL(h, -1), IFNULL(u, -1), SUM(n), SUM(s), SUM(q) FROM agg GROUP BY x, c, t, h, u) WHERE true ON CONFLICT DO UPDATE SET n = n + excluded.n, s = s + excluded.s, q = q + excluded.q;"
                    echo "INSERT INTO c.day_hist SELECT * FROM (SELECT x + $b_from, c = 2, $UPX, fb, SUM(n) FROM agg WHERE fb IS NOT NULL GROUP BY x, c = 2, $UPX, fb) WHERE true ON CONFLICT DO UPDATE SET n = n + excluded.n;"
                    [ -n "$CACHE_WATCH" ] && echo "INSERT INTO c.day_vals SELECT * FROM v WHERE true ON CONFLICT DO UPDATE SET n = n + excluded.n;"
                    echo "COMMIT;"
                } > "$WORK_DIR/b_$bi.sql"; B_JOBS+=("b_$bi")
            done
            if [ "$BK" -gt 1 ]; then run_jobs true "${B_JOBS[@]}"; else run_jobs false "${B_JOBS[@]}"; fi
            K=$KSAVE
            # Record what each day looked like, then mark the days as cached (only after everything succeeded)
            if [ ! -s "$WORK_DIR/sqlite.err" ]; then
                printf '.timeout 30000\nATTACH %s AS c;\nPRAGMA c.synchronous = NORMAL;\nBEGIN IMMEDIATE;\nWITH RECURSIVE d(day) AS (SELECT %s UNION ALL SELECT day + 1 FROM d WHERE day + 1 < %s)\nINSERT OR REPLACE INTO c.day_check SELECT day, (SELECT id FROM queries WHERE timestamp >= day * 86400 ORDER BY timestamp LIMIT 1), (SELECT id FROM queries WHERE timestamp < (day + 1) * 86400 ORDER BY timestamp DESC LIMIT 1) FROM d;\nINSERT OR REPLACE INTO c.meta VALUES (%s, %s), (%s, %s);\nCOMMIT;\n' \
                    "'$CACHE_FILE'" "$b_from" "$b_to" "'ce'" "'$b_to'" "'maxid'" "'$ID_MAX'" | sqlite3 "$DBfile" 2>> "$WORK_DIR/sqlite.err"
            fi
            if [ -s "$WORK_DIR/sqlite.err" ]; then
                # Never trust a half-written cache: drop it, this run falls back to a full read
                rm -f "$CACHE_FILE"; CACHE_ON=false; CACHE_STATE="error (cache dropped)"
            fi
        fi
        [ "$CACHE_ON" = true ] && fix_perms "$CACHE_FILE" "user"
        if [ "$CACHE_ON" = true ]; then
            use_from="$want_from"; use_to="$b_to"
            [ "$use_from" -ge "$use_to" ] && CACHE_ON=false
        fi
    fi
    phls_mark cache

    # =====================================================================================
    # Phase 1: counts / sums / tiers / health / fine histogram
    # =====================================================================================
    local P1_JOBS=() j
    if [ "$CACHE_ON" = true ]; then
        local CS_TS=$(( use_from * 86400 )) CE_TS=$(( use_to * 86400 ))
        # Cached days: a whole day belongs to window W if it starts at or after W's start
        local CMASK="(0"
        for b in 0 1 2 3 4; do [ -n "${WIN_TS[$b]}" ] && CMASK+=" + (day * 86400 >= ${WIN_TS[$b]}) * $((1 << b))"; done
        CMASK+=")"
        {
            echo "$HDR"
            echo "SELECT 'G', $CMASK AS mk, c, NULLIF(t, -1), NULLIF(h, -1), NULLIF(u, -1), '', SUM(n), SUM(s), SUM(q) FROM day_tot WHERE day >= $use_from AND day < $use_to GROUP BY mk, c, t, h, u;"
            echo ".output $WORK_DIR/p1_cache.h"
            echo "SELECT 'H', $CMASK AS mk, g, uf, fb, SUM(n) FROM day_hist WHERE day >= $use_from AND day < $use_to GROUP BY fb, mk, g, uf ORDER BY fb;"
        } > "$WORK_DIR/p1_cache.sql"
        # Raw rows: outside the cached days, or in a cached day that a window only partly covers.
        # A raw row in a cached day only counts for the windows that start inside that day.
        local RMASK="(0"
        for b in 0 1 2 3 4; do
            [ -n "${WIN_TS[$b]}" ] && RMASK+=" + (timestamp >= ${WIN_TS[$b]} AND NOT (timestamp >= $CS_TS AND timestamp < $CE_TS AND (CAST(timestamp AS INTEGER) / 86400) * 86400 >= ${WIN_TS[$b]})) * $((1 << b))"
        done
        RMASK+=")"
        # Raw time segments, as half-open ranges [from, to) because timestamps can be fractional:
        # before the cached days, and each window's edge day inside the cached days. Merged so no row is read
        # twice. The tail after the cached days is [CE_TS, QUERY_END] (inclusive end, like an uncached run).
        local segs=() ts
        [ "$R_START" -lt "$CS_TS" ] && segs+=("$R_START $CS_TS")
        for b in 0 1 2 3 4; do
            ts="${WIN_TS[$b]}"; [ -z "$ts" ] && continue
            if [ "$ts" -gt "$CS_TS" ] && [ "$ts" -lt "$CE_TS" ] && [ $(( ts % 86400 )) -ne 0 ]; then
                segs+=("$ts $(( ts - ts % 86400 + 86400 ))")
            fi
        done
        local merged=() cur_s="" cur_e="" a z
        while read -r a z; do
            [ -z "$a" ] && continue
            if [ -z "$cur_s" ]; then cur_s=$a; cur_e=$z
            elif [ "$a" -le "$cur_e" ]; then [ "$z" -gt "$cur_e" ] && cur_e=$z
            else merged+=("$cur_s $cur_e"); cur_s=$a; cur_e=$z; fi
        done < <(printf '%s\n' "${segs[@]}" | sort -n -k1,1)
        [ -n "$cur_s" ] && merged+=("$cur_s $cur_e")
        {
            echo "$HDR"
            echo "$AGG_TABLE"
            for a in "${merged[@]}"; do
                agg_insert "$(classified "$RMASK" "timestamp >= ${a% *} AND timestamp < ${a#* }" "$U_COL" "$FB_COL")" 32
            done
            agg_insert "$(classified "$RMASK" "timestamp >= $CE_TS AND timestamp <= $QUERY_END" "$U_COL" "$FB_COL")" 32
            echo "SELECT 'G', x, c, t, h, u, '', SUM(n), SUM(s), SUM(q) FROM agg GROUP BY x, c, t, h, u;"
            echo ".output $WORK_DIR/p1_raw.h"
            echo "SELECT 'H', x, c = 2, $UPX, fb, SUM(n) FROM agg WHERE fb IS NOT NULL GROUP BY fb, x, c = 2, $UPX ORDER BY fb;"
        } > "$WORK_DIR/p1_raw.sql"
        # the cache query reads the cache file, the raw query the Pi-hole database - run both at once
        sqlite3 "$CACHE_FILE" < "$WORK_DIR/p1_cache.sql" > "$WORK_DIR/p1_cache.out" 2>> "$WORK_DIR/sqlite.err" &
        local cpid=$!
        run_jobs false p1_raw
        wait "$cpid"
        P1_JOBS=(p1_cache p1_raw)
    else
        for ((i = 0; i < K; i++)); do
            {
                echo "$HDR"
                echo "$AGG_TABLE"
                agg_insert "$(classified "$MASK_RAW" "$(slice_cond "$i" "$R_START" "$QUERY_END")" "$U_COL" "$FB_COL")" 32
                echo "SELECT 'G', x, c, t, h, u, '', SUM(n), SUM(s), SUM(q) FROM agg GROUP BY x, c, t, h, u;"
                echo ".output $WORK_DIR/p1_$i.h"
                echo "SELECT 'H', x, c = 2, $UPX, fb, SUM(n) FROM agg WHERE fb IS NOT NULL GROUP BY fb, x, c = 2, $UPX ORDER BY fb;"
            } > "$WORK_DIR/p1_$i.sql"; P1_JOBS+=("p1_$i")
        done
        # Upstream graph ignores the domain filter (v4.4 semantics) -> separate pass only when one is set
        if [ "$DO_UP" = true ] && [ "$has_dom" -eq 1 ]; then
            local UFB="NULL"; [ "${#TARGETS[@]}" -gt 0 ] && UFB="$FB_EXPR"
            local UINNER="SELECT reply_time AS rt, $MASK_RAW AS x, $UP_CASE AS u, $UFB AS fb FROM queries WHERE timestamp >= $R_START AND timestamp <= $QUERY_END AND $IS_UP"
            {
                echo "$HDR"
                if [ "$HAVE_UPSERT" = true ]; then
                    echo "CREATE TEMP TABLE uagg (k INTEGER PRIMARY KEY, x INTEGER, u INTEGER, fb INTEGER, n INTEGER, s REAL, q REAL);"
                    echo "INSERT INTO uagg SELECT (IFNULL(fb, 61001) * 32 + x) * 10 + u, x, u, fb, 1, rt, rt * rt FROM ($UINNER) WHERE true ON CONFLICT(k) DO UPDATE SET n = n + 1, s = s + excluded.s, q = q + excluded.q;"
                else
                    echo "CREATE TEMP TABLE uagg AS SELECT x, u, fb, COUNT(*) AS n, SUM(rt) AS s, SUM(rt * rt) AS q FROM ($UINNER) GROUP BY x, u, fb;"
                fi
                echo "SELECT 'UG', x, '', '', '', u, '', SUM(n), SUM(s), SUM(q) FROM uagg GROUP BY x, u;"
                echo ".output $WORK_DIR/p1_ug.h"
                echo "SELECT 'U', x, 0, 1, fb, SUM(n) FROM uagg WHERE fb IS NOT NULL GROUP BY fb, x ORDER BY fb;"
            } > "$WORK_DIR/p1_ug.sql"; P1_JOBS+=("p1_ug")
        fi
        if [ "$K" -gt 1 ]; then run_jobs true "${P1_JOBS[@]}"; else run_jobs false "${P1_JOBS[@]}"; fi
    fi
    phls_mark phase1
    local T_P1=${EPOCHREALTIME:-}

    # =====================================================================================
    # Phase 2: exact percentiles. The fine histogram tells which bucket holds each k-th value and its
    # position inside it; only rows of those few buckets are read and sorted.
    # =====================================================================================
    local cand=0
    if [ "${#TARGETS[@]}" -gt 0 ]; then
        local tgt_str="${TARGETS[*]}" hfiles=()
        for j in "${P1_JOBS[@]}"; do [ -f "$WORK_DIR/$j.h" ] && hfiles+=("$WORK_DIR/$j.h"); done
        if [ "${#hfiles[@]}" -gt 0 ]; then sort -m -t'|' -k5,5n "${hfiles[@]}"; fi > "$WORK_DIR/p1_sorted"
        # Lines: H|window-mask|is_latency_row|is_upstream_row|bucket|count   (U = upstream rows of the no-domain pass)
        # Counts are accumulated per (set, window) and checked against the targets once per latency bucket.
        awk -F'|' -v targets="$tgt_str" -v hasdom="$has_dom" -v persrv="$([ -n "$PLIST" ] && echo 1 || echo 0)" '
            BEGIN {
                nt = split(targets, TT, " ")
                for (i = 1; i <= nt; i++) {
                    split(TT[i], p, ":"); tag[i] = p[1]; set[i] = p[2]; wbit[i] = p[3] + 0
                    sc[i] = (p[2] == "g") ? 1 : ((p[2] == "u") ? 2 : ((p[2] == "r") ? 3 : 3 + substr(p[2], 2)))
                }
                for (mm = 0; mm < 32; mm++) { nbits[mm] = 0; for (bb = 0; bb < 5; bb++) if (int(mm / (2 ^ bb)) % 2) bl[mm, ++nbits[mm]] = bb }
            }
            function add(arr,   mk, n, z) {
                mk = $2 + 0; n = $6 + 0
                for (z = 1; z <= nbits[mk]; z++) {
                    if ($1 == "H") { if ($3 == 1) arr[1, bl[mk, z]] += n; if ($4 > 0) { if (!hasdom) arr[2, bl[mk, z]] += n; arr[3, bl[mk, z]] += n; if (persrv) arr[3 + $4, bl[mk, z]] += n } }
                    else if (hasdom) arr[2, bl[mk, z]] += n
                }
            }
            function flush(   i, g) {
                if (gfb == "") return
                for (i = 1; i <= nt; i++) {
                    if ((fM[i] || kM[i] < 0) && (fP[i] || kP[i] < 0)) continue
                    g = A[sc[i], wbit[i]] + 0
                    if (!fM[i] && kM[i] >= 0 && cum[i] + g > kM[i]) { fM[i] = 1; fbM[i] = gfb; offM[i] = kM[i] - cum[i]; want = 1; left-- }
                    if (!fP[i] && kP[i] >= 0 && cum[i] + g > kP[i]) { fP[i] = 1; fbP[i] = gfb; offP[i] = kP[i] - cum[i]; want = 1; left-- }
                    cum[i] += g
                }
                if (want) candn += gall
                for (x in A) delete A[x]
                gall = 0; want = 0
            }
            NR == FNR { add(TOT); next }
            FNR == 1 {
                left = 0
                for (i = 1; i <= nt; i++) {
                    tot = TOT[sc[i], wbit[i]] + 0
                    if (tot > 0) { kM[i] = int((tot - 1) / 2); kP[i] = int(tot * 0.95 - 1); if (kP[i] < 0) kP[i] = 0; left += 2 } else { kM[i] = -1; kP[i] = -1 }
                }
            }
            $5 != gfb { flush(); if (left <= 0) exit; gfb = $5 }
            { gall += $6; add(A) }
            END {
                if (left > 0) flush()
                for (i = 1; i <= nt; i++) {
                    if (fM[i]) print "T|" tag[i] "|M|" set[i] "|" wbit[i] "|" fbM[i] "|" offM[i]
                    if (fP[i]) print "T|" tag[i] "|P|" set[i] "|" wbit[i] "|" fbP[i] "|" offP[i]
                }
                printf "CAND|%.0f\n", candn
            }' "$WORK_DIR/p1_sorted" "$WORK_DIR/p1_sorted" > "$WORK_DIR/targets"

        phls_mark pick_buckets
        cand=$(awk -F'|' '$1 == "CAND" { print $2 }' "$WORK_DIR/targets")
        [[ "$cand" =~ ^[0-9]+$ ]] || cand=0
        local fb_list
        fb_list=$(awk -F'|' '$1 == "T" { print $6 }' "$WORK_DIR/targets" | sort -nu | paste -sd, -)
        local P2_MODE="full" VAL_INFO=""
        if [ -n "$fb_list" ]; then
            local P2_JOBS=()
            if [ "$CACHE_ON" = true ]; then
                # The long windows (7d / 30d / main range) need the cached days' exact values for their target
                # buckets. (12h / 24h never contain a whole cached day: their values come from the raw rows.)
                local needed missing
                needed=$(awk -F'|' '$1 == "T" && $5 >= 2 { print $6 }' "$WORK_DIR/targets" | sort -nu)
                missing=$(printf '%s\n' $needed | awk -v w="$CACHE_WATCH" 'BEGIN { n = split(w, a, ","); for (i = 1; i <= n; i++) W[a[i]] = 1 } NF && !($1 in W)')
                if [ -z "$missing" ]; then
                    P2_MODE="cache"
                else
                    # Refill: widen the band around the new targets and read their values once for all cached days
                    local band newwatch addb addlist nwlist reset=0 errsz fi F_JOBS=()
                    band=$(printf '%s\n' $needed | awk 'NF { f = $1 + 0
                        if (f < 1000) { lo = f - 30; hi = f + 30; if (lo < 0) lo = 0; if (hi > 999) hi = 999 }
                        else { lo = f - 3; hi = f + 3; if (lo < 1000) lo = 1000; if (hi > 61000) hi = 61000 }
                        for (b = lo; b <= hi; b++) print b }' | sort -nu)
                    newwatch=$( { printf '%s\n' $band; tr ',' '\n' <<< "$CACHE_WATCH"; } | awk 'NF' | sort -nu)
                    if [ "$(printf '%s\n' $newwatch | wc -l)" -gt 400 ]; then newwatch="$band"; reset=1; fi
                    addb=$(printf '%s\n' $newwatch | awk -v w="$CACHE_WATCH" -v r="$reset" 'BEGIN { if (!r) { n = split(w, a, ","); for (i = 1; i <= n; i++) W[a[i]] = 1 } } NF && !($1 in W)')
                    addlist=$(printf '%s\n' $addb | paste -sd, -); nwlist=$(printf '%s\n' $newwatch | paste -sd, -)
                    errsz=$(stat -c %s "$WORK_DIR/sqlite.err" 2>/dev/null || echo 0)
                    # values of these buckets left behind by an interrupted refill must not be counted twice
                    printf '.timeout 30000\nDELETE FROM day_vals WHERE fb IN (%s);\n' "$addlist" | sqlite3 "$CACHE_FILE" 2>> "$WORK_DIR/sqlite.err"
                    for ((fi = 0; fi < K; fi++)); do
                        {
                            echo "$HDR"
                            echo "CREATE TEMP TABLE v AS SELECT x AS day, fb, c = 2 AS g, $UPX AS uf, rt, COUNT(*) AS n FROM ($(classified "CAST(timestamp AS INTEGER) / 86400" "$(slice_cond "$fi" "$CS_TS" "$CE_TS" "<")" "$U_ALWAYS" "$FB_ALWAYS")) WHERE fb IN ($addlist) GROUP BY 1, 2, 3, 4, 5;"
                            echo "ATTACH '$CACHE_FILE' AS c;"
                            echo "BEGIN IMMEDIATE;"
                            echo "INSERT INTO c.day_vals SELECT * FROM v WHERE true ON CONFLICT DO UPDATE SET n = n + excluded.n;"
                            echo "COMMIT;"
                        } > "$WORK_DIR/f_$fi.sql"; F_JOBS+=("f_$fi")
                    done
                    if [ "$K" -gt 1 ]; then run_jobs true "${F_JOBS[@]}"; else run_jobs false "${F_JOBS[@]}"; fi
                    {
                        echo ".timeout 30000"
                        echo "BEGIN IMMEDIATE;"
                        [ "$reset" -eq 1 ] && echo "DELETE FROM day_vals WHERE fb NOT IN ($nwlist);"
                        echo "INSERT OR REPLACE INTO meta VALUES ('watch', '$nwlist');"
                        echo "COMMIT;"
                    } | sqlite3 "$CACHE_FILE" 2>> "$WORK_DIR/sqlite.err"
                    if [ "$(stat -c %s "$WORK_DIR/sqlite.err" 2>/dev/null || echo 0)" -gt "$errsz" ]; then
                        rm -f "$CACHE_FILE"; VAL_INFO="value refill failed: cache dropped"   # this run: full read below
                    else
                        P2_MODE="cache"; CACHE_WATCH="$nwlist"
                        VAL_INFO="refilled $(printf '%s\n' $addb | wc -l) buckets$([ "$reset" -eq 1 ] && echo ', band reset')"
                    fi
                fi
            fi
            if [ "$P2_MODE" = "cache" ]; then
                # Candidates = raw rows that are not in a cached day (tail, edge days) + the cached days' values
                local first=1 cond
                {
                    echo "$HDR"
                    echo "SELECT 'C', fb, x, ig, iu, ir, rt, COUNT(*), pq FROM ("
                    for a in "${merged[@]}" "TAIL"; do
                        if [ "$a" = "TAIL" ]; then cond="timestamp >= $CE_TS AND timestamp <= $QUERY_END"
                        else cond="timestamp >= ${a% *} AND timestamp < ${a#* }"; fi
                        [ "$first" -eq 0 ] && echo " UNION ALL"; first=0
                        echo " SELECT reply_time AS rt, $RMASK AS x, $FB_EXPR AS fb,"
                        echo "  CASE WHEN $IS_MET THEN 1 ELSE 0 END AS ig, CASE WHEN $IS_UP THEN 1 ELSE 0 END AS iu, CASE WHEN $IS_UP THEN 1 ELSE 0 END AS ir,"
                        echo "  CASE WHEN $IS_UP THEN $P_EXPR ELSE 0 END AS pq"
                        echo "  FROM $SRC WHERE $cond"
                    done
                    echo ") WHERE fb IN ($fb_list) AND x > 0 AND (ig + iu + ir) > 0 GROUP BY rt, fb, x, ig, iu, ir, pq ORDER BY rt;"
                } > "$WORK_DIR/p2_raw.sql"
                {
                    echo "$HDR"
                    echo "SELECT 'C', fb, $CMASK AS mk, g, uf > 0, uf > 0, rt, SUM(n), uf FROM day_vals WHERE day >= $use_from AND day < $use_to AND fb IN ($fb_list) AND fb IN ($CACHE_WATCH) GROUP BY rt, fb, mk, g, uf ORDER BY rt;"
                } > "$WORK_DIR/p2_cvals.sql"
                sqlite3 "$CACHE_FILE" < "$WORK_DIR/p2_cvals.sql" > "$WORK_DIR/p2_cvals.out" 2>> "$WORK_DIR/sqlite.err" &
                local vpid=$!
                run_jobs false p2_raw
                wait "$vpid"
                P2_JOBS=(p2_raw p2_cvals)
            else
            # Each core streams only the candidate values of its slice, sorted by reply_time and grouped
            # (Pi-hole records reply times in microseconds, so many rows share a value: one line + count each)
            local P2_JOBS=()
            for ((i = 0; i < K; i++)); do
                {
                    printf '.mode list\n.headers off\n.output /dev/null\nPRAGMA busy_timeout = 30000;\n.output stdout\n'
                    echo "SELECT 'C', fb, x, ig, iu, ir, rt, COUNT(*), pq FROM (SELECT reply_time AS rt, $MASK_RAW AS x, $FB_EXPR AS fb,"
                    echo " CASE WHEN $IS_MET AND ($DOM_EXPR) THEN 1 ELSE 0 END AS ig,"
                    echo " CASE WHEN $IS_UP THEN 1 ELSE 0 END AS iu,"
                    echo " CASE WHEN $IS_UP AND ($DOM_EXPR) THEN 1 ELSE 0 END AS ir,"
                    echo " CASE WHEN $IS_UP THEN $P_EXPR ELSE 0 END AS pq"
                    echo " FROM $SRC WHERE $(slice_cond "$i" "$R_START" "$QUERY_END")) WHERE fb IN ($fb_list) AND (ig + iu + ir) > 0 GROUP BY rt, fb, x, ig, iu, ir, pq ORDER BY rt;"
                } > "$WORK_DIR/p2_$i.sql"; P2_JOBS+=("p2_$i")
            done
            if [ "$K" -gt 1 ]; then run_jobs true "${P2_JOBS[@]}"; else run_jobs false "${P2_JOBS[@]}"; fi
            fi
            phls_mark phase2_sql
            # Each slice is already sorted by reply_time: merge (no re-sort), stop once every target is found
            local p2files=(); for j in "${P2_JOBS[@]}"; do p2files+=("$WORK_DIR/$j.out"); done
            sort -m -t'|' -k7,7g "${p2files[@]}" | awk -F'|' '
                BEGIN { for (mm = 0; mm < 32; mm++) for (bb = 0; bb < 5; bb++) isb[mm, bb] = int(mm / (2 ^ bb)) % 2 }
                FNR == NR { if ($1 == "T") { n++; tg[n] = $2; tq[n] = $3; col[n] = ($4 == "g") ? 4 : (($4 == "u") ? 5 : (($4 == "r") ? 6 : 5)); ps[n] = ($4 ~ /^p/) ? substr($4, 2) + 0 : 0; tb[n] = $5 + 0; off[n] = $7 + 0; nf[$6]++; L[$6, nf[$6]] = n }; next }
                $1 == "C" && ($2 in nf) {
                    k = nf[$2]; mk = $3 + 0
                    for (x = 1; x <= k; x++) { id = L[$2, x]
                        if (id in val) continue
                        if ($(col[id]) == 1 && (ps[id] == 0 || $9 == ps[id]) && isb[mk, tb[id]]) { cnt[id] += $8; if (cnt[id] > off[id]) { val[id] = $7; if (++done == n) exit } }
                    }
                }
                END { for (id = 1; id <= n; id++) if (id in val) print "PCT|" tg[id] "|" tq[id] "|" val[id] }
            ' "$WORK_DIR/targets" - > "$WORK_DIR/p2.out"
        fi
    fi
    phls_mark phase2_merge
    local T_P2=${EPOCHREALTIME:-}

    # --- Parse everything with ONE awk process ---
    local VALS="$WORK_DIR/values"
    { for j in "${P1_JOBS[@]}"; do cat "$WORK_DIR/$j.out"; done; cat "$WORK_DIR/p2.out" 2>/dev/null; } | awk -F'|' \
        -v nt="$NT" -v dash="$DASH_MODE" -v math_all="$ENABLE_MATH_ALL_TIME" -v up_math_all="$DO_UP_ALL_MATH" \
        -v ref="$DO_REF" -v hasdom="$has_dom" -v doup="$DO_UP" -v plist="$PLIST" -v unbp="$UNB_P" -v servers="$UPS_JSON" \
        -v excl="$UPS_EXCL" -v pnames="$PNAMES" -v cutms="${UPSTREAM_DIST_MIN_CUTOFF:-3}" -v upmath="${W_MATH[*]} $DO_UP_ALL_MATH" '
        function f0(x) { return sprintf("%.0f", x + 0) }
        function ms(x) { return sprintf("%.2f", ((x == "") ? 0 : x) * 1000) }
        function avg(s, c) { return (c > 0) ? sprintf("%.2f", (s * 1000) / c) : "0.00" }
        function sd(s, q, c,   m, v) { if (c <= 0) return "0.00"; m = s / c; v = q / c - m * m; if (v < 0) v = 0; return sprintf("%.2f", sqrt(v) * 1000) }
        BEGIN { for (mm = 0; mm < 32; mm++) for (bb = 0; bb < 5; bb++) isb[mm, bb] = int(mm / (2 ^ bb)) % 2 }
        $1 == "G" {
            mk = $2 + 0; c = $3; t = $4; h = $5; u = $6; n = $8 + 0; s = $9 + 0; q = $10 + 0
            inmain = isb[mk, 4]
            if (inmain) {
                tot += n
                if (c == 0) inv += n; else val += n
                if (c == 1) blk += n
                if (c == 2) { an += n; dur += s; sqs += q; tier[t] += n; hl[h] += n }
            }
            if (dash == "true") {
                # u = server * 10 + bucket; bucket 9 = answered from the Unbound cache (not an upstream lookup)
                if (u != "") { ub = u % 10; usv = int(u / 10) } else { ub = -1; usv = 0 }
                for (w = 1; w <= 4; w++) if (isb[mk, w - 1]) {
                    if (c == 2) { wc[w] += n; ws[w] += s; wq[w] += q; wt[w, t] += n; wh[w, h] += n }
                    if (ub >= 0 && hasdom == 0 && doup == "true") {
                        if (ub == 9) uch[w] += n
                        else { uc[w] += n; us[w] += s; uq[w] += q; ut[w, ub] += n; pc[usv, w] += n; pS[usv, w] += s; pQ[usv, w] += q; pT[usv, w, ub] += n }
                    }
                }
                if (ub >= 0 && ub < 9 && inmain) {
                    if (hasdom == 0 && doup == "true") { uc[5] += n; us[5] += s; uq[5] += q; ut[5, ub] += n; pc[usv, 5] += n; pS[usv, 5] += s; pQ[usv, 5] += q; pT[usv, 5, ub] += n }
                    if (ref == "true") { rc += n; rs += s; rq += q }
                }
                if (ub == 9 && inmain && hasdom == 0 && doup == "true") uch[5] += n
            }
        }
        $1 == "UG" {
            mk = $2 + 0; u = $6; n = $8 + 0; s = $9 + 0; q = $10 + 0
            for (w = 1; w <= 4; w++) if (isb[mk, w - 1]) { uc[w] += n; us[w] += s; uq[w] += q; ut[w, u] += n }
            if (isb[mk, 4]) { uc[5] += n; us[5] += s; uq[5] += q; ut[5, u] += n }
        }
        $1 == "PCT" { if ($3 == "M") pm[$2] = $4; else pp[$2] = $4 }
        END {
            print "P_TOTAL=" f0(tot); print "P_INVALID=" f0(inv); print "P_VALID=" f0(val)
            print "P_BLOCKED=" f0(blk); print "P_ANALYZED=" f0(an)
            print "P_HEX=" f0(hl[0]); print "P_HGD=" f0(hl[1]); print "P_HFR=" f0(hl[2]); print "P_HPR=" f0(hl[3])
            if (an > 0) { print "P_AVG=" avg(dur, an); print "P_STD=" sd(dur, sqs, an) }
            for (i = 0; i < nt; i++) {
                print "TIER_COUNTS[" i "]=" f0(tier[i])
                print "TIER_PCTS[" i "]=" ((an > 0) ? sprintf("%.2f", (tier[i] / an) * 100) : "0.00")
            }
            if (math_all == "true") { print "P_MED=" ms(pm["all"]); print "P_95=" ms(pp["all"]) } else { print "P_MED=0.00"; print "P_95=0.00" }

            if (dash == "true") {
                split("12h 24h 7d 30d", wn, " "); split("W12 W24 W7D W30", wv, " "); split("12H 24H 7D 30D ALL", uv, " ")
                for (w = 1; w <= 4; w++) {
                    for (i = 0; i < nt; i++) print wv[w] "_TIERS[" i "]=" f0(wt[w, i])
                    print wv[w] "_STATS[0]=" avg(ws[w], wc[w]); print wv[w] "_STATS[1]=" sd(ws[w], wq[w], wc[w])
                    print wv[w] "_STATS[2]=" ms(pm["g" wn[w]]); print wv[w] "_STATS[3]=" ms(pp["g" wn[w]])
                    for (i = 0; i < 4; i++) print wv[w] "_STATS[" (4 + i) "]=" f0(wh[w, i])
                }
                for (w = 1; w <= 5; w++) {
                    for (i = 0; i < 9; i++) print "UP_TIERS_" uv[w] "[" i "]=" f0(ut[w, i])
                    print "UP_STATS_" uv[w] "[0]=" avg(us[w], uc[w]); print "UP_STATS_" uv[w] "[1]=" sd(us[w], uq[w], uc[w])
                    if (w < 5) { print "UP_STATS_" uv[w] "[2]=" ms(pm["u" wn[w]]); print "UP_STATS_" uv[w] "[3]=" ms(pp["u" wn[w]]) }
                    else if (up_math_all == "true") { print "UP_STATS_ALL[2]=" ms(pm["uall"]); print "UP_STATS_ALL[3]=" ms(pp["uall"]) }
                    else { print "UP_STATS_ALL[2]=0.00"; print "UP_STATS_ALL[3]=0.00" }
                }
                if (doup == "true" && hasdom == 0) {
                    # Upstream details: Unbound cache share, and per-server stats when there are 2+ servers
                    split("12h 24h 7d 30d all", wk, " "); split(upmath, um, " ")
                    js = "{\"cutoff_ms\":" (cutms + 0) ",\"servers\":" servers ",\"excluded\":" excl
                    if (unbp != " ") {
                        js = js ",\"unbound_cache\":{"
                        for (w = 1; w <= 5; w++) {
                            ut2 = uch[w] + 0; np2 = split(unbp, UB, " "); for (z = 1; z <= np2; z++) ut2 += pc[UB[z], w]
                            js = js (w > 1 ? "," : "") "\"" wk[w] "\":{\"hits\":" f0(uch[w]) ",\"replies\":" f0(ut2) ",\"percent\":" ((ut2 > 0) ? sprintf("%.1f", uch[w] * 100 / ut2) : "0") "}"
                        }
                        js = js "}"
                    }
                    if (plist != "") {
                        js = js ",\"by_server\":{"; nps = split(plist, PL, " "); first = 1
                        for (z = 1; z <= nps; z++) {
                            sv = PL[z]; if (pc[sv, 5] + pc[sv, 1] + pc[sv, 2] + pc[sv, 3] + pc[sv, 4] == 0) continue
                            js = js (first ? "" : ",") "\"" sv "\":{"; first = 0
                            for (w = 1; w <= 5; w++) {
                                tg = "u" wk[w] "_p" sv; dom = (um[w] == "true")
                                js = js (w > 1 ? "," : "") "\"" wk[w] "\":{\"count\":" f0(pc[sv, w]) ",\"average\":" avg(pS[sv, w], pc[sv, w]) ",\"stddev\":" sd(pS[sv, w], pQ[sv, w], pc[sv, w]) \
                                    ",\"median\":" (dom ? ms(pm[tg]) : "0.00") ",\"p95\":" (dom ? ms(pp[tg]) : "0.00") ",\"tiers\":["
                                for (i = 0; i < 9; i++) js = js (i ? "," : "") f0(pT[sv, w, i])
                                js = js "]}"
                            }
                            js = js "}"
                            if (!pnl) { pnl = 1; npn = split(pnames, PNA, "\t"); for (z2 = 1; z2 <= npn; z2++) if (PNA[z2] != "") { e2 = index(PNA[z2], "="); PN[substr(PNA[z2], 1, e2 - 1)] = substr(PNA[z2], e2 + 1) } }
                            hist = hist (hist == "" ? "" : ",") "\"" ((sv in PN) ? PN[sv] : sv) "\":[" avg(pS[sv, 5], pc[sv, 5]) "," ((um[5] == "true") ? ms(pm["uall_p" sv]) : "0.00") "," ((um[5] == "true") ? ms(pp["uall_p" sv]) : "0.00") "]"
                        }
                        js = js "}"
                    }
                    print "UPINFO_JSON=" js "}"
                    if (hist != "") print "UPHIST_JSON={" hist "}"
                }
                if (ref == "true") {
                    if (hasdom == 0) { pm["ref"] = pm["uall"]; pp["ref"] = pp["uall"] }
                    print "REF_COUNT=" f0(rc)
                    if (rc > 0) { print "REF_AVG_F=" avg(rs, rc); print "REF_STD=" sd(rs, rq, rc); print "REF_MED_F=" ms(pm["ref"]); print "REF_P95=" ms(pp["ref"]) }
                }
            }
        }' > "$VALS"

    phls_mark parse
    # Run as root in a user's install: give the cache back to the install dir's owner, so that user's runs can use it
    if [ "$EUID" -eq 0 ] && [ -n "$CACHE_FILE" ] && [ -d "$PHLS_STATE_DIR/cache" ]; then
        chown -R --reference="$PHLS_STATE_DIR" "$PHLS_STATE_DIR/cache" 2>/dev/null
    fi
    if [ -s "$WORK_DIR/sqlite.err" ] && [ "$SILENT_MODE" = false ]; then
        echo "⚠️  SQLite reported: $(head -n 1 "$WORK_DIR/sqlite.err")" >&2
    fi
    if [ "$DEBUG_MODE" = true ] && [ -n "$DEBUG_LOG" ]; then
        local tinfo=""
        [ -n "$T_START" ] && tinfo=$(awk -v a="$T_START" -v b="$T_P1" -v c="$T_P2" 'BEGIN { printf "phase1=%.2fs phase2=%.2fs", b - a, c - b }')
        {
            echo "--- SQL (rows=$rows, slices=$K/$cores cores ($SLICE_MODE), cache=$CACHE_STATE, days built=$built, percentiles=$P2_MODE${VAL_INFO:+ ($VAL_INFO)}, cached days used=$(( use_to > use_from ? use_to - use_from : 0 )), candidates=$cand, sqlite=$sq_ver, upsert=$HAVE_UPSERT, avail=${avail_kb}kB, $tinfo) ---"
            for j in "${P1_JOBS[@]}"; do cat "$WORK_DIR/$j.sql"; done
            cat "$WORK_DIR/targets" "$WORK_DIR/p2_0.sql" "$WORK_DIR/sqlite.err" 2>/dev/null
        } >> "$DEBUG_LOG"
    fi

    REF_COUNT=0; UPINFO_JSON=""; UPHIST_JSON=""
    while IFS='=' read -r _k _v; do [ -n "$_k" ] && printf -v "$_k" '%s' "$_v"; done < "$VALS"
    P_IGNORED=$((P_VALID - P_BLOCKED - P_ANALYZED))

    load_unbound_results
    phls_mark unbound_wait

    # Precision refinement (opt-in: ENABLE_MANUAL_REFINEMENT="yes")
    if [ "$DO_REF" = true ] && [ "$HAS_UNBOUND" = true ] && [ "$REF_COUNT" -gt 0 ]; then
        U_STD="$REF_STD"; U_AVG_F="$REF_AVG_F"; U_MED_F="$REF_MED_F"; U_P95="$REF_P95"
    fi
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
            R_LINES+=("Msg Cache   : ${U_MB_MSG}MB / ${U_MB_LIM_MSG}MB  ($U_PCT_MEM_MSG%)")
            R_LINES+=("RRset Cache : ${U_MB_RR}MB / ${U_MB_LIM_RR}MB ($U_PCT_MEM_RR%)")
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

    if [ "$HAS_UNBOUND" = true ] && [ "$((H_B1 + H_B2 + H_B3 + H_B4 + H_B5 + H_B6 + H_B7 + H_B8 + H_B9))" -gt 0 ]; then
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
    local CURRENT_EPOCH; printf -v CURRENT_EPOCH '%(%s)T' -1
    # "date" is the server's local time (no time zone); "epoch" lets the dashboard compare times
    # correctly when the browser is in another time zone
    JSTR="{\"version\": \"$VERSION\", \"hostname\": \"${HOSTNAME:-$(hostname)}\", \"date\": \"$CURRENT_DATE\", \"epoch\": $CURRENT_EPOCH, \"time_period\": \"$TIME_LABEL\", \"mode\": \"$MODE_LABEL\""
    if [ -n "$DOMAIN_FILTER" ]; then JSTR="$JSTR, \"domain_filter\": \"$DOMAIN_FILTER\""; fi
    JSTR="$JSTR, \"stats\": {\"total_queries\": $P_TOTAL, \"unsuccessful\": $P_INVALID, \"total_valid\": $P_VALID, \"blocked\": $P_BLOCKED, \"ignored\": $P_IGNORED, \"analyzed\": $P_ANALYZED}"
    # Global Health (All Time)
    JSTR="$JSTR, \"latency\": {\"average\": $P_AVG, \"median\": $P_MED, \"p95\": $P_95, \"stddev\": $P_STD, \"health\": {\"ex\": ${P_HEX:-0}, \"gd\": ${P_HGD:-0}, \"fr\": ${P_HFR:-0}, \"pr\": ${P_HPR:-0}}}"
    JSTR="$JSTR, \"tiers\": ["
    FIRST=true
    for i in "${!TIER_LABELS[@]}"; do
        if [ "$FIRST" = true ]; then FIRST=false; else JSTR="$JSTR, "; fi
        JSTR="$JSTR{\"label\": \"${TIER_LABELS[$i]}\", \"count\": ${TIER_COUNTS[$i]}, \"percentage\": ${TIER_PCTS[$i]}}"
    done
    JSTR="$JSTR]"
    
    if [ "$DASH_MODE" = true ]; then
        add_arr() { local -n arr=$2; local IFS=,; JSTR="$JSTR, \"$1\": [${arr[*]}]"; }
        
        # Standard Global Stats (With Health)
        add_arr tiers_12h W12_TIERS; add_arr tiers_24h W24_TIERS; add_arr tiers_7d W7D_TIERS; add_arr tiers_30d W30_TIERS
        JSTR="$JSTR, \"stats_12h\": {\"average\": ${W12_STATS[0]:-0}, \"stddev\": ${W12_STATS[1]:-0}, \"median\": ${W12_STATS[2]:-0}, \"p95\": ${W12_STATS[3]:-0}, \"health\": {\"ex\": ${W12_STATS[4]:-0}, \"gd\": ${W12_STATS[5]:-0}, \"fr\": ${W12_STATS[6]:-0}, \"pr\": ${W12_STATS[7]:-0}}}"
        JSTR="$JSTR, \"stats_24h\": {\"average\": ${W24_STATS[0]:-0}, \"stddev\": ${W24_STATS[1]:-0}, \"median\": ${W24_STATS[2]:-0}, \"p95\": ${W24_STATS[3]:-0}, \"health\": {\"ex\": ${W24_STATS[4]:-0}, \"gd\": ${W24_STATS[5]:-0}, \"fr\": ${W24_STATS[6]:-0}, \"pr\": ${W24_STATS[7]:-0}}}"
        JSTR="$JSTR, \"stats_7d\": {\"average\": ${W7D_STATS[0]:-0}, \"stddev\": ${W7D_STATS[1]:-0}, \"median\": ${W7D_STATS[2]:-0}, \"p95\": ${W7D_STATS[3]:-0}, \"health\": {\"ex\": ${W7D_STATS[4]:-0}, \"gd\": ${W7D_STATS[5]:-0}, \"fr\": ${W7D_STATS[6]:-0}, \"pr\": ${W7D_STATS[7]:-0}}}"
        JSTR="$JSTR, \"stats_30d\": {\"average\": ${W30_STATS[0]:-0}, \"stddev\": ${W30_STATS[1]:-0}, \"median\": ${W30_STATS[2]:-0}, \"p95\": ${W30_STATS[3]:-0}, \"health\": {\"ex\": ${W30_STATS[4]:-0}, \"gd\": ${W30_STATS[5]:-0}, \"fr\": ${W30_STATS[6]:-0}, \"pr\": ${W30_STATS[7]:-0}}}"
        
        # New Upstream Stats (Simulated Unbound)
        if [ "$ENABLE_UPSTREAM_DIST" = "true" ]; then
            add_arr up_tiers_12h UP_TIERS_12H; add_arr up_tiers_24h UP_TIERS_24H; add_arr up_tiers_7d UP_TIERS_7D; add_arr up_tiers_30d UP_TIERS_30D; add_arr up_tiers_all UP_TIERS_ALL
            JSTR="$JSTR, \"up_stats_12h\": {\"average\": ${UP_STATS_12H[0]:-0}, \"stddev\": ${UP_STATS_12H[1]:-0}, \"median\": ${UP_STATS_12H[2]:-0}, \"p95\": ${UP_STATS_12H[3]:-0}}"
            JSTR="$JSTR, \"up_stats_24h\": {\"average\": ${UP_STATS_24H[0]:-0}, \"stddev\": ${UP_STATS_24H[1]:-0}, \"median\": ${UP_STATS_24H[2]:-0}, \"p95\": ${UP_STATS_24H[3]:-0}}"
            JSTR="$JSTR, \"up_stats_7d\": {\"average\": ${UP_STATS_7D[0]:-0}, \"stddev\": ${UP_STATS_7D[1]:-0}, \"median\": ${UP_STATS_7D[2]:-0}, \"p95\": ${UP_STATS_7D[3]:-0}}"
            JSTR="$JSTR, \"up_stats_30d\": {\"average\": ${UP_STATS_30D[0]:-0}, \"stddev\": ${UP_STATS_30D[1]:-0}, \"median\": ${UP_STATS_30D[2]:-0}, \"p95\": ${UP_STATS_30D[3]:-0}}"
            JSTR="$JSTR, \"up_stats_all\": {\"average\": ${UP_STATS_ALL[0]:-0}, \"stddev\": ${UP_STATS_ALL[1]:-0}, \"median\": ${UP_STATS_ALL[2]:-0}, \"p95\": ${UP_STATS_ALL[3]:-0}}"
            [ -n "$UPINFO_JSON" ] && JSTR="$JSTR, \"upstream_info\": $UPINFO_JSON"
        fi
    fi
    
    JSTR="$JSTR, \"unbound_state\": \"${U_STATE:-not_installed}\", \"unbound\": " 
    if [ "$HAS_UNBOUND" = true ] && [[ "$U_STATUS" != *"Error"* ]]; then 
        U_JSON="{\"status\": \"active\", \"total_hits\": $U_HITS, \"total_miss\": $U_MISS, \"prefetch\": $U_PRE, \"ratio\": $U_PCT_HIT, \"memory\": { \"msg\": { \"used_mb\": ${U_MB_MSG}, \"limit_mb\": ${U_MB_LIM_MSG}, \"percent\": $U_PCT_MEM_MSG }, \"rrset\": { \"used_mb\": ${U_MB_RR}, \"limit_mb\": ${U_MB_LIM_RR}, \"percent\": $U_PCT_MEM_RR } }, \"cache_count\": { \"messages\": ${UCC_MSG:-0}, \"rrsets\": ${UCC_RR:-0} }"
        
        # --- FIXED LINE BELOW ---
        U_JSON="$U_JSON, \"stats\": {\"avg\": $U_AVG_F, \"med\": $U_MED_F, \"std\": ${U_STD:-0.00}, \"p95\": \"${U_P95:-0.00}\"}"
        # ------------------------

        if [ "$((H_B1 + H_B2 + H_B3 + H_B4 + H_B5 + H_B6 + H_B7 + H_B8 + H_B9))" -gt 0 ]; then H_JSON=", \"histogram\": {\"b1\": $H_B1, \"b2\": $H_B2, \"b3\": $H_B3, \"b4\": $H_B4, \"b5\": $H_B5, \"b6\": $H_B6, \"b7\": $H_B7, \"b8\": $H_B8, \"b9\": $H_B9 }"; U_JSON="$U_JSON$H_JSON"; fi
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

phls_mark setup
collect_unbound_async & PID_UNB=$!
collect_pihole_stats

if [ "$SILENT_MODE" = false ] && [ "$SHOW_UNBOUND" != "only" ] && [ -n "$SPINNER_PID" ]; then stop_spinner; fi

phls_mark collect_done
# Text report is only needed outside dashboard mode
if [ "$DASH_MODE" = false ]; then TEXT_REPORT=$(print_text_report); fi
if [ "$DO_JSON" = true ]; then JSON_REPORT=$(print_json_report); fi

# --- SD-card friendly writers ---
# Snapshot: write a temp file next to the target, then rename (readers never see a half-written file).
write_atomic() {
    local f="$1" tmp="$1.tmp.$$"
    printf '%s\n' "$2" > "$tmp" && fix_perms "$tmp" "dash" && mv -f "$tmp" "$f"
}

# History: append in place by overwriting the closing ']' with ',{entry}]'.
# Only a few hundred bytes are written per run instead of the whole file (several MB).
# The file is rebuilt (trimmed to MAX_HISTORY_ENTRIES) only every ~50 runs, or to repair it.
HISTORY_TRIM_SLACK=50
write_history() {
    local new="$1" f="$2" max="${MAX_HISTORY_ENTRIES:-8640}" size=0 count=0 last=""
    [[ "$max" =~ ^[0-9]+$ ]] && [ "$max" -gt 0 ] || max=8640
    if [ -s "$f" ]; then
        size=$(stat -c %s "$f" 2>/dev/null || echo 0)
        last=$(tail -c 1 "$f" 2>/dev/null)
        count=$(tr -cd '}' < "$f" | wc -c)
    fi
    if [ "$size" -gt 2 ] && [ "$last" = "]" ] && [ "$count" -lt $((max + HISTORY_TRIM_SLACK)) ]; then
        if printf ',%s]' "$new" | dd of="$f" bs=65536 seek=$((size - 1)) oflag=seek_bytes conv=notrunc iflag=fullblock status=none 2>/dev/null; then
            return 0
        fi
    fi
    local tmp="$f.tmp.$$"
    if [ -s "$f" ]; then
        { grep -o '{[^}]*}' "$f" 2>/dev/null; printf '%s\n' "$new"; } | tail -n "$max" | awk 'BEGIN { ORS = ""; print "[" } NR > 1 { print "," } { print } END { print "]" }' > "$tmp"
    else
        printf '[%s]' "$new" > "$tmp"
    fi
    fix_perms "$tmp" "dash"
    mv -f "$tmp" "$f"
}

phls_mark reports_built
if [ "$DASH_MODE" = true ] && [ "$DASH_HISTORY" = true ] && [ "$SHOW_UNBOUND" != "only" ]; then
    DIFF_HITS=0; DIFF_MISS=0
    if [ -f "$SNAP_PATH" ]; then
        PREV_SNAP=$(< "$SNAP_PATH")
        PREV_HITS=""; PREV_MISS=""
        [[ "$PREV_SNAP" =~ \"total_hits\":[[:space:]]*([0-9]+) ]] && PREV_HITS="${BASH_REMATCH[1]}"
        [[ "$PREV_SNAP" =~ \"total_miss\":[[:space:]]*([0-9]+) ]] && PREV_MISS="${BASH_REMATCH[1]}"
        if [ -n "$PREV_HITS" ] && [ -n "$PREV_MISS" ]; then
            DIFF_HITS=$((U_HITS - PREV_HITS)); DIFF_MISS=$((U_MISS - PREV_MISS))
            # Counters went down = Unbound restarted since the last run: everything since then is new
            if [ "$DIFF_HITS" -lt 0 ] || [ "$DIFF_MISS" -lt 0 ]; then DIFF_HITS=$U_HITS; DIFF_MISS=$U_MISS; fi
        fi
    fi
    printf -v NOW_STR '%(%Y-%m-%d %H:%M:%S)T' -1
    printf -v NEW_ENTRY '{"version":"%s","date":"%s","average":%s,"median":%s,"p95":%s,"stddev":%s,"u_avg":%s,"u_std":%s,"u_med":%s,"u_p95":%s,"messages":%d,"rrsets":%d,"cache_mb_msg":%s,"cache_mb_rr":%s,"diff_hits":%d,"diff_miss":%d}' "$VERSION" "$NOW_STR" "$P_AVG" "$P_MED" "$P_95" "$P_STD" "${UP_STATS_ALL[0]:-0}" "${UP_STATS_ALL[1]:-0}" "${UP_STATS_ALL[2]:-0}" "${UP_STATS_ALL[3]:-0}" "${UCC_MSG:-0}" "${UCC_RR:-0}" "${U_MB_MSG:-0.00}" "${U_MB_RR:-0.00}" "$DIFF_HITS" "$DIFF_MISS"
    [ -n "$UPHIST_JSON" ] && NEW_ENTRY="${NEW_ENTRY%\}},\"u_by\":$UPHIST_JSON}"
    mkdir -p "$(dirname "$HIST_PATH")"
    write_history "$NEW_ENTRY" "$HIST_PATH"
fi

phls_mark history
if [ "$DASH_MODE" = true ]; then
    if [ ! -d "$(dirname "$SNAP_PATH")" ]; then mkdir -p "$(dirname "$SNAP_PATH")"; fi
    write_atomic "$SNAP_PATH" "$JSON_REPORT"
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

phls_mark files_written
if [ "$DEBUG_MODE" = true ] && [ -n "$PHLS_T0" ] && [ -n "$DEBUG_LOG" ]; then
    printf '%s\n' "${PHLS_T[@]}" | awk -v t0="$PHLS_T0" 'BEGIN { p = t0; printf "--- TIMING: " } { printf "%s=%.2fs ", $1, $2 - p; p = $2 } END { printf "| total=%.2fs ---\n", p - t0 }' >> "$DEBUG_LOG"
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
