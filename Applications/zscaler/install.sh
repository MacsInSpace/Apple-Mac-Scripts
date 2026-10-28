#!/bin/bash

# Enhanced Zscaler Client Connector installer with error checking
# Run direct with:
# sudo bash < <(curl -Ls https://github.com/MacsInSpace/Apple-Mac-Scripts/edit/main/Applications/zscaler/install.sh)
# 
# $env:eduvic=0
# Exit on any error, treat unset variables as error, pipefail for pipeline errors
set -euo pipefail

LOGFILE="/var/log/zscaler_install_$(date '+%Y%m%d_%H%M%S').log"

# Function to log messages to both console and file
log() {
    echo "$@" | tee -a "$LOGFILE"
}

# Check if running as root
if [[ $UID -ne 0 ]]; then
    log "$0 must be run as root.
Please enter your Mac's admin/login password:"
    exec sudo bash "$0" "$@"
fi

loggedInUser=$(stat -f%Su /dev/console)

log "=== Zscaler Installation Started: $(date) ==="
log "Logged in user: $loggedInUser"

year=$(date '+%Y')

# Get loggedInUser ID
userID=$(id -u "$loggedInUser")

# Check if Zscaler components exist before cleanup
zscaler_processes=$(pgrep -i zscaler 2>/dev/null || true)
zscaler_launch_agents=$(find /Library/LaunchAgents -name "*zscaler*" 2>/dev/null || true)
zscaler_user_agents=$(find ~/Library/LaunchAgents -name "*zscaler*" 2>/dev/null || true)
zscaler_daemons=$(find /Library/LaunchDaemons -name "*zscaler*" 2>/dev/null || true)
zscaler_packages=$(pkgutil --pkgs | grep -i zscaler 2>/dev/null || true)

if [[ -n "$zscaler_processes" || -n "$zscaler_launch_agents" || -n "$zscaler_user_agents" || -n "$zscaler_daemons" || -n "$zscaler_packages" ]]; then
    log "Existing Zscaler components found. Starting cleanup..."
    
    # First, move Zscaler.app to prevent restart, then kill processes
    log "Disabling Zscaler application..."
    if [[ -d "/Applications/Zscaler/Zscaler.app" ]]; then
        mv "/Applications/Zscaler/Zscaler.app" "/Applications/Zscaler/Zscaler.app.disabled" 2>/dev/null || true
        sleep 1
    fi
    
    # Kill all Zscaler processes (may be running under multiple users)
    log "Stopping all Zscaler processes..."
    pkill -f "Zscaler" 2>/dev/null || true
    sleep 2
    # Force kill if still running
    pkill -9 -f "Zscaler" 2>/dev/null || true
    sleep 1
    
    # Remove the entire Zscaler directory
    log "Removing Zscaler application directory..."
    rm -rf "/Applications/Zscaler" 2>/dev/null || true
    
    # Unload existing Zscaler services only if they exist
    if [[ -n "$zscaler_launch_agents" ]]; then
        log "Unloading Zscaler launch agents..."
        find /Library/LaunchAgents -name "*zscaler*" -exec launchctl bootout gui/"$userID" {} \; 2>/dev/null || true
    fi
    
    if [[ -n "$zscaler_user_agents" ]]; then
        log "Unloading user Zscaler launch agents..."
        find ~/Library/LaunchAgents -name "*zscaler*" -exec launchctl bootout gui/"$userID" {} \; 2>/dev/null || true
    fi
    
    if [[ -n "$zscaler_daemons" ]]; then
        log "Unloading Zscaler launch daemons..."
        find /Library/LaunchDaemons -name "*zscaler*" -exec launchctl bootout system {} \; 2>/dev/null || true
    fi
    
    # Remove existing Zscaler launch files only if they exist
    if [[ -n "$zscaler_launch_agents" ]]; then
        log "Removing Zscaler launch agents..."
        find /Library/LaunchAgents -name "*zscaler*" -exec rm -f {} \; 2>/dev/null || true
    fi
    
    if [[ -n "$zscaler_user_agents" ]]; then
        log "Removing user Zscaler launch agents..."
        find ~/Library/LaunchAgents -name "*zscaler*" -exec rm -f {} \; 2>/dev/null || true
    fi
    
    if [[ -n "$zscaler_daemons" ]]; then
        log "Removing Zscaler launch daemons..."
        find /Library/LaunchDaemons -name "*zscaler*" -exec rm -f {} \; 2>/dev/null || true
    fi
    
    # Forget existing package receipts only if they exist
    if [[ -n "$zscaler_packages" ]]; then
        log "Forgetting Zscaler package receipts..."
        pkgutil --forget "com.zscaler.*" 2>/dev/null || true
    fi
    
    # Finally, remove the entire Zscaler directory
    log "Removing Zscaler application directory..."
    rm -rf "/Applications/Zscaler" 2>/dev/null || true
    
    log "Cleanup completed."
else
    log "No existing Zscaler components found. Skipping cleanup."
fi

log "Fetching latest version information..."

# Zscaler release pages RSS feed to get version numbers
RSSURL="https://help.zscaler.com/rss-feed/zscaler-client-connector/client-connector-app-release-summary-$year/macOS"

# Current server hasn't changed in a while but there's always a chance
DLdomain='https://d32a6ru7mhaq0c.cloudfront.net'

# Read RSS feed and get latest available version number
log "Checking for latest available Zscaler version from RSS feed..."

set +e  # Temporarily disable exit on error
LatestVersion=$(curl -s "$RSSURL" |
    xmllint --xpath "//rss/channel/item[category='Release Available']/version" - 2>/dev/null |
    grep -oE '<version>[0-9.]+</version>' |
    sed -E 's/<version>//; s/<\/version>//' |
    sort -rV |
    head -n 1)
set -e  # Re-enable exit on error

# Validate version was found
if [[ -z "$LatestVersion" ]]; then
    log "No available versions found in $year RSS feed. Trying previous year..."
    year=$((year - 1))
    RSSURL="https://help.zscaler.com/rss-feed/zscaler-client-connector/client-connector-app-release-summary-$year/macOS"
    log "RSS URL: $RSSURL"
    
    set +e
    LatestVersion=$(curl -s "$RSSURL" |
        xmllint --xpath "//rss/channel/item[category='Release Available']/version" - 2>/dev/null |
        grep -oE '<version>[0-9.]+</version>' |
        sed -E 's/<version>//; s/<\/version>//' |
        sort -rV |
        head -n 1)
    set -e
fi

# Validate version was not found
if [[ -z "$LatestVersion" ]]; then
    log "Error: Could not determine latest Zscaler version from RSS feed"
    log "RSS URL: $RSSURL"
    exit 1
fi

log "Latest Zscaler version: $LatestVersion"

# PKG install option (commented out function for reference)
comment_out_pkg_block() {
    THEPKG="Zscaler-osx-$LatestVersion-installer.pkg"
    DLPKGURL="$DLdomain/$THEPKG"
    
    log "Downloading PKG installer..."
    if curl --fail --location --progress-bar "$DLPKGURL" -o "/tmp/$THEPKG"; then
        log "Installing via PKG..."
        if sudo installer -pkg "/tmp/$THEPKG" -target /; then
            log "PKG installation completed"
            sudo rm -f "/tmp/$THEPKG"
        else
            log "Error: PKG installation failed"
            sudo rm -f "/tmp/$THEPKG"
            exit 1
        fi
    else
        log "Error: PKG download failed"
        exit 1
    fi
}

# ZIP installer method
THEZIP="Zscaler-osx-$LatestVersion-installer.app.zip"
DLZIPURL="$DLdomain/$THEZIP"
TEMP_ZIP="/tmp/$THEZIP"
INSTALLER_PATH="/tmp/Zscaler-osx-$LatestVersion-installer.app/Contents/MacOS/installbuilder.sh"

log "Downloading Zscaler installer ZIP v$LatestVersion..."
log "URL: $DLZIPURL"

# Download with error checking and progress display
if curl --fail --location --progress-bar "$DLZIPURL" -o "$TEMP_ZIP"; then
    log "Download completed successfully"
    
    # Verify file exists and has content
    if [[ ! -f "$TEMP_ZIP" ]] || [[ ! -s "$TEMP_ZIP" ]]; then
        log "Error: Downloaded file is missing or empty"
        exit 1
    fi
    
    log "Extracting installer..."
    if unzip -o -q "$TEMP_ZIP" -d /tmp/; then
        log "Extraction completed successfully"
        
        # Verify installer exists before running
        if [[ -f "$INSTALLER_PATH" ]]; then
            log "Running Zscaler installer with configured parameters..."
            if bash "$INSTALLER_PATH" \
                --cloudName zscalerone \
                --unattendedmodeui none \
                --userDomain education.vic.gov.au \
                --hideAppUIOnLaunch 1 \
                --mode unattended; then
                log "Zscaler installation completed successfully"
            else
                log "Error: Zscaler installation failed"
                exit 1
            fi
        else
            log "Error: Installer script not found at expected location: $INSTALLER_PATH"
            exit 1
        fi
    else
        log "Error: Failed to extract zip file"
        exit 1
    fi
else
    log "Error: Failed to download Zscaler installer"
    log "URL attempted: $DLZIPURL"
    exit 1
fi

log "Starting Zscaler cleanup and installation process..."

# Function to cleanup temp files
cleanup() {
    if [[ -f "/tmp/$THEZIP" ]]; then
        log "Cleaning up downloaded zip file..."
        rm -f "/tmp/$THEZIP"
    fi
    if [[ -d "/tmp/Zscaler-osx-$LatestVersion-installer.app" ]]; then
        log "Cleaning up extracted installer..."
        rm -rf "/tmp/Zscaler-osx-$LatestVersion-installer.app"
    fi
}

# Set trap to cleanup on script exit
trap cleanup EXIT

log "Zscaler installation process completed successfully"
