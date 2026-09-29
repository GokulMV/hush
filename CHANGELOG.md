# Changelog

Newest first. Each release needs a section here: `scripts/release.sh` uses it for the GitHub release
notes, and Hush shows it in "What's New" after an upgrade and in Settings → Updates.

## 1.1.12
- **One way to pause everything.** Over&Out now asks macOS what is playing (its “Now Playing”, the same
  thing the media keys and Control Centre use) and sends it a real Pause, then Play when you're back.
  That covers Spotify, Music, YouTube, Netflix and any other app or browser tab the same way, needs no
  per-app setup, and can never start something by accident (the old ⏯ key was a toggle). Spotify and
  Music are still paused directly too, and browser tab control still pauses several tabs at once.
- **The camera turns off after a meeting.** A call now means an app you can see in the Dock (or a calling
  service) using the microphone; background helpers that keep the mic open no longer count, which
  could keep a “call” going and the camera on after the meeting ended.
- The camera only watches for playing media when “pause media when I step away” is on, and only while
  macOS says something is actually playing (not just an app holding the speakers open).
- The menu shows what's playing (“🎵 Playing: …”).
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
