import CoreML
import Foundation
import Vision

/// Finds phones in camera frames with an on-device object detector from Apple's Core ML model gallery
/// (COCO class "cell phone"):
/// - Apple Silicon: full YOLOv3 (62 MB, 8-bit). Far better than the Tiny model at small, tilted or
///   partly covered phones, and quick on the Neural Engine.
/// - Intel Macs, or until the full model is there: YOLOv3-Tiny (9 MB).
/// Models come bundled when the build could fetch them; otherwise Over&Out downloads them from Apple
/// by itself in the background (once), compiles them on this Mac and caches them. Tiny is used in
/// the meantime, and until any model is ready phone detection is simply off.
final class PhoneDetector: @unchecked Sendable {
    static let shared = PhoneDetector()

    enum Status { case notStarted, downloading, ready, unavailable }

    /// Detections below this confidence are ignored.
    static let minimumConfidence: Float = 0.3
    private static let phoneLabels: Set<String> = ["cell phone", "cellphone", "mobile phone", "cell_phone"]
    /// The detectors, best first. `name` is the file name in the app bundle / Application Support.
    struct Variant: Equatable {
        let name: String
        let urls: [URL]
        let minimumSize: Int
    }

    static let large = Variant(name: "PhoneDetectorLarge", urls: [
        "https://ml-assets.apple.com/coreml/models/Image/ObjectDetection/YOLOv3/YOLOv3Int8LUT.mlmodel",
        "https://ml-assets.apple.com/coreml/models/Image/ObjectDetection/YOLOv3/YOLOv3FP16.mlmodel",
    ].compactMap(URL.init(string:)), minimumSize: 30_000_000)

    static let tiny = Variant(name: "ObjectDetector", urls: [
        "https://ml-assets.apple.com/coreml/models/Image/ObjectDetection/YOLOv3Tiny/YOLOv3TinyInt8LUT.mlmodel",
        "https://ml-assets.apple.com/coreml/models/Image/ObjectDetection/YOLOv3Tiny/YOLOv3TinyFP16.mlmodel",
        "https://ml-assets.apple.com/coreml/models/Image/ObjectDetection/YOLOv3Tiny/YOLOv3Tiny.mlmodel",
    ].compactMap(URL.init(string:)), minimumSize: 1_000_000)

    /// The best detector this Mac should use (the full model needs the Neural Engine to keep up).
    static var preferred: Variant {
        #if arch(arm64)
        return large
        #else
        return tiny
        #endif
    }

    private static let retryAfter: TimeInterval = 10 * 60

    private let lock = NSLock()
    private var model: VNCoreMLModel?
    /// Which detector `model` is (Camera Preview shows it).
    private(set) var loadedVariant: Variant?
    private var loadAttempted = false
    private var downloading = false
    private var lastDownloadFailure: Date?

    /// The detector in use right now, in words, for About and Camera Preview.
    var modelDescription: String {
        lock.lock()
        let loaded = loadedVariant
        let fetching = downloading
        lock.unlock()
        switch loaded {
        case Self.large?:
            return "full YOLOv3 model"
        case Self.tiny?:
            return Self.preferred == Self.large
                ? "YOLOv3-Tiny model" + (fetching ? " (the full YOLOv3 model is downloading)" : " (the full YOLOv3 model will be downloaded)")
                : "YOLOv3-Tiny model (Intel Macs use the smaller model)"
        default:
            return fetching ? "detector (downloading)" : "detector (not loaded yet)"
        }
    }

    /// For Camera Preview and Settings.
    var status: Status {
        lock.lock()
        defer { lock.unlock() }
        if model != nil { return .ready }
        if downloading { return .downloading }
        return lastDownloadFailure == nil ? .notStarted : .unavailable
    }

    /// Call at launch: gets the model ready (loads it, or downloads it in the background).
    func prepare() {
        DispatchQueue.global(qos: .utility).async { self.loadIfNeeded() }
    }

    /// Phones in the frame (or only in `region`, which the model then sees enlarged: that's how an
    /// edge-on phone at the ear gets big enough to recognise). Boxes are normalised to the whole
    /// frame, origin bottom-left.
    func phones(in handler: VNImageRequestHandler, region: CGRect? = nil,
                minimum: Float = PhoneDetector.minimumConfidence) -> [(box: CGRect, confidence: Float)] {
        loadIfNeeded()
        lock.lock()
        let model = self.model
        lock.unlock()
        guard let model else { return [] }
        let request = VNCoreMLRequest(model: model)
        request.imageCropAndScaleOption = .scaleFill
        if let region { request.regionOfInterest = region }
        guard (try? handler.perform([request])) != nil else { return [] }
        return (request.results as? [VNRecognizedObjectObservation] ?? []).compactMap { object in
            guard let label = object.labels.first,
                  Self.phoneLabels.contains(label.identifier.lowercased()),
                  label.confidence >= minimum else { return nil }
            var box = object.boundingBox
            if let region { // results come relative to the region; map back to the whole frame
                box = CGRect(x: region.minX + box.minX * region.width, y: region.minY + box.minY * region.height,
                             width: box.width * region.width, height: box.height * region.height)
            }
            return (box, label.confidence)
        }
    }

    // MARK: Loading

    private func loadIfNeeded() {
        lock.lock()
        let needsLoad = !loadAttempted
        loadAttempted = true
        let current = loadedVariant
        lock.unlock()
        guard needsLoad else {
            downloadIfNeeded()
            return
        }
        // The best one that's here; a weaker one only until the preferred one has been fetched.
        for variant in [Self.preferred, Self.tiny] {
            if let current, current == variant || current == Self.preferred { break }
            guard let source = Self.localModel(variant) else { continue }
            guard let loaded = try? load(source, as: variant) else {
                // A damaged download: remove it (fetched again later) and keep using what works.
                if source.path.hasPrefix(Self.supportDirectory?.path ?? "/nonexistent") {
                    try? FileManager.default.removeItem(at: source)
                }
                lock.lock(); lastDownloadFailure = Date(); lock.unlock()
                continue
            }
            lock.lock()
            model = loaded
            loadedVariant = variant
            lock.unlock()
            break
        }
        downloadIfNeeded()
    }

    private func load(_ source: URL, as variant: Variant) throws -> VNCoreMLModel {
        let compiled = try compiledURL(for: source, name: variant.name)
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all // Neural Engine where available: fast and cool
        return try VNCoreMLModel(for: MLModel(contentsOf: compiled, configuration: configuration))
    }

    private static func localModel(_ variant: Variant) -> URL? {
        if let bundled = Bundle.main.url(forResource: variant.name, withExtension: "mlmodel") { return bundled }
        guard let url = supportDirectory?.appendingPathComponent(variant.name + ".mlmodel"),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    private static var supportDirectory: URL? {
        guard let base = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                      appropriateFor: nil, create: true) else { return nil }
        let folder = base.appendingPathComponent("OverAndOut", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    // MARK: Downloading (automatic, in the background)

    /// Fetches the preferred detector if it isn't here yet (and Tiny first when there's nothing
    /// at all, so phone detection starts working within seconds rather than after 62 MB).
    private func downloadIfNeeded() {
        lock.lock()
        let recentlyFailed = lastDownloadFailure.map { Date().timeIntervalSince($0) < Self.retryAfter } ?? false
        let haveAny = model != nil
        guard loadedVariant != Self.preferred, !downloading, !recentlyFailed else {
            lock.unlock()
            return
        }
        let wanted: Variant
        if Self.localModel(Self.preferred) == nil {
            wanted = (!haveAny && Self.localModel(Self.tiny) == nil) ? Self.tiny : Self.preferred
        } else {
            loadAttempted = false // it's here, just not loaded yet: the next frame loads it
            lock.unlock()
            return
        }
        downloading = true
        lock.unlock()
        tryDownload(wanted, wanted.urls)
    }

    private func tryDownload(_ variant: Variant, _ remaining: [URL]) {
        guard let url = remaining.first, let folder = Self.supportDirectory else {
            finishDownload(success: false)
            return
        }
        URLSession.shared.downloadTask(with: url) { file, response, _ in
            let ok = (response as? HTTPURLResponse)?.statusCode == 200
            let size = (file.flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? Int }) ?? 0
            guard ok, let file, size > variant.minimumSize else {
                self.tryDownload(variant, Array(remaining.dropFirst()))
                return
            }
            let destination = folder.appendingPathComponent(variant.name + ".mlmodel")
            try? FileManager.default.removeItem(at: destination)
            do {
                try FileManager.default.moveItem(at: file, to: destination)
                self.finishDownload(success: true)
            } catch {
                self.tryDownload(variant, Array(remaining.dropFirst()))
            }
        }.resume()
    }

    private func finishDownload(success: Bool) {
        lock.lock()
        downloading = false
        lastDownloadFailure = success ? nil : Date()
        if success { loadAttempted = false } // pick up the new model (and fetch the next one if needed)
        lock.unlock()
        if success { loadIfNeeded() }
    }

    /// Compiles the .mlmodel on first use and keeps the result in Application Support.
    private func compiledURL(for source: URL, name: String) throws -> URL {
        guard let folder = Self.supportDirectory else { throw CocoaError(.fileNoSuchFile) }
        let cached = folder.appendingPathComponent(name + ".mlmodelc", isDirectory: true)
        let sourceDate = (try? source.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let cachedDate = (try? cached.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if FileManager.default.fileExists(atPath: cached.path), let sourceDate, let cachedDate, cachedDate >= sourceDate {
            return cached
        }
        let temporary = try MLModel.compileModel(at: source)
        try? FileManager.default.removeItem(at: cached)
        try FileManager.default.moveItem(at: temporary, to: cached)
        return cached
    }
}

/// The rule, kept free of Vision types so it can be unit-tested: a detected phone counts when a
/// hand is holding it (hand points on or right around the phone) or when it's at the face/ear
/// (the hand is often hidden behind the phone then). A phone lying on the desk doesn't count, and
/// a hand at the ear without a phone never counts.
enum PhoneRule {
    /// Confidence accepted for a phone found in the enlarged area around the face: an edge-on
    /// phone at the ear scores much lower than one held face-on.
    static let nearFaceMinimum: Float = 0.15

    /// The area around the face and ears, searched enlarged for a phone.
    static func earRegion(_ face: CGRect) -> CGRect {
        let region = CGRect(x: face.minX - face.width, y: face.minY - face.height * 0.5,
                            width: face.width * 3, height: face.height * 1.8)
        return region.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    /// A hand held beside the face on one side (≥80% of its points), reaching at least lower-mid face
    /// height, mostly above the chin. On its own this never means "phone" (a hand at the ear isn't a
    /// phone); it only continues a phone that was *seen* in the hand moments before.
    static func handBesideFace(_ points: [CGPoint], face box: CGRect) -> Bool {
        guard points.count >= 4 else { return false }
        let margin = box.width * 0.05
        let reach = box.width * 1.1
        let left = points.filter { $0.x <= box.minX + margin && $0.x >= box.minX - reach }
        let right = points.filter { $0.x >= box.maxX - margin && $0.x <= box.maxX + reach }
        let side = left.count >= right.count ? left : right
        guard side.count * 5 >= points.count * 4 else { return false }
        let top = side.map(\.y).max() ?? 0 // Vision's origin is bottom-left
        guard top >= box.minY + box.height * 0.35, top <= box.maxY + box.height * 0.5 else { return false }
        return side.filter { $0.y >= box.minY - box.height * 0.1 }.count * 2 >= side.count
    }

    static func verdict(phone: CGRect, hands: [[CGPoint]], faces: [CGRect]) -> String? {
        let grip = phone.insetBy(dx: -phone.width * 0.5, dy: -phone.height * 0.5)
        if hands.contains(where: { hand in hand.filter { grip.contains($0) }.count >= 3 }) {
            return "phone in your hand"
        }
        for face in faces {
            let nearFace = face.insetBy(dx: -face.width * 0.6, dy: -face.height * 0.25)
            if nearFace.intersects(phone) { return "phone at your ear" }
        }
        return nil
    }
}
