import SwiftUI

/// Live data for the Camera Preview window.
@MainActor
final class CameraPreviewModel: ObservableObject {
    @Published var image: CGImage?
    @Published var analysis: PresenceAnalysis?
}

/// Shows what Over&Out's camera sees and what it makes of it: face box (green), detected phones (red),
/// hand points (orange), and the verdict with its reason. For checking and tuning
/// detection; frames still never leave the Mac and nothing is saved.
struct CameraPreviewView: View {
    @ObservedObject var model: CameraPreviewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                Color.black
                if let image = model.image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .overlay(GeometryReader { geometry in overlay(in: geometry.size) })
                        .scaleEffect(x: -1, y: 1) // mirror, like a selfie view
                } else {
                    Text("Waiting for the camera…\nIf this stays empty, check that Over&Out's camera is on and allowed.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(minWidth: 480, minHeight: 300)
            .clipShape(RoundedRectangle(cornerRadius: 10))

            if let analysis = model.analysis {
                HStack(spacing: 8) {
                    Text(verdict(analysis.reading)).font(.headline)
                    Text("– \(analysis.reason)").foregroundStyle(.secondary)
                }
                Text("Phones: \(analysis.phones.count) (best \(Int(analysis.phoneScore * 100))%)   ·   Faces: \(analysis.faces.count)   ·   Hands: \(analysis.handPoints.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            switch PhoneDetector.shared.status {
            case .ready:
                Text("Hold your phone, at your ear or in your hand. It has to stay detected for 1 second to count. A hand at your ear without a phone doesn't count. Using the \(PhoneDetector.shared.modelDescription).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .downloading, .notStarted:
                Text("Getting the phone detector ready (a one-time download from Apple)… phone detection starts by itself when it's done.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .unavailable:
                Text("The phone detector couldn't be downloaded (no internet?). Over&Out tries again automatically in a few minutes.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(14)
        .frame(minWidth: 520)
    }

    private func verdict(_ reading: PresenceReading) -> String {
        switch reading {
        case .present: return "🙂 You're here"
        case .absent: return "🚶 No one"
        case .phoneToEar: return "📞 On the phone"
        }
    }

    /// Vision coordinates are normalised with the origin bottom-left; SwiftUI's is top-left.
    private func overlay(in size: CGSize) -> some View {
        let current = model.analysis
        return Canvas { context, _ in
            guard let analysis = current else { return }
            func rect(_ r: CGRect) -> CGRect {
                CGRect(x: r.minX * size.width, y: (1 - r.maxY) * size.height,
                       width: r.width * size.width, height: r.height * size.height)
            }
            for phone in analysis.phones {
                context.stroke(Path(roundedRect: rect(phone), cornerRadius: 4), with: .color(.red), lineWidth: 2.5)
            }
            for face in analysis.faces {
                context.stroke(Path(roundedRect: rect(face), cornerRadius: 6), with: .color(.green), lineWidth: 2.5)
            }
            for hand in analysis.handPoints {
                for point in hand {
                    let center = CGPoint(x: point.x * size.width, y: (1 - point.y) * size.height)
                    context.fill(Path(ellipseIn: CGRect(x: center.x - 3.5, y: center.y - 3.5, width: 7, height: 7)),
                                 with: .color(.orange))
                }
            }
        }
    }
}
