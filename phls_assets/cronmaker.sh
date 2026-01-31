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

# --- VERSION ---
VERSION="1.5"

# --- PATHS ---
SCRIPT_PATH="$(realpath "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"

if [[ "$(basename "$SCRIPT_DIR")" != "cron" ]]; then
    INSTALL_DIR="$SCRIPT_DIR"
    CRON_DIR="$INSTALL_DIR/cron"
else
    CRON_DIR="$SCRIPT_DIR"
    INSTALL_DIR="$(dirname "$CRON_DIR")"
fi

MAIN_SCRIPT="$INSTALL_DIR/pihole_stats.sh"
DEFAULT_CONFIG="$INSTALL_DIR/pihole_stats.conf"
CRON_DB="$CRON_DIR/cron_profiles.db"

mkdir -p "$CRON_DIR"

# --- COLORS ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;36m'
NC='\033[0m' # No Color

# --- HIDDEN ARGUMENTS ---
ALLOW_SECONDS=false; for arg in "$@"; do if [[ "$arg" == "-s" ]]; then ALLOW_SECONDS=true; fi; done

# --- VALIDATION ARRAYS ---
VALID_FLAGS=(
    "-up:Upstream queries only"
    "-pi:Pi-hole queries only"
    "-nx:Exclude Blocked queries"
    "-dm:Domain filter (Wildcard allowed)"
    "-edm:Exact Domain filter"
    "-unb:Show Unbound Stats"
    "-24h:Last 24 Hours"
    "-7d:Last 7 Days"
    "-from:Custom Start Date"
    "-to:Custom End Date"
)

# --- ROOT CHECK ---
if [ "$EUID" -ne 0 ]; then echo -e "${RED}❌ Please run as root (sudo).${NC}"; exit 1; fi
if [ ! -f "$MAIN_SCRIPT" ]; then echo -e "${RED}❌ Error: Cannot find pihole_stats.sh at:${NC} $MAIN_SCRIPT"; exit 1; fi

# ==============================================================================
#                               HELPER FUNCTIONS
# ==============================================================================

# --- AUTO-FIX EXISTING JOBS ---
enforce_security_flags() {
    # STRICTLY targets lines containing '# PHLS-ID:'
    local temp_cron=$(mktemp)
    crontab -l 2>/dev/null > "$temp_cron"
    
    if grep -q "# PHLS-ID:" "$temp_cron"; then
        # Logic: On lines matching PHLS-ID, IF they lack -snap, inject it.
        sed -i -E '/# PHLS-ID:/ { / -snap/! s|pihole_stats\.sh |pihole_stats.sh -snap | }' "$temp_cron"
        crontab "$temp_cron"
    fi
    rm -f "$temp_cron"
}

ask_val() {
    local prompt="$1"; local default="$2"; local val=""
    if [ -n "$default" ]; then read -p "$(echo -e "$prompt [${YELLOW}$default${NC}]: ")" val >&2; echo "${val:-$default}"
    else while [ -z "$val" ]; do read -p "$(echo -e "$prompt: ")" val >&2; done; echo "$val"; fi
}

ask_bool() {
    local prompt="$1"; local default="$2"; local val=""
    [ "$default" == "y" ] && def_display="Y/n" || def_display="y/N"
    while true; do
        read -p "$(echo -e "$prompt [$def_display]: ")" -n 1 -r val >&2; echo "" >&2
        if [ -z "$val" ]; then val="$default"; fi
        if [[ "$val" =~ ^[YyNn]$ ]]; then break; else echo -e "${RED}❌ Invalid input.${NC}" >&2; fi
    done
    if [[ "$val" =~ ^[Yy]$ ]]; then echo "true"; else echo "false"; fi
}

show_header() {
    echo -e "${BLUE}====================================================${NC}"
    echo -e "           ${GREEN}Pi-hole Latency Stats${NC}"
    echo -e "        ${YELLOW}Dashboard Cron Job Maker v$VERSION${NC}"
    echo -e "${BLUE}====================================================${NC}"
    echo ""
}

show_valid_args() {
    echo -e "\n${BLUE}--- Available Dashboard Arguments ---${NC}"
    echo -e "Press any key to return."
    echo "------------------------------------------------"
    for item in "${VALID_FLAGS[@]}"; do
        flag="${item%%:*}"; desc="${item#*:}"
        printf "${GREEN}%-10s${NC} : %s\n" "$flag" "$desc"
    done
    echo "------------------------------------------------"
    echo -e "${RED}Auto-handled:${NC} -j, -f, -snap, -ucc, -dash"
    read -n 1 -s -r
}

validate_args() {
    local input="$1"
    if [[ "$input" =~ (-j[[:space:]]|-f[[:space:]]|-hor|-ver|-s[[:space:]]|-s$|-ucc|-snap) ]]; then
        echo -e "${RED}❌ Error: Do not use output, layout, -snap, or -ucc flags here.${NC}"
        return 1
    fi
    return 0
}

ask_tiers() {
    local config_file="$1"
    echo -e "\n${BLUE}--- Latency Tiers Setup ---${NC}"
    echo -e "Press ${YELLOW}[ENTER]${NC} to keep default. Press ${YELLOW}[~]${NC} to SAVE/EXIT Tiers."
    
    for i in {01..20}; do
        local current_val=$(grep -o "L$i=\"[^\"]*\"" "$config_file" | cut -d'"' -f2)
        read -p "$(echo -e "Tier L$i (ms) [${YELLOW}$current_val${NC}]: ")" input
        
        if [[ "$input" == "~" ]]; then 
            echo -e "${GREEN}✅ Saved tiers. Continuing setup...${NC}"
            break 
        fi
        
        if [ -n "$input" ]; then
            if [[ "$input" =~ ^[0-9]+([.][0-9]+)?$ ]]; then 
                sed -i "s/L$i=\"[^\"]*\"/L$i=\"$input\"/" "$config_file"
            else 
                echo -e "${RED}❌ Invalid number.${NC}"
            fi
        fi
    done
}

ask_cutoffs() {
    local config_file="$1"
    echo -e "\n${BLUE}--- Latency Cutoffs (Optional) ---${NC}"
    echo -e "${YELLOW}ℹ️  This allows you to ignore anomalies or extremely slow queries.${NC}"
    echo -e "Type '0' or 'x' to disable a cutoff."

    # --- MIN CUTOFF ---
    local cur_min=$(grep '^MIN_LATENCY_CUTOFF=' "$config_file" | cut -d'"' -f2)
    local disp_min="${cur_min:-None}"
    
    read -p "$(echo -e "Min Latency (ignore faster than X ms) [${YELLOW}$disp_min${NC}]: ")" val_min
    
    local final_min="$cur_min"
    if [[ "$val_min" =~ ^[0-9]+$ ]]; then
        if [ "$val_min" -eq 0 ]; then final_min=""; else final_min="$val_min"; fi
    elif [[ "$val_min" =~ ^[xX]$ ]]; then
        final_min=""
    fi
    sed -i "s|^MIN_LATENCY_CUTOFF=.*|MIN_LATENCY_CUTOFF=\"$final_min\"|" "$config_file"

    # --- MAX CUTOFF ---
    local cur_max=$(grep '^MAX_LATENCY_CUTOFF=' "$config_file" | cut -d'"' -f2)
    local disp_max="${cur_max:-None}"

    read -p "$(echo -e "Max Latency (ignore slower than X ms) [${YELLOW}$disp_max${NC}]: ")" val_max

    local final_max="$cur_max"
    if [[ "$val_max" =~ ^[0-9]+$ ]]; then
        if [ "$val_max" -eq 0 ]; then final_max=""; else final_max="$val_max"; fi
    elif [[ "$val_max" =~ ^[xX]$ ]]; then
        final_max=""
    fi
    sed -i "s|^MAX_LATENCY_CUTOFF=.*|MAX_LATENCY_CUTOFF=\"$final_max\"|" "$config_file"
    echo -e "${GREEN}✅ Cutoffs applied.${NC}"
}

# ==============================================================================
#                               LOGIC FUNCTIONS
# ==============================================================================

create_profile() {
    echo -e "${BLUE}--- Create Dashboard Profile ---${NC}"
    local p_name=""
    while true; do
        p_name=$(ask_val "Profile Name (alphanumeric)" "default")
        if [[ "$p_name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
            if grep -q "^$p_name|" "$CRON_DB" 2>/dev/null; then echo -e "${RED}❌ Taken.${NC}" >&2; else break; fi
        else echo -e "${RED}❌ Invalid.${NC}" >&2; fi
    done

    local p_conf="$CRON_DIR/${p_name}.conf"
    if [ ! -f "$DEFAULT_CONFIG" ]; then echo -e "${RED}❌ Default config missing.${NC}"; return; fi
    
    # HARVEST DEFAULTS: Ask main script to generate fresh config with factory defaults
    "$MAIN_SCRIPT" -mc "$p_conf" > /dev/null 2>&1
    if [ ! -f "$p_conf" ]; then echo -e "${RED}❌ Error creating config file.${NC}"; return; fi
    
    # Customize Tiers
    if [ "$(ask_bool "Customize Latency Tiers?" "n")" == "true" ]; then ask_tiers "$p_conf"; fi

    # Customize Cutoffs (NEW)
    if [ "$(ask_bool "Set Latency Cutoffs (Min/Max)?" "n")" == "true" ]; then ask_cutoffs "$p_conf"; fi

    local extra_args=""
    if [ "$p_name" != "default" ]; then
        while true; do
            echo -e "\n${YELLOW}ℹ️  Extra Arguments (Filters only)${NC}"
            echo -e "Type 'h' for help, or enter arguments:"
            read -e -p "> " input_args
            if [[ "$input_args" == "h" ]]; then show_valid_args; elif [ -z "$input_args" ]; then break; else
                if validate_args "$input_args"; then
                    extra_args="$input_args"
                    sed -i "s|^CONFIG_ARGS=.*|CONFIG_ARGS='$extra_args'|" "$p_conf"
                    break
                fi
            fi
        done
    else echo -e "\n${YELLOW}ℹ️  'Default' profile: Skipping extra arguments.${NC}"; fi

    # Schedule
    echo -e "\n${BLUE}💡 Interval Guidance:${NC}"
    local unit="m"; local prompt_txt="Run every X minutes"; local def_val="5"
    if [ "$ALLOW_SECONDS" = true ]; then unit="s"; prompt_txt="Run every X seconds (10..30)"; def_val="15"; fi

    local freq=""
    while true; do
        freq=$(ask_val "$prompt_txt" "$def_val")
        if [ "$unit" == "s" ]; then if [[ "$freq" =~ ^(10|15|20|30)$ ]]; then break; fi
        else if [[ "$freq" =~ ^[0-9]+$ ]] && [ "$freq" -ge 1 ]; then break; fi; fi
        echo -e "${RED}❌ Invalid.${NC}" >&2
    done
    
    echo ""
    local ucc=$(ask_bool "Enable Unbound Cache Stats (-ucc)?" "n")
    save_and_schedule "$p_name" "$freq" "$unit" "$ucc" "$p_conf"
}

save_and_schedule() {
    local name="$1"; local val="$2"; local unit="$3"; local ucc="$4"; local conf_file="$5"

    # --- BUILD COMMAND (FORCED -snap) ---
    local cmd_args="-dash \"$name\" -c \"$conf_file\" -snap"
    if [ "$ucc" == "true" ]; then cmd_args="$cmd_args -ucc"; fi
    
    local required_path="export PATH=\$PATH:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin;"
    local full_cmd="$required_path cd $INSTALL_DIR && ./pihole_stats.sh $cmd_args >> $CRON_DIR/${name}_debug.log 2>&1"
    
    local cron_entries=""; local summary=""
    if [ "$unit" == "s" ]; then
        local count=$((60 / val))
        for (( i=0; i<count; i++ )); do
            local sleep_sec=$((i * val))
            if [ "$sleep_sec" -eq 0 ]; then cron_entries+="* * * * * $full_cmd # PHLS-ID:$name";
            else cron_entries+=$'\n'; cron_entries+="* * * * * sleep $sleep_sec; $full_cmd # PHLS-ID:$name"; fi
        done
        summary="Every $val Second(s)"
    else
        if [ "$val" -lt 60 ]; then cron_entries="*/$val * * * * $full_cmd # PHLS-ID:$name"; summary="Every $val Minute(s)"
        else
            local hrs=$((val / 60))
            if [ "$hrs" -ge 24 ]; then local days=$((hrs / 24)); cron_entries="0 0 */$days * * $full_cmd # PHLS-ID:$name"; summary="Every $days Day(s)"
            else cron_entries="0 */$hrs * * * $full_cmd # PHLS-ID:$name"; summary="Every $hrs Hour(s)"; fi
        fi
    fi
    
    local EXISTING_CRON=$(crontab -l 2>/dev/null)
    echo -e "$EXISTING_CRON\n$cron_entries" | crontab -
    echo "$name|$val$unit|$(date)|$conf_file" >> "$CRON_DB"

    echo -e "${GREEN}✅ Profile '$name' updated!${NC}"
    echo -e "   Schedule: ${YELLOW}$summary${NC}"
    echo -e "${YELLOW}🚀 Reloading data...${NC}"
    echo -e "${YELLOW} If you want to change default Dashboard settings edit ${BLUE}/phls/cron/$name.conf${NC}"

    eval "$full_cmd &"
}

remove_cron_job() { local name="$1"; crontab -l 2>/dev/null | grep -v "# PHLS-ID:$name" | crontab -; }

modify_profile() {
    if [ ! -s "$CRON_DB" ]; then echo "No profiles found."; return; fi
    echo -e "${BLUE}--- Modify Profile ---${NC}"
    mapfile -t lines < "$CRON_DB"
    local count=${#lines[@]}
    local i=1; for line in "${lines[@]}"; do echo "$i. $(echo "$line" | cut -d'|' -f1)"; ((i++)); done

    local choice=""; while true; do choice=$(ask_val "Select number [1-$count]" ""); if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "$count" ]; then break; fi; echo -e "${RED}❌ Invalid.${NC}" >&2; done

    local idx=$((choice-1)); local db_line="${lines[$idx]}"
    local p_name=$(echo "$db_line" | cut -d'|' -f1); local raw_freq=$(echo "$db_line" | cut -d'|' -f2); local p_conf=$(echo "$db_line" | cut -d'|' -f4)

    echo -e "\n${BLUE}Editing: ${GREEN}$p_name${NC}"
    
    # Customize Tiers
    if [ "$(ask_bool "Edit Latency Tiers?" "n")" == "true" ]; then ask_tiers "$p_conf"; fi

    # Customize Cutoffs (NEW)
    if [ "$(ask_bool "Edit Latency Cutoffs?" "n")" == "true" ]; then ask_cutoffs "$p_conf"; fi

    local cur_args=$(grep "^CONFIG_ARGS=" "$p_conf" | cut -d"'" -f2)
    if [ "$p_name" == "default" ]; then echo -e "\n${YELLOW}ℹ️  'Default' profile cannot have extra args.${NC}"
    else
        echo -e "\n${YELLOW}ℹ️  Extra Arguments${NC} (Current: ${GREEN}${cur_args:-None}${NC})"
        if [ "$(ask_bool "Change arguments?" "n")" == "true" ]; then
             while true; do
                read -e -p "New Args > " input_args
                if [[ "$input_args" == "h" ]]; then show_valid_args; elif [ -z "$input_args" ]; then break; else
                    if validate_args "$input_args"; then sed -i "s|^CONFIG_ARGS=.*|CONFIG_ARGS='$input_args'|" "$p_conf"; echo -e "${GREEN}✅ Updated.${NC}"; break; fi
                fi
            done
        fi
    fi

    local old_unit="${raw_freq: -1}"; local old_val="${raw_freq%?}"
    local new_val="$old_val"; local new_unit="$old_unit"

    echo -e "\n${BLUE}--- Schedule Setup ---${NC}"
    if [ "$(ask_bool "Change Schedule (Current: $old_val$old_unit)?" "n")" == "true" ]; then
        local def_val="5"; local unit="m"; local prompt_txt="Run every X minutes"
        if [ "$ALLOW_SECONDS" = true ]; then unit="s"; prompt_txt="Run every X seconds (10..30)"; def_val="15"; fi
        local freq=""; while true; do freq=$(ask_val "$prompt_txt" "$def_val"); if [ "$unit" == "s" ]; then if [[ "$freq" =~ ^(10|15|20|30)$ ]]; then break; fi; else if [[ "$freq" =~ ^[0-9]+$ ]] && [ "$freq" -ge 1 ]; then break; fi; fi; echo -e "${RED}❌ Invalid.${NC}" >&2; done
        new_val="$freq"; new_unit="$unit"
    fi

    local cur_ucc_bool="false"; if crontab -l 2>/dev/null | grep "# PHLS-ID:$p_name" | grep -q -- "-ucc"; then cur_ucc_bool="true"; fi
    local disp_char="n"; if [ "$cur_ucc_bool" == "true" ]; then disp_char="y"; fi
    echo ""; local new_ucc=$(ask_bool "Enable Unbound Cache Stats (-ucc)?" "$disp_char")

    sed -i "/^$p_name|/d" "$CRON_DB"
    crontab -l 2>/dev/null | grep -v "# PHLS-ID:$p_name" | crontab -
    save_and_schedule "$p_name" "$new_val" "$new_unit" "$new_ucc" "$p_conf"
}

delete_profile() {
    if [ ! -s "$CRON_DB" ]; then echo "No profiles found."; return 1; fi
    echo -e "${BLUE}--- Delete Profile ---${NC}"
    mapfile -t lines < "$CRON_DB"
    local count=${#lines[@]}; local i=1; for line in "${lines[@]}"; do echo "$i. $(echo "$line" | cut -d'|' -f1)"; ((i++)); done
    local choice=""; while true; do choice=$(ask_val "Select number to DELETE [1-$count]" ""); if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "$count" ]; then break; fi; echo -e "${RED}❌ Invalid.${NC}" >&2; done
    local idx=$((choice-1)); local name=$(echo "${lines[$idx]}" | cut -d'|' -f1)
    
    if [ "$(ask_bool "Permanently delete '$name'?" "n")" == "true" ]; then
        remove_cron_job "$name"; sed -i "/^$name|/d" "$CRON_DB"; rm -f "$CRON_DIR/${name}.conf" "$CRON_DIR/${name}_debug.log"
        echo -e "${GREEN}✅ Deleted.${NC}"; return 0
    else echo "Aborted."; return 1; fi
}

# ==============================================================================
#                               MAIN MENU
# ==============================================================================
touch "$CRON_DB"
enforce_security_flags

show_header
if [ -s "$CRON_DB" ]; then
    echo "1. Create New Profile"; echo "2. Modify Existing Profile"; echo "3. Delete Profile"; echo "4. Exit"; echo ""
    while true; do choice=$(ask_val "Choose option" ""); if [[ "$choice" =~ ^[1-4]$ ]]; then break; fi; echo -e "${RED}❌ Invalid.${NC}" >&2; done
    case $choice in 1) create_profile ;; 2) modify_profile ;; 3) delete_profile ;; 4) exit 0 ;; esac
else echo "No profiles found. Starting creator..."; create_profile; fi