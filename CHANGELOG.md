# Changelog

Newest first. Each release needs a section here: `scripts/release.sh` uses it for the GitHub release
notes, and Hush shows it in "What's New" after an upgrade and in Settings → Updates.

## 1.0.1
- **Meetings in a browser tab**: your camera and microphone now come back on when you return, even if
  the meeting tab is in the background. If the browser holds the change back (background tabs are
  throttled), Hush brings the meeting tab to the front to finish it.
- Homebrew: Apple-Silicon-only builds are marked as such, so Intel Macs get a clear message.

## 1.0.0 — first release
- **Presence**: pauses videos, mutes your mic and turns off your meeting camera when you step away, and
  puts everything back when you return.
- **Phone detection**: an on-device detector spots a phone in your hand or at your ear.
- **Meetings**: presses the camera and mute buttons in Zoom, Teams, Webex, Slack, Discord and (with
  browser control on) Google Meet; system-wide mic mute everywhere.
- **Media**: pauses and resumes Spotify, Music, TV, VLC, QuickTime and browser tabs on every desktop.
- **Setup Assistant**, Camera Preview, Test Meeting Controls, update checks, and Homebrew install.
