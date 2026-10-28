#!/bin/bash

# Zscaler Client Connector installer (macOS)
# Scrapes the Zscaler release RSS feed for the latest "Release Available" build,
# removes any existing install, then installs the new version unattended.
#
# Run direct with:
#   sudo bash < <(curl -Ls https://raw.githubusercontent.com/MacsInSpace/Apple-Mac-Scripts/refs/heads/main/Applications/zscaler/install.sh)
#
# Options (env vars). Put them AFTER sudo, or sudo will strip them:
#   EDUVIC=true                 Preset for Victorian DET (zscalerone, education.vic.gov.au, hidden UI)
#   ZCC_CLOUDNAME=<cloud>       e.g. zscalerone, zscalertwo, zscaler
#   ZCC_USERDOMAIN=<domain>     e.g. example.com
#   ZCC_HIDEAPPUIONLAUNCH=1|0
#   ZCC_POLICYTOKEN=<token>
#   ZCC_STRICTENFORCEMENT=1|0
#   ZCC_UNATTENDEDMODEUI=none   (default: none)
#   ZCC_MODE=unattended         (default: unattended)
#   ZCC_EXTRA_ARGS="--foo 1"    Anything else, passed straight to the installer
#
# Examples:
#   sudo EDUVIC=true bash < <(curl -Ls <url>)
#   sudo ZCC_CLOUDNAME=zscalertwo ZCC_USERDOMAIN=example.com bash < <(curl -Ls <url>)
#   sudo EDUVIC=true ZCC_EXTRA_ARGS="--strictEnforcement 1" bash < <(curl -Ls <url>)
#
# Explicit ZCC_* values always win over the EDUVIC preset.

# Exit on any error, treat unset variables as error, pipefail for pipeline errors
set -euo pipefail

# Must be root. Checked before logging, since /var/log is not writable otherwise.
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root."
    echo "Re-run with: sudo [VARS=...] bash < <(curl -Ls <url>)"
    exit 1
fi

LOGFILE="/var/log/zscaler_install_$(date '+%Y%m%d_%H%M%S').log"

log() {
    echo "$@" | tee -a "$LOGFILE"
}

# ---- Installer options ----
EDUVIC="${EDUVIC:-false}"
EDUVIC="$(echo "$EDUVIC" | tr '[:upper:]' '[:lower:]')"

if [[ "$EDUVIC" == "true" || "$EDUVIC" == "1" || "$EDUVIC" == "yes" ]]; then
    EDUVIC="true"
    : "${ZCC_CLOUDNAME:=zscalerone}"
    : "${ZCC_USERDOMAIN:=education.vic.gov.au}"
    : "${ZCC_HIDEAPPUIONLAUNCH:=1}"
else
    EDUVIC="false"
fi

ZCC_CLOUDNAME="${ZCC_CLOUDNAME:-}"
ZCC_USERDOMAIN="${ZCC_USERDOMAIN:-}"
ZCC_HIDEAPPUIONLAUNCH="${ZCC_HIDEAPPUIONLAUNCH:-}"
ZCC_POLICYTOKEN="${ZCC_POLICYTOKEN:-}"
ZCC_STRICTENFORCEMENT="${ZCC_STRICTENFORCEMENT:-}"
ZCC_UNATTENDEDMODEUI="${ZCC_UNATTENDEDMODEUI:-none}"
ZCC_MODE="${ZCC_MODE:-unattended}"
ZCC_EXTRA_ARGS="${ZCC_EXTRA_ARGS:-}"

loggedInUser=$(stat -f%Su /dev/console)
userID=$(id -u "$loggedInUser")
userHome=$(dscl . -read "/Users/$loggedInUser" NFSHomeDirectory 2>/dev/null | awk '{print $2}')
userHome="${userHome:-/Users/$loggedInUser}"
year=$(date '+%Y')

log "=== Zscaler Installation Started: $(date) ==="
log "Logged in user: $loggedInUser"
log "EDUVIC preset: $EDUVIC"

# Temp paths are set once the version is known; declared here so the trap is safe under set -u
THEZIP=""
INSTALLER_APP=""

cleanup() {
    if [[ -n "$THEZIP" && -f "/tmp/$THEZIP" ]]; then
        log "Cleaning up downloaded zip file..."
        rm -f "/tmp/$THEZIP"
    fi
    if [[ -n "$INSTALLER_APP" && -d "$INSTALLER_APP" ]]; then
        log "Cleaning up extracted installer..."
        rm -rf "$INSTALLER_APP"
    fi
}
trap cleanup EXIT

# ---- Remove existing install ----
zscaler_processes=$(pgrep -i zscaler 2>/dev/null || true)
zscaler_launch_agents=$(find /Library/LaunchAgents -iname "*zscaler*" 2>/dev/null || true)
zscaler_user_agents=$(find "$userHome/Library/LaunchAgents" -iname "*zscaler*" 2>/dev/null || true)
zscaler_daemons=$(find /Library/LaunchDaemons -iname "*zscaler*" 2>/dev/null || true)
zscaler_packages=$(pkgutil --pkgs 2>/dev/null | grep -i zscaler || true)

if [[ -n "$zscaler_processes" || -n "$zscaler_launch_agents" || -n "$zscaler_user_agents" || -n "$zscaler_daemons" || -n "$zscaler_packages" || -d "/Applications/Zscaler" ]]; then
    log "Existing Zscaler components found. Starting cleanup..."

    # Move the app first so nothing relaunches it
    if [[ -d "/Applications/Zscaler/Zscaler.app" ]]; then
        log "Disabling Zscaler application..."
        mv "/Applications/Zscaler/Zscaler.app" "/Applications/Zscaler/Zscaler.app.disabled" 2>/dev/null || true
        sleep 1
    fi

    # Unload services before killing, so launchd does not respawn them
    if [[ -n "$zscaler_launch_agents" ]]; then
        log "Unloading Zscaler launch agents..."
        while IFS= read -r f; do launchctl bootout gui/"$userID" "$f" 2>/dev/null || true; done <<< "$zscaler_launch_agents"
    fi
    if [[ -n "$zscaler_user_agents" ]]; then
        log "Unloading user Zscaler launch agents..."
        while IFS= read -r f; do launchctl bootout gui/"$userID" "$f" 2>/dev/null || true; done <<< "$zscaler_user_agents"
    fi
    if [[ -n "$zscaler_daemons" ]]; then
        log "Unloading Zscaler launch daemons..."
        while IFS= read -r f; do launchctl bootout system "$f" 2>/dev/null || true; done <<< "$zscaler_daemons"
    fi

    log "Stopping all Zscaler processes..."
    pkill -f "Zscaler" 2>/dev/null || true
    sleep 2
    pkill -9 -f "Zscaler" 2>/dev/null || true
    sleep 1

    if [[ -n "$zscaler_launch_agents" ]]; then
        log "Removing Zscaler launch agents..."
        while IFS= read -r f; do rm -f "$f"; done <<< "$zscaler_launch_agents"
    fi
    if [[ -n "$zscaler_user_agents" ]]; then
        log "Removing user Zscaler launch agents..."
        while IFS= read -r f; do rm -f "$f"; done <<< "$zscaler_user_agents"
    fi
    if [[ -n "$zscaler_daemons" ]]; then
        log "Removing Zscaler launch daemons..."
        while IFS= read -r f; do rm -f "$f"; done <<< "$zscaler_daemons"
    fi

    if [[ -n "$zscaler_packages" ]]; then
        log "Forgetting Zscaler package receipts..."
        while IFS= read -r p; do pkgutil --forget "$p" >/dev/null 2>&1 || true; done <<< "$zscaler_packages"
    fi

    log "Removing Zscaler application directory..."
    rm -rf "/Applications/Zscaler" 2>/dev/null || true

    log "Cleanup completed."
else
    log "No existing Zscaler components found. Skipping cleanup."
fi

# ---- Find latest version ----
DLdomain='https://d32a6ru7mhaq0c.cloudfront.net'

get_latest_version() {
    local feed_year="$1"
    local url="https://help.zscaler.com/rss-feed/zscaler-client-connector/client-connector-app-release-summary-$feed_year/macOS"
    log "RSS URL: $url" >&2
    curl -fsSL "$url" 2>/dev/null |
        xmllint --xpath "//rss/channel/item[category='Release Available']/version" - 2>/dev/null |
        grep -oE '<version>[0-9.]+</version>' |
        sed -E 's/<version>//; s/<\/version>//' |
        sort -rV |
        head -n 1 || true
}

log "Checking for latest available Zscaler version from RSS feed..."
LatestVersion=$(get_latest_version "$year")

if [[ -z "$LatestVersion" ]]; then
    log "No available versions found in $year RSS feed. Trying previous year..."
    year=$((year - 1))
    LatestVersion=$(get_latest_version "$year")
fi

if [[ -z "$LatestVersion" ]]; then
    log "Error: Could not determine latest Zscaler version from RSS feed"
    exit 1
fi

log "Latest Zscaler version: $LatestVersion (from $year feed)"

# ---- Download ----
THEZIP="Zscaler-osx-$LatestVersion-installer.app.zip"
DLZIPURL="$DLdomain/$THEZIP"
TEMP_ZIP="/tmp/$THEZIP"
INSTALLER_APP="/tmp/Zscaler-osx-$LatestVersion-installer.app"
INSTALLER_PATH="$INSTALLER_APP/Contents/MacOS/installbuilder.sh"

log "Downloading Zscaler installer ZIP v$LatestVersion..."
log "URL: $DLZIPURL"

if ! curl --fail --location --progress-bar "$DLZIPURL" -o "$TEMP_ZIP"; then
    log "Error: Failed to download Zscaler installer"
    log "URL attempted: $DLZIPURL"
    exit 1
fi

if [[ ! -s "$TEMP_ZIP" ]]; then
    log "Error: Downloaded file is missing or empty"
    exit 1
fi
log "Download completed successfully"

# ---- Extract ----
log "Extracting installer..."
if ! unzip -o -q "$TEMP_ZIP" -d /tmp/; then
    log "Error: Failed to extract zip file"
    exit 1
fi
log "Extraction completed successfully"

if [[ ! -f "$INSTALLER_PATH" ]]; then
    log "Error: Installer script not found at expected location: $INSTALLER_PATH"
    exit 1
fi

# ---- Install ----
INSTALL_ARGS=(--mode "$ZCC_MODE" --unattendedmodeui "$ZCC_UNATTENDEDMODEUI")
[[ -n "$ZCC_CLOUDNAME" ]]         && INSTALL_ARGS+=(--cloudName "$ZCC_CLOUDNAME")
[[ -n "$ZCC_USERDOMAIN" ]]        && INSTALL_ARGS+=(--userDomain "$ZCC_USERDOMAIN")
[[ -n "$ZCC_HIDEAPPUIONLAUNCH" ]] && INSTALL_ARGS+=(--hideAppUIOnLaunch "$ZCC_HIDEAPPUIONLAUNCH")
[[ -n "$ZCC_POLICYTOKEN" ]]       && INSTALL_ARGS+=(--policyToken "$ZCC_POLICYTOKEN")
[[ -n "$ZCC_STRICTENFORCEMENT" ]] && INSTALL_ARGS+=(--strictEnforcement "$ZCC_STRICTENFORCEMENT")
if [[ -n "$ZCC_EXTRA_ARGS" ]]; then
    read -r -a _extra <<< "$ZCC_EXTRA_ARGS"
    INSTALL_ARGS+=("${_extra[@]}")
fi

# Mask the policy token in the log
LOG_ARGS="${INSTALL_ARGS[*]}"
if [[ -n "$ZCC_POLICYTOKEN" ]]; then
    LOG_ARGS="${LOG_ARGS//$ZCC_POLICYTOKEN/********}"
fi
log "Running Zscaler installer with: $LOG_ARGS"

if bash "$INSTALLER_PATH" "${INSTALL_ARGS[@]}"; then
    log "Zscaler installation completed successfully"
else
    log "Error: Zscaler installation failed"
    exit 1
fi

log "=== Zscaler installation process completed: $(date) ==="
