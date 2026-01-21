#!/bin/bash
# ==============================================================================
# Script:      Pi-hole Latency Stats Installer
# Description: Installs/Uninstalls PHLS and the Dashboard with dependencies.
# Author:      panoc
# ==============================================================================

# --- CONFIGURATION: URLs ---
URL_SCRIPT="https://raw.githubusercontent.com/panoc/pihole-latency-stats/refs/heads/main/pihole_stats.sh"
URL_DASH="https://raw.githubusercontent.com/panoc/pihole-latency-stats/refs/heads/main/dashboard/dash.html"
URL_FAVICON="https://github.com/panoc/pihole-latency-stats/blob/main/assets/favicon32x32.png?raw=true"

# Dependencies
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

# --- HELPER: Strict Y/N Input ---
ask_yn() {
    local prompt="$1"
    while true; do
        read -p "$prompt [Y/N]: " -n 1 -r input
        echo ""
        case $input in
            [Yy]) return 0 ;;
            [Nn]) return 1 ;;
            *) ;;
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

# --- HELPER: Add to Manifest ---
log_file() {
    local tag="$1"
    local file="$2"
    echo "${tag}:${file}" >> "$FINAL_INSTALL_DIR/$MANIFEST_FILE"
}

# ==============================================================================
#                               UNINSTALLATION LOGIC (-un)
# ==============================================================================
if [[ "$1" == "-un" ]]; then
    echo "========================================"
    echo "   Pi-hole Latency Stats Uninstaller"
    echo "========================================"

    if ! ask_yn "Do you want to Uninstall Pi-hole Latency Stats?"; then
        echo "Aborted."
        exit 0
    fi

    # Locate Installation
    DETECTED_DIR=""
    if [ -f "$SCRIPT_DIR/$STATE_FILE" ]; then
        source "$SCRIPT_DIR/$STATE_FILE"
        DETECTED_DIR="$SCRIPT_DIR"
    elif [ -f "$DEFAULT_INSTALL_DIR/$STATE_FILE" ]; then
        source "$DEFAULT_INSTALL_DIR/$STATE_FILE"
        DETECTED_DIR="$DEFAULT_INSTALL_DIR"
    else
        echo "⚠️  Could not auto-detect installation."
        read -e -p "Please enter the installation directory: " DETECTED_DIR
        DETECTED_DIR="${DETECTED_DIR%/}"
        [ -f "$DETECTED_DIR/$STATE_FILE" ] && source "$DETECTED_DIR/$STATE_FILE" || { echo "❌ Record not found."; exit 1; }
    fi

    MANIFEST="$DETECTED_DIR/$MANIFEST_FILE"
    if [ ! -f "$MANIFEST" ]; then
        echo "⚠️  Manifest file missing. Manual deletion required."
        exit 1
    fi

    echo ""
    echo "Select Uninstall Mode:"
    echo "1. Uninstall All"
    echo "2. Uninstall Pi-hole Latency Stats Only"
    echo "3. Uninstall Dashboard Only"
    echo "4. Abort"
    while true; do read -p "Enter number [1-4]: " OPTION; case $OPTION in [1-4]) break ;; *) echo "Invalid.";; esac; done

    delete_files_by_tag() {
        local target_tag="$1"
        while IFS=':' read -r tag path; do
            if [ "$target_tag" == "ALL" ] || [ "$target_tag" == "$tag" ]; then
                [ -f "$path" ] && rm -f "$path"
            fi
        done < "$MANIFEST"
    }

    case $OPTION in
        1)
            if ask_yn "Keep Configuration File?"; then K_CONF=true; else K_CONF=false; fi
            if ask_yn "Keep Dashboard Logs?"; then K_LOGS=true; else K_LOGS=false; fi
            delete_files_by_tag "ALL"
            [ "$K_CONF" = false ] && rm -f "$INSTALL_PATH/pihole_stats.conf"
            [ "$K_LOGS" = false ] && [ -n "$DASH_PATH" ] && { rm -f "$DASH_PATH"/*.json; rmdir "$DASH_PATH" 2>/dev/null; }
            rm -f "$INSTALL_PATH/$STATE_FILE" "$INSTALL_PATH/$MANIFEST_FILE" "$INSTALL_PATH/install_phls.sh"
            rmdir "$INSTALL_PATH" 2>/dev/null
            echo "✅ Uninstallation complete." ;;
        2)
            if ask_yn "Keep Configuration File?"; then K_CONF=true; else K_CONF=false; fi
            delete_files_by_tag "SCRIPT"
            [ "$K_CONF" = false ] && rm -f "$INSTALL_PATH/pihole_stats.conf"
            echo "✅ Script files removed." ;;
        3)
            if ask_yn "Keep Dashboard Logs?"; then K_LOGS=true; else K_LOGS=false; fi
            delete_files_by_tag "DASH"
            [ "$K_LOGS" = false ] && [ -n "$DASH_PATH" ] && { rm -f "$DASH_PATH"/*.json; rmdir "$DASH_PATH" 2>/dev/null; }
            echo "✅ Dashboard files removed." ;;
        4) echo "Aborted."; exit 0 ;;
    esac
    exit 0
fi
# ==============================================================================
#                               INSTALLATION LOGIC
# ==============================================================================

if [ "$EUID" -ne 0 ]; then
    echo "❌ Please run as root (sudo)."
    exit 1
fi

echo "========================================"
echo "   Pi-hole Latency Stats Installer"
echo "========================================"

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
        [ -n "$USER_PATH" ] && FINAL_INSTALL_DIR="${USER_PATH%/}"
    fi
else
    if ask_yn "Do you want to install to custom path?"; then
        read -e -p "Enter path: " USER_PATH
        [ -n "$USER_PATH" ] && FINAL_INSTALL_DIR="${USER_PATH%/}"
    fi
fi

if [ ! -d "$FINAL_INSTALL_DIR" ]; then mkdir -p "$FINAL_INSTALL_DIR"; fi
fix_perms "$FINAL_INSTALL_DIR"
echo "# PHLS Installed Files List" > "$FINAL_INSTALL_DIR/$MANIFEST_FILE"
fix_perms "$FINAL_INSTALL_DIR/$MANIFEST_FILE"

# --- 2. INSTALL MAIN SCRIPT ---
echo "⬇️  Downloading pihole_stats.sh..."
curl -sL "$URL_SCRIPT" -o "$FINAL_INSTALL_DIR/pihole_stats.sh"
[ ! -s "$FINAL_INSTALL_DIR/pihole_stats.sh" ] && { echo "❌ Download failed."; exit 1; }
chmod +x "$FINAL_INSTALL_DIR/pihole_stats.sh"
fix_perms "$FINAL_INSTALL_DIR/pihole_stats.sh"
log_file "SCRIPT" "$FINAL_INSTALL_DIR/pihole_stats.sh"
echo "✅ Script installed."

echo "⚙️  Generating configuration..."
# Generate the config
sudo -u "$REAL_USER" bash "$FINAL_INSTALL_DIR/pihole_stats.sh" -mc "$FINAL_INSTALL_DIR/pihole_stats.conf" > /dev/null 2>&1

# FIX: Force ownership change as root to avoid "Operation not permitted"
if [ -f "$FINAL_INSTALL_DIR/pihole_stats.conf" ]; then
    chown "$REAL_USER":"$(id -gn "$REAL_USER")" "$FINAL_INSTALL_DIR/pihole_stats.conf"
fi

# --- 3. INSTALL DASHBOARD (Optional) ---
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
# --- 4. SAVE INSTALL STATE ---
cat <<EOF > "$FINAL_INSTALL_DIR/$STATE_FILE"
# PHLS Installation Record
INSTALL_PATH="$FINAL_INSTALL_DIR"
DASH_PATH="$DASH_INSTALLED_PATH"
INSTALL_DATE="$(date)"
VERSION="v3.2.5"
EOF
fix_perms "$FINAL_INSTALL_DIR/$STATE_FILE"

# --- 5. SETUP UNINSTALLER (Self-Copy) ---
echo "📦 Setting up uninstaller..."
cp "$0" "$FINAL_INSTALL_DIR/install_phls.sh"
chmod +x "$FINAL_INSTALL_DIR/install_phls.sh"
fix_perms "$FINAL_INSTALL_DIR/install_phls.sh"

log_file "SCRIPT" "$FINAL_INSTALL_DIR/install_phls.sh"
log_file "SCRIPT" "$FINAL_INSTALL_DIR/$STATE_FILE"
log_file "SCRIPT" "$FINAL_INSTALL_DIR/$MANIFEST_FILE"

# --- 6. FINISH (Highlighted Output) ---
echo "========================================"
echo "   Installation Complete!"
echo "========================================"
echo "Script Location: \033[1;33msudo $FINAL_INSTALL_DIR/pihole_stats.sh -un\033[0m"
echo ""
echo "To run:"
echo -e "  \033[1;32msudo $FINAL_INSTALL_DIR/pihole_stats.sh\033[0m"
echo ""

if [ "$INSTALL_DASHBOARD" = true ]; then
    PIHOLE_IP=$(hostname -I | awk '{print $1}')
    echo "Dashboard URL:"
    echo -e "  \033[1;36mhttp://$PIHOLE_IP/admin/img/dash/dash.html?p=default\033[0m"
    echo ""
fi

echo "To uninstall later, run:"
echo -e "  \033[1;33msudo $FINAL_INSTALL_DIR/install_phls.sh -un\033[0m"
echo ""

# --- 7. CLEANUP (Self-Destruct original copy) ---
CURRENT_SCRIPT="$(realpath "$0")"
INSTALLED_SCRIPT="$(realpath "$FINAL_INSTALL_DIR/install_phls.sh")"

if [ "$CURRENT_SCRIPT" != "$INSTALLED_SCRIPT" ]; then
    echo "🧹 Cleaning up installer from download location..."
    rm -- "$0"
fi
