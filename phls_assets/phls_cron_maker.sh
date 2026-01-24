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
VERSION="1.1"

# --- FILES ---
PROFILE_DB="phls_cron.conf"
MAIN_SCRIPT="pihole_stats.sh"
# Required PATH for cron to find unbound-control/sqlite3
CRON_PATH="PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin"

# --- COLORS ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;36m'
NC='\033[0m' # No Color

# --- HIDDEN ARGUMENTS ---
ALLOW_SECONDS=false
for arg in "$@"; do
    if [[ "$arg" == "-s" ]]; then
        ALLOW_SECONDS=true
    fi
done

# --- ROOT CHECK ---
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}❌ Please run as root (sudo).${NC}"
    echo "Cron management requires root privileges."
    exit 1
fi

# --- LOCATE MAIN SCRIPT ---
SCRIPT_PATH=""
SCRIPT_DIR=""
POSSIBLE_LOCS=(
    "$(dirname "$(realpath "$0")")/$MAIN_SCRIPT"
    "/usr/local/bin/$MAIN_SCRIPT"
    "$HOME/phls/$MAIN_SCRIPT"
    "/opt/phls/$MAIN_SCRIPT"
    "/var/www/html/admin/img/dash/$MAIN_SCRIPT"
)

for loc in "${POSSIBLE_LOCS[@]}"; do
    if [ -f "$loc" ]; then
        SCRIPT_PATH="$loc"
        break
    fi
done

if [ -z "$SCRIPT_PATH" ]; then
    echo -e "${YELLOW}⚠️  Could not auto-locate $MAIN_SCRIPT${NC}"
    read -e -p "Please enter full path to $MAIN_SCRIPT: " INPUT_PATH
    if [ -f "$INPUT_PATH" ]; then
        SCRIPT_PATH="$INPUT_PATH"
    else
        echo -e "${RED}❌ File not found. Aborting.${NC}"
        exit 1
    fi
fi

# Extract directory for the 'cd' command
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"

# ==============================================================================
#                               HELPER FUNCTIONS
# ==============================================================================

ask_val() {
    local prompt="$1"
    local default="$2"
    local val=""
    if [ -n "$default" ]; then
        read -p "$(echo -e "$prompt [${YELLOW}$default${NC}]: ")" val >&2
        echo "${val:-$default}"
    else
        while [ -z "$val" ]; do
            read -p "$(echo -e "$prompt: ")" val >&2
        done
        echo "$val"
    fi
}

ask_bool() {
    local prompt="$1"
    local default="$2"
    local val=""
    local def_display=""
    [ "$default" == "y" ] && def_display="Y/n" || def_display="y/N"
    
    while true; do
        read -p "$(echo -e "$prompt [$def_display]: ")" -n 1 -r val >&2
        echo "" >&2 
        if [ -z "$val" ]; then val="$default"; fi
        if [[ "$val" =~ ^[YyNn]$ ]]; then break;
        else echo -e "${RED}❌ Invalid input. Press 'y' or 'n'.${NC}" >&2; fi
    done
    if [[ "$val" =~ ^[Yy]$ ]]; then echo "true"; else echo "false"; fi
}

show_header() {
    clear
    echo -e "${BLUE}====================================================${NC}"
    echo -e "           ${GREEN}Pi-hole Latency Stats${NC}"
    echo -e "        ${YELLOW}Dashboard Cron Job Maker v$VERSION${NC}"
    echo -e "${BLUE}====================================================${NC}"
    echo ""
}

# ==============================================================================
#                               LOGIC FUNCTIONS
# ==============================================================================

create_profile() {
    echo -e "${BLUE}--- Create New Dashboard Profile ---${NC}"
    
    local p_name=""
    while true; do
        p_name=$(ask_val "Profile Name (alphanumeric, no spaces)" "default")
        if [[ "$p_name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
            if grep -q "^$p_name|" "$PROFILE_DB" 2>/dev/null; then
                echo -e "${RED}❌ Profile exists.${NC}" >&2
            else break; fi
        else echo -e "${RED}❌ Invalid name.${NC}" >&2; fi
    done

    echo -e "\n${BLUE}💡 Interval Guidance:${NC}"
    echo -e "Standard intervals (e.g., 1, 5, 10, 15, 30, 60) align perfectly with the clock."
    echo -e "Non-standard numbers (e.g., 7, 13, 47) may result in irregular execution times."
    echo -e "Numbers >= 60 will be automatically converted to Hourly/Daily schedules.\n"

    # Determine Unit (Seconds if hidden flag, else Minutes)
    local unit="m"
    local prompt_txt="Run every X minutes"
    local def_val="5"
    
    if [ "$ALLOW_SECONDS" = true ]; then
        unit="s"
        prompt_txt="Run every X seconds (10, 15, 20, 30)"
        def_val="15"
    fi

    # Ask Value
    local freq=""
    while true; do
        freq=$(ask_val "$prompt_txt" "$def_val")
        
        if [ "$unit" == "s" ]; then
            if [[ "$freq" =~ ^(10|15|20|30)$ ]]; then break;
            else echo -e "${RED}❌ For seconds, use 10, 15, 20, or 30.${NC}" >&2; fi
        else
            # Minutes Validation
            if [[ "$freq" =~ ^[0-9]+$ ]] && [ "$freq" -ge 1 ]; then
                # Check for "weird" numbers (not divisors of 60)
                if [ "$freq" -lt 60 ] && [ $((60 % freq)) -ne 0 ]; then
                    echo -e "${YELLOW}⚠️  Warning: '$freq' is a 'weird' interval.${NC}" >&2
                    echo -e "Execution will occur at :00, :${freq}, etc., but will reset every hour." >&2
                    local nearest=5
                    if [ "$freq" -lt 7 ]; then nearest=5; elif [ "$freq" -lt 12 ]; then nearest=10; elif [ "$freq" -lt 22 ]; then nearest=15; else nearest=30; fi
                    echo -e "Suggesting a 'normal' value: ${GREEN}${nearest}${NC}" >&2
                    if [ "$(ask_bool "Keep '$freq' anyway?" "y")" == "true" ]; then break; fi
                else
                    break
                fi
            else echo -e "${RED}❌ Invalid number.${NC}" >&2; fi
        fi
    done

    echo -e "\n${YELLOW}ℹ️  Unbound Cache Count (-ucc)${NC}"
    local ucc=$(ask_bool "Enable Unbound Cache Stats?" "n")

    # Load Warning
    if [ "$ucc" == "true" ] && [ "$unit" == "m" ] && [ "$freq" -lt 5 ]; then
        echo -e "${RED}⚠️  High frequency ($freq min) + UCC = High Load.${NC}"
        if [ "$(ask_bool "Proceed?" "n")" == "false" ]; then ucc="false"; fi
    fi
    
    save_and_schedule "$p_name" "$freq" "$unit" "$ucc"
}

modify_profile() {
    if [ ! -s "$PROFILE_DB" ]; then echo "No profiles found."; return; fi
    echo -e "${BLUE}--- Modify Profile ---${NC}"
    mapfile -t lines < "$PROFILE_DB"
    local count=${#lines[@]}
    local i=1; for line in "${lines[@]}"; do echo "$i. $(echo "$line" | cut -d'|' -f1)"; ((i++)); done

    local choice=""
    while true; do
        choice=$(ask_val "Select number [1-$count]" "")
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "$count" ]; then break; fi
        echo -e "${RED}❌ Invalid.${NC}" >&2
    done

    local idx=$((choice-1))
    local curr_line="${lines[$idx]}"
    local old_name=$(echo "$curr_line" | cut -d'|' -f1)
    local old_val=$(echo "$curr_line" | cut -d'|' -f2)
    local col3=$(echo "$curr_line" | cut -d'|' -f3)
    
    local old_unit="m"
    local old_ucc="false"

    if [[ "$col3" =~ ^[mhds]$ ]]; then
        old_unit="$col3"
        old_ucc=$(echo "$curr_line" | cut -d'|' -f4)
    else
        old_ucc="$col3"
    fi

    local new_unit="m"
    if [ "$ALLOW_SECONDS" = true ]; then new_unit="s"; fi

    echo -e "\n${BLUE}--- Modifying: $old_name ---${NC}"
    
    local prompt_txt="Run every X minutes"
    [ "$new_unit" == "s" ] && prompt_txt="Run every X seconds"

    local new_val=""
    while true; do
        new_val=$(ask_val "$prompt_txt" "$old_val")
        if [ "$new_unit" == "s" ]; then
            if [[ "$new_val" =~ ^(10|15|20|30)$ ]]; then break;
            else echo -e "${RED}❌ Use 10, 15, 20, or 30.${NC}" >&2; fi
        else
            if [[ "$new_val" =~ ^[0-9]+$ ]] && [ "$new_val" -ge 1 ]; then break;
            else echo -e "${RED}❌ Invalid number.${NC}" >&2; fi
        fi
    done

    local ucc_char="n"; [ "$old_ucc" == "true" ] && ucc_char="y"
    local new_ucc_bool=$(ask_bool "Enable Unbound Cache Stats (-ucc)?" "$ucc_char")

    remove_cron_job "$old_name"
    sed -i "/^$old_name|/d" "$PROFILE_DB"
    save_and_schedule "$old_name" "$new_val" "$new_unit" "$new_ucc_bool"
}

delete_profile() {
    if [ ! -s "$PROFILE_DB" ]; then echo "No profiles found."; return; fi
    echo -e "${BLUE}--- Delete Profile ---${NC}"
    mapfile -t lines < "$PROFILE_DB"
    local count=${#lines[@]}
    local i=1; for line in "${lines[@]}"; do echo "$i. $(echo "$line" | cut -d'|' -f1)"; ((i++)); done

    local choice=""
    while true; do
        choice=$(ask_val "Select number to DELETE [1-$count]" "")
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "$count" ]; then break; fi
        echo -e "${RED}❌ Invalid.${NC}" >&2
    done

    local idx=$((choice-1))
    local name=$(echo "${lines[$idx]}" | cut -d'|' -f1)
    
    if [ "$(ask_bool "Permanently delete '$name'?" "n")" == "true" ]; then
        remove_cron_job "$name"
        sed -i "/^$name|/d" "$PROFILE_DB"
        echo -e "${GREEN}✅ Deleted.${NC}"
    else echo "Aborted."; fi
}

# --- CORE BACKEND ---

save_and_schedule() {
    local name="$1"; local val="$2"; local unit="$3"; local ucc="$4"

    # 1. Build Command: "cd [DIR] && ./script [ARGS] -debug >> log 2>&1"
    local cmd_args="-dash \"$name\""
    if [ "$ucc" == "true" ]; then cmd_args="$cmd_args -ucc"; fi
    
    # Force CD to ensure relative paths work, add debug flag and logging
    local full_script_cmd="cd $SCRIPT_DIR && ./$MAIN_SCRIPT $cmd_args -debug >> $SCRIPT_DIR/cron_debug.log 2>&1"
    
    # 2. Build Cron Entries
    local cron_entries=""
    local summary=""
    
    if [ "$unit" == "s" ]; then
        local count=$((60 / val))
        for (( i=0; i<count; i++ )); do
            local sleep_sec=$((i * val))
            if [ "$sleep_sec" -eq 0 ]; then cron_entries+="* * * * * $full_script_cmd # PHLS-ID:$name";
            else cron_entries+=$'\n'; cron_entries+="* * * * * sleep $sleep_sec; $full_script_cmd # PHLS-ID:$name"; fi
        done
        summary="Every $val Second(s)"
    else
        if [ "$val" -lt 60 ]; then
             cron_entries="*/$val * * * * $full_script_cmd # PHLS-ID:$name"
             summary="Every $val Minute(s)"
        else
            local hrs=$((val / 60))
            local rem=$((val % 60))
            
            if [ "$rem" -eq 0 ]; then
                if [ "$hrs" -ge 24 ] && [ $((hrs % 24)) -eq 0 ]; then
                    local days=$((hrs / 24))
                    cron_entries="0 0 */$days * * $full_script_cmd # PHLS-ID:$name"
                    summary="Every $days Day(s)"
                else
                    cron_entries="0 */$hrs * * * $full_script_cmd # PHLS-ID:$name"
                    summary="Every $hrs Hour(s)"
                fi
            else
                cron_entries="*/$val * * * * $full_script_cmd # PHLS-ID:$name"
                summary="Every $val Minutes (Irregular)"
            fi
        fi
    fi
    
    # 3. Read existing Crontab
    local EXISTING_CRON
    EXISTING_CRON=$(crontab -l 2>/dev/null)

    # 4. Check for PATH variable. If missing, prepend it.
    local FINAL_CRON=""
    if echo "$EXISTING_CRON" | grep -q "^PATH="; then
        # PATH exists, just append new entries
        FINAL_CRON=$(echo -e "$EXISTING_CRON\n$cron_entries")
    else
        # PATH missing, prepend CRON_PATH + existing + new
        echo -e "${YELLOW}ℹ️  Adding required PATH to crontab for Unbound detection.${NC}"
        FINAL_CRON=$(echo -e "$CRON_PATH\n$EXISTING_CRON\n$cron_entries")
    fi

    # 5. Install New Crontab
    echo "$FINAL_CRON" | crontab -

    echo "$name|$val|$unit|$ucc|$full_script_cmd" >> "$PROFILE_DB"

    echo -e "${YELLOW}🚀 Running immediate update...${NC}"
    eval "$full_script_cmd &"

    echo -e "${GREEN}✅ Profile '$name' saved!${NC}"
    echo -e "   Schedule: ${YELLOW}$summary${NC}"
    echo -e "   Debug Log: ${BLUE}$SCRIPT_DIR/cron_debug.log${NC}"
}

remove_cron_job() {
    local name="$1"
    crontab -l 2>/dev/null | grep -v "# PHLS-ID:$name" | crontab -
}

# ==============================================================================
#                               MAIN MENU
# ==============================================================================

touch "$PROFILE_DB"
show_header

if [ -s "$PROFILE_DB" ]; then
    echo "1. Create New Profile"
    echo "2. Modify Existing Profile"
    echo "3. Delete Profile"
    echo "4. Exit"
    echo ""
    while true; do
        choice=$(ask_val "Choose option" "")
        if [[ "$choice" =~ ^[1-4]$ ]]; then break; fi
        echo -e "${RED}❌ Invalid.${NC}" >&2
    done
    case $choice in
        1) create_profile ;;
        2) modify_profile ;;
        3) delete_profile ;;
        4) exit 0 ;;
    esac
else
    echo "No profiles found. Starting creator..."
    create_profile
fi