# Changelog

Newest first. Each release needs a section here: `scripts/release.sh` uses it for the GitHub release
notes, and Hush shows it in "What's New" after an upgrade and in Settings → Updates.

## 1.1.3
- **Permissions now survive updates.** Releases are signed with the same certificate every time, so
  macOS recognises each update as the same app and keeps Camera and Accessibility. (This update asks
  one last time; after that, updates keep them.)

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
