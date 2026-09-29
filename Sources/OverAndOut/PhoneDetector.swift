import CoreML
import Foundation
import Vision

/// Finds phones in camera frames with an on-device object detector (Apple's Core ML YOLOv3-Tiny,
/// COCO class "cell phone"). The model comes bundled when the build could fetch it; otherwise Over&Out
/// downloads it from Apple by itself in the background on first launch (~9 MB, once), compiles it
/// on this Mac and caches it. Until it's ready, phone detection is simply off.
final class PhoneDetector: @unchecked Sendable {
    static let shared = PhoneDetector()

    enum Status { case notStarted, downloading, ready, unavailable }

    /// Detections below this confidence are ignored.
    static let minimumConfidence: Float = 0.3
    private static let phoneLabels: Set<String> = ["cell phone", "cellphone", "mobile phone", "cell_phone"]
    private static let downloadURLs = [
        "https://ml-assets.apple.com/coreml/models/Image/ObjectDetection/YOLOv3Tiny/YOLOv3TinyInt8LUT.mlmodel",
        "https://ml-assets.apple.com/coreml/models/Image/ObjectDetection/YOLOv3Tiny/YOLOv3TinyFP16.mlmodel",
        "https://ml-assets.apple.com/coreml/models/Image/ObjectDetection/YOLOv3Tiny/YOLOv3Tiny.mlmodel",
    ].compactMap(URL.init(string:))
    private static let retryAfter: TimeInterval = 10 * 60

    private let lock = NSLock()
    private var model: VNCoreMLModel?
    private var loadAttempted = false
    private var downloading = false
    private var lastDownloadFailure: Date?

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
        let needsLoad = model == nil && !loadAttempted
        loadAttempted = true
        lock.unlock()
        guard needsLoad else {
            downloadIfNeeded()
            return
        }
        guard let source = Self.bundledModel ?? Self.downloadedModel else {
            downloadIfNeeded()
            return
        }
        let loaded = try? load(source)
        lock.lock()
        model = loaded
        lock.unlock()
        if loaded == nil { downloadIfNeeded() }
    }

    private func load(_ source: URL) throws -> VNCoreMLModel {
        let compiled = try compiledURL(for: source)
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all // Neural Engine where available: fast and cool
        return try VNCoreMLModel(for: MLModel(contentsOf: compiled, configuration: configuration))
    }

    private static var bundledModel: URL? {
        Bundle.main.url(forResource: "ObjectDetector", withExtension: "mlmodel")
    }

    private static var supportDirectory: URL? {
        guard let base = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                      appropriateFor: nil, create: true) else { return nil }
        let folder = base.appendingPathComponent("OverAndOut", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private static var downloadedModel: URL? {
        guard let url = supportDirectory?.appendingPathComponent("ObjectDetector.mlmodel"),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    // MARK: Downloading (automatic, in the background)

    private func downloadIfNeeded() {
        lock.lock()
        let recentlyFailed = lastDownloadFailure.map { Date().timeIntervalSince($0) < Self.retryAfter } ?? false
        guard model == nil, !downloading, !recentlyFailed, Self.bundledModel == nil else {
            lock.unlock()
            return
        }
        downloading = true
        lock.unlock()
        tryDownload(Self.downloadURLs)
    }

    private func tryDownload(_ remaining: [URL]) {
        guard let url = remaining.first, let folder = Self.supportDirectory else {
            finishDownload(success: false)
            return
        }
        URLSession.shared.downloadTask(with: url) { file, response, _ in
            let ok = (response as? HTTPURLResponse)?.statusCode == 200
            let size = (file.flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? Int }) ?? 0
            guard ok, let file, size > 1_000_000 else {
                self.tryDownload(Array(remaining.dropFirst()))
                return
            }
            let destination = folder.appendingPathComponent("ObjectDetector.mlmodel")
            try? FileManager.default.removeItem(at: destination)
            do {
                try FileManager.default.moveItem(at: file, to: destination)
                self.finishDownload(success: true)
            } catch {
                self.tryDownload(Array(remaining.dropFirst()))
            }
        }.resume()
    }

    private func finishDownload(success: Bool) {
        lock.lock()
        downloading = false
        lastDownloadFailure = success ? nil : Date()
        loadAttempted = !success // after a download, load on the next frame (or now, below)
        lock.unlock()
        if success { loadIfNeeded() }
    }

    /// Compiles the .mlmodel on first use and keeps the result in Application Support.
    private func compiledURL(for source: URL) throws -> URL {
        guard let folder = Self.supportDirectory else { throw CocoaError(.fileNoSuchFile) }
        let cached = folder.appendingPathComponent("ObjectDetector.mlmodelc", isDirectory: true)
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
