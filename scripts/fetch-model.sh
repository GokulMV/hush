#!/usr/bin/env bash
# Downloads the on-device phone detector: Apple's Core ML YOLOv3-Tiny object detector (COCO classes,
# including "cell phone"), from developer.apple.com/machine-learning/models. ~9 MB, fetched once.
set -euo pipefail
cd "$(dirname "$0")/.."

DEST="Resources/ObjectDetector.mlmodel"
if [ -s "$DEST" ]; then
    echo "Phone detector already present: $DEST"
    exit 0
fi

URLS=(
    "https://ml-assets.apple.com/coreml/models/Image/ObjectDetection/YOLOv3Tiny/YOLOv3TinyInt8LUT.mlmodel"
    "https://ml-assets.apple.com/coreml/models/Image/ObjectDetection/YOLOv3Tiny/YOLOv3TinyFP16.mlmodel"
    "https://ml-assets.apple.com/coreml/models/Image/ObjectDetection/YOLOv3Tiny/YOLOv3Tiny.mlmodel"
)
for url in "${URLS[@]}"; do
    echo "Downloading phone detector from $url"
    if curl -fL --retry 2 -o "$DEST.part" "$url" && [ "$(wc -c < "$DEST.part")" -gt 1000000 ]; then
        mv "$DEST.part" "$DEST"
        echo "✅ Saved $DEST"
        exit 0
    fi
    rm -f "$DEST.part"
done

echo "⚠️  Couldn't download the phone detector. Get “YOLOv3 Tiny” from"
echo "    https://developer.apple.com/machine-learning/models/ and save it as $DEST, then rebuild."
exit 1
