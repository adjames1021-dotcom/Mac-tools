MacTools Lite - diagnostics stick for Mac and Windows
=====================================================

Nothing on this stick installs anything. Reports are saved to the Reports folder here.

ON A MAC
  Double-click MacToolsLite.app (works on Apple silicon and Intel, macOS 13 or later).
  If macOS says it "can't be opened" or is from an unidentified developer:
  right-click (or Control-click) MacToolsLite.app > Open > Open. You only do this once per Mac.
  Still blocked? Open Terminal and run:  xattr -dr com.apple.quarantine /Volumes/<stick>/MacToolsLite.app

  Tools: System Info (with "Save Diagnostic Report"), Management Inspector, App & Process Manager, Startup Items,
  App Uninstaller, Disk Usage, Duplicate Finder, Network Tools, Nmap Scanner*, Ports,
  Hash & Checksum, Command Runner, Text Tools.   (*needs nmap installed on that Mac)

  The app keeps its settings in "MacToolsLite Data" on the stick and leaves nothing on the Mac when you quit.
  No app? In Terminal:  bash /Volumes/<stick>/Tools/mac-report.sh

ON WINDOWS (10 / 11)
  Double-click "Windows Tools.bat". For disk health (SMART) and full details,
  right-click it > Run as administrator.
  Press R to save a full report, or pick a single check: system info, disk health, battery,
  startup items, top processes, network test, recent errors, security status.
  If SmartScreen warns you: More info > Run anyway.

Both report tools only read information; they don't change settings or delete anything.

ALSO ON THE STICK
  Tools/Windows Apps: Recuva (file recovery installer), TestDisk + PhotoRec (partition/photo recovery), portable VLC.
  Music (FLAC and MP3 copies), HTML Games, and the AJUSB Vault page.
