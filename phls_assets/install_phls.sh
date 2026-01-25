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


# --- VERSION TRACKING ---
VERSION="v4.0"

# --- CONFIGURATION: URLs ---
BASE_URL="https://github.com/panoc/pihole-latency-stats/releases/latest/download"
# BASE_URL="https://raw.githubusercontent.com/panoc/pihole-latency-stats/refs/heads/main/phls_assets/test36"

URL_SCRIPT="$BASE_URL/pihole_stats.sh"
URL_VERSION="$BASE_URL/version"
URL_CRON_MAKER="$BASE_URL/cronmaker.sh"

URL_DASH="$BASE_URL/dash.html"
URL_FAVICON="$BASE_URL/favicon.png"
URL_BOOTSTRAP="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/css/bootstrap.min.css"
URL_CHARTJS="https://cdn.jsdelivr.net/npm/chart.js@3.9.1/dist/chart.min.js"

# --- DETECT REAL USER ---
if [ -n "$SUDO_USER" ]; then
    REAL_USER="$SUDO_USER"
    REAL_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
else
    REAL_USER="$USER"
    REAL_HOME="$HOME"
fi

# --- DEFAULTS ---
DEFAULT_INSTALL_DIR="$REAL_HOME/phls"
DEFAULT_DASH_DIR="/var/www/html/admin/img/dash"
STATE_FILE=".phls_install.conf"
MANIFEST_FILE=".phls_file_list"

# Global Variables
FINAL_INSTALL_DIR="$DEFAULT_INSTALL_DIR"
FINAL_DASH_DIR="$DEFAULT_DASH_DIR"
DO_INSTALL_CORE=false
DO_INSTALL_DASH=false
IS_CLEAN_INSTALL=false

# --- HELPER FUNCTIONS ---

ask_yn() {
    local prompt="$1"
    while true; do
        read -r -p "$prompt [y/N]: " input
        case $input in
            [Yy]|[Yy][Ee][Ss]) return 0 ;;
            [Nn]|[Nn][Oo]) return 1 ;;
            *) echo "Please answer yes (y) or no (n)." ;;
        esac
    done
}

fix_perms() {
    local target="$1"
    if [ -f "$target" ] || [ -d "$target" ]; then
        chown -R "$REAL_USER":"$(id -gn "$REAL_USER")" "$target"
    fi
}

log_file() {
    echo "${1}:${2}" >> "$FINAL_INSTALL_DIR/$MANIFEST_FILE"
}

check_dependencies() {
    echo "🔍 Checking system dependencies..."
    local deps=("sqlite3" "curl" "awk" "sed")
    local missing=()
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then missing+=("$dep"); fi
    done

    if [ ${#missing[@]} -ne 0 ]; then
        echo "⚠️  Missing: ${missing[*]}"
        if command -v apt-get &> /dev/null; then
            if ask_yn "Install via apt?"; then
                apt-get update && apt-get install -y "${missing[@]}"
            else exit 1; fi
        else
            echo "❌ Install manually: ${missing[*]}"; exit 1
        fi
    fi
}

check_and_remove_old_installer() {
    local target_path="$1"
    local target_file="$target_path/install_phls.sh"
    if [ -f "$target_file" ] && [ "$target_file" != "$(realpath "$0")" ]; then
        rm -f "$target_file"
    fi
}

# --- INSTALLATION MODULES ---

create_uninstaller() {
    UNINSTALLER_PATH="$FINAL_INSTALL_DIR/phls_uninstall.sh"
    cat << 'EOF' > "$UNINSTALLER_PATH"
#!/bin/bash
# PHLS Uninstaller
if [ "$EUID" -ne 0 ]; then echo "❌ Please run as root (sudo)."; exit 1; fi

INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
STATE_FILE="$INSTALL_DIR/.phls_install.conf"
REMOVE_DASH_PATH=""
REMOVE_INSTALL_PATH="$INSTALL_DIR"

if [ -f "$STATE_FILE" ]; then
    source "$STATE_FILE"
    [ -n "$DASH_PATH" ] && REMOVE_DASH_PATH="$DASH_PATH"
    [ -n "$INSTALL_PATH" ] && REMOVE_INSTALL_PATH="$INSTALL_PATH"
fi

echo "========================================"
echo "   Pi-hole Latency Stats Uninstaller"
echo "========================================"
echo "Permanently removing from: $REMOVE_INSTALL_PATH"
[ -n "$REMOVE_DASH_PATH" ] && echo "Removing Dashboard: $REMOVE_DASH_PATH"
echo ""
read -p "Are you sure? [y/N]: " -r confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then echo "Aborted."; exit 0; fi

echo "🧹 Removing Cron Jobs..."
crontab -l 2>/dev/null | grep -v "# PHLS-ID:" | crontab -

if [ -n "$REMOVE_DASH_PATH" ] && [ -d "$REMOVE_DASH_PATH" ]; then
    echo "🗑️  Removing Dashboard Directory..."
    rm -rf "$REMOVE_DASH_PATH"
fi

echo "🗑️  Removing PHLS Directory..."
rm -rf "$REMOVE_INSTALL_PATH"
echo "✅ Done."
EOF
    chmod +x "$UNINSTALLER_PATH"
    fix_perms "$UNINSTALLER_PATH"
}

install_core() {
    # 1. Path Confirmation (Only on clean install)
    if [ "$IS_CLEAN_INSTALL" = true ]; then
        if ask_yn "Install Core Script to custom path?"; then
            read -e -p "Enter path: " USER_PATH
            [ -n "$USER_PATH" ] && FINAL_INSTALL_DIR="${USER_PATH%/}"
        fi
    fi

    if [ ! -d "$FINAL_INSTALL_DIR" ]; then mkdir -p "$FINAL_INSTALL_DIR"; fi
    fix_perms "$FINAL_INSTALL_DIR"
    check_and_remove_old_installer "$FINAL_INSTALL_DIR"

    # Reset Config if Clean Install
    if [ "$IS_CLEAN_INSTALL" = true ]; then
        echo "🧹 Cleaning old configuration..."
        rm -f "$FINAL_INSTALL_DIR/pihole_stats.conf"
        rm -rf "$FINAL_INSTALL_DIR/cron"
        # Wipe CRON
        crontab -l 2>/dev/null | grep -v "# PHLS-ID:" | crontab -
    fi

    # Initialize Manifest
    echo "# PHLS Installed Files List" > "$FINAL_INSTALL_DIR/$MANIFEST_FILE"
    fix_perms "$FINAL_INSTALL_DIR/$MANIFEST_FILE"

    echo "⬇️  Downloading Core Files..."
    
    # Download Core
    curl -sL "$URL_SCRIPT" -o "$FINAL_INSTALL_DIR/pihole_stats.sh"
    chmod +x "$FINAL_INSTALL_DIR/pihole_stats.sh"
    fix_perms "$FINAL_INSTALL_DIR/pihole_stats.sh"
    log_file "SCRIPT" "$FINAL_INSTALL_DIR/pihole_stats.sh"

    # Download Version
    curl -sL "$URL_VERSION" -o "$FINAL_INSTALL_DIR/version"
    fix_perms "$FINAL_INSTALL_DIR/version"
    log_file "SCRIPT" "$FINAL_INSTALL_DIR/version"

    # Download Cron Maker
    CRON_DIR="$FINAL_INSTALL_DIR/cron"
    mkdir -p "$CRON_DIR"
    curl -sL "$URL_CRON_MAKER" -o "$CRON_DIR/cronmaker.sh"
    chmod +x "$CRON_DIR/cronmaker.sh"
    fix_perms "$CRON_DIR/cronmaker.sh"
    log_file "SCRIPT" "$CRON_DIR/cronmaker.sh"

    # Generate Config if missing
    if [ ! -f "$FINAL_INSTALL_DIR/pihole_stats.conf" ]; then
        echo "⚙️  Generating default configuration..."
        sudo -u "$REAL_USER" bash "$FINAL_INSTALL_DIR/pihole_stats.sh" -mc "$FINAL_INSTALL_DIR/pihole_stats.conf" > /dev/null 2>&1
        if [ -f "$FINAL_INSTALL_DIR/pihole_stats.conf" ]; then
            chown "$REAL_USER":"$(id -gn "$REAL_USER")" "$FINAL_INSTALL_DIR/pihole_stats.conf"
        fi
    fi

    create_uninstaller

    # --- AUTO UPDATER SETUP ---
    # Only ask if clean install OR if the updater script is missing
    if [ "$IS_CLEAN_INSTALL" = true ] || [ ! -f "$FINAL_INSTALL_DIR/phls_version_check.sh" ]; then
        if ask_yn "Enable Auto-Update Check? (Checks every 3 days)"; then
            setup_auto_update
        fi
    fi
}

setup_auto_update() {
    echo "----------------------------------------"
    echo "Configuring Auto-Update..."
    UPDATER_SCRIPT="$FINAL_INSTALL_DIR/phls_version_check.sh"
    
    # Use global FINAL_DASH_DIR variable
    TARGET_DASH_DIR=""
    [ "$DO_INSTALL_DASH" = true ] && TARGET_DASH_DIR="$FINAL_DASH_DIR"

    cat <<EOF > "$UPDATER_SCRIPT"
#!/bin/bash
# PHLS Version Auto-Checker
INSTALL_DIR="$FINAL_INSTALL_DIR"
DASH_DIR="$TARGET_DASH_DIR"
URL_VERSION="$URL_VERSION"

if [ -d "\$INSTALL_DIR" ]; then
    curl -sL "\$URL_VERSION" -o "\$INSTALL_DIR/version" 2>/dev/null
    if [ -n "\$DASH_DIR" ] && [ -d "\$DASH_DIR" ] && [ -f "\$INSTALL_DIR/version" ]; then
        cp "\$INSTALL_DIR/version" "\$DASH_DIR/version"
        chown www-data:www-data "\$DASH_DIR/version" 2>/dev/null
        chmod 644 "\$DASH_DIR/version" 2>/dev/null
    fi
fi
EOF
    chmod +x "$UPDATER_SCRIPT"
    fix_perms "$UPDATER_SCRIPT"
    log_file "SCRIPT" "$UPDATER_SCRIPT"

    REQUIRED_PATH="export PATH=\$PATH:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin;"
    CRON_CMD="$REQUIRED_PATH $UPDATER_SCRIPT # PHLS-ID:updater"
    
    # Update Cron
    EXISTING_CRON=$(crontab -l 2>/dev/null | grep -v "# PHLS-ID:updater")
    echo -e "$EXISTING_CRON\n0 0 */3 * * $CRON_CMD" | crontab -
    echo "✅ Auto-Update scheduled."
}

install_dashboard() {
    if [ "$IS_CLEAN_INSTALL" = true ]; then
        if ask_yn "Install Dashboard to custom path?"; then
            read -e -p "Enter path: " USER_PATH
            [ -n "$USER_PATH" ] && FINAL_DASH_DIR="${USER_PATH%/}"
        fi
    fi

    echo "⬇️  Downloading Dashboard to $FINAL_DASH_DIR..."
    [ ! -d "$FINAL_DASH_DIR" ] && { mkdir -p "$FINAL_DASH_DIR"; chown www-data:www-data "$FINAL_DASH_DIR"; chmod 775 "$FINAL_DASH_DIR"; }

    dl_dash() { curl -sL "$1" -o "$2"; log_file "DASH" "$2"; }

    dl_dash "$URL_DASH" "$FINAL_DASH_DIR/dash.html"
    dl_dash "$URL_VERSION" "$FINAL_DASH_DIR/version"
    dl_dash "$URL_FAVICON" "$FINAL_DASH_DIR/favicon.png"
    dl_dash "$URL_BOOTSTRAP" "$FINAL_DASH_DIR/bootstrap.min.css"
    dl_dash "$URL_CHARTJS" "$FINAL_DASH_DIR/chart.js"

    chown -R www-data:www-data "$FINAL_DASH_DIR"
    chmod -R 755 "$FINAL_DASH_DIR"
    echo "✅ Dashboard Updated."

    # --- SAFETY CHECK: Priming Logic ---
    # We check if 'dash_default.json' or 'dash_default.h.json' exists.
    # If they do, we warn the user that running the update might touch them.
    
    DATA_EXISTS=false
    if [ -f "$FINAL_DASH_DIR/dash_default.json" ] || [ -f "$FINAL_DASH_DIR/dash_default.h.json" ]; then
        DATA_EXISTS=true
    fi

    if [ "$DATA_EXISTS" = true ]; then
        echo ""
        echo -e "\033[1;33m⚠️  EXISTING DATA DETECTED IN DASHBOARD FOLDER\033[0m"
        echo "   Running an immediate update (Prime) typically appends to history,"
        echo "   but running a new script version against old data carries a small risk."
        echo ""
        if ask_yn "Do you want to run an update check now? (Say NO to preserve data as-is)"; then
            echo "📊 Updating dashboard data..."
            sudo "$FINAL_INSTALL_DIR/pihole_stats.sh" -dash "default" > /dev/null
            echo "✅ Data updated."
        else
            echo "ℹ️  Skipping data update to protect existing history."
        fi
    
    # If clean install or no data found, proceed normally
    elif [ "$IS_CLEAN_INSTALL" = true ] || ask_yn "Repopulate/Prime dashboard data now?"; then
        echo "📊 Priming dashboard..."
        sudo "$FINAL_INSTALL_DIR/pihole_stats.sh" -dash "default" > /dev/null
        echo "✅ Data initialized."
    fi
}

# ==============================================================================
#                               MAIN LOGIC
# ==============================================================================

if [ "$EUID" -ne 0 ]; then echo "❌ Please run as root (sudo)."; exit 1; fi
check_dependencies

echo "========================================"
echo "   Pi-hole Latency Stats Installer $VERSION"
echo "========================================"

# --- 1. DETECTION PHASE ---
DETECTED_CORE=false
DETECTED_DASH=false

# Load state
if [ -f "$DEFAULT_INSTALL_DIR/$STATE_FILE" ]; then
    source "$DEFAULT_INSTALL_DIR/$STATE_FILE"
    [ -n "$INSTALL_PATH" ] && FINAL_INSTALL_DIR="$INSTALL_PATH"
    [ -n "$DASH_PATH" ] && FINAL_DASH_DIR="$DASH_PATH"
fi

[ -f "$FINAL_INSTALL_DIR/pihole_stats.sh" ] && DETECTED_CORE=true
[ -f "$FINAL_DASH_DIR/dash.html" ] && DETECTED_DASH=true

# --- 2. MENU PHASE ---

if [ "$DETECTED_CORE" = true ] || [ "$DETECTED_DASH" = true ]; then
    echo -e "\033[1;32m✅ Existing Installation Detected.\033[0m"
    echo "   Core: $FINAL_INSTALL_DIR"
    echo "   Dash: $FINAL_DASH_DIR"
    echo ""
    echo "Options:"
    echo "   1) Upgrade Core Script Only"
    echo "   2) Upgrade Dashboard Only"
    echo "   3) Upgrade EVERYTHING (Preserve Config)"
    echo "   4) CLEAN INSTALL (Wipe Configs, Cron & Start Over)"
    echo "   5) Cancel"
    echo ""
    read -r -p "Select [1-5]: " OPTION

    case $OPTION in
        1) DO_INSTALL_CORE=true ;;
        2) DO_INSTALL_DASH=true ;;
        3) DO_INSTALL_CORE=true; DO_INSTALL_DASH=true ;;
        4) DO_INSTALL_CORE=true; DO_INSTALL_DASH=true; IS_CLEAN_INSTALL=true ;;
        *) echo "Aborted."; exit 0 ;;
    esac
else
    # New Install
    echo "No installation found."
    if ask_yn "Install Core Scripts?"; then
        DO_INSTALL_CORE=true
        IS_CLEAN_INSTALL=true # Treat new install like clean install for logic
    else
        echo "Aborted."; exit 0
    fi
    if ask_yn "Install Dashboard?"; then DO_INSTALL_DASH=true; fi
fi

# --- 3. EXECUTION PHASE ---

# A. Install Core
if [ "$DO_INSTALL_CORE" = true ]; then
    install_core
else
    echo "ℹ️  Skipping Core update."
fi

# B. Install Dashboard
if [ "$DO_INSTALL_DASH" = true ]; then
    install_dashboard
else
    echo "ℹ️  Skipping Dashboard update."
fi

# C. Save State
cat <<EOF > "$FINAL_INSTALL_DIR/$STATE_FILE"
# PHLS Installation Record
INSTALL_PATH="$FINAL_INSTALL_DIR"
DASH_PATH="$([ "$DO_INSTALL_DASH" = true ] || [ "$DETECTED_DASH" = true ] && echo "$FINAL_DASH_DIR" || echo "")"
INSTALL_DATE="$(date)"
VERSION="$VERSION"
EOF
fix_perms "$FINAL_INSTALL_DIR/$STATE_FILE"

# --- 4. FINALE (Port Detection & Cron Maker) ---

echo "========================================"
echo "   Operation Complete!"
echo "========================================"

if [ "$DO_INSTALL_DASH" = true ]; then
    PIHOLE_IP=$(hostname -I | awk '{print $1}')
    PORT="80"
    if [ -f "/etc/pihole/pihole.toml" ]; then
        DETECTED=$(awk '/^[ \t]*\[.*webserver.*\]/{f=1;next}/^[ \t]*\[/{f=0}f&&/^[ \t]*port[ \t]*=/{gsub(/"/,"",$0);split($0,a,"=");split(a[2],b,",");gsub(/[^0-9]/,"",b[1]);print b[1];exit}' /etc/pihole/pihole.toml)
        [[ "$DETECTED" =~ ^[0-9]+$ ]] && PORT="$DETECTED"
    fi
    DISPLAY_URL="$PIHOLE_IP"
    [ "$PORT" != "80" ] && DISPLAY_URL="$PIHOLE_IP:$PORT"
    
    echo "Dashboard URL:"
    echo -e "  \033[1;36mhttp://$DISPLAY_URL/admin/img/dash/dash.html?p=default\033[0m"
fi

if [ "$DO_INSTALL_CORE" = true ]; then
    echo "Core Script: $FINAL_INSTALL_DIR/pihole_stats.sh"
    echo "Cron Maker:  $FINAL_INSTALL_DIR/cron/cronmaker.sh"
    
    if [ "$IS_CLEAN_INSTALL" = true ] && ask_yn "Launch Cron Maker now?"; then
        rm -- "$0" # Cleanup self
        exec "$FINAL_INSTALL_DIR/cron/cronmaker.sh"
    fi
fi

echo ""
echo "🧹 Cleaning up installer..."
rm -- "$0" 2>/dev/null