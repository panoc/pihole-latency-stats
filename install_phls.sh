#!/bin/bash
# ==============================================================================
# Pi-hole Latency Stats (PHLS) installer
#
#   curl -sSL https://github.com/panoc/pihole-latency-stats/releases/latest/download/install_phls.sh | sudo bash
#
# or, after downloading this file:
#   sudo bash install_phls.sh                       install / update / upgrade from v4
#   sudo bash install_phls.sh --local phls_assets.tar.gz   use a local release file (no download)
#   sudo bash install_phls.sh --yes                 no questions (default answers)
#
# It downloads the release, checks its SHA-256, and runs its setup, which:
#   - checks for Pi-hole v6, installs what is missing (sqlite3, lighttpd for the dashboard)
#   - installs PHLS in /opt/phls, settings in /etc/phls, data in /var/lib/phls, dashboard in /var/www/phls
#   - moves the settings and history of a v4 install (~/phls) over and disables its cron jobs
#   - schedules the analysis with systemd and starts the dashboard on its own port
# Afterwards everything is managed with:  sudo phls
#
# Author: panoc - https://github.com/panoc/pihole-latency-stats - GPLv3
# ==============================================================================

RELEASE_URL="https://github.com/panoc/pihole-latency-stats/releases/latest/download"

main() {
    local local_archive="" yes="" a
    while [ $# -gt 0 ]; do
        case "$1" in
            --local) local_archive="$2"; shift 2 ;;
            --yes|-y) yes="--yes"; shift ;;
            *) echo "Unknown option: $1"; exit 1 ;;
        esac
    done

    if [ "$EUID" -ne 0 ]; then
        echo "Please run as root:"
        echo "  curl -sSL $RELEASE_URL/install_phls.sh | sudo bash"
        exit 1
    fi

    for a in tar sha256sum; do command -v "$a" >/dev/null 2>&1 || { echo "Missing command: $a"; exit 1; }; done
    if [ -z "$local_archive" ] && ! command -v curl >/dev/null 2>&1; then
        echo "Installing curl..."
        apt-get update -qq >/dev/null 2>&1; apt-get install -y -qq curl >/dev/null 2>&1 || { echo "Please install curl first."; exit 1; }
    fi

    local tmp; tmp=$(mktemp -d) || exit 1
    trap 'rm -rf "$tmp"' EXIT
    if [ -n "$local_archive" ]; then
        [ -s "$local_archive" ] || { echo "File not found: $local_archive"; exit 1; }
        cp "$local_archive" "$tmp/phls_assets.tar.gz"
        if [ -s "$local_archive.sha256" ]; then
            [ "$(awk '{print $1; exit}' "$local_archive.sha256")" = "$(sha256sum "$tmp/phls_assets.tar.gz" | awk '{print $1}')" ] \
                || { echo "Checksum mismatch for $local_archive"; exit 1; }
            echo "Checksum verified."
        fi
    else
        echo "Downloading Pi-hole Latency Stats..."
        curl -fsSL --retry 2 --connect-timeout 15 "$RELEASE_URL/phls_assets.tar.gz" -o "$tmp/phls_assets.tar.gz" && [ -s "$tmp/phls_assets.tar.gz" ] \
            || { echo "Download failed. Check the internet connection and try again."; exit 1; }
        if curl -fsSL --connect-timeout 15 "$RELEASE_URL/phls_assets.tar.gz.sha256" -o "$tmp/sum" 2>/dev/null; then
            [ "$(awk '{print $1; exit}' "$tmp/sum")" = "$(sha256sum "$tmp/phls_assets.tar.gz" | awk '{print $1}')" ] \
                || { echo "Checksum mismatch: the download is damaged or was modified. Nothing was installed."; exit 1; }
            echo "Checksum verified."
        else
            echo "Warning: no checksum published for this release."
        fi
    fi
    tar -xzf "$tmp/phls_assets.tar.gz" -C "$tmp" && [ -s "$tmp/phls_assets/phls" ] || { echo "The release archive is damaged."; exit 1; }

    # Questions come from the terminal, also when this script was piped into bash
    if [ -t 0 ]; then bash "$tmp/phls_assets/phls" setup $yes
    elif (exec < /dev/tty) 2>/dev/null; then bash "$tmp/phls_assets/phls" setup $yes < /dev/tty
    else bash "$tmp/phls_assets/phls" setup --yes < /dev/null; fi
}

# Everything runs from main, so a download cut off half-way cannot run half a script
main "$@"
