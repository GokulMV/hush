import AVFoundation
import CoreImage
import Vision

/// Everything one camera frame was read as: the verdict plus what it was based on
/// (shown in the Camera Preview window so detection problems can be seen).
struct PresenceAnalysis {
    var reading: PresenceReading
    /// Why, in words: "hand beside face (6 of 9 points)", "phone beside face (cellphone 42%)", …
    var reason: String
    /// Normalised (0–1, origin bottom-left) rectangles and points, for drawing.
    var faces: [CGRect] = []
    var handPoints: [[CGPoint]] = []
    var phones: [CGRect] = []
    /// Best phone-detection confidence in this frame (0 when none, or no detector installed).
    var phoneScore: Float = 0
}

/// Watches the Mac's camera on-device (about 4 frames a second) and reports whether someone is
/// in front of it and whether they're on the phone: a phone *object* detected in their hand or at
/// their face (PhoneDetector). A hand at the ear without a phone never counts.
/// Frames are analysed in memory and thrown away; nothing is recorded.
final class PresenceSensor: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    /// Called on the main thread for every analysed frame. The image is only produced while
    /// `wantsPreviewFrames` is on (the Camera Preview window is open).
    var onAnalysis: (@MainActor (PresenceAnalysis, CGImage?) -> Void)?
    var wantsPreviewFrames = false

    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "overandout.presence")
    private var configured = false
    private var askingForAccess = false
    private var lastAnalysis = Date.distantPast
    /// Frames right after the camera starts can be dark or blurry and look like "no one";
    /// they're reported as a warm-up instead of a verdict.
    private var startedAt = Date.distantPast
    /// When a phone was last seen held in a hand: a hand that then goes to the ear continues it.
    private var lastPhoneInHand = Date.distantPast
    static let phoneMemory: TimeInterval = 10
    static let warmUp: TimeInterval = 2
    private(set) var isRunning = false

    static var authorization: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .video)
    }

    func start() {
        guard !isRunning else { return }
        switch Self.authorization {
        case .authorized:
            break
        case .notDetermined:
            guard !askingForAccess else { return }
            askingForAccess = true
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    self.askingForAccess = false
                    if granted { self.start() }
                }
            }
            return
        default:
            return // denied or restricted: the menu shows how to fix it
        }
        guard configured || configure() else { return }
        startedAt = Date()
        runningSince = Date()
        isRunning = true
        queue.async { self.session.startRunning() }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        queue.async { self.session.stopRunning() }
    }

    private func configure() -> Bool {
        let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .unspecified)
            ?? AVCaptureDevice.default(for: .video)
        guard let camera, let input = try? AVCaptureDeviceInput(device: camera) else { return false }

        session.beginConfiguration()
        session.sessionPreset = .medium // enough pixels for body pose, cheap to analyse
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddInput(input), session.canAddOutput(output) else {
            session.commitConfiguration()
            return false
        }
        session.addInput(input)
        session.addOutput(output)
        session.commitConfiguration()
        configured = true
        return true
    }

    private let imageContext = CIContext()

    /// When the camera last delivered a frame (any frame, analysed or not).
    private(set) var lastFrameAt = Date.distantPast
    private(set) var runningSince = Date.distantPast

    /// Started a while ago but no frames lately: the session is stuck (e.g. another app grabbed the
    /// camera in a way that starves Over&Out). The engine restarts it and says so in the menu.
    var isStalled: Bool {
        isRunning && Date().timeIntervalSince(runningSince) > 4 && Date().timeIntervalSince(lastFrameAt) > 4
    }

    /// Stops and starts the capture session again.
    func restart() {
        guard isRunning else { return }
        runningSince = Date()
        queue.async {
            self.session.stopRunning()
            self.session.startRunning()
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // The camera delivers ~30 fps; four looks per second are plenty and keep CPU low.
        let now = Date()
        lastFrameAt = now
        guard now.timeIntervalSince(lastAnalysis) >= 0.25,
              let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastAnalysis = now

        if now.timeIntervalSince(startedAt) < Self.warmUp {
            let warming = PresenceAnalysis(reading: .present, reason: "camera warming up")
            Task { @MainActor in self.onAnalysis?(warming, nil) }
            return
        }

        let handler = VNImageRequestHandler(cvPixelBuffer: pixels, orientation: .up)
        let faceRequest = VNDetectFaceRectanglesRequest()
        let handRequest = VNDetectHumanHandPoseRequest()
        handRequest.maximumHandCount = 2
        let poseRequest = VNDetectHumanBodyPoseRequest()
        do {
            try handler.perform([faceRequest, handRequest, poseRequest])
        } catch {
            return
        }
        let faces = faceRequest.results ?? []
        let hands = handRequest.results ?? []
        let poses = poseRequest.results ?? []
        var analysis = PresenceAnalysis(reading: .absent, reason: "")
        analysis.faces = faces.map(\.boundingBox)
        analysis.handPoints = hands.map { Self.points(of: $0) }

        // A phone, as an object, in your hand or at your face: the whole frame, plus an enlarged look
        // around each face with a lower bar (an edge-on phone at the ear is small and dark).
        var detections = PhoneDetector.shared.phones(in: handler)
        for face in analysis.faces {
            detections += PhoneDetector.shared.phones(in: handler, region: PhoneRule.earRegion(face),
                                                      minimum: PhoneRule.nearFaceMinimum)
        }
        for phone in detections {
            analysis.phones.append(phone.box)
            analysis.phoneScore = max(analysis.phoneScore, phone.confidence)
            if analysis.reading != .phoneToEar,
               let why = PhoneRule.verdict(phone: phone.box, hands: analysis.handPoints, faces: analysis.faces) {
                analysis.reading = .phoneToEar
                analysis.reason = "\(why) (\(Int(phone.confidence * 100))%)"
            }
        }
        if analysis.reading == .phoneToEar {
            lastPhoneInHand = now
        } else if now.timeIntervalSince(lastPhoneInHand) < Self.phoneMemory,
                  analysis.faces.contains(where: { face in
                      analysis.handPoints.contains { PhoneRule.handBesideFace($0, face: face) }
                  }) {
            // The phone was just in your hand and now your hand is at your ear: it's hidden, not gone.
            analysis.reading = .phoneToEar
            analysis.reason = "phone carried to your ear"
            lastPhoneInHand = now
        }
        if analysis.reading != .phoneToEar {
            let headVisible = poses.contains { pose in
                let head: [VNHumanBodyPoseObservation.JointName] = [.nose, .leftEye, .rightEye, .leftEar, .rightEar]
                return head.contains { (try? pose.recognizedPoint($0))?.confidence ?? 0 > 0.3 }
            }
            // A turned or half-covered face (e.g. holding a phone) mustn't look like "you left":
            // visible hands or shoulders mean someone's there too.
            let bodyVisible = !hands.isEmpty || poses.contains { pose in
                [VNHumanBodyPoseObservation.JointName.leftShoulder, .rightShoulder].contains {
                    (try? pose.recognizedPoint($0))?.confidence ?? 0 > 0.3
                }
            }
            if !faces.isEmpty || headVisible || bodyVisible {
                analysis.reading = .present
                analysis.reason = !faces.isEmpty ? "your face is visible" : headVisible ? "your head is visible" : "you're in view"
                if !analysis.phones.isEmpty { analysis.reason += "; a phone is in view but nobody's holding it" }
            } else {
                analysis.reason = "no one in view"
            }
        }

        var image: CGImage?
        if wantsPreviewFrames {
            let frame = CIImage(cvPixelBuffer: pixels)
            image = imageContext.createCGImage(frame, from: frame.extent)
        }
        let result = analysis
        let frameImage = image
        Task { @MainActor in self.onAnalysis?(result, frameImage) }
    }

    // MARK: Hands

    private static func points(of hand: VNHumanHandPoseObservation) -> [CGPoint] {
        guard let joints = try? hand.recognizedPoints(.all) else { return [] }
        return joints.values.filter { $0.confidence > 0.2 }.map(\.location)
    }
}
