# PHLS settings library: one list of the settings a user may change, and one validator.
# Used by the `phls` command (as root), the dashboard's settings endpoint (as www-data) and
# `phls apply` (as root, which checks every value again: nothing the web side writes is trusted).
#
# Only these keys can be changed from the dashboard. Paths (DBfile, DASH_DIR, SAVE_DIR_*) and
# CONFIG_ARGS (extra command-line arguments) are deliberately NOT here: they can only be changed
# by root with the `phls` command.

PHLS_ETC="/etc/phls"
PHLS_PROFILES="$PHLS_ETC/profiles"
PHLS_LIB="/var/lib/phls"
PHLS_PENDING="$PHLS_LIB/pending"
PHLS_STATUS="$PHLS_LIB/status"
PHLS_WEB="/var/www/phls"

# KEY|type|min|max|group|label|help
#   int     whole number min..max
#   num     number min..max (decimals allowed)
#   numopt  like num, or empty (= off)
#   bool    true / false
#   enum    one of the comma-separated values in "min"
PHLS_SCHEMA=(
"PROFILE_TYPE|enum|dashboard,report||Profile|Profile type|dashboard = runs on the schedule and fills the charts. report = runs only when you press Run report, and gives a text report like the command line."
"FILTER_DOMAIN|domain|||Profile|Domains|Only queries for these domains. youtube = every domain containing youtube; github.com = github.com and its subdomains; =youtube.com = exactly that name; * matches any text, e.g. *.netflix.com. Several, separated by commas, count together: youtube.com,googlevideo.com,ytimg.com. Empty = all queries. Changing it on a dashboard profile clears its history."
"REPORT_RANGE|range|||Report|Time range|All data, the last hours or days before the report runs, or a fixed From - To range."
"REPORT_FROM|datetime|||Report|From|Start of a From - To range."
"REPORT_TO|datetime|||Report|To|End of a From - To range. Empty = now."
"REPORT_COUNT|enum|all,upstream,pihole||Report|Queries|all = every answered query; upstream = only queries Pi-hole forwarded (-up); pihole = only queries Pi-hole answered itself, from its cache or local records (-pi)."
"REPORT_NX|bool|||Report|Leave out special blocks (-nx)|Same as -nx on the command line: leaves out replies Pi-hole gave for special domains and from its stale cache (status 16 and 17)."
"REPORT_UNBOUND|enum|include,only,none||Report|Unbound section|include = add Unbound's stats when Pi-hole uses Unbound; only = only Unbound's stats; none = leave them out."
"RUN_EVERY|int|1|1440|Schedule|Run every (minutes)|How often the analysis runs. Each run adds one point to the history graphs."
"UCC|bool|||Schedule|Unbound cache counts|Also record how many messages / RRsets are in Unbound's cache (needs Unbound)."
"MAX_DB_DAYS|int|1|365|Analysis|Days to analyze|How far back the analysis looks (Pi-hole keeps 91 days by default)."
"ENABLE_UNBOUND|enum|auto,true,false||Analysis|Unbound stats|auto = only if Unbound is installed and used by Pi-hole."
"EXCLUDE_PTR|bool|||Analysis|Ignore reverse lookups (PTR)|Reverse lookups (IP to name, mostly for your own devices) are left out of the latency and upstream stats. They still count in the totals."
"MIN_LATENCY_CUTOFF|numopt|0|60000|Analysis|Ignore replies faster than (ms)|Empty = off."
"MAX_LATENCY_CUTOFF|numopt|0|60000|Analysis|Ignore replies slower than (ms)|Empty = off."
"L01|numopt|0|60000|Tiers|Tier 1 up to (ms)|"
"L02|numopt|0|60000|Tiers|Tier 2 up to (ms)|"
"L03|numopt|0|60000|Tiers|Tier 3 up to (ms)|"
"L04|numopt|0|60000|Tiers|Tier 4 up to (ms)|"
"L05|numopt|0|60000|Tiers|Tier 5 up to (ms)|"
"L06|numopt|0|60000|Tiers|Tier 6 up to (ms)|"
"L07|numopt|0|60000|Tiers|Tier 7 up to (ms)|"
"L08|numopt|0|60000|Tiers|Tier 8 up to (ms)|"
"L09|numopt|0|60000|Tiers|Tier 9 up to (ms)|"
"L10|numopt|0|60000|Tiers|Tier 10 up to (ms)|"
"L11|numopt|0|60000|Tiers|Tier 11 up to (ms)|"
"L12|numopt|0|60000|Tiers|Tier 12 up to (ms)|"
"L13|numopt|0|60000|Tiers|Tier 13 up to (ms)|"
"L14|numopt|0|60000|Tiers|Tier 14 up to (ms)|"
"L15|numopt|0|60000|Tiers|Tier 15 up to (ms)|"
"L16|numopt|0|60000|Tiers|Tier 16 up to (ms)|"
"L17|numopt|0|60000|Tiers|Tier 17 up to (ms)|"
"L18|numopt|0|60000|Tiers|Tier 18 up to (ms)|"
"L19|numopt|0|60000|Tiers|Tier 19 up to (ms)|"
"L20|numopt|0|60000|Tiers|Tier 20 up to (ms)|"
"ENABLE_MATH_ALL_TIME|bool|||Median & P95|Whole range|Median/P95 for the full range."
"ENABLE_MATH_30D|bool|||Median & P95|Last 30 days|"
"ENABLE_MATH_7D|bool|||Median & P95|Last 7 days|"
"ENABLE_MATH_24H|bool|||Median & P95|Last 24 hours|"
"ENABLE_MATH_12H|bool|||Median & P95|Last 12 hours|"
"ENABLE_UPSTREAM_DIST|bool|||Charts|Upstream chart|Show the chart of upstream (forwarded) replies."
"ENABLE_UPSTREAM_MATH_ALL_TIME|bool|||Charts|Upstream median/P95 (whole range)|"
"UPSTREAM_DIST_MIN_CUTOFF|num|0|60000|Charts|Unbound cache limit (ms)|Replies from Unbound on this machine faster than this came from its cache and are not counted as upstream lookups. Other servers are always counted. 0 = count everything."
"UPSTREAM_BY_PROVIDER|bool|||Charts|Group upstream servers by provider|On: servers of the same public DNS provider (e.g. Cloudflare 1.1.1.1 and 1.0.0.1) count as one upstream. Off: every server separately."
"MAX_HISTORY_ENTRIES|int|100|200000|Charts|History points kept|8640 = 30 days at one run every 5 minutes."
"ENABLE_CACHE|bool|||Performance|Daily cache|Counts finished days once. Results are identical; runs are much faster."
)

# Which profile type each setting applies to: d = dashboard, r = report, dr = both (default)
declare -A PHLS_SCOPE=(
    [RUN_EVERY]=d [UCC]=d [MAX_DB_DAYS]=d
    [REPORT_RANGE]=r [REPORT_FROM]=r [REPORT_TO]=r [REPORT_COUNT]=r [REPORT_NX]=r [REPORT_UNBOUND]=r
    [ENABLE_MATH_30D]=d [ENABLE_MATH_7D]=d [ENABLE_MATH_24H]=d [ENABLE_MATH_12H]=d
    [ENABLE_UPSTREAM_DIST]=d [ENABLE_UPSTREAM_MATH_ALL_TIME]=d [UPSTREAM_DIST_MIN_CUTOFF]=d [UPSTREAM_BY_PROVIDER]=d
    [MAX_HISTORY_ENTRIES]=d [ENABLE_CACHE]=d
)
phls_scope() { printf '%s' "${PHLS_SCOPE[$1]:-dr}"; }

# Default values of the PHLS-only keys (the engine ignores them)
PHLS_DEFAULTS_RUN_EVERY="5"
PHLS_DEFAULTS_UCC="false"
declare -A PHLS_DEFAULT=(
    [RUN_EVERY]="$PHLS_DEFAULTS_RUN_EVERY" [UCC]="$PHLS_DEFAULTS_UCC" [PROFILE_TYPE]="dashboard" [FILTER_DOMAIN]=""
    [REPORT_RANGE]="all" [REPORT_FROM]="" [REPORT_TO]="" [REPORT_COUNT]="all" [REPORT_NX]="false" [REPORT_UNBOUND]="include"
)
# phls_value FILE KEY -> the value in FILE, or the default of a PHLS-only key that is missing
phls_value() {
    if grep -q "^$2=" "$1" 2>/dev/null; then phls_get "$1" "$2"; else printf '%s' "${PHLS_DEFAULT[$2]}"; fi
}
phls_profile_type() { [ "$(phls_value "$(printf '%s/%s.conf' "$PHLS_PROFILES" "$1")" PROFILE_TYPE)" = "report" ] && echo report || echo dashboard; }

phls_schema_line() {   # KEY -> schema line (empty if not editable)
    local l
    for l in "${PHLS_SCHEMA[@]}"; do [ "${l%%|*}" = "$1" ] && { printf '%s' "$l"; return 0; }; done
    return 1
}

# phls_valid KEY VALUE -> 0 if VALUE is acceptable for KEY (prints the reason on stdout otherwise)
phls_valid() {
    local key="$1" val="$2" line typ min max rest
    line=$(phls_schema_line "$key") || { echo "unknown setting"; return 1; }
    IFS='|' read -r _ typ min max rest <<< "$line"
    case "$typ" in
        bool) [[ "$val" == "true" || "$val" == "false" ]] || { echo "must be true or false"; return 1; } ;;
        enum) [[ ",$min," == *",$val,"* && -n "$val" ]] || { echo "must be one of: ${min//,/, }"; return 1; } ;;
        int)  [[ "$val" =~ ^[0-9]{1,7}$ ]] && (( 10#$val >= min && 10#$val <= max )) || { echo "must be a whole number from $min to $max"; return 1; } ;;
        num|numopt)
            [ "$typ" = "numopt" ] && [ -z "$val" ] && return 0
            [[ "$val" =~ ^[0-9]{1,6}(\.[0-9]{1,4})?$ ]] || { echo "must be a number$([ "$typ" = numopt ] && echo ' (or empty)')"; return 1; }
            awk -v v="$val" -v a="$min" -v b="$max" 'BEGIN { exit !(v + 0 >= a + 0 && v + 0 <= b + 0) }' || { echo "must be from $min to $max"; return 1; } ;;
        domain) phls_valid_domains "$val" || { echo "one or more domains separated by commas, each made of letters, digits, . - _ and *, optionally starting with = (max 10)"; return 1; } ;;
        range) [[ "$val" =~ ^(all|custom|[1-9][0-9]{0,3}[hd])$ ]] || { echo "must be all, custom, or a number followed by h or d (e.g. 24h, 7d)"; return 1; } ;;
        datetime)
            [ -z "$val" ] && return 0
            [[ "$val" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}( [0-9]{2}:[0-9]{2})?$ ]] && date -d "$val" +%s >/dev/null 2>&1 \
                || { echo "must be a date like 2026-11-10 or 2026-11-10 08:30"; return 1; } ;;
        *) echo "bad schema"; return 1 ;;
    esac
    return 0
}

# phls_get FILE KEY -> value of KEY="..." in FILE (parsed, never executed)
phls_get() {
    local file="$1" key="$2"
    [ -r "$file" ] || return 0
    sed -n "s/^${key}=[\"']\(.*\)[\"'][[:space:]]*\(#.*\)\{0,1\}$/\1/p" "$file" | tail -n 1
}

# phls_set FILE KEY VALUE -> replaces (or appends) KEY="VALUE". Values must already be validated
# (no quotes / newlines can reach here).
phls_set() {
    local file="$1" key="$2" val="$3" tmp
    [[ "$val" == *[\"\'\\$'\n'\`]* ]] && return 1
    tmp=$(mktemp "${file}.XXXXXX") || return 1
    if grep -q "^${key}=" "$file" 2>/dev/null; then
        awk -v k="$key" -v v="$val" 'index($0, k "=") == 1 { print k "=\"" v "\""; next } { print }' "$file" > "$tmp"
    else
        { cat "$file" 2>/dev/null; printf '%s="%s"\n' "$key" "$val"; } > "$tmp"
    fi
    chmod 644 "$tmp"; mv -f "$tmp" "$file"
}

# Tiers in order: takes the 20 "Lxx=VALUE" lines on stdin and prints them sorted from low to high,
# duplicates removed, empty ones last. Users can enter tiers in any order.
phls_sort_tiers() {
    awk -F'=' '$1 ~ /^L[0-9][0-9]$/ && $2 != "" { if (!(($2 + 0) in seen)) { seen[$2 + 0] = 1; v[++n] = $2 } }
        END {
            for (i = 2; i <= n; i++) { x = v[i]; j = i - 1; while (j > 0 && v[j] + 0 > x + 0) { v[j + 1] = v[j]; j-- } v[j + 1] = x }
            for (i = 1; i <= 20; i++) printf "L%02d=%s\n", i, (i <= n ? v[i] : "")
        }'
}

# Tiers must go up: L01 < L02 < ... among the ones that are set. Takes "KEY=VALUE" lines on stdin.
phls_check_tiers() {
    awk -F'=' '$1 ~ /^L[0-9][0-9]$/ && $2 != "" { n++; v[n] = $2 + 0; k[n] = $1 }
        END { for (i = 2; i <= n; i++) if (v[i] <= v[i-1]) { print k[i] " must be larger than " k[i-1]; exit 1 } }'
}

# Domains setting: empty, or up to 10 comma-separated items like  youtube  github.com  *.netflix.com  =youtube.com
phls_valid_domains() {
    local v="$1" d n=0
    [ -z "$v" ] && return 0
    [ ${#v} -le 253 ] && [[ "$v" =~ ^[A-Za-z0-9.*_=,-]+$ ]] || return 1
    local IFS=','; for d in $v; do
        n=$((n + 1)); [[ "$d" =~ ^=?[A-Za-z0-9.*_-]+$ ]] || return 1
    done
    [[ "$v" != *, && "$v" != ,* && "$v" != *,,* ]] && [ $n -le 10 ]
}

phls_valid_profile_name() { [[ "$1" =~ ^[A-Za-z0-9_-]{1,32}$ ]]; }
