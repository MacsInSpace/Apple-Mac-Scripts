#!/bin/bash
# =============================================================================
# Microsoft Office 365 Installer (postflight)
# =============================================================================
# Run direct with
#
# sudo bash < <(curl -Ls https://raw.githubusercontent.com/MacsInSpace/Apple-Mac-Scripts/refs/heads/main/Applications/MS%20Office%20365/Install.sh)
#
#	Bundle the following in your .pkg payload at /private/var/tmp/ms_office_install:
#   Microsoft_Office_LTSC_2024_VL_Serializer.pkg  (for macOS 14+ / Office 365)
#   Microsoft_Office_LTSC_2021_VL_Serializer.pkg  (for macOS 11-13 / Office 16.88-16.101)
#
# Notification: SwiftDialog (installed automatically if not present)
#   Falls back to silent/log-only if no console user (DEP/no loginwindow)
#
# OS version matrix:
#   macOS 14+ Sonoma and later  -> latest Office 365 via Microsoft linkid
#   macOS 13  Ventura           -> Office 16.101.25091314 (last supported build)
#   macOS 12  Monterey          -> Office 16.88.24081116  (last supported build)
#   macOS 11  Big Sur          -> Office 16.77  (last supported build)
#   macOS 10  Catalina and older -> unsupported, exits cleanly
#
# Microsoft stable linkids (macOS 14+ only):
#   525133  = Standard installer (without Teams)
#   2009112 = BusinessPro installer (with Teams)
#
# spctl --master-disable is intentionally omitted - on macOS Sequoia and later
#   it requires System Settings confirmation and cannot be used silently.
#   The Microsoft Office CDN pkg and SwiftDialog are both signed/notarised
#   and do not require Gatekeeper to be disabled.
# =============================================================================

set -euo pipefail

# --- Configuration -----------------------------------------------------------
# Default Teams behaviour for unattended/DEP deployments,
# and fallback if the prompt times out
INCLUDE_TEAMS_DEFAULT=true

# Allow a logged-in user to override the Teams default via a prompt
ALLOW_TEAMS_OVERRIDE=true

# Seconds before the Teams prompt auto-dismisses and uses the default
TEAMS_PROMPT_TIMEOUT=15

WORK_DIR="/private/var/tmp/ms_office_install"

# Serializer source - set to a stable URL or a local path
# Local path example:  "$WORK_DIR/Microsoft_Office_LTSC_2024_VL_Serializer.pkg"
# URL example:         "https://yourserver.example.com/pkgs/Microsoft_Office_LTSC_2024_VL_Serializer.pkg"
# https://github.com/MacsInSpace/Apple-Mac-Scripts/raw/refs/heads/main/Applications/MS%20Office%20365/support/serializer/Microsoft_Office_LTSC_2024_VL_Serializer.pkg
# Serializer sources: prefer bundled pkgs in WORK_DIR, else download from GitLab
SERIALIZER_2024_LOCAL_SRC="$WORK_DIR/Microsoft_Office_LTSC_2024_VL_Serializer.pkg"
SERIALIZER_2021_LOCAL_SRC="$WORK_DIR/Microsoft_Office_LTSC_2021_VL_Serializer.pkg"

SERIALIZER_2024_WEB_SRC="https://github.com/MacsInSpace/Apple-Mac-Scripts/raw/refs/heads/main/Applications/MS%20Office%20365/support/serializer/Microsoft_Office_LTSC_2024_VL_Serializer.pkg"
SERIALIZER_2021_WEB_SRC="https://github.com/MacsInSpace/Apple-Mac-Scripts/raw/refs/heads/main/Applications/MS%20Office%20365/support/serializer/Microsoft_Office_LTSC_2021_VL_Serializer.pkg"

if [[ -f "$SERIALIZER_2024_LOCAL_SRC" ]]; then
    SERIALIZER_2024_SRC="$SERIALIZER_2024_LOCAL_SRC"
else
    SERIALIZER_2024_SRC="$SERIALIZER_2024_WEB_SRC"
fi

if [[ -f "$SERIALIZER_2021_LOCAL_SRC" ]]; then
    SERIALIZER_2021_SRC="$SERIALIZER_2021_LOCAL_SRC"
else
    SERIALIZER_2021_SRC="$SERIALIZER_2021_WEB_SRC"
fi

OFFICE_PKG="$WORK_DIR/Office.pkg"
CONNECTIVITY_HOST="go.microsoft.com"
DIALOG_BIN="/usr/local/bin/dialog"
DIALOG_CMD_FILE="/var/tmp/office_install_dialog.log"
DIALOG_PID=""
INCLUDE_TEAMS="$INCLUDE_TEAMS_DEFAULT"
SERIALIZER=""
FULL_VERSION_URL=""
VERSION=""

# Icon for SwiftDialog
# Replace with a local path if you bundle an icon in your pkg payload
DIALOG_ICON="https://raw.githubusercontent.com/MacsInSpace/Apple-Mac-Scripts/refs/heads/main/Applications/MS%20Office%20365/support/icon.png"

# --- Detect logged-in console user -------------------------------------------
CONSOLE_USER=$(scutil <<< "show State:/Users/ConsoleUser" \
    | awk '/Name :/ && !/loginwindow/ { print $3 }')

has_user() {
    [[ -n "$CONSOLE_USER" && "$CONSOLE_USER" != "root" ]]
}

# --- SwiftDialog install -----------------------------------------------------
install_swiftdialog() {
    echo "INFO: SwiftDialog not found - fetching latest release..." >&2

    local api_url="https://api.github.com/repos/bartreardon/swiftDialog/releases/latest"
    local sd_pkg="$WORK_DIR/swiftdialog.pkg"

    local sd_url
    sd_url=$(curl -LSs "$api_url" \
        | grep -o '"browser_download_url": *"[^"]*\.pkg"' \
        | grep -o 'https://[^"]*' \
        | head -n 1)

    if [[ -z "$sd_url" ]]; then
        echo "ERROR: Could not resolve SwiftDialog download URL" >&2
        return 1
    fi

    echo "INFO: Downloading SwiftDialog from $sd_url" >&2
    if ! curl -L --retry 3 --retry-delay 5 --retry-connrefused \
        "$sd_url" -o "$sd_pkg"; then
        echo "ERROR: SwiftDialog download failed" >&2
        return 1
    fi

    if ! installer -pkg "$sd_pkg" -target /; then
        echo "ERROR: SwiftDialog install failed" >&2
        return 1
    fi

    rm -f "$sd_pkg"
    echo "INFO: SwiftDialog installed at $DIALOG_BIN" >&2
}

# --- SwiftDialog helpers -----------------------------------------------------
dialog_update() {
    if [[ -n "$DIALOG_PID" ]] && kill -0 "$DIALOG_PID" 2>/dev/null; then
        echo "$1" >> "$DIALOG_CMD_FILE"
    fi
}

dialog_start() {
    has_user || return 0
    [[ -x "$DIALOG_BIN" ]] || return 0

    rm -f "$DIALOG_CMD_FILE"

    launchctl asuser "$(id -u "$CONSOLE_USER")" \
        sudo -u "$CONSOLE_USER" \
        "$DIALOG_BIN" \
        --title "Microsoft Office Installer" \
        --message "Starting installation..." \
        --icon "$DIALOG_ICON" \
        --progress 6 \
        --progresstext "Initialising..." \
        --position centre \
        --moveable \
        --width 550 \
        --height 220 \
        --commandfile "$DIALOG_CMD_FILE" \
        --no-buttons \
        &>/dev/null &

    DIALOG_PID=$!
    sleep 1
}

dialog_close() {
    dialog_update "quit:"
    sleep 1
    if [[ -n "$DIALOG_PID" ]] && kill -0 "$DIALOG_PID" 2>/dev/null; then
        kill "$DIALOG_PID" &>/dev/null || true
    fi
    rm -f "$DIALOG_CMD_FILE"
}

# --- Notification helper -----------------------------------------------------
notify() {
    local message="$1"
    local progress="${2:-}"

    echo "INFO: $message" >&2

    if [[ -n "$DIALOG_PID" ]] && kill -0 "$DIALOG_PID" 2>/dev/null; then
        dialog_update "progresstext: $message"
        dialog_update "message: $message"
        [[ -n "$progress" ]] && dialog_update "progress: $progress"
    fi
}

# --- Teams pre-flight prompt -------------------------------------------------
# If ALLOW_TEAMS_OVERRIDE is false, always use INCLUDE_TEAMS_DEFAULT silently.
# If true and a user is present, show a SwiftDialog checkbox prompt with a
#   countdown timer - auto-dismisses and uses INCLUDE_TEAMS_DEFAULT on timeout.
# If true but no user present, fall back to INCLUDE_TEAMS_DEFAULT silently.
prompt_teams() {
    if [[ "$ALLOW_TEAMS_OVERRIDE" != true ]]; then
        echo "INFO: Teams override disabled - using default: INCLUDE_TEAMS=$INCLUDE_TEAMS_DEFAULT" >&2
        INCLUDE_TEAMS="$INCLUDE_TEAMS_DEFAULT"
        return 0
    fi

    if ! has_user || [[ ! -x "$DIALOG_BIN" ]]; then
        echo "INFO: No console user - using default: INCLUDE_TEAMS=$INCLUDE_TEAMS_DEFAULT" >&2
        INCLUDE_TEAMS="$INCLUDE_TEAMS_DEFAULT"
        return 0
    fi

    # Pre-tick the checkbox to match the default
    local checkbox_flag=""
    [[ "$INCLUDE_TEAMS_DEFAULT" == true ]] && checkbox_flag=",checked"

    local result
    result=$(launchctl asuser "$(id -u "$CONSOLE_USER")" \
        sudo -u "$CONSOLE_USER" \
        "$DIALOG_BIN" \
        --title "Microsoft Office Installer" \
        --message "Microsoft Office will be downloaded and installed.\n\nThis may take several minutes depending on your internet connection.\n\nInstallation will begin automatically if no selection is made." \
        --icon "$DIALOG_ICON" \
        --checkbox "Include Microsoft Teams${checkbox_flag}" \
        --button1text "Install" \
        --button2text "Cancel" \
        --timer "$TEAMS_PROMPT_TIMEOUT" \
        --buttontimer "Install" \
        --width 550 \
        --height 360 \
        --position centre \
        --json \
        2>/dev/null) || true

    # Handle cancel - timeout will not trigger this, only explicit cancel click
    local button
    button=$(echo "$result" | grep -o '"termination reason" *: *"[^"]*"' \
        | grep -o '[^"]*"$' | tr -d '"') || true

    if [[ "$button" == "cancelled" ]]; then
        echo "INFO: User cancelled installation" >&2
        exit 0
    fi

    # Parse Teams checkbox - on timeout this reflects the default checked state
    local teams_checked
    teams_checked=$(echo "$result" \
        | grep -o '"Include Microsoft Teams" *: *[^,}]*' \
        | awk -F': ' '{print $2}' \
        | tr -d ' "') || true

    if [[ "$teams_checked" == "true" ]]; then
        INCLUDE_TEAMS=true
    else
        INCLUDE_TEAMS=false
    fi

    echo "INFO: User selected INCLUDE_TEAMS=$INCLUDE_TEAMS" >&2
}

# --- Human-readable byte sizes (integer MB, for progress text) ---------------
human_mb() {
    echo "$(( ${1:-0} / 1048576 )) MB"
}

# --- Download Office pkg with optional SwiftDialog progress ------------------
download_office_pkg() {
    local curl_pid bytes msg

    rm -f "$OFFICE_PKG"

    curl -fL \
        --connect-timeout 10 \
        --max-time 7200 \
        --retry 3 \
        --retry-delay 5 \
        --retry-connrefused \
        -o "$OFFICE_PKG" \
        "$FULL_VERSION_URL" &
    curl_pid=$!

    while kill -0 "$curl_pid" 2>/dev/null; do
        sleep 10
        bytes=$(stat -f%z "$OFFICE_PKG" 2>/dev/null || echo 0)

        if [[ -n "${CONTENT_LENGTH//[[:space:]]/}" && "${CONTENT_LENGTH//[[:space:]]/}" -gt 0 ]]; then
            pct=$(awk -v b="$bytes" -v t="${CONTENT_LENGTH//[[:space:]]/}" \
                'BEGIN { if (t > 0) printf "%d", (b * 100) / t; else print 0 }')
            msg="Downloading Office $VERSION... $(human_mb "$bytes") / $(human_mb "$CONTENT_LENGTH") (${pct}%)"
        else
            msg="Downloading Office $VERSION $(human_mb "$bytes")"
        fi

        echo "INFO: $msg" >&2

        if [[ -n "$DIALOG_PID" ]] && kill -0 "$DIALOG_PID" 2>/dev/null; then
            dialog_update "progresstext: $msg"
        fi
    done

    if ! wait "$curl_pid"; then
        echo "ERROR: Download failed for $FULL_VERSION_URL" >&2
        rm -f "$OFFICE_PKG"
        return 1
    fi

    if [[ ! -s "$OFFICE_PKG" ]]; then
        echo "ERROR: Downloaded file is missing or empty" >&2
        return 1
    fi

    return 0
}

# --- Serializer fetch --------------------------------------------------------
fetch_serializer() {
    local src="$1"
    local dest="$2"

    if [[ "$src" == http* ]]; then
        echo "INFO: Downloading serializer from $src" >&2
        if ! curl -L --retry 3 --retry-delay 5 --retry-connrefused \
            "$src" -o "$dest"; then
            echo "ERROR: Serializer download failed" >&2
            return 1
        fi
    elif [[ -f "$src" ]]; then
        echo "INFO: Copying serializer from $src" >&2
        cp "$src" "$dest"
    else
        echo "INFO: Serializer not found at $src - skipping" >&2
        return 1
    fi
}

# --- Cleanup on exit (success or failure) ------------------------------------
cleanup() {
    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        if [[ -n "$DIALOG_PID" ]] && kill -0 "$DIALOG_PID" 2>/dev/null; then
            dialog_update "progresstext: Installation failed - please contact IT support."
            dialog_update "progress: complete"
            sleep 4
        fi
    fi
    dialog_close
    rm -rf "$WORK_DIR"
    exit $exit_code
}
trap cleanup EXIT

# --- Working directory -------------------------------------------------------
mkdir -p "$WORK_DIR"

# --- Install SwiftDialog if needed -------------------------------------------
if [[ ! -x "$DIALOG_BIN" ]]; then
    install_swiftdialog || echo "WARNING: SwiftDialog unavailable - continuing without GUI" >&2
fi

# --- Teams prompt (before progress window opens) -----------------------------
prompt_teams

# --- Launch progress window --------------------------------------------------
dialog_start

notify "Checking connectivity..." 1

# --- Connectivity check ------------------------------------------------------
if ! /usr/bin/nc -z "$CONNECTIVITY_HOST" 443 &>/dev/null; then
    notify "No connection to Microsoft. Check your internet connection."
    echo "ERROR: Cannot reach $CONNECTIVITY_HOST:443" >&2
    exit 1
fi

# --- Prompt to close Office apps (console user only) -------------------------
OFFICE_APPS=(
    "Microsoft Word"
    "Microsoft Excel"
    "Microsoft PowerPoint"
    "Microsoft Outlook"
    "Microsoft Teams"
    "Microsoft OneNote"
)
is_overlay_running() {
    pgrep -x "DEPNotify" &>/dev/null || \
#    pgrep -x "Dialog" &>/dev/null || \ # We run this when theres a user... derp
    pgrep -x "JamfSetupManager" &>/dev/null || \
    pgrep -x "IBM Notifier" &>/dev/null
}

quit_office_apps() {
    local running=()

    for app in "${OFFICE_APPS[@]}"; do
        if pgrep -ix "$app" &>/dev/null; then
            running+=("$app")
        fi
    done

    [[ ${#running[@]} -eq 0 ]] && return 0

    # Show close prompt only if user is present AND DEPNotify / Dialog is not running
    # Overlay runs fullscreen during enrolment and will block any dialog
    if has_user && ! is_overlay_running; then
    # show dialog
        APP_LIST=$(printf '• %s\n' "${running[@]}")
        dialog_update "progresstext: Waiting for you to close Office apps…"

        /usr/bin/osascript <<EOF
display dialog "The following Microsoft apps are open and must be closed before installation:

${APP_LIST}

Please save your work and quit them, then click OK to continue." \
    buttons {"OK"} default button "OK" \
    with title "Microsoft Office Installer"
EOF
    else
        echo "INFO: DEPNotify active or no console user — skipping close prompt, quitting silently" >&2
    fi

    # Graceful quit via osascript
    for app in "${running[@]}"; do
        echo "INFO: Requesting graceful quit of $app" >&2
        /usr/bin/osascript -e "tell application \"$app\" to quit" &>/dev/null || true
    done

    # Wait up to 15 seconds for graceful close
    local wait=0
    while [[ $wait -lt 15 ]]; do
        local still_running=false
        for app in "${running[@]}"; do
            if pgrep -ix "$app" &>/dev/null; then
                still_running=true
                break
            fi
        done
        [[ "$still_running" == false ]] && break
        sleep 1
        (( wait++ ))
    done

    # Force kill anything still open
    for app in "${running[@]}"; do
        if pgrep -ix "$app" &>/dev/null; then
            echo "INFO: Force killing $app" >&2
            pkill -9 -ix "$app" &>/dev/null || true
        fi
    done
}

quit_office_apps

# --- Determine OS version and set download URL and serializer ----------------
OS_MAJOR=$(sw_vers -productVersion | cut -d. -f1)

# macOS 14+ -----------------------------------------------
if [[ "$OS_MAJOR" -ge 14 ]]; then
    # macOS 14 Sonoma and later - latest Office 365
    notify "Checking for latest Office version..." 2
    if [[ "$INCLUDE_TEAMS" == true ]]; then
        LINKID="2009112"    # BusinessPro (with Teams)
    else
        LINKID="525133"     # Standard (without Teams)
    fi
    # HEAD only - a GET here would download the full ~3 GB pkg just to resolve the URL
    FULL_VERSION_URL=$(curl -fsSLI \
        --connect-timeout 5 \
        --max-time 20 \
        -o /dev/null \
        -w '%{url_effective}' \
        "https://go.microsoft.com/fwlink/?linkid=${LINKID}")
    if [[ -z "$FULL_VERSION_URL" || "$FULL_VERSION_URL" == *"GatewayException"* ]]; then
        echo "ERROR: Could not resolve Office 365 download URL" >&2
        exit 1
    fi
    SERIALIZER="$SERIALIZER_2024_SRC"

# macOS 13 Ventura ----------------------------------------
elif [[ "$OS_MAJOR" -eq 13 ]]; then
    # macOS 13 Ventura - last supported build is 16.101
    notify "macOS Ventura detected - using last compatible Office version..." 2
    if [[ "$INCLUDE_TEAMS" == true ]]; then
        FULL_VERSION_URL="https://officecdn.microsoft.com/pr/C1297A47-86C4-4C1F-97FA-950631F94777/MacAutoupdate/Microsoft_365_and_Office_16.101.25091314_BusinessPro_Installer.pkg"
    else
        FULL_VERSION_URL="https://officecdn.microsoft.com/pr/C1297A47-86C4-4C1F-97FA-950631F94777/MacAutoupdate/Microsoft_365_and_Office_16.101.25091314_Installer.pkg"
    fi
    SERIALIZER="$SERIALIZER_2021_SRC"

# macOS 12 Monterey ---------------------------------------
elif [[ "$OS_MAJOR" -eq 12 ]]; then
    # macOS 12 Monterey - last supported build is 16.88
    notify "macOS Monterey detected - using last compatible Office version..." 2
    if [[ "$INCLUDE_TEAMS" == true ]]; then
        FULL_VERSION_URL="https://officecdn.microsoft.com/pr/C1297A47-86C4-4C1F-97FA-950631F94777/MacAutoupdate/Microsoft_365_and_Office_16.88.24081116_BusinessPro_Installer.pkg"
    else
        FULL_VERSION_URL="https://officecdn.microsoft.com/pr/C1297A47-86C4-4C1F-97FA-950631F94777/MacAutoupdate/Microsoft_365_and_Office_16.88.24081116_Installer.pkg"
    fi
    SERIALIZER="$SERIALIZER_2021_SRC"

# macOS 11 Big Sur ---------------------------------------
elif [[ "$OS_MAJOR" -eq 11 ]]; then
    # macOS 11 Big Sur - last supported build is 16.77
    notify "macOS Big Sur detected - using last compatible Office version..." 2
    if [[ "$INCLUDE_TEAMS" == true ]]; then
        FULL_VERSION_URL="https://officecdn.microsoft.com/pr/C1297A47-86C4-4C1F-97FA-950631F94777/MacAutoupdate/Microsoft_365_and_Office_16.77.23091003_BusinessPro_Installer.pkg"
    else
        FULL_VERSION_URL="https://officecdn.microsoft.com/pr/C1297A47-86C4-4C1F-97FA-950631F94777/MacAutoupdate/Microsoft_365_and_Office_16.77.23091003_Installer.pkg"
    fi
    SERIALIZER="$SERIALIZER_2021_SRC"

# Unsupported ---------------------------------------------
else
	# macOS 10 Catalina and older - unsupported
	echo "ERROR: macOS $OS_MAJOR is unsupported. Minimum supported version is macOS 11 Big Sur." >&2
    notify "macOS version is unsupported. Minimum supported version is macOS 11 Big Sur."
    exit 1
fi

# --- Extract version from URL ------------------------------------------------
VERSION=$(echo "$FULL_VERSION_URL" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)

if [[ -z "$VERSION" ]]; then
    echo "ERROR: Could not parse version from URL: $FULL_VERSION_URL" >&2
    exit 1
fi

# --- Optional: pkg size for download progress (all OS versions) --------------
# %{size_download} is 0 on HEAD; parse Content-Length from response headers
CONTENT_LENGTH=$(curl -fsSLI \
    --connect-timeout 5 \
    --max-time 20 \
    "$FULL_VERSION_URL" 2>/dev/null \
    | awk 'tolower($1) == "content-length:" { gsub(/\r/, "", $2); print $2; exit }')
CONTENT_LENGTH=${CONTENT_LENGTH:-0}

# --- Download ----------------------------------------------------------------
notify "Downloading Office $VERSION..." 3
if ! download_office_pkg; then
    exit 1
fi

# --- Install Office ----------------------------------------------------------
notify "Installing Office $VERSION - this may take a while..." 4

if ! installer -pkg "$OFFICE_PKG" -target /; then
    echo "ERROR: Office installer failed" >&2
    rm -f "$OFFICE_PKG"
    exit 1
fi

# --- Apply VL Serializer (optional) ------------------------------------------
SERIALIZER_DEST="$WORK_DIR/serializer.pkg"

if fetch_serializer "$SERIALIZER" "$SERIALIZER_DEST"; then
    notify "Applying Volume Licence..." 5
    if ! installer -pkg "$SERIALIZER_DEST" -target /; then
        echo "ERROR: VL Serializer failed" >&2
        exit 1
    fi
    rm -f "$SERIALIZER_DEST"
else
    echo "INFO: No serializer available - skipping VL activation" >&2
fi

# --- Done --------------------------------------------------------------------
notify "Office $VERSION installed successfully." 6

if [[ -n "$DIALOG_PID" ]] && kill -0 "$DIALOG_PID" 2>/dev/null; then
    dialog_update "progresstext: Office $VERSION installed successfully."
    dialog_update "progress: complete"
    sleep 3
fi

# cleanup trap handles dialog close and WORK_DIR removal
exit 0
