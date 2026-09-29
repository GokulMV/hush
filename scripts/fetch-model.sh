#!/usr/bin/env bash
# Downloads the on-device phone detectors from Apple's Core ML model gallery
# (developer.apple.com/machine-learning/models; COCO classes, including "cell phone"):
#   Resources/ObjectDetector.mlmodel       YOLOv3-Tiny, ~9 MB (used on Intel Macs, and as a fallback)
#   Resources/PhoneDetectorLarge.mlmodel   full YOLOv3, ~62 MB (used on Apple Silicon: far more accurate)
# For local development only: builds don't bundle them (the app downloads them from Apple itself on
# first launch, see THIRD_PARTY_NOTICES.md). The files are git-ignored and must never be committed.
set -uo pipefail
cd "$(dirname "$0")/.."

BASE="https://ml-assets.apple.com/coreml/models/Image/ObjectDetection"

fetch() { # fetch <destination> <minimum bytes> <url>...
    local dest="$1" minimum="$2"; shift 2
    if [ -s "$dest" ]; then
        echo "Phone detector already present: $dest"
        return 0
    fi
    for url in "$@"; do
        echo "Downloading phone detector from $url"
        if curl -fL --retry 2 -o "$dest.part" "$url" && [ "$(wc -c < "$dest.part")" -gt "$minimum" ]; then
            mv "$dest.part" "$dest"
            echo "✅ Saved $dest"
            return 0
        fi
        rm -f "$dest.part"
    done
    echo "⚠️  Couldn't download $dest (the app will fetch it by itself)."
    return 1
}

fetch Resources/ObjectDetector.mlmodel 1000000 \
    "$BASE/YOLOv3Tiny/YOLOv3TinyInt8LUT.mlmodel" "$BASE/YOLOv3Tiny/YOLOv3TinyFP16.mlmodel" "$BASE/YOLOv3Tiny/YOLOv3Tiny.mlmodel"
tiny=$?
fetch Resources/PhoneDetectorLarge.mlmodel 30000000 \
    "$BASE/YOLOv3/YOLOv3Int8LUT.mlmodel" "$BASE/YOLOv3/YOLOv3FP16.mlmodel"
exit $tiny
