import AppKit
import CoreText
import SwiftUI

/// Menu-bar geometry in points. The panel scales this same coordinate system to panelSize.
/// Tune these values here; menu images, panel arcs and their previews share them.
enum MenuArcMetrics {
    static let segmentSize: CGFloat = 22             // Fills the 22pt menu bar.
    static let scale = segmentSize / 18
    static let segmentGap: CGFloat = (6 * scale).rounded() // Whole-point spacing between canvases.
    static let lineWidth: CGFloat = 1.7              // Track and remaining-quota stroke.
    static let digitFontSize: CGFloat = 6.8          // Percentage at the top of the arc.
    static let digitWeight: NSFont.Weight = .semibold // Rounded monospaced percentage weight.
    static let logoSizeWithPercent: CGFloat = 12.04  // Logo with arc-top digits.
    static let logoSizeWithoutPercent: CGFloat = 13.81 // Logo with no digits.
    static let logoSizeBeside: CGFloat = 11.30
    static let besideDigitFontSize: CGFloat = 10.5 * scale // Percentage beside the arc.
    static let besideGap: CGFloat = 2 * scale        // Arc-to-beside-number spacing.
    static let digitCenterY: CGFloat = 1.1 * scale   // Arc-top ink's preferred vertical center.
    static let digitKerning: CGFloat = -0.3 * scale  // Arc-top number tracking.
    static let digitTopClearance: CGFloat = 0.3 * scale // Ink clearance before pixel alignment.
    static let digitCutoutPadding: CGFloat = 0.9 * scale // Arc cutout padding on either side of ink.
    static let digitCutoutCornerRatio: CGFloat = 0.3 // Cutout radius relative to digit size.
    static let digitKnockoutPadding: CGFloat = 0.6   // Glyph-shaped clearance under arc-top digits.
    static let logoClearance: CGFloat = 0.6 * scale  // Moat between logo and arc.
    static let trackOpacity: CGFloat = 0.3           // Empty arc's foreground alpha.
    static let arcSweep = 291.0                      // Arc sweep in degrees.
    static let arcStart = 55.5                       // Right-bottom starting angle in degrees.
    static let panelSize: CGFloat = 44               // Panel arc canvas; all ink scales with it.
}

extension AIUsageStore {
    /// Presentation only; account selection, fetching and cached values remain owned by the store.
    var subscriptionDisplaySnapshots: [AIUsageSnapshot] {
        subscriptionPreferences.sorted(displaySnapshots).filter {
            $0.isConnected || $0.updatedAt != nil || $0.wasConfigured
        }
    }
    var menuBarDisplaySnapshots: [AIUsageSnapshot] {
        subscriptionDisplaySnapshots.filter { subscriptionPreferences.showsInMenuBar($0.provider) }
    }
}

/// Screen coordinates: right/bottom is 0%, through the top to left/bottom at 100%.
enum QuotaArc {
    enum ColorLevel { case green, orange, red }
    static func colorLevel(percent: Double) -> ColorLevel {
        percent >= 50 ? .green : percent >= 20 ? .orange : .red
    }

    static let sweep = MenuArcMetrics.arcSweep
    static let start = MenuArcMetrics.arcStart
    static func end(percent: Double) -> Double { start - sweep * percent / 100 }
    static func point(size: CGFloat, lineWidth: CGFloat, angle: Double) -> CGPoint {
        let radius = (size - lineWidth) / 2
        return CGPoint(x: size / 2 + radius * cos(angle * .pi / 180),
                       y: size / 2 + radius * sin(angle * .pi / 180))
    }
    static func path(size: CGFloat, lineWidth: CGFloat, percent: Double = 100) -> Path {
        guard percent > 0 else { return Path() }
        var path = Path()
        var angle = start
        let finish = end(percent: percent)
        // Split at the axes so the cubic arc approximation cannot overshoot the canvas.
        while angle > finish {
            let next = max(finish, (ceil(angle / 90) - 1) * 90)
            path.addArc(center: CGPoint(x: size / 2, y: size / 2), radius: (size - lineWidth) / 2,
                        startAngle: .degrees(angle), endAngle: .degrees(next), clockwise: true)
            angle = next
        }
        return path
    }
}

@MainActor
enum SubscriptionGlyph {
    private static var images: [AIUsageProvider: NSImage] = [:]
    private static var pixelImages: [AIUsageProvider: [Int: NSImage]] = [:]
    static func image(_ provider: AIUsageProvider) -> NSImage {
        if let image = images[provider] { return image }
        let filename: String
        switch provider {
        case .codex: filename = "openai.svg"
        case .claude: filename = "claude.svg"
        case .grok: filename = "grok.svg"
        default: return AIUsageBrand.menuImage(for: provider)
        }
        let image = NSImage(contentsOf: SharedResources.url(filename, directory: "logos/subscriptions"))!
        image.isTemplate = true
        images[provider] = image
        return image
    }

    /// Small 1x glyphs need their own raster, rather than a resampled Retina image.
    static func pixelImage(_ provider: AIUsageProvider, side: Int) -> NSImage {
        if let image = pixelImages[provider]?[side] { return image }
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else { return image(provider) }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        image(provider).draw(in: CGRect(x: 0, y: 0, width: side, height: side), from: .zero,
                             operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        // A dedicated binary raster keeps small strokes crisp on a 1x menu bar.
        for y in 0..<side {
            for x in 0..<side {
                let alpha = bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0
                bitmap.setColor(NSColor(deviceRed: 0, green: 0, blue: 0,
                    alpha: alpha >= 0.45 ? 1 : 0), atX: x, y: y)
            }
        }
        let result = NSImage(size: NSSize(width: side, height: side))
        result.addRepresentation(bitmap)
        result.isTemplate = true
        pixelImages[provider, default: [:]][side] = result
        return result
    }
}

struct QuotaArcView: View {
    var provider: AIUsageProvider
    var percent: Double?
    var size: CGFloat = MenuArcMetrics.panelSize
    var dark: Bool
    var showPercentage = true
    @AppStorage(SubscriptionPreferences.colorKey) private var colorsByQuota = true

    var body: some View {
        Image(nsImage: QuotaMenuImage.segmentImage(provider: provider, percent: percent,
                                                  size: size, foreground: dark ? .white : .black,
                                                  showPercentage: showPercentage, colorsByQuota: colorsByQuota))
            .resizable().interpolation(.high)
            .frame(width: size, height: size).accessibilityHidden(true)
    }
}

@MainActor
enum QuotaMenuImage {
    static func logoSize(showPercentage: Bool,
                         placement: AIUsageMenuBarPreference.PercentagePlacement = .arcTop) -> CGFloat {
        if showPercentage && placement == .beside { return MenuArcMetrics.logoSizeBeside }
        return showPercentage ? MenuArcMetrics.logoSizeWithPercent : MenuArcMetrics.logoSizeWithoutPercent
    }

    static func logoRect(showPercentage: Bool, scale: CGFloat,
                         placement: AIUsageMenuBarPreference.PercentagePlacement = .arcTop) -> CGRect {
        // Even device-pixel sides keep the raster crisp and centered in every mode.
        let side = (logoSize(showPercentage: showPercentage, placement: placement) * scale / 2).rounded() * 2 / scale
        return CGRect(x: (MenuArcMetrics.segmentSize - side) / 2,
                      y: (MenuArcMetrics.segmentSize - side) / 2, width: side, height: side)
    }

    struct NumberLayout {
        let line: CTLine
        let baseline: CGFloat
        let inkBounds: CGRect
        let cutout: CGRect
    }

    static func numberLayout(percent: Int, scale: CGFloat = 1, foreground: NSColor = .black,
                             placement: AIUsageMenuBarPreference.PercentagePlacement = .arcTop) -> NumberLayout {
        let fontSize = placement == .beside ? MenuArcMetrics.besideDigitFontSize : MenuArcMetrics.digitFontSize
        // Semibold keeps the rounded digits readable at 1x and 2x, including the 44pt panel.
        let descriptor = NSFont.systemFont(ofSize: fontSize, weight: MenuArcMetrics.digitWeight).fontDescriptor
            .withDesign(.rounded)!
            .addingAttributes([.featureSettings: [[NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
                                                  .selectorIdentifier: kMonospacedNumbersSelector]]])
        let label = NSAttributedString(string: placement == .beside ? "\(percent)%" : String(percent), attributes: [
            .font: NSFont(descriptor: descriptor, size: fontSize)!,
            .foregroundColor: foreground, .kern: placement == .beside ? 0 : MenuArcMetrics.digitKerning
        ])
        let line = CTLineCreateWithAttributedString(label)
        let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        if placement == .beside {
            // Center the glyph ink, independent of the font's line height and baseline grid.
            let baseline = MenuArcMetrics.segmentSize / 2 + bounds.midY
            return NumberLayout(line: line, baseline: baseline,
                inkBounds: CGRect(x: MenuArcMetrics.segmentSize + MenuArcMetrics.besideGap + bounds.minX, y: baseline - bounds.maxY,
                                  width: bounds.width, height: bounds.height), cutout: .zero)
        }
        // Keep the ink inside the image, with clearance before pixel alignment.
        // Whole-pixel baselines preserve crisp digits at both 1x and 2x.
        let baseline = ceil(max(MenuArcMetrics.digitCenterY + bounds.midY, bounds.maxY + MenuArcMetrics.digitTopClearance) * scale) / scale
        let inkBounds = CGRect(x: MenuArcMetrics.segmentSize / 2 - bounds.width / 2, y: baseline - bounds.maxY,
                               width: bounds.width, height: bounds.height)
        let width = inkBounds.width + 2 * MenuArcMetrics.digitCutoutPadding
        let cutout = CGRect(x: (MenuArcMetrics.segmentSize - width) / 2, y: inkBounds.midY - fontSize / 2,
                            width: width, height: fontSize)
        return NumberLayout(line: line, baseline: baseline, inkBounds: inkBounds, cutout: cutout)
    }

    static func segmentWidth(percent: Double?, showPercentage: Bool,
                             placement: AIUsageMenuBarPreference.PercentagePlacement) -> CGFloat {
        guard showPercentage, placement == .beside, let percent else { return MenuArcMetrics.segmentSize }
        let line = numberLayout(percent: Int(percent.rounded()), placement: .beside).line
        return ceil(MenuArcMetrics.segmentSize + MenuArcMetrics.besideGap + CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)))
    }

    static func fillColor(percent: Double, colorsByQuota: Bool = true, foreground: NSColor = .labelColor) -> NSColor {
        guard colorsByQuota else { return foreground }
        switch QuotaArc.colorLevel(percent: percent) {
        case .green: return .systemGreen
        case .orange: return .systemOrange
        case .red: return .systemRed
        }
    }

    static func image(snapshots: [AIUsageSnapshot], showPercentage: Bool,
                      colorsByQuota: Bool = SubscriptionPreferences().colorsByQuota,
                      placement: AIUsageMenuBarPreference.PercentagePlacement = .arcTop) -> NSImage {
        let ordered = snapshots
        let percentages = ordered.map { snapshot in
            snapshot.isConnected && snapshot.error == nil
                ? snapshot.windows.compactMap { AIUsageMenuBarController.remaining($0.remainingPercent) }.first : nil
        }
        let widths = percentages.map { segmentWidth(percent: $0, showPercentage: showPercentage, placement: placement) }
        let width = widths.reduce(0, +) + CGFloat(max(0, ordered.count - 1)) * MenuArcMetrics.segmentGap
        let image = NSImage(size: NSSize(width: width, height: MenuArcMetrics.segmentSize), flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let dark = NSAppearance.currentDrawing().bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let foreground: NSColor = dark ? .white : .black
            var x: CGFloat = 0
            for (index, snapshot) in ordered.enumerated() {
                context.saveGState()
                context.translateBy(x: x, y: 0)
                drawSegment(provider: snapshot.provider, percent: percentages[index], showPercentage: showPercentage,
                            foreground: foreground, colorsByQuota: colorsByQuota, context: context, placement: placement)
                context.restoreGState()
                x += widths[index] + MenuArcMetrics.segmentGap
            }
            return true
        }
        // Layout stays in points. Resolve foreground and system colors on every draw.
        image.isTemplate = false
        return image
    }

    /// The panel scales the shared menu coordinate system to its own canvas size.
    static func segmentImage(provider: AIUsageProvider, percent: Double?, size: CGFloat,
                             foreground: NSColor, showPercentage: Bool = true,
                             colorsByQuota: Bool = SubscriptionPreferences().colorsByQuota) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.saveGState()
            context.scaleBy(x: size / MenuArcMetrics.segmentSize, y: size / MenuArcMetrics.segmentSize)
            drawSegment(provider: provider, percent: percent, showPercentage: showPercentage,
                        foreground: foreground, colorsByQuota: colorsByQuota, context: context)
            context.restoreGState()
            return true
        }
        image.isTemplate = false
        return image
    }

    private static func drawSegment(provider: AIUsageProvider, percent: Double?, showPercentage: Bool,
                                    foreground: NSColor, colorsByQuota: Bool, context: CGContext,
                                    placement: AIUsageMenuBarPreference.PercentagePlacement = .arcTop) {
        let number = showPercentage ? percent.map { Int($0.rounded()) } : nil
        let layout = number.map {
            numberLayout(percent: $0, scale: hypot(context.ctm.c, context.ctm.d), foreground: foreground, placement: placement)
        }
        // destinationOut affects only this segment, preserving the menu-bar background.
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        context.saveGState()
        if let layout, placement == .arcTop {
            // Clip only the arcs; the logo and digits retain their full alpha.
            let clip = CGMutablePath()
            clip.addRect(CGRect(x: 0, y: 0, width: MenuArcMetrics.segmentSize, height: MenuArcMetrics.segmentSize))
            clip.addRoundedRect(in: layout.cutout,
                                cornerWidth: MenuArcMetrics.digitFontSize * MenuArcMetrics.digitCutoutCornerRatio, cornerHeight: MenuArcMetrics.digitFontSize * MenuArcMetrics.digitCutoutCornerRatio)
            context.addPath(clip)
            context.clip(using: .evenOdd)
        }
        context.setLineWidth(MenuArcMetrics.lineWidth)
        context.setLineCap(.round)
        context.setStrokeColor(foreground.withAlphaComponent(MenuArcMetrics.trackOpacity).cgColor)
        context.addPath(QuotaArc.path(size: MenuArcMetrics.segmentSize, lineWidth: MenuArcMetrics.lineWidth).cgPath)
        context.strokePath()
        if let percent {
            context.setStrokeColor(fillColor(percent: percent, colorsByQuota: colorsByQuota, foreground: foreground).cgColor)
            context.addPath(QuotaArc.path(size: MenuArcMetrics.segmentSize, lineWidth: MenuArcMetrics.lineWidth, percent: percent).cgPath)
            context.strokePath()
        }
        context.restoreGState()

        drawLogo(provider: provider, showPercentage: layout != nil, foreground: foreground,
                 context: context, placement: placement)
        if let layout { drawNumber(layout, context: context) }
        context.endTransparencyLayer()
    }

    static func drawLogo(provider: AIUsageProvider, showPercentage: Bool, foreground: NSColor,
                         context: CGContext,
                         placement: AIUsageMenuBarPreference.PercentagePlacement = .arcTop) {
        let scale = hypot(context.ctm.c, context.ctm.d)
        let logoRect = logoRect(showPercentage: showPercentage, scale: scale, placement: placement)
        let glyph = abs(scale - 1) < 0.001
            ? SubscriptionGlyph.pixelImage(provider, side: Int(logoRect.width.rounded())) : SubscriptionGlyph.image(provider)
        // Isolate sourceIn so tinting cannot recolor the arcs underneath.
        context.saveGState()
        // Keep enlarged ink inside the arc with a moat, including its end caps.
        // Account for the device pixel footprint when clipping at 1x/2x.
        // The open bottom of the arc remains available to the larger glyph.
        let clearance = MenuArcMetrics.logoClearance + sqrt(0.5) / scale
        let safe = CGMutablePath()
        safe.addRect(CGRect(x: 0, y: 0, width: MenuArcMetrics.segmentSize, height: MenuArcMetrics.segmentSize))
        safe.addPath(QuotaArc.path(size: MenuArcMetrics.segmentSize, lineWidth: MenuArcMetrics.lineWidth).cgPath.copy(
            strokingWithWidth: MenuArcMetrics.lineWidth + 2 * clearance, lineCap: .round,
            lineJoin: .round, miterLimit: 0))
        context.addPath(safe)
        if abs(scale - 1) < 0.001 { context.setShouldAntialias(false) }
        context.clip(using: .evenOdd)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        if abs(scale - 1) < 0.001 { NSGraphicsContext.current?.imageInterpolation = .none }
        glyph.draw(in: logoRect, from: .zero,
            operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        context.setBlendMode(.sourceIn)
        context.setFillColor(foreground.cgColor)
        context.fill(logoRect)
        context.endTransparencyLayer()
        context.restoreGState()
    }

    static func drawNumber(_ layout: NumberLayout, context: CGContext) {
        let bounds = CTLineGetBoundsWithOptions(layout.line, .useGlyphPathBounds)
        context.saveGState()
        if !layout.cutout.isEmpty {
            let path = CGMutablePath()
            for run in CTLineGetGlyphRuns(layout.line) as! [CTRun] {
                let font = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as! CTFont
                let count = CTRunGetGlyphCount(run)
                var glyphs = [CGGlyph](repeating: 0, count: count)
                var positions = [CGPoint](repeating: .zero, count: count)
                CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
                CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
                for index in 0..<count {
                    if let glyph = CTFontCreatePathForGlyph(font, glyphs[index], nil) {
                        path.addPath(glyph, transform: CGAffineTransform(translationX: positions[index].x, y: positions[index].y))
                    }
                }
            }
            context.saveGState()
            context.translateBy(x: layout.inkBounds.minX - bounds.minX, y: layout.baseline)
            context.scaleBy(x: 1, y: -1)
            context.setBlendMode(.destinationOut)
            context.setFillColor(NSColor.black.cgColor)
            context.setStrokeColor(NSColor.black.cgColor)
            context.setLineWidth(2 * MenuArcMetrics.digitKnockoutPadding)
            context.setLineJoin(.round)
            context.addPath(path)
            context.drawPath(using: .fillStroke)
            context.restoreGState()
        }
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.textPosition = CGPoint(x: layout.inkBounds.minX - bounds.minX, y: layout.baseline)
        CTLineDraw(layout.line, context)
        context.restoreGState()
    }
}

struct MenuBarPercentageToggle: View {
    @AppStorage(AIUsageMenuBarPreference.percentageKey) private var showPercentage = true
    var body: some View {
        Toggle(L10n.text("panel.showPercentageInMenuBar"), isOn: $showPercentage)
            .toggleStyle(SettingsSwitchStyle()).font(.callout)
            .accessibilityIdentifier("ai-usage.menu-bar-percentage")
    }
}
