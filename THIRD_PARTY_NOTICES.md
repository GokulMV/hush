# Third-party notices

Over&Out itself is licensed under the GNU General Public License, version 3 or (at your option) any
later version. See [LICENSE](LICENSE). This file lists the work by others that it uses.

## Phone detection models (not included; downloaded from Apple)

Over&Out does **not** include or redistribute any machine-learning model. On first launch the app
downloads Apple's Core ML object-detection models directly from Apple, and keeps them only on that Mac:

- `YOLOv3Int8LUT.mlmodel` (Apple Silicon) and `YOLOv3TinyInt8LUT.mlmodel` (Intel, and as a fallback)
  from Apple's model gallery, <https://developer.apple.com/machine-learning/models/>, served from
  `ml-assets.apple.com`. Apple's page does not state a license for these conversions; they're used
  as Apple provides them, subject to Apple's terms.
- They are Core ML conversions of **YOLOv3** by Joseph Redmon and Ali Farhadi
  (“YOLOv3: An Incremental Improvement”, 2018, <https://arxiv.org/abs/1804.02767>), originally
  released in **Darknet**, <https://github.com/pjreddie/darknet>, whose license reads:
  “Darknet is public domain. Do whatever you want with it.”
- They were trained on the **COCO** dataset (<https://cocodataset.org>); Over&Out only uses the
  “cell phone” class.

`scripts/fetch-model.sh` downloads the same files from Apple for local development; they're
git-ignored and never committed.

## Apple frameworks

Over&Out is built on macOS system frameworks (AppKit, SwiftUI, AVFoundation, Vision, Core ML,
Core Audio, ApplicationServices/Accessibility, ServiceManagement, UserNotifications). They are part
of macOS and are not distributed with Over&Out.

To read what macOS reports as “Now Playing”, Over&Out runs a short script with Apple's own
`/usr/bin/osascript` that loads the system MediaRemote framework. The approach was learned from
public discussions of macOS 15.4's changes (for example
<https://github.com/ungive/mediaremote-adapter> and <https://github.com/MaxBroda/roger/issues/27>);
no code from those projects is included.

## Tools used to build and distribute it (not part of the app)

Swift and Swift Package Manager (Apache License 2.0 with Runtime Library Exception), Homebrew
(BSD 2-Clause), GitHub Actions and the GitHub CLI.
