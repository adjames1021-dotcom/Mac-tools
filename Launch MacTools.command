#!/bin/bash
# Double-click this file in Finder to open MacTools.
# The first time, it builds the app from source (about a minute). After that it opens instantly.
# Once MacTools is running, this Terminal window closes itself.

cd "$(dirname "$0")" || exit 1

clear
echo "🧰  MacTools"
echo

# Installs into /Applications (or ~/Applications), the copy the Dock icon and the in-app updater use,
# so a MacTools kept in the Dock always opens the latest build.
if ! /bin/bash ./build.sh --install; then
  echo
  echo "MacTools couldn't be built – see the messages above."
  read -r -p "Press Return to close this window… " _
  exit 1
fi

if [[ -d "/Applications/MacTools.app" ]]; then
  open "/Applications/MacTools.app"
elif [[ -d "$HOME/Applications/MacTools.app" ]]; then
  open "$HOME/Applications/MacTools.app"
else
  open "build/MacTools.app"
fi

# Close this Terminal window (and quit Terminal if nothing else is open).
# This runs in the background *after* the script exits, so Terminal doesn't ask
# "Do you want to terminate running processes?".
close_this_window() {
  [[ "${TERM_PROGRAM:-}" == "Apple_Terminal" ]] || return 0
  local my_tty
  my_tty="$(tty 2>/dev/null)" || return 0
  nohup /usr/bin/osascript - "$my_tty" >/dev/null 2>&1 <<'APPLESCRIPT' &
on run argv
	set targetTTY to item 1 of argv
	delay 0.6
	tell application "Terminal"
		set targetWindow to missing value
		repeat with w in windows
			try
				repeat with t in tabs of w
					if tty of t is targetTTY then
						set targetWindow to contents of w
						exit repeat
					end if
				end repeat
			end try
			if targetWindow is not missing value then exit repeat
		end repeat
		if targetWindow is not missing value then close targetWindow
		delay 0.2
		if (count of windows) is 0 then quit
	end tell
end run
APPLESCRIPT
  disown
}

close_this_window
exit 0
