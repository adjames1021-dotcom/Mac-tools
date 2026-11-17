# 🧰 MacTools

One native macOS app with 60 tools: a keyboard & mouse **macro recorder/player**, an **auto clicker that can also press keys**, an **auto typer**, a **PDF editor**, key presser, text expander, window snapping, clipboard history and lots more. It's written in Swift/SwiftUI, has no dependencies, and is built on your own Mac from this source code.

**Themes**: pick a color theme for all of MacTools – Classic, Ocean, Forest, Sunset, Grape, Candy, Midnight, Graphite, Frost or Cocoa – and Auto, Light or Dark mode.

## Getting started

1. **Download** this repository (green **Code** button ▸ **Download ZIP**, then unzip it) or `git clone` it.
2. **Double-click `Launch MacTools.command`.**
   - The first time, macOS may say it's from an unidentified developer. **Right-click** the file ▸ **Open** ▸ **Open**. You only need to do this once.
   - If the Swift compiler isn't installed yet, macOS offers to install the free **Command Line Tools**. Click **Install**, wait for it to finish, then double-click the launcher again.
3. The first build takes a minute or two. After that MacTools opens straight away, and **the Terminal window closes itself** once the app is running.

### Updates are automatic

Once MacTools is installed, you never have to rebuild it by hand. The **Updates** page (and the menu bar's **Check for Updates…**) checks GitHub, downloads the new version, builds it in the background and swaps it in – just click **Restart MacTools**. You can also turn on *Install updates automatically*. Use **Move to Applications Folder** on that page so MacTools lives in Launchpad and Spotlight like any other app.

Builds are signed with a local certificate (“MacTools Local Code Signing”, created in your login keychain on the first build), so macOS **keeps your permissions** across updates. The first time, macOS may ask whether `codesign` can use that key – click **Always Allow**. You can delete the certificate in Keychain Access at any time; builds then fall back to a basic signature.

Prefer the command line?

```bash
./build.sh            # build (skipped if nothing changed)
./build.sh --install  # build and copy MacTools.app to /Applications
open build/MacTools.app
```

Requirements: macOS 13 Ventura or newer, plus Xcode or the Command Line Tools (`xcode-select --install`).

## Setting up School To-Do

1. Open **School To-Do ▸ Setup**.
2. Pick **Claude** or **ChatGPT**, then paste an API key from [console.anthropic.com](https://console.anthropic.com/settings/keys) or [platform.openai.com](https://platform.openai.com/api-keys). It's saved in your Mac's keychain.
3. **Google Classroom**: click **Sign In to Google…** and sign in with your school account. You only do this once. If you use several Google accounts, change the account number until Classroom opens the right one.
4. **Infinite Campus**: paste any Infinite Campus address – just the site, like `https://yourdistrict.infinitecampus.org`, is enough; MacTools finds your district's sign-in page. Choose how you sign in:
   - **With Google**: click **Sign In to Infinite Campus…** and pick your school Google account. Infinite Campus signs you out when MacTools quits, so each sync signs you back in through Google by itself.
   - **With a username and password**: sign in once, and turn on **Remember my username and password** so MacTools can sign you back in by itself.
5. Click **Sync Now**.

Each sync sends the text of these pages to the AI company you picked and uses your API credit; a sync that finds nothing new is skipped for free. **Setup ▸ Last Data Sent to the AI** shows exactly what was sent. If a page isn't picked up, open it in the sign-in browser and click **Sync This Page Too**.

## Permissions

Automation tools need macOS's permission to control your Mac. MacTools asks when a tool needs it. You can also open **Permissions & Hotkeys** in the sidebar to see what's granted.

| Permission | Used by |
|---|---|
| **Accessibility** | Auto clicker, auto typer, key presser, macro playback, text expander, window manager, keyboard cleaner |
| **Input Monitoring** | Macro recording |
| **Screen Recording** | Screenshots of other apps' windows |

> Permissions normally survive updates (see above). If a switch is **on** in System Settings but a tool still doesn't work, click **Reset Permissions…** in *Permissions & Hotkeys*, or remove MacTools from the list with **–** and add it again.

## Global hotkeys (defaults)

These work from any app and can be changed in **Permissions & Hotkeys**. On most Mac keyboards you need to hold **fn** to press F-keys.

| Hotkey | Action |
|---|---|
| **F5** | Auto clicker: capture the mouse position (sets the click spot or adds a step) |
| **F6** | Start / stop the auto clicker (or hold it down to click, in hold mode) |
| **F7** | Start / stop the auto typer |
| **F8** | Start / stop the key presser |
| **F9** | Start / stop macro recording |
| **F10** | Play / stop the current macro |
| **F12** | **Stop all automation** |
| ⌃⌥ ← → ↑ ↓ | Snap the window to the left, right, top or bottom half |
| ⌃⌥ ↩ / C | Maximize / center the window |
| ⌃⌥ U I J K | Snap the window to a corner quarter |
| ⌃⌥ D F G / E T | Snap the window to thirds / two-thirds |
| ⌃⌥⌘ → | Move the window to the next display |

MacTools also has a **menu bar icon** (🔧) for quick start/stop, and it keeps running there when you close the window, so hotkeys, clipboard history and schedules keep working. Use **Quit MacTools** from that menu to exit completely.

## The tools

### Automation
- **Macro Recorder**: records mouse moves, clicks, drags, scrolls and every key press with exact timing. Replay it at 0.25×–5× speed, loop it a set number of times or forever, edit events, shorten pauses, save a library of macros, and import/export them as JSON.
- **Auto Clicker**: left, right or middle button; single, double or triple clicks; at the cursor, a fixed spot, or a **sequence of steps**.
  - **Press any keys too**: add any key or shortcut (Space, Return, letters, F-keys, arrows, ⌘C…), pressed before each click, after each click, or instead of clicking.
  - **Step sequences** can mix clicks at points, key presses, typed text and waits, each with its own delay.
  - **Hotkeys** are set right on the page: toggle mode (press to start, press again to stop) or **hold-to-click** mode (clicks only while you hold the hotkey), plus a capture-position hotkey and stop-everything.
  - Set the interval (down to 1 ms), hold time, random timing and position jitter, a start delay, and stop after N actions or N seconds.
- **Auto Typer**: types any text, either the whole text, one line at a time or a random line. Set the per-character delay (with a human-like option), repeats, the wait between repeats and Return after each message, or paste instantly.
- **Key Presser**: presses any key or shortcut (⌘, ⇧, ⌥, ⌃ work too), or a sequence of keys, on repeat. It can also hold keys down.
- **Text Expander**: type `;sig` anywhere and it becomes your signature. Supports `{date}`, `{time}`, `{clipboard}`, `{uuid}` and more.
- **Keep Awake & Mouse Jiggler**: keeps your Mac awake (optionally with the display on) indefinitely or for a set time, and jiggles the mouse (visibly or invisibly).
- **Task Scheduler**: runs things once, every N minutes, hourly, daily, on weekdays or weekly. It can show notifications, speak, open apps or URLs, run shell commands or AppleScripts, play macros, start the clicker, sleep, lock, restart or shut down the Mac.
- **Command Runner**: runs zsh commands or AppleScript with live output, saves favourites, and can open them in Terminal.
- **Workspace Launcher**: opens a whole set of apps, files, folders, websites and commands in one click.
- **Keyboard Cleaner**: locks the keyboard (and optionally the trackpad) for a while so you can wipe it.

### Productivity
- **School To-Do**: one to-do list built from **Google Classroom** and **Infinite Campus**, organized by AI (**Claude** or **ChatGPT**, your choice).
  - Reads your Classroom To-do pages (assigned, missing, done), each class's **Stream** for announcements that need doing ("test Friday", "bring the permission slip"), and your Infinite Campus assignments, scores and grade categories. No Google Classroom API or school admin setup needed.
  - Work goes into separate **To-Do**, **Missing** and **Done** lists, **grouped by class**. Inside each class, the work that **counts most toward your grade** comes first (from Infinite Campus category weights and points, or estimated from the kind of work), or switch to soonest due first.
  - Each item links straight to the assignment when the site has a link, and **what you check off is remembered** across syncs.
  - **Sign in once**: the built-in browser remembers your Google sign-in, and Infinite Campus is signed back in automatically – through Google single sign-on, or with a username and password saved in the keychain.
  - **Edit anything**: right-click (or click the pencil) to change an item's due date, title, class, how much it counts, which list it's in, notes or link. Your edits stay after every sync; the school sites aren't changed. **Add your own items**, **hide** ones you don't care about, and **search**.
  - **Only this quarter**: shows just the work due in the current grading period, with the dates taken from Infinite Campus (or set them yourself).
  - Each class gets its own color from your theme. A progress bar shows each step. It can also sync automatically, notify you about new work, remind you every evening about what's due tomorrow, and copy the list as Markdown.
- **Clipboard History**: a searchable list with pinning. It skips passwords copied from password managers.
- **Quick Notes**: a scratchpad that saves automatically, with search and export.
- **Timers**: stopwatch with laps, a countdown with spoken alerts, and a Pomodoro focus timer.
- **Window Manager**: halves, quarters, thirds, maximize, center, next display, with an optional gap between windows.
- **Screenshot**: full screen, selection or window, with a delay, format, clipboard, cursor and shadow options. Also opens the macOS screenshot and recording toolbar.
- **Color Picker**: picks any pixel on screen and shows HEX, RGB, HSL, HSB, CMYK, SwiftUI, NSColor and UIColor values, plus shades, contrast ratios and history.
- **Mouse & Screen Ruler**: live cursor coordinates (for setting up clicks), display info, and point-to-point distance measuring.
- **Text to Speech**: every installed voice, speed and pitch, and export to an audio file.

### Fun & media
- **Spotify**: Spotify's own player built into MacTools – search, your library, playlists and podcasts. Sign in once; music keeps playing while you use other tools, and the menu bar has play/pause, next and previous.
- **Christmas**: switch on falling snow (flurries, snowfall or a blizzard), twinkling lights along the top of every page, red-and-green Christmas colors, snowflakes on tool icons, a snowflake menu bar icon with the days until Christmas, a countdown on the Home page, jingle bells when you check off schoolwork or a sync finishes, ornament check-offs in School To-Do and one-click Christmas music. Each is its own switch, and they can be limited to December 1–26.

### Developer
- **HTTP / API Client**: send GET/POST/PUT/PATCH/DELETE requests with headers and JSON bodies, see status, timing, headers and pretty-printed responses, keep a history, copy as cURL.
- **Git Helper**: pick any repository to see its branch, status and recent commits; fetch, pull, push, commit everything, stash, switch or create branches, and open it in Terminal, Finder, VS Code or on the web.
- **Ports & Web Server**: see which processes are listening on which ports and stop them, check whether a port is free, and serve any folder at `http://localhost` with one click.
- **Dev Environment**: checks ~30 languages and tools (Git, Swift, Xcode, Python, Node, npm, Go, Rust, Ruby, Docker, Homebrew, gh…) and shows versions, your PATH and environment variables (secrets hidden).
- **Homebrew Manager**: list installed packages and apps, see what's outdated, search, install, upgrade, uninstall, update, clean up and run doctor. Offers to install Homebrew if you don't have it.
- **SSH Keys**: list your keys with fingerprints, copy public keys, create new Ed25519/RSA/ECDSA keys, add them to the agent and Keychain, and test your GitHub connection.
- **JWT Decoder**: decode tokens, show issued/expiry dates and verify HS256/384/512 signatures.
- **URL Parser**: split a URL into its parts and edit its query parameters.
- **CSV ⇄ JSON**: convert both ways (quotes, delimiters, type detection) with a table preview.
- **Cron Helper**: explains cron expressions in plain English and lists the next 10 run times.
- **Markdown Editor**: live preview, open/save `.md`, export HTML.
- **Code Snippets**: a searchable library of reusable code with languages.
- **.gitignore Generator**: combine templates for 17 languages, editors and OSes and save into a project.
- **Hex Viewer**: byte-by-byte view of any file plus real file-type detection.
- **Encrypt & Decrypt**: password-protect text or files with AES-256-GCM.
- **Key Code Viewer**: press keys to see their key codes, characters and modifiers.
- **Developer Cleaner**: measure and clear Xcode DerivedData, archives, simulator caches, npm/Yarn/pnpm/pip/Gradle/Maven/Go/Cargo/Homebrew caches, and find old `node_modules` folders.

### Text & data
- **Text Tools**: 40 transformations (all case styles, sort, dedupe, shuffle and number lines, Base64, URL, HTML, ROT13, slugify…), find & replace, word, character and line counts, and lorem ipsum.
- **JSON Formatter**: pretty-print, minify, sort keys and validate.
- **Regex Tester**: live highlighting, capture groups, replace preview and a cheat sheet.
- **Diff Checker**: line-by-line comparison that can ignore case or whitespace.
- **Password Generator**: passwords or passphrases with an entropy-based strength meter.
- **Hash & Checksum**: MD5, SHA-1, SHA-256/384/512 and HMAC for text and files, plus checksum verification.
- **QR Codes**: create QR codes for text, URLs or Wi-Fi, and read them from images, the clipboard or any area of the screen.
- **Random Generator**: numbers, dice notation (`3d8+2`), coin flips, list picks and UUIDs.

### Files & media
- **PDF Editor**: open, edit and save PDFs.
  - Annotate with text boxes, sticky notes, a freehand pen (for signatures), rectangles, ellipses, lines, arrows, highlight areas, white-out and images. Highlight, underline or strike out selected text. An eraser and undo are included.
  - Rotate, reorder, duplicate, delete and insert pages (blank pages, pages from another PDF, or images). Merge PDFs and split them into single pages.
  - Search, add watermarks and page numbers, and edit the title, author and keywords. Fill in PDF forms.
  - Save, or export a password-protected copy, a flattened PDF with annotations baked in, PNG images of each page, or plain text. Unlock password-protected PDFs.
- **Batch Renamer**: find/replace (with regex), prefix, suffix, case, numbering and extension changes, with a live preview, clash detection and undo.
- **Image Converter**: convert between JPEG, PNG, HEIC, TIFF, GIF, BMP and PDF; resize, rotate, flip; combine images into a PDF.
- **Disk Usage**: volume overview, the biggest folders and files, and Move to Trash.
- **Duplicate Finder**: finds identical files by content (SHA-256) and shows how much space you'd save.

### System & network
- **System Info**: CPU, memory, disk, battery, uptime, load and thermal state.
- **App Uninstaller**: pick an app and see **everything** it keeps on your Mac – caches, preferences, sandbox containers, saved state, logs, crash reports, cookies, web data, launch agents and helper tools – with sizes. Uninstall the app and the data you've ticked, or **reset** an app by deleting only its data. A **Leftovers** scan finds data from apps you've already deleted. Everything goes to the Trash (so it can be restored), the app is quit first, and system-wide files ask for your password.
- **Startup Items**: see the background helpers (launch agents and daemons) that start with your Mac, stop them, or remove them.
- **App & Process Manager**: switch to, hide, quit or force quit apps; list processes by CPU or memory and end them.
- **System Toggles**: Dark Mode, hidden files, file extensions, desktop icons, Dock auto-hide and delay, Wi-Fi, mute, volume and more. Quick actions include lock, sleep, restart Finder/Dock, empty Trash, eject disks, flush DNS, free memory, log out, restart and shut down.
- **Network Tools**: public and local IPs, ping, traceroute, DNS lookup, port check, whois, HTTP headers, a speed test, interfaces, connections, routes and LAN devices.

### Calculators & converters
- **Calculator**: a scientific expression calculator with history, degrees/radians, `ans`, hex and binary literals.
- **Unit Converter**: 13 categories (length, weight, temperature, volume, area, speed, time, data, energy, pressure, angle, fuel, power).
- **Number Base Converter**: binary, octal, decimal and hex, plus text ↔ UTF-8 bytes and code points.
- **Date & Time Tools**: Unix timestamps in both directions, date arithmetic, time between dates and a world clock.

## Where your data lives

Macros, snippets, notes, schedules, launcher profiles and clipboard history are stored as JSON in `~/Library/Application Support/MacTools`. **Permissions & Hotkeys ▸ Open Data Folder** takes you there.

School To-Do keeps its list in `school-todo.json`, your check-offs in `school-todo-checked.json`, and your edits, hidden items and added items in `school-todo-changes.json` in that folder. Its API keys and the optional Infinite Campus login are in your login keychain, and the school sites' sign-in cookies are in MacTools' website data (**School To-Do ▸ Setup ▸ Sign Out of All School Sites** clears them).

## Project layout

```
Launch MacTools.command   double-click launcher (builds, opens the app, closes Terminal)
build.sh                  compiles Sources/ into build/MacTools.app with swiftc
update.conf               which GitHub repository/branch the in-app updater follows
Resources/Info.plist      app bundle metadata
Scripts/make_icon.swift   draws the app icon during the build
Sources/MacTools/
  App/                    app entry point, sidebar, tool registry, settings
  Core/                   permissions, hotkeys, input synthesis, shell, shared UI
  Tools/                  one folder per category, one file per tool
```
