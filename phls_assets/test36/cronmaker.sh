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
VERSION="2.2"

# --- PATHS ---
# Base install dir is where this script is located (assuming it's in /phls/cron/ or /phls/)
SCRIPT_PATH="$(realpath "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"

# Ensure we are in [INSTALL]/cron/
if [[ "$(basename "$SCRIPT_DIR")" != "cron" ]]; then
    # If user runs it from main folder, redirect to cron folder creation
    INSTALL_DIR="$SCRIPT_DIR"
    CRON_DIR="$INSTALL_DIR/cron"
else
    CRON_DIR="$SCRIPT_DIR"
    INSTALL_DIR="$(dirname "$CRON_DIR")"
fi

MAIN_SCRIPT="$INSTALL_DIR/pihole_stats.sh"
DEFAULT_CONFIG="$INSTALL_DIR/pihole_stats.conf"

# Databases
CRON_DB="$CRON_DIR/cron_profiles.db"
# Required PATH for cron to find unbound-control/sqlite3
CRON_PATH="PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin"

# Ensure Cron Dir Exists
mkdir -p "$CRON_DIR"

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

# --- VALIDATION ARRAYS ---
# Removed -ucc from here as it has a dedicated prompt
VALID_FLAGS=(
    "-up:Upstream queries only"
    "-pi:Pi-hole queries only"
    "-nx:Exclude Blocked queries"
    "-dm:Domain filter (Wildcard allowed)"
    "-edm:Exact Domain filter"
    "-unb:Show Unbound Stats"
    "-snap:Use Database Snapshot"
    "-24h:Last 24 Hours"
    "-7d:Last 7 Days"
    "-from:Custom Start Date"
    "-to:Custom End Date"
)

# --- ROOT CHECK ---
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}❌ Please run as root (sudo).${NC}"
    echo "Cron management requires root privileges."
    exit 1
fi

# Check if main script exists
if [ ! -f "$MAIN_SCRIPT" ]; then
    echo -e "${RED}❌ Error: Cannot find pihole_stats.sh at:${NC} $MAIN_SCRIPT"
    exit 1
fi

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

show_valid_args() {
    echo -e "\n${BLUE}--- Available Dashboard Arguments ---${NC}"
    echo -e "Press any key to return."
    echo "------------------------------------------------"
    for item in "${VALID_FLAGS[@]}"; do
        flag="${item%%:*}"
        desc="${item#*:}"
        printf "${GREEN}%-10s${NC} : %s\n" "$flag" "$desc"
    done
    echo "------------------------------------------------"
    echo -e "${RED}Invalid/Auto-handled:${NC} -j, -f, -hor, -ver, -s, -ucc"
    read -n 1 -s -r
}

validate_args() {
    local input="$1"
    # Block output flags AND -ucc (since it has dedicated prompt)
    if [[ "$input" =~ (-j[[:space:]]|-f[[:space:]]|-hor|-ver|-s[[:space:]]|-s$|-ucc) ]]; then
        echo -e "${RED}❌ Error: Do not use output flags, layout flags, or -ucc here.${NC}"
        return 1
    fi
    return 0
}

ask_tiers() {
    local config_file="$1"
    echo -e "\n${BLUE}--- Latency Tiers Setup ---${NC}"
    echo -e "Default tiers are used unless you change them."
    echo -e "Enter valid numbers (e.g., 10, 50, 0.5)."
    echo -e "Press ${YELLOW}[ENTER]${NC} to keep default."
    echo -e "Press ${YELLOW}[~]${NC} (Tilde) at any time to SAVE and finish."
    
    # Read first 20 tiers
    for i in {01..20}; do
        # Get current default from file if exists (extract value inside quotes)
        local current_val=$(grep "^L$i=" "$config_file" | cut -d'"' -f2)
        local prompt="Tier L$i (ms)"
        
        # Colorize the default value in the prompt
        read -p "$(echo -e "$prompt [${YELLOW}$current_val${NC}]: ")" input
        
        # Check for Exit Key
        if [[ "$input" == "~" ]]; then 
            echo -e "${GREEN}✅ Saved tiers.${NC}"; break 
        fi
        
        if [ -n "$input" ]; then
            # Validate Number
            if [[ "$input" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
                # Update config file using sed
                sed -i "s/^L$i=.*/L$i=\"$input\"/" "$config_file"
            else
                echo -e "${RED}❌ Invalid number. Using default.${NC}"
            fi
        fi
    done
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
            if grep -q "^$p_name|" "$CRON_DB" 2>/dev/null; then
                echo -e "${RED}❌ Profile name taken.${NC}" >&2
            else break; fi
        else echo -e "${RED}❌ Invalid name.${NC}" >&2; fi
    done

    # --- 1. Prepare Config File ---
    local p_conf="$CRON_DIR/${p_name}.conf"
    if [ ! -f "$DEFAULT_CONFIG" ]; then
        echo -e "${RED}❌ Default config not found. Cannot clone.${NC}"
        return
    fi
    cp "$DEFAULT_CONFIG" "$p_conf"
    
    # --- 2. Tiers (Always ask, even for default) ---
    if [ "$(ask_bool "Customize Latency Tiers?" "n")" == "true" ]; then
        ask_tiers "$p_conf"
    fi

    # --- 3. Extra Arguments (Skip if profile is 'default') ---
    local extra_args=""
    if [ "$p_name" != "default" ]; then
        while true; do
            echo -e "\n${YELLOW}ℹ️  Extra Arguments (Domain filters, etc)${NC}"
            echo -e "Type 'h' for help, or enter arguments:"
            read -e -p "> " input_args
            
            if [[ "$input_args" == "h" ]]; then
                show_valid_args
            elif [ -z "$input_args" ]; then
                break # No args, empty is fine
            else
                if validate_args "$input_args"; then
                    extra_args="$input_args"
                    # Inject into config file
                    sed -i "s|^CONFIG_ARGS=.*|CONFIG_ARGS='$extra_args'|" "$p_conf"
                    break
                fi
            fi
        done
    else
        echo -e "\n${YELLOW}ℹ️  'Default' profile selected. Skipping extra arguments.${NC}"
    fi

    # --- 4. Schedule ---
    echo -e "\n${BLUE}💡 Interval Guidance:${NC}"
    echo -e "Standard intervals (e.g., 1, 5, 10, 15, 30, 60) align perfectly with the clock."
    
    local unit="m"
    local prompt_txt="Run every X minutes"
    local def_val="5"
    
    if [ "$ALLOW_SECONDS" = true ]; then
        unit="s"; prompt_txt="Run every X seconds (10, 15, 20, 30)"; def_val="15"
    fi

    local freq=""
    while true; do
        freq=$(ask_val "$prompt_txt" "$def_val")
        if [ "$unit" == "s" ]; then
            if [[ "$freq" =~ ^(10|15|20|30)$ ]]; then break;
            else echo -e "${RED}❌ For seconds, use 10, 15, 20, or 30.${NC}" >&2; fi
        else
            if [[ "$freq" =~ ^[0-9]+$ ]] && [ "$freq" -ge 1 ]; then break;
            else echo -e "${RED}❌ Invalid number.${NC}" >&2; fi
        fi
    done
    
    # --- 5. Unbound Cache Count (Dedicated Prompt) ---
    echo ""
    local ucc=$(ask_bool "Enable Unbound Cache Stats (-ucc)?" "n")
    
    save_and_schedule "$p_name" "$freq" "$unit" "$ucc" "$p_conf"
}

save_and_schedule() {
    local name="$1"; local val="$2"; local unit="$3"; local ucc="$4"; local conf_file="$5"

    # BUILD COMMAND
    local cmd_args="-dash \"$name\" -c \"$conf_file\""
    if [ "$ucc" == "true" ]; then cmd_args="$cmd_args -ucc"; fi
    
    local full_cmd="cd $INSTALL_DIR && ./pihole_stats.sh $cmd_args >> $CRON_DIR/${name}_debug.log 2>&1"
    
    # BUILD CRON STRING
    local cron_entries=""
    local summary=""
    
    if [ "$unit" == "s" ]; then
        local count=$((60 / val))
        for (( i=0; i<count; i++ )); do
            local sleep_sec=$((i * val))
            if [ "$sleep_sec" -eq 0 ]; then cron_entries+="* * * * * $full_cmd # PHLS-ID:$name";
            else cron_entries+=$'\n'; cron_entries+="* * * * * sleep $sleep_sec; $full_cmd # PHLS-ID:$name"; fi
        done
        summary="Every $val Second(s)"
    else
        if [ "$val" -lt 60 ]; then
             cron_entries="*/$val * * * * $full_cmd # PHLS-ID:$name"
             summary="Every $val Minute(s)"
        else
            local hrs=$((val / 60))
            if [ "$hrs" -ge 24 ]; then
                 local days=$((hrs / 24))
                 cron_entries="0 0 */$days * * $full_cmd # PHLS-ID:$name"
                 summary="Every $days Day(s)"
            else
                 cron_entries="0 */$hrs * * * $full_cmd # PHLS-ID:$name"
                 summary="Every $hrs Hour(s)"
            fi
        fi
    fi
    
    # INSTALL CRON
    local EXISTING_CRON=$(crontab -l 2>/dev/null)
    local FINAL_CRON=""
    if echo "$EXISTING_CRON" | grep -q "^PATH="; then
        FINAL_CRON=$(echo -e "$EXISTING_CRON\n$cron_entries")
    else
        FINAL_CRON=$(echo -e "$CRON_PATH\n$EXISTING_CRON\n$cron_entries")
    fi
    echo "$FINAL_CRON" | crontab -

    # SAVE TO DB (Append)
    echo "$name|$val$unit|$(date)|$conf_file" >> "$CRON_DB"

    echo -e "${GREEN}✅ Profile '$name' updated!${NC}"
    echo -e "   Schedule: ${YELLOW}$summary${NC}"
    
    echo -e "${YELLOW}🚀 Reloading data...${NC}"
    eval "$full_cmd &"
}

remove_cron_job() {
    local name="$1"
    crontab -l 2>/dev/null | grep -v "# PHLS-ID:$name" | crontab -
    
    # Clean up files if we are NOT modifying (keep files if just edit logic)
    # But usually we want to delete.
    # In modify logic we handle file updates separately.
}

modify_profile() {
    if [ ! -s "$CRON_DB" ]; then echo "No profiles found."; return; fi
    echo -e "${BLUE}--- Modify Profile ---${NC}"
    
    # 1. Select Profile
    mapfile -t lines < "$CRON_DB"
    local count=${#lines[@]}
    local i=1; for line in "${lines[@]}"; do echo "$i. $(echo "$line" | cut -d'|' -f1)"; ((i++)); done

    local choice=""
    while true; do
        choice=$(ask_val "Select number [1-$count]" "")
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "$count" ]; then break; fi
        echo -e "${RED}❌ Invalid.${NC}" >&2
    done

    local idx=$((choice-1))
    local db_line="${lines[$idx]}"
    local p_name=$(echo "$db_line" | cut -d'|' -f1)
    local raw_freq=$(echo "$db_line" | cut -d'|' -f2)
    local p_conf=$(echo "$db_line" | cut -d'|' -f4)

    echo -e "\n${BLUE}Editing Profile: ${GREEN}$p_name${NC}"

    # 2. Edit Tiers (In-place update, reads current values as defaults)
    if [ "$(ask_bool "Edit Latency Tiers?" "n")" == "true" ]; then
        ask_tiers "$p_conf"
    fi

    # 3. Edit Extra Arguments
    local cur_args=$(grep "^CONFIG_ARGS=" "$p_conf" | cut -d"'" -f2)
    
    if [ "$p_name" == "default" ]; then
         echo -e "\n${YELLOW}ℹ️  'Default' profile does not support extra arguments.${NC}"
    else
        echo -e "\n${YELLOW}ℹ️  Extra Arguments${NC}"
        echo -e "Current: [${GREEN}${cur_args:-None}${NC}]"
        
        if [ "$(ask_bool "Change arguments?" "n")" == "true" ]; then
             while true; do
                echo -e "Type 'h' for help, or enter new arguments (Press Enter to keep current):"
                read -e -p "> " input_args
                
                if [[ "$input_args" == "h" ]]; then
                    show_valid_args
                elif [ -z "$input_args" ]; then
                    # Keep current
                    break 
                else
                    if validate_args "$input_args"; then
                        # Update Config
                        sed -i "s|^CONFIG_ARGS=.*|CONFIG_ARGS='$input_args'|" "$p_conf"
                        echo -e "${GREEN}✅ Arguments updated.${NC}"
                        break
                    fi
                fi
            done
        fi
    fi

    # 4. Edit Schedule
    # Parse old frequency (e.g. 15s or 5m)
    local old_unit="${raw_freq: -1}"
    local old_val="${raw_freq%?}"
    
    # Prompt with current settings
    local new_val="$old_val"
    local new_unit="$old_unit"

    echo -e "\n${BLUE}--- Schedule Setup ---${NC}"
    if [ "$(ask_bool "Change Schedule (Currently: $old_val$old_unit)?" "n")" == "true" ]; then
        local def_val="5"
        local unit="m"
        local prompt_txt="Run every X minutes"
        
        if [ "$ALLOW_SECONDS" = true ]; then
            unit="s"; prompt_txt="Run every X seconds (10, 15, 20, 30)"; def_val="15"
        fi

        local freq=""
        while true; do
            freq=$(ask_val "$prompt_txt" "$def_val")
            if [ "$unit" == "s" ]; then
                if [[ "$freq" =~ ^(10|15|20|30)$ ]]; then break;
                else echo -e "${RED}❌ For seconds, use 10, 15, 20, or 30.${NC}" >&2; fi
            else
                if [[ "$freq" =~ ^[0-9]+$ ]] && [ "$freq" -ge 1 ]; then break;
                else echo -e "${RED}❌ Invalid number.${NC}" >&2; fi
            fi
        done
        new_val="$freq"
        new_unit="$unit"
    fi

    # 5. Edit UCC
    # Check Crontab for current state by finding the flag in the command
    local cur_ucc_bool="false"
    if crontab -l 2>/dev/null | grep "# PHLS-ID:$p_name" | grep -q -- "-ucc"; then cur_ucc_bool="true"; fi
    
    local disp_char="n"
    if [ "$cur_ucc_bool" == "true" ]; then disp_char="y"; fi
    
    echo ""
    local new_ucc=$(ask_bool "Enable Unbound Cache Stats (-ucc)?" "$disp_char")

    # 6. Save (Delete old DB entry first, then call saver)
    sed -i "/^$p_name|/d" "$CRON_DB"
    # Also clear old cron job from crontab before re-adding
    crontab -l 2>/dev/null | grep -v "# PHLS-ID:$p_name" | crontab -
    
    save_and_schedule "$p_name" "$new_val" "$new_unit" "$new_ucc" "$p_conf"
}

delete_profile() {
    if [ ! -s "$CRON_DB" ]; then echo "No profiles found."; return 1; fi
    echo -e "${BLUE}--- Delete Profile ---${NC}"
    mapfile -t lines < "$CRON_DB"
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
        # 1. Remove from Crontab
        remove_cron_job "$name"
        # 2. Remove from DB
        sed -i "/^$name|/d" "$CRON_DB"
        # 3. Delete Config and Log
        rm -f "$CRON_DIR/${name}.conf" "$CRON_DIR/${name}_debug.log"
        
        echo -e "${GREEN}✅ Deleted.${NC}"
        return 0
    else 
        echo "Aborted."
        return 1
    fi
}

# ==============================================================================
#                               MAIN MENU
# ==============================================================================

touch "$CRON_DB"
show_header

if [ -s "$CRON_DB" ]; then
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