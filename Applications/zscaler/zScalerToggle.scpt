set appName to "zscaler"
# AppleScript to Disable/Enable zscaler
# Add sudo to allow fingerprint auth via /etc/pam.d/sudo_local  https://apple.stackexchange.com/questions/259093/can-touch-id-on-mac-authenticate-sudo-in-terminal
# sed "s/^#auth/auth/" /etc/pam.d/sudo_local.template | sudo tee /etc/pam.d/sudo_local


if application appName is running then
	do shell script "loggedInUser=$( ls -l /dev/console | awk '{print $3}' )

# Get loggedInUser ID
userID=$( id -u $loggedInUser )

# to load:
sudo find ~/Library/LaunchAgents -name \"*zscaler*\" -exec launchctl bootout gui/$userID {} \\;
sudo find /Library/LaunchAgents -name \"*zscaler*\" -exec launchctl bootout gui/$userID {} \\;
sudo find /Library/LaunchDaemons -name \"*zscaler*\" -exec launchctl bootout system {} \\;
	"
else
	do shell script "loggedInUser=$( ls -l /dev/console | awk '{print $3}' )

# Get loggedInUser ID
userID=$( id -u $loggedInUser )

# to load:
sudo find ~/Library/LaunchAgents -name \"*zscaler*\" -exec launchctl bootstrap gui/$userID {} \\;
sudo find /Library/LaunchAgents -name \"*zscaler*\" -exec launchctl bootstrap gui/$userID {} \\;
sudo find /Library/LaunchDaemons -name \"*zscaler*\" -exec launchctl bootstrap system {} \\;
	"
end if
