#!/bin/bash
# MacTools Lite – Mac diagnostic report. Read-only: changes nothing on the Mac.
#   bash mac-report.sh [output-folder]     (default: the Reports folder on the stick)
# Prints the report's path as its last line.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:-$HERE/../Reports}"
mkdir -p "$OUT" || exit 1
HOST="$(scutil --get ComputerName 2>/dev/null || hostname)"
FILE="$OUT/Mac-${HOST//[^A-Za-z0-9_-]/_}-$(date +%Y-%m-%d_%H%M).txt"

section() { printf '\n==================== %s ====================\n' "$1"; }
# Runs a command with a time limit so one slow check can't hang the report.
run() { local t="$1"; shift; perl -e 'alarm shift; exec @ARGV' "$t" "$@" 2>&1 || echo "(not available)"; }

{
  echo "MacTools Lite diagnostic report"
  echo "Computer: $HOST"
  echo "Created:  $(date)"

  section "Hardware & macOS"
  run 60 system_profiler SPHardwareDataType SPSoftwareDataType
  section "Memory"
  run 30 system_profiler SPMemoryDataType
  run 10 vm_stat
  section "Graphics & displays"
  run 30 system_profiler SPDisplaysDataType

  section "Disks"
  run 20 diskutil list
  echo
  for d in $(diskutil list | awk '/^\/dev\/disk[0-9]+ \(internal/{print $1}'); do
    echo "$d: $(diskutil info "$d" | grep -E 'Device / Media Name|SMART Status|Disk Size|Solid State' | sed 's/^ *//' | paste -sd ';' -)"
  done
  echo
  df -h
  section "Storage (APFS)"
  run 30 system_profiler SPStorageDataType

  section "Battery & power"
  run 10 pmset -g batt
  run 30 system_profiler SPPowerDataType | grep -E 'Cycle Count|Condition|Maximum Capacity|Full Charge|Charging|Connected|Wattage' | sed 's/^ *//'

  section "Uptime, load & top processes"
  uptime
  run 15 top -l 2 -n 15 -o cpu -stats pid,command,cpu,mem | tail -n 16  # 2nd sample: the 1st shows 0% CPU

  section "Security"
  echo "SIP:        $(csrutil status 2>&1)"
  echo "Gatekeeper: $(spctl --status 2>&1)"
  echo "FileVault:  $(fdesetup status 2>&1)"
  echo "Firewall:   $(/usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate 2>&1)"

  section "Startup items (launch agents & daemons, non-Apple)"
  for dir in /Library/LaunchAgents /Library/LaunchDaemons "$HOME/Library/LaunchAgents"; do
    echo "-- $dir"
    ls -1 "$dir" 2>/dev/null | grep -v '^com\.apple\.' || echo "(none)"
  done
  echo "-- Kernel/system extensions"
  run 15 systemextensionsctl list
  run 15 kmutil showloaded --list-only 2>/dev/null | grep -v com.apple | head -30

  section "Network"
  run 10 networksetup -listallhardwareports
  echo
  ifconfig | grep -E '^[a-z]|inet ' | grep -B1 'inet ' | grep -v '^--'
  echo
  echo "Default route: $(route -n get default 2>/dev/null | awk '/gateway|interface/{printf "%s ", $0}')"
  echo "DNS servers:   $(scutil --dns | awk '/nameserver/{print $3}' | sort -u | paste -sd ' ' -)"
  echo "Wi-Fi:         $(networksetup -getairportnetwork en0 2>&1)"
  echo
  run 10 ping -c 3 -t 5 1.1.1.1
  echo
  echo "DNS lookup apple.com: $(run 10 dig +short apple.com | head -1)"
  echo "HTTPS to apple.com:   $(run 15 curl -s -o /dev/null -w '%{http_code} in %{time_total}s' https://www.apple.com)"

  section "Recent crashes & panics (last 30 days)"
  find /Library/Logs/DiagnosticReports "$HOME/Library/Logs/DiagnosticReports" -maxdepth 1 -type f -mtime -30 2>/dev/null \
    | sed 's|.*/||' | sort | tail -40
  [[ -z "$(find /Library/Logs/DiagnosticReports "$HOME/Library/Logs/DiagnosticReports" -maxdepth 1 -type f -mtime -30 2>/dev/null)" ]] && echo "(none)"

  section "Management & lockdown (for the administrator)"
  # Read-only: lists the management policies in force, not a way around them.
  echo "MDM enrollment: $(profiles status -type enrollment 2>/dev/null | paste -sd '; ' -)"
  echo
  echo "Configuration profiles installed:"
  run 20 profiles show 2>/dev/null | grep -E 'attribute: name|ProfileIdentifier' | sed 's/^ */  /' || echo "  (none, or needs admin)"
  echo
  echo "Restrictions payloads in force:"
  run 20 profiles show 2>/dev/null | grep -iE 'Restrictions|allowErase|allowCamera|allowScreenShot|forceList|blacklisted|whitelisted' | sed 's/^ *//' | sort -u || echo "  (none visible)"
  echo
  echo "Parental / content & privacy controls:"
  echo "  Screen Time / content filter: $(defaults read com.apple.applicationaccess 2>/dev/null | tr -d '\n' | cut -c1-200 || echo 'not set for this user')"
  echo
  echo "Gatekeeper / SIP / FileVault (repeated here for the admin): SIP=$(csrutil status 2>&1 | sed 's/.*: //'); Gatekeeper=$(spctl --status 2>&1); FileVault=$(fdesetup status 2>&1 | head -1)"
  echo "Login restrictions: $(defaults read /Library/Preferences/com.apple.loginwindow 2>/dev/null | grep -E 'HiddenUsersList|DisableConsoleAccess|RestartDisabled|SHOWFULLNAME' | tr -d '\n' | cut -c1-200 || echo 'default')"
  echo
  echo "Notes for IT: this lists the active management profiles and restrictions so they can be reviewed; it is not a bypass."

  section "Software updates"
  run 90 softwareupdate --list
} > "$FILE" 2>&1

echo "$FILE"
