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
VERSION="v3.6"

# --- CONFIGURATION: URLs (Stable Release Links) ---
BASE_URL="https://github.com/panoc/pihole-latency-stats/releases/latest/download"

URL_SCRIPT="$BASE_URL/pihole_stats.sh"
URL_VERSION="$BASE_URL/version"
URL_CRON_MAKER="$BASE_URL/phls_cron_maker.sh"

URL_DASH="$BASE_URL/dash.html"
URL_FAVICON="$BASE_URL/favicon.png"

# Remote Dependencies
URL_BOOTSTRAP="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/css/bootstrap.min.css"
URL_CHARTJS="https://cdn.jsdelivr.net/npm/chart.js@3.9.1/dist/chart.min.js"

# --- DETECT REAL USER (Sudo Handling) ---
if [ -n "$SUDO_USER" ]; then
    REAL_USER="$SUDO_USER"
    REAL_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
else
    REAL_USER="$USER"
    REAL_HOME="$HOME"
fi

# --- PATHS & FILES ---
DEFAULT_INSTALL_DIR="$REAL_HOME/phls"
DEFAULT_DASH_DIR="/var/www/html/admin/img/dash"
STATE_FILE=".phls_install.conf"
MANIFEST_FILE=".phls_file_list"

# Get directory where this script is running
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
CURRENT_SCRIPT_NAME=$(basename "$0")

# --- HELPER: Strict Y/N Input (Requires Enter) ---
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

# --- HELPER: Fix Permissions ---
fix_perms() {
    local target="$1"
    if [ -f "$target" ] || [ -d "$target" ]; then
        chown -R "$REAL_USER":"$(id -gn "$REAL_USER")" "$target"
    fi
}

# --- HELPER: Dependency Check ---
check_dependencies() {
    echo "🔍 Checking system dependencies..."
    local deps=("sqlite3" "curl" "awk" "sed")
    local missing=()

    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            missing+=("$dep")
        fi
    done

    if [ ${#missing[@]} -ne 0 ]; then
        echo "⚠️  The following dependencies are missing: ${missing[*]}"
        if command -v apt-get &> /dev/null; then
            if ask_yn "Would you like to install them via apt?"; then
                apt-get update && apt-get install -y "${missing[@]}"
            else
                echo "❌ Please install them manually and run the installer again."
                exit 1
            fi
        else
            echo "❌ 'apt' not detected. Please manually install: ${missing[*]}"
            exit 1
        fi
    else
        echo "✅ All system dependencies are present."
    fi
}

# --- HELPER: Add to Manifest ---
log_file() {
    local tag="$1"
    local file="$2"
    echo "${tag}:${file}" >> "$FINAL_INSTALL_DIR/$MANIFEST_FILE"
}

# --- HELPER: Remove Duplicate Installer ---
check_and_remove_old_installer() {
    local target_path="$1"
    local target_file="$target_path/install_phls.sh"
    if [ -f "$target_file" ] && [ "$target_file" != "$(realpath "$0")" ]; then
        rm -f "$target_file"
    fi
}

# ==============================================================================
#                               INSTALLATION LOGIC
# ==============================================================================

if [ "$EUID" -ne 0 ]; then
    echo "❌ Please run as root (sudo)."
    exit 1
fi

check_dependencies

echo "========================================"
echo "   Pi-hole Latency Stats Installer $VERSION"
echo "========================================"

check_and_remove_old_installer "$DEFAULT_INSTALL_DIR"

if ! ask_yn "This will install Pi-hole Latency Stats. Continue?"; then
    echo "Aborted."
    exit 0
fi

# --- 1. DETERMINE PATHS ---
INSTALL_DASHBOARD=false
FINAL_INSTALL_DIR="$DEFAULT_INSTALL_DIR"

if ask_yn "Do you want to install Pi-hole Latency Stats Dashboard?"; then
    INSTALL_DASHBOARD=true
    if ask_yn "Do you want to install script to custom path?"; then
        read -e -p "Enter path: " USER_PATH
        if [ -n "$USER_PATH" ]; then
            FINAL_INSTALL_DIR="${USER_PATH%/}"
            check_and_remove_old_installer "$FINAL_INSTALL_DIR"
        fi
    fi
else
    if ask_yn "Do you want to install to custom path?"; then
        read -e -p "Enter path: " USER_PATH
        if [ -n "$USER_PATH" ]; then
            FINAL_INSTALL_DIR="${USER_PATH%/}"
            check_and_remove_old_installer "$FINAL_INSTALL_DIR"
        fi
    fi
fi

if [ ! -d "$FINAL_INSTALL_DIR" ]; then mkdir -p "$FINAL_INSTALL_DIR"; fi
fix_perms "$FINAL_INSTALL_DIR"

# --- 2. OVERWRITE & CLEAN INSTALL CHECK ---
if [ -f "$FINAL_INSTALL_DIR/pihole_stats.sh" ] || [ -f "$FINAL_INSTALL_DIR/pihole_stats.conf" ]; then
    echo ""
    echo -e "\033[1;33m⚠️  An existing installation was found in $FINAL_INSTALL_DIR\033[0m"
    if ! ask_yn "Do you want to overwrite it?"; then
        echo "Aborted."
        exit 0
    fi
    
    echo ""
    if ask_yn "Do you want to perform a Clean Install (Reset configuration to defaults)?"; then
        echo "🧹 Clean Install selected. Removing old configuration..."
        rm -f "$FINAL_INSTALL_DIR/pihole_stats.conf"
    else
        echo "🔄 Update Mode selected. Existing configuration will be preserved."
    fi
fi

# Initialize Manifest
echo "# PHLS Installed Files List" > "$FINAL_INSTALL_DIR/$MANIFEST_FILE"
fix_perms "$FINAL_INSTALL_DIR/$MANIFEST_FILE"

# --- 3. INSTALL MAIN SCRIPT & UTILS ---
echo "⬇️  Downloading Core Files..."

# 3a. Main Script
curl -sL "$URL_SCRIPT" -o "$FINAL_INSTALL_DIR/pihole_stats.sh"
[ ! -s "$FINAL_INSTALL_DIR/pihole_stats.sh" ] && { echo "❌ Download failed (Script)."; exit 1; }
chmod +x "$FINAL_INSTALL_DIR/pihole_stats.sh"
fix_perms "$FINAL_INSTALL_DIR/pihole_stats.sh"
log_file "SCRIPT" "$FINAL_INSTALL_DIR/pihole_stats.sh"

# 3b. Version File
curl -sL "$URL_VERSION" -o "$FINAL_INSTALL_DIR/version"
fix_perms "$FINAL_INSTALL_DIR/version"
log_file "SCRIPT" "$FINAL_INSTALL_DIR/version"

# 3c. Cron Maker
curl -sL "$URL_CRON_MAKER" -o "$FINAL_INSTALL_DIR/phls_cron_maker.sh"
chmod +x "$FINAL_INSTALL_DIR/phls_cron_maker.sh"
fix_perms "$FINAL_INSTALL_DIR/phls_cron_maker.sh"
log_file "SCRIPT" "$FINAL_INSTALL_DIR/phls_cron_maker.sh"

echo "✅ Core files installed."

echo "⚙️  Updating/Generating configuration..."
sudo -u "$REAL_USER" bash "$FINAL_INSTALL_DIR/pihole_stats.sh" -mc "$FINAL_INSTALL_DIR/pihole_stats.conf" > /dev/null 2>&1
if [ -f "$FINAL_INSTALL_DIR/pihole_stats.conf" ]; then
    chown "$REAL_USER":"$(id -gn "$REAL_USER")" "$FINAL_INSTALL_DIR/pihole_stats.conf"
fi

# --- 4. INSTALL DASHBOARD (Optional) ---
DASH_INSTALLED_PATH=""
if [ "$INSTALL_DASHBOARD" = true ]; then
    echo "----------------------------------------"
    echo "Installing Dashboard..."
    [ ! -d "$DEFAULT_DASH_DIR" ] && { mkdir -p "$DEFAULT_DASH_DIR"; chown www-data:www-data "$DEFAULT_DASH_DIR"; chmod 775 "$DEFAULT_DASH_DIR"; }

    dl_and_log() {
        curl -sL "$1" -o "$2"
        log_file "DASH" "$2"
    }

    dl_and_log "$URL_DASH" "$DEFAULT_DASH_DIR/dash.html"
    # UPDATED: Download common version file to dashboard dir
    dl_and_log "$URL_VERSION" "$DEFAULT_DASH_DIR/version"
    dl_and_log "$URL_FAVICON" "$DEFAULT_DASH_DIR/favicon.png"
    dl_and_log "$URL_BOOTSTRAP" "$DEFAULT_DASH_DIR/bootstrap.min.css"
    dl_and_log "$URL_CHARTJS" "$DEFAULT_DASH_DIR/chart.js"

    chown -R www-data:www-data "$DEFAULT_DASH_DIR"
    chmod -R 755 "$DEFAULT_DASH_DIR"
    DASH_INSTALLED_PATH="$DEFAULT_DASH_DIR"
    echo "✅ Dashboard installed to: $DEFAULT_DASH_DIR"

    if ask_yn "Do you want to save json log file to dashboard directory?"; then
        CONF_FILE="$FINAL_INSTALL_DIR/pihole_stats.conf"
        ESCAPED_PATH=$(echo "$DEFAULT_DASH_DIR" | sed 's/\//\\\//g')
        sed -i "s/^SAVE_DIR_JSON=\"\"/SAVE_DIR_JSON=\"$ESCAPED_PATH\"/" "$CONF_FILE"
        sed -i "s/^JSON_NAME=\"\"/JSON_NAME=\"dash_default.json\"/" "$CONF_FILE"
        echo "✅ Configuration updated."
        
        echo "📊 Priming dashboard data..."
        sudo "$FINAL_INSTALL_DIR/pihole_stats.sh" -j > /dev/null
    fi
fi

# --- 5. AUTO-UPDATE CHECK SETUP ---
if ask_yn "Enable Auto-Update Check? (Checks for new versions every 3 days)"; then
    echo "----------------------------------------"
    echo "Configuring Auto-Update..."
    UPDATER_SCRIPT="$FINAL_INSTALL_DIR/phls_version_check.sh"
    
    TARGET_DASH_DIR=""
    [ -n "$DASH_INSTALLED_PATH" ] && TARGET_DASH_DIR="$DASH_INSTALLED_PATH"

    # Create the updater script
    # UPDATED: Downloads version once, then copies to Dash dir if needed
    cat <<EOF > "$UPDATER_SCRIPT"
#!/bin/bash
# PHLS Version Auto-Checker
# Downloads the unified 'version' file to trigger notifications.

INSTALL_DIR="$FINAL_INSTALL_DIR"
DASH_DIR="$TARGET_DASH_DIR"
URL_VERSION="$URL_VERSION"

# 1. Download to Installation Directory
if [ -d "\$INSTALL_DIR" ]; then
    curl -sL "\$URL_VERSION" -o "\$INSTALL_DIR/version" 2>/dev/null
    
    # 2. Copy to Dashboard Directory (if installed)
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
    
    CRON_CMD="$UPDATER_SCRIPT # PHLS-ID:updater"
    CRON_SCHED="0 0 */3 * *" 
    
    EXISTING_CRON=$(crontab -l 2>/dev/null)
    CRON_PATH="PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin"
    
    if echo "$EXISTING_CRON" | grep -q "^PATH="; then
        FINAL_CRON=$(echo -e "$EXISTING_CRON\n$CRON_SCHED $CRON_CMD")
    else
        FINAL_CRON=$(echo -e "$CRON_PATH\n$EXISTING_CRON\n$CRON_SCHED $CRON_CMD")
    fi
    
    echo "$FINAL_CRON" | crontab -
    echo "✅ Auto-Update scheduled (Every 3 days)."
fi

# --- 6. SAVE INSTALL STATE ---
cat <<EOF > "$FINAL_INSTALL_DIR/$STATE_FILE"
# PHLS Installation Record
INSTALL_PATH="$FINAL_INSTALL_DIR"
DASH_PATH="$DASH_INSTALLED_PATH"
INSTALL_DATE="$(date)"
VERSION="$VERSION"
EOF
fix_perms "$FINAL_INSTALL_DIR/$STATE_FILE"

log_file "SCRIPT" "$FINAL_INSTALL_DIR/$STATE_FILE"
log_file "SCRIPT" "$FINAL_INSTALL_DIR/$MANIFEST_FILE"

# --- 7. GENERATE UNINSTALLER ---
UNINSTALLER_PATH="$FINAL_INSTALL_DIR/phls_uninstall.sh"
cat << 'EOF' > "$UNINSTALLER_PATH"
#!/bin/bash
# ==============================================================================
# Script:      Pi-hole Latency Stats Uninstaller
# Description: Completely removes PHLS, Dashboard, and Cron jobs.
# ==============================================================================

# Ensure Root
if [ "$EUID" -ne 0 ]; then
    echo "❌ Please run as root (sudo)."
    exit 1
fi

INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
STATE_FILE="$INSTALL_DIR/.phls_install.conf"

REMOVE_DASH_PATH=""
REMOVE_INSTALL_PATH="$INSTALL_DIR"

if [ -f "$STATE_FILE" ]; then
    source "$STATE_FILE"
    if [ -n "$DASH_PATH" ]; then REMOVE_DASH_PATH="$DASH_PATH"; fi
    if [ -n "$INSTALL_PATH" ]; then REMOVE_INSTALL_PATH="$INSTALL_PATH"; fi
fi

echo "========================================"
echo "   Pi-hole Latency Stats Uninstaller"
echo "========================================"
echo "This will PERMANENTLY remove:"
echo " - Main Script & Config ($REMOVE_INSTALL_PATH)"
[ -n "$REMOVE_DASH_PATH" ] && echo " - Dashboard Files ($REMOVE_DASH_PATH)"
echo " - Auto-Update Checker (if enabled)"
echo " - All Cron Jobs (tagged with # PHLS-ID)"
echo ""
read -p "Are you sure you want to proceed? [y/N]: " -r confirm
echo ""
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
fi

echo "🧹 Removing Cron Jobs..."
crontab -l 2>/dev/null | grep -v "# PHLS-ID:" | crontab -

if [ -n "$REMOVE_DASH_PATH" ] && [ -d "$REMOVE_DASH_PATH" ]; then
    echo "🗑️  Removing Dashboard Directory: $REMOVE_DASH_PATH"
    rm -rf "$REMOVE_DASH_PATH"
fi

echo "🗑️  Removing PHLS Directory: $REMOVE_INSTALL_PATH"
rm -rf "$REMOVE_INSTALL_PATH"

echo "✅ Uninstallation Complete."
EOF

chmod +x "$UNINSTALLER_PATH"
fix_perms "$UNINSTALLER_PATH"

# --- 8. FINISH ---
echo "========================================"
echo "   Installation Complete!"
echo "========================================"
echo "Script Location: $FINAL_INSTALL_DIR/pihole_stats.sh"
echo "Uninstaller:     $FINAL_INSTALL_DIR/phls_uninstall.sh"
echo ""
echo "To run:"
echo -e "  \033[1;32msudo $FINAL_INSTALL_DIR/pihole_stats.sh\033[0m"
echo ""

if [ "$INSTALL_DASHBOARD" = true ]; then
    PIHOLE_IP=$(hostname -I | awk '{print $1}')
    PORT=$(grep "webserver.port" /etc/pihole/pihole.toml 2>/dev/null | cut -d'=' -f2 | tr -d ' "')
    [ -z "$PORT" ] && PORT="80"
    DISPLAY_URL="$PIHOLE_IP"
    [ "$PORT" != "80" ] && DISPLAY_URL="$PIHOLE_IP:$PORT"

    echo "Dashboard URL:"
    echo -e "  \033[1;36mhttp://$DISPLAY_URL/admin/img/dash/dash.html?p=default\033[0m"
    echo ""
    
    if ask_yn "Do you want to create a Cron Job for the Dashboard now?"; then
        echo "🧹 Cleaning up installer..."
        rm -- "$0"
        echo "🚀 Launching Cron Job Maker..."
        echo "----------------------------------------"
        exec "$FINAL_INSTALL_DIR/phls_cron_maker.sh"
    fi
fi

echo "To uninstall later, run:"
echo -e "  \033[1;33msudo $FINAL_INSTALL_DIR/phls_uninstall.sh\033[0m"
echo ""

echo "🧹 Cleaning up installer from download location..."
rm -- "$0"