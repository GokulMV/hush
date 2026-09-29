import AppKit

/// Menu-bar icons that stay visible on light and dark menu bars (and over any wallpaper tint).
///
/// Normal states use the Hush waveform drawn as a *template* image: macOS colours templates
/// itself (black on light bars, white on dark ones, inverted while the menu is open).
/// Alert states use coloured symbols with shades picked for the bar's actual appearance.
enum MenuBarIcon {
    enum Alert {
        case live // red: your mic is on in a call
        case warn // orange: away, on the phone, panic

        func color(dark: Bool) -> NSColor {
            switch (self, dark) {
            case (.live, true): return NSColor(srgbRed: 1.00, green: 0.27, blue: 0.23, alpha: 1) // #FF453A
            case (.live, false): return NSColor(srgbRed: 0.84, green: 0.00, blue: 0.08, alpha: 1) // #D70015
            case (.warn, true): return NSColor(srgbRed: 1.00, green: 0.62, blue: 0.04, alpha: 1) // #FF9F0A
            case (.warn, false): return NSColor(srgbRed: 0.79, green: 0.20, blue: 0.00, alpha: 1) // #C93400
            }
        }
    }

    static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    /// The Hush waveform (a slash through it when Hush is off), drawn at 2x as a template image.
    @MainActor
    static func brand(slashed: Bool) -> NSImage {
        let size = NSSize(width: 20, height: 18)
        let image = NSImage(size: size)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return image }
        // Set the point size *before* making the context, so it scales 2x; otherwise drawing in
        // points fills only a quarter of the bitmap and the icon shows up half-size.
        rep.size = size
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return image }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.black.setFill()
        let heights: [CGFloat] = [7, 11, 16, 11, 7]
        let barWidth: CGFloat = 2.8
        let gap: CGFloat = 1.5
        let total = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap
        var x = (size.width - total) / 2
        for height in heights {
            let bar = NSRect(x: x, y: (size.height - height) / 2, width: barWidth, height: height)
            NSBezierPath(roundedRect: bar, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
            x += barWidth + gap
        }
        if slashed {
            let slash = NSBezierPath()
            slash.move(to: NSPoint(x: 2.5, y: size.height - 1.5))
            slash.line(to: NSPoint(x: size.width - 2.5, y: 1.5))
            slash.lineCapStyle = .round
            context.compositingOperation = .clear // cut a gap so the slash reads clearly
            slash.lineWidth = 4.2
            slash.stroke()
            context.compositingOperation = .sourceOver
            NSColor.black.setStroke()
            slash.lineWidth = 2.2
            slash.stroke()
        }
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        image.addRepresentation(rep)
        image.isTemplate = true
        return image
    }

    /// An SF Symbol; template (auto light/dark) when `alert` is nil, otherwise coloured for the bar.
    static func symbol(_ name: String, alert: Alert?, dark: Bool, description: String) -> NSImage? {
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: description) else { return nil }
        var config = NSImage.SymbolConfiguration(pointSize: 15, weight: .bold)
        if let alert {
            config = config.applying(NSImage.SymbolConfiguration(paletteColors: [alert.color(dark: dark)]))
        }
        let image = base.withSymbolConfiguration(config) ?? base
        image.isTemplate = alert == nil
        return image
    }
}
