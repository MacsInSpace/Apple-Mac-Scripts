#!/bin/bash
# Uninstall zscaler (forcfully)
#   sudo bash < <(curl -Ls https://raw.githubusercontent.com/MacsInSpace/Apple-Mac-Scripts/refs/heads/main/Applications/zscaler/uninstall.sh)

# Check if Zscaler components exist before cleanup
zscaler_processes=$(pgrep -i zscaler 2>/dev/null || true)
zscaler_launch_agents=$(find /Library/LaunchAgents -name "*zscaler*" 2>/dev/null)
zscaler_user_agents=$(find ~/Library/LaunchAgents -name "*zscaler*" 2>/dev/null)
zscaler_daemons=$(find /Library/LaunchDaemons -name "*zscaler*" 2>/dev/null)
zscaler_packages=$(pkgutil --pkgs | grep -i zscaler 2>/dev/null || true)

if [[ -n "$zscaler_processes" || -n "$zscaler_launch_agents" || -n "$zscaler_user_agents" || -n "$zscaler_daemons" || -n "$zscaler_packages" ]]; then
    echo "Existing Zscaler components found. Starting cleanup..."
    
    # First, move Zscaler.app to prevent restart, then kill processes
    echo "Disabling Zscaler application..."
    if [[ -d "/Applications/Zscaler/Zscaler.app" ]]; then
        mv "/Applications/Zscaler/Zscaler.app" "/Applications/Zscaler/Zscaler.app.disabled" 2>/dev/null || true
        sleep 1
    fi
    
    # Kill all Zscaler processes (may be running under multiple users)
    echo "Stopping all Zscaler processes..."
    pkill -f "Zscaler" 2>/dev/null || true
    sleep 2
    # Force kill if still running
    pkill -9 -f "Zscaler" 2>/dev/null || true
    sleep 1
    
    # Remove the entire Zscaler directory
    echo "Removing Zscaler application directory..."
    rm -rf "/Applications/Zscaler" 2>/dev/null || true
    
    # Unload existing Zscaler services only if they exist
    if [[ -n "$zscaler_launch_agents" ]]; then
        echo "Unloading Zscaler launch agents..."
        find /Library/LaunchAgents -name "*zscaler*" -exec launchctl bootout gui/"$userID" {} \; 2>/dev/null || true
    fi
    
    if [[ -n "$zscaler_user_agents" ]]; then
        echo "Unloading user Zscaler launch agents..."
        find ~/Library/LaunchAgents -name "*zscaler*" -exec launchctl bootout gui/"$userID" {} \; 2>/dev/null || true
    fi
    
    if [[ -n "$zscaler_daemons" ]]; then
        echo "Unloading Zscaler launch daemons..."
        find /Library/LaunchDaemons -name "*zscaler*" -exec launchctl bootout system {} \; 2>/dev/null || true
    fi
    
    # Remove existing Zscaler launch files only if they exist
    if [[ -n "$zscaler_launch_agents" ]]; then
        echo "Removing Zscaler launch agents..."
        find /Library/LaunchAgents -name "*zscaler*" -exec rm -f {} \; 2>/dev/null || true
    fi
    
    if [[ -n "$zscaler_user_agents" ]]; then
        echo "Removing user Zscaler launch agents..."
        find ~/Library/LaunchAgents -name "*zscaler*" -exec rm -f {} \; 2>/dev/null || true
    fi
    
    if [[ -n "$zscaler_daemons" ]]; then
        echo "Removing Zscaler launch daemons..."
        find /Library/LaunchDaemons -name "*zscaler*" -exec rm -f {} \; 2>/dev/null || true
    fi
    
    # Forget existing package receipts only if they exist
    if [[ -n "$zscaler_packages" ]]; then
        echo "Forgetting Zscaler package receipts..."
        pkgutil --forget "com.zscaler.*" 2>/dev/null || true
    fi
    
    # Finally, remove the entire Zscaler directory
    echo "Removing Zscaler application directory..."
    rm -rf "/Applications/Zscaler" 2>/dev/null || true
    
    echo "Cleanup completed."
else
    echo "No existing Zscaler components found. Skipping cleanup."
fi
