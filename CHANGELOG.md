# Changelog

Newest first. Each release needs a section here: `scripts/release.sh` uses it for the GitHub release
notes, and Hush shows it in "What's New" after an upgrade and in Settings → Updates.

## 1.1.12
- **Fixed: a “call” that never ended.** macOS's own speech service (com.apple.CoreSpeech, used by Siri,
  “Hey Siri” and dictation) keeps the microphone open and was taken for a call, so the camera stayed on,
  a real call didn't count as a new one, and Spotify and your meeting weren't handled. macOS's
  background services are now never a call; FaceTime and iPhone calls still are.
- **Muting yourself doesn't end the call.** Some apps (WhatsApp) release the microphone while you're
  muted; the call now goes on while the call app still plays the call's sound (up to 30 minutes muted),
  so music doesn't start again mid-call. The menu shows “In a call (WhatsApp, mic off)”.
- The menu stays live while it's open, and detection keeps running meanwhile.
- **Runs on Intel Macs again.** Releases are built for both Apple Silicon and Intel even on a Mac with
  only the Command Line Tools (each chip is built separately and joined), instead of Apple Silicon only.
- **Add any call app yourself** (Settings → Calls & Media → Other call apps → Add App…). Its microphone
  use then counts as a call, and Over&Out asks for the permission it needs (Accessibility) right away.
  If the app's camera or mute isn't switched off when you step away, start a call in it and press
  **Learn Buttons…**: pick its camera and mute buttons from the ones it shows, and Over&Out presses those.
  The built-in names are still tried first, so apps that already worked are unchanged.
- **What you switch off yourself stays off**, for learned buttons too: Over&Out only presses a button
  while it shows the camera or mic is on, and only switches back on what it switched off itself (and
  only if it's still the way it left it). Buttons that look the same on and off aren't offered.
- WhatsApp, Skype and FaceTime are treated as meeting apps when finding camera/mute buttons, and a few
  more common button names are recognised (“Turn off video”, “Camera off”…).
- **Pausing gets a safety net.** Everything that paused media before still does, the same way. On top
  of that, Over&Out now asks macOS what is playing (its “Now Playing”, as used by the media keys and
  Control Centre) and, if something is still playing that the usual steps didn't handle, sends it a real
  Pause (and Play when you're back). It never presses ⏯ for that, so it can't start anything by accident.
- **The camera turns off after a meeting.** Background-only helpers that keep the microphone open
  (dictation tools, noise filters and other menu-bar apps without a Dock icon) no longer count as a call;
  they could keep a “call” going, and the camera on, after the meeting ended. Meeting apps and browsers
  count exactly as before.
- The camera only watches for playing media when “pause media when I step away” is on.
- The menu shows what's playing (“🎵 Playing: …”).
- **Better phone detection on Apple Silicon Macs**: the full YOLOv3 detector from Apple's Core ML gallery
  replaces the small “Tiny” one, and is much better at spotting a phone that's small, tilted, partly
  covered by your hand, or held edge-on at your ear. It runs on the Neural Engine. Intel Macs keep the
  small detector, which also stays as a fallback everywhere. The rules for what counts as a phone call
  (a phone in your hand or at your ear, never just a hand at your ear) are unchanged.
- **Automation rows show ✅ when the permission is on**, even when macOS doesn't answer Over&Out's
  question about it (as happened with Spotify): Over&Out then asks the open app itself for its version,
  which only works when the permission is on. Apps that aren't open still say so.

## 1.1.11
- **Automation rows in Settings → Permissions no longer stay on “checking…”.** macOS sometimes never
  answers for an app; each app is now checked separately with a 3-second limit, and when macOS stays
  quiet the row shows what happened the last time Over&Out controlled that app.

## 1.1.10
- **Settings → Permissions lists everything again.** It showed nothing while macOS was slow to answer
  about one app; now the list appears at once and the per-app rows fill in when ready.
  It says “All set” when nothing is missing, and only suggests the Setup Assistant when something is.
- Settings, Setup and other windows open truly centred on the screen you're using, never tucked
  under the menu bar.
- Closing the Setup window counts as finishing it; it only comes back if a permission is really missing.

## 1.1.9
- If Homebrew has lost track of the installed app (“there is already an App at /Applications/Over&Out.app”),
  Update Now reinstalls over it instead of failing. The Homebrew cask uses the new Homebrew 7 install
  steps, so `brew` no longer prints deprecation warnings about it.

## 1.1.8
- **Updating from the app works again.** “Update Now” refreshes Homebrew first (it used to find nothing
  new and quietly reopen the old version), and after reopening Over&Out tells you whether the update
  really happened, with what Homebrew said if it didn't.
- **Checking for updates no longer gets stuck on “Checking…”**: it gives up after 15 seconds, and
  falls back to github.com when GitHub's API is busy.
- Release notes wrap to the window instead of breaking mid-sentence, leave out the Homebrew install
  line, and cover every version since yours when you've skipped a few updates.

## 1.1.7
- **Settings is a regular window again, in the middle of the screen**, with close and minimise buttons
  and the page icons (General, Presence, Calls & Media, Permissions, Updates, About) in its toolbar,
  like most Mac apps; the title shows the page you're on. Roomier layout, and it stays open until you close it.

## 1.1.6
- **One thing at a time after an update or first launch.** If something needs permission, only the
  Setup checklist opens (it asks for each permission when you press Allow); What's New or the welcome
  card follows once you close it, instead of windows and macOS prompts piling up together.
- **Settings opens fully below the menu bar**, sized to fit your screen (it used to open above the
  menu bar, cut off), and stays open until you click outside it or press Esc (it used to close by itself).

## 1.1.5
- **The camera no longer stays on for a browser that isn't playing anything.** Browsers keep the
  speakers open for paused videos and some websites; Over&Out now checks the tab bar and ignores a
  quiet browser (and nameless background helpers). The menu's “Camera sees” line says why it's on.
- **Settings drops down from the menu-bar icon**, like other menu-bar apps: no window buttons, and it
  closes when you click elsewhere. Cleaner icon tabs replace the old segmented tab bar.

## 1.1.4
- **Accessibility no longer gets stuck after an update.** macOS kept showing the old version's switch as
  on while ignoring it, so Over&Out kept saying “Allow Accessibility”. Updating now clears that stale
  entry, and “Allow Accessibility…” (menu or Setup) clears it too before asking, so turning the switch
  on works straight away. You get a notification the moment it takes effect.

## 1.1.3
- **Permissions now survive updates.** Releases are signed with the same certificate every time, so
  macOS recognises each update as the same app and keeps Camera and Accessibility. (This update asks
  one last time; after that, updates keep them.)
- **Turning off “Keep watching” (or closing Camera Preview) turns the camera off right away**, unless a call
  or video still needs it; the menu now says why the camera is on (e.g. “Brave Browser is playing”).

## 1.1.2
- **No more "Not Responding" when macOS's audio service is busy**: every audio query (who's using the mic
  and speakers, muting, volume) now runs in the background. If Activity Monitor shows *coreaudiod* using
  lots of CPU, restart it once with `sudo killall coreaudiod` (it comes straight back).
- Settings no longer freezes: the permission list is read in the background, only while its tab is open.

## 1.1.1
- **Fixed a freeze while your mic is muted.** Over&Out kept re-checking every audio input device
  (including virtual ones such as ZoomAudioDevice) twice a second on its main thread; slow drivers
  froze its menu and could make the whole Mac stutter. It now mutes only real microphones, re-checks
  in the background every 2 seconds, and stops fighting a mic that keeps refusing.
- The browser tab check has a time limit, so a busy browser can't stall Over&Out either.

## 1.1.0
- **Hush is now Over&Out.** Homebrew already had an unrelated app called `hush` (a Safari cookie-banner
  blocker) that also installed as Hush.app, so `brew install --cask hush` and updates could fetch the wrong
  app. Install and update with `brew install --cask gokulmv/tap/over-and-out`. Settings start fresh and
  macOS asks for the permissions once more.

## 1.0.1
- **Meetings in a browser tab**: your camera and microphone now come back on when you return, even if
  the meeting tab is in the background. If the browser holds the change back (background tabs are
  throttled), Hush brings the meeting tab to the front to finish it.
- Homebrew: Apple-Silicon-only builds are marked as such, so Intel Macs get a clear message.
- **Camera watchdog**: if the camera stops delivering video (e.g. while another app such as Zoom holds it),
  Hush restarts it instead of silently watching nothing, and the menu says so.
- **⌃⌥⌘H opens Hush's menu** at the mouse pointer, even when a full menu bar hides its icon behind the
  notch. Opening Hush while it's running points at its icon, or opens Settings if the icon is hidden.

## 1.0.0 — first release
- **Presence**: pauses videos, mutes your mic and turns off your meeting camera when you step away, and
  puts everything back when you return.
- **Phone detection**: an on-device detector spots a phone in your hand or at your ear.
- **Meetings**: presses the camera and mute buttons in Zoom, Teams, Webex, Slack, Discord and (with
  browser control on) Google Meet; system-wide mic mute everywhere.
- **Media**: pauses and resumes Spotify, Music, TV, VLC, QuickTime and browser tabs on every desktop.
- **Setup Assistant**, Camera Preview, Test Meeting Controls, update checks, and Homebrew install.
