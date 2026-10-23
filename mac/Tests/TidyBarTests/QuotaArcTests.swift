import AppKit
import Combine
import CoreText
import Testing
@testable import TidyBar

extension TidyBarTests {
    @Test func quotaArcStartsOnRightAndTraversesTheTopToTheLeft() {
        #expect(QuotaArc.path(size: MenuArcMetrics.segmentSize, lineWidth: MenuArcMetrics.lineWidth, percent: 0).isEmpty)
        #expect(QuotaArc.end(percent: 100) == MenuArcMetrics.arcStart - MenuArcMetrics.arcSweep)
        let start = QuotaArc.point(size: MenuArcMetrics.segmentSize, lineWidth: MenuArcMetrics.lineWidth, angle: QuotaArc.start)
        let end = QuotaArc.point(size: MenuArcMetrics.segmentSize, lineWidth: MenuArcMetrics.lineWidth, angle: QuotaArc.end(percent: 100))
        #expect(start.x > MenuArcMetrics.segmentSize / 2 && start.y > MenuArcMetrics.segmentSize / 2)
        #expect(end.x < MenuArcMetrics.segmentSize / 2 && end.y > MenuArcMetrics.segmentSize / 2)
        #expect(abs(start.y - end.y) < 0.0001)
        // 50% must cover the right side and finish exactly at the top, not the bottom.
        let half = QuotaArc.path(size: MenuArcMetrics.segmentSize, lineWidth: MenuArcMetrics.lineWidth, percent: 50).boundingRect
        #expect(abs(half.minX - MenuArcMetrics.segmentSize / 2) < 0.0001)
        #expect(abs(half.minY - MenuArcMetrics.lineWidth / 2) < 0.0001)
        // CoreGraphics approximates the circle with cubic curves (subpixel overshoot).
        #expect(abs(half.maxX - (MenuArcMetrics.segmentSize - MenuArcMetrics.lineWidth / 2)) < 0.001)
        #expect(abs(half.maxY - start.y) < 0.0001)
        for percent in [15.0, 18, 45, 72] {
            #expect(abs((QuotaArc.start - QuotaArc.end(percent: percent)) - MenuArcMetrics.arcSweep * percent / 100) < 0.0001)
        }
    }

    @Test func quotaArcColorThresholds() {
        for percent in [100.0, 50] { #expect(QuotaArc.colorLevel(percent: percent) == .green) }
        for percent in [49.0, 20] { #expect(QuotaArc.colorLevel(percent: percent) == .orange) }
        for percent in [19.0, 0] { #expect(QuotaArc.colorLevel(percent: percent) == .red) }
    }

    @MainActor @Test func arcStrokeFitsTwentyTwoPointCanvasAtBothScales() throws {
        let size = MenuArcMetrics.segmentSize
        let radius = QuotaArc.point(size: size, lineWidth: MenuArcMetrics.lineWidth, angle: 0).x - size / 2
        #expect(abs(radius - 10.15) < 0.0001)
        #expect(abs(radius + MenuArcMetrics.lineWidth / 2 - size / 2) < 0.0001)
        let padding: CGFloat = 4
        for percent in [15.0, 50, 100] {
            let path = QuotaArc.path(size: size, lineWidth: MenuArcMetrics.lineWidth, percent: percent).cgPath
            let bounds = path.copy(strokingWithWidth: MenuArcMetrics.lineWidth, lineCap: .round,
                                   lineJoin: .round, miterLimit: 0).boundingBoxOfPath
            #expect(bounds.minX >= -0.001 && bounds.minY >= -0.001)
            #expect(bounds.maxX <= size + 0.001 && bounds.maxY <= size + 0.001)
            let image = NSImage(size: NSSize(width: size + 2 * padding, height: size + 2 * padding), flipped: true) { _ in
                let context = NSGraphicsContext.current!.cgContext
                context.translateBy(x: padding, y: padding)
                context.setLineWidth(MenuArcMetrics.lineWidth)
                context.setLineCap(.round)
                context.addPath(path)
                context.strokePath()
                return true
            }
            for scale in [1, 2] {
                let bitmap = try Self.renderMenu(image, scale: scale)
                for y in 0..<bitmap.pixelsHigh {
                    for x in 0..<bitmap.pixelsWide where x < Int(padding) * scale || y < Int(padding) * scale
                        || x >= Int(padding + size) * scale || y >= Int(padding + size) * scale {
                        #expect(try #require(bitmap.colorAt(x: x, y: y)).alphaComponent == 0)
                    }
                }
            }
        }
    }

    @MainActor @Test func arcTopAndPercentageOffLogosShareTheArcCenter() {
        for scale in [CGFloat(1), 2, MenuArcMetrics.panelSize / MenuArcMetrics.segmentSize,
                      2 * MenuArcMetrics.panelSize / MenuArcMetrics.segmentSize] {
            for showPercentage in [false, true] {
                let rect = QuotaMenuImage.logoRect(showPercentage: showPercentage, scale: scale)
                #expect(rect.midX == 11 && rect.midY == 11)
                #expect(rect.width * scale == (rect.width * scale).rounded())
            }
        }
        #expect(MenuArcMetrics.digitFontSize == 6.8)
        #expect(MenuArcMetrics.logoClearance >= 0.5)
        #expect(MenuArcMetrics.logoSizeWithPercent == 12.04)
        #expect(MenuArcMetrics.logoSizeWithoutPercent == 13.81)
    }

    @MainActor @Test func arcTopDigitsKnockOutTheirExpandedGlyphsBeforeDrawingOnTop() throws {
        #expect(MenuArcMetrics.digitKnockoutPadding == 0.6)
        for scale in [1, 2] {
            for foreground in [NSColor.black, .white] {
                for percent in [8, 15, 35, 100] {
                    let layout = QuotaMenuImage.numberLayout(percent: percent, scale: CGFloat(scale), foreground: foreground)
                    let image = NSImage(size: NSSize(width: 22, height: 22), flipped: true) { _ in
                        let context = NSGraphicsContext.current!.cgContext
                        context.beginTransparencyLayer(auxiliaryInfo: nil)
                        context.setFillColor(foreground.cgColor)
                        context.fill(CGRect(x: 0, y: 0, width: 22, height: 22))
                        QuotaMenuImage.drawNumber(layout, context: context)
                        context.endTransparencyLayer()
                        return true
                    }
                    let bitmap = try Self.renderMenu(image, scale: scale)
                    let text = NSImage(size: image.size, flipped: true) { _ in
                        QuotaMenuImage.drawNumber(layout, context: NSGraphicsContext.current!.cgContext)
                        return true
                    }
                    let digits = try Self.renderMenu(text, scale: scale)
                    var clearedPixels = 0, digitPixels = 0
                    for y in 0..<bitmap.pixelsHigh {
                        for x in 0..<bitmap.pixelsWide {
                            let alpha = try #require(bitmap.colorAt(x: x, y: y)).alphaComponent
                            let digitAlpha = try #require(digits.colorAt(x: x, y: y)).alphaComponent
                            if alpha < 0.9 { clearedPixels += 1 }
                            if digitAlpha > 0.5 {
                                digitPixels += 1
                                #expect(alpha >= digitAlpha - 0.01)
                            }
                            let point = CGPoint(x: (CGFloat(x) + 0.5) / CGFloat(scale), y: (CGFloat(y) + 0.5) / CGFloat(scale))
                            if !layout.inkBounds.insetBy(dx: -1.6, dy: -1.6).contains(point) { #expect(alpha == 1) }
                        }
                    }
                    #expect(clearedPixels > 0 && digitPixels > 0)
                    // Erasing a segment must leave the opaque menu-bar background intact.
                    let composite = try Self.renderMenu(image, scale: scale, background: foreground == .black ? 0xF6F6F8 : 0x1C1C20)
                    for y in 0..<composite.pixelsHigh {
                        for x in 0..<composite.pixelsWide {
                            #expect(try #require(composite.colorAt(x: x, y: y)).alphaComponent == 1)
                        }
                    }
                }
            }
        }
    }

    @MainActor @Test func menuArcUsesTemplateGlyphsWithFixedPointLayout() {
        for provider in [AIUsageProvider.codex, .claude, .grok] {
            #expect(SubscriptionGlyph.image(provider).isValid)
            #expect(SubscriptionGlyph.image(provider).isTemplate)
        }
        let without = QuotaMenuImage.image(snapshots: Self.menuSnapshots, showPercentage: false)
        let with = QuotaMenuImage.image(snapshots: Self.menuSnapshots, showPercentage: true)
        #expect(!with.isTemplate && !without.isTemplate)
        #expect(with.representations.contains { $0 is NSCustomImageRep })
        #expect(without.size == NSSize(width: Self.menuWidth, height: MenuArcMetrics.segmentSize))
        #expect(with.size == without.size)
        #expect(MenuArcMetrics.segmentSize == 22)
        #expect(with.size.height == 22)
        #expect(MenuArcMetrics.lineWidth == 1.7)
        #expect(QuotaMenuImage.image(snapshots: Array(Self.menuSnapshots.prefix(2)), showPercentage: false).size.width == 2 * MenuArcMetrics.segmentSize + MenuArcMetrics.segmentGap)
        #expect(abs(QuotaMenuImage.logoSize(showPercentage: true) - MenuArcMetrics.logoSizeWithPercent) < 0.0001)
        #expect(abs(QuotaMenuImage.logoSize(showPercentage: false) - MenuArcMetrics.logoSizeWithoutPercent) < 0.0001)
        let besideLogo = QuotaMenuImage.logoSize(showPercentage: true, placement: .beside)
        #expect(besideLogo < QuotaMenuImage.logoSize(showPercentage: true))
        #expect(besideLogo == 11.30)
    }

    @MainActor @Test func enlargedLogosKeepClearOfArcInk() throws {
        for provider in [AIUsageProvider.codex, .claude, .grok] {
            for (percentage, placement) in [(false, AIUsageMenuBarPreference.PercentagePlacement.arcTop),
                                             (true, .arcTop), (true, .beside)] {
                let side = Int(QuotaMenuImage.logoRect(showPercentage: percentage, scale: 1, placement: placement).width)
                let raster = SubscriptionGlyph.pixelImage(provider, side: side)
                #expect(raster.size.width == CGFloat(side))
                #expect(raster === SubscriptionGlyph.pixelImage(provider, side: side))
                for pointSize in [MenuArcMetrics.segmentSize, MenuArcMetrics.panelSize] {
                    for scale in [1, 2] {
                        let factor = pointSize / MenuArcMetrics.segmentSize
                        let logo = NSImage(size: NSSize(width: pointSize, height: pointSize), flipped: true) { _ in
                            let context = NSGraphicsContext.current!.cgContext
                            context.scaleBy(x: factor, y: factor)
                            QuotaMenuImage.drawLogo(provider: provider, showPercentage: percentage,
                                foreground: .black, context: context, placement: placement)
                            return true
                        }
                        let ink = try Self.renderMenu(logo, scale: scale)
                        var count = 0
                        var minimumGap = MenuArcMetrics.segmentSize
                        for y in 0..<ink.pixelsHigh {
                            for x in 0..<ink.pixelsWide {
                                let alpha = ink.colorAt(x: x, y: y)!.alphaComponent
                                if alpha > 0.5 {
                                    count += 1
                                    let point = CGPoint(x: (CGFloat(x) + 0.5) / (CGFloat(scale) * factor),
                                                        y: (CGFloat(y) + 0.5) / (CGFloat(scale) * factor))
                                    let dx = point.x - MenuArcMetrics.segmentSize / 2, dy = point.y - MenuArcMetrics.segmentSize / 2
                                    var angle = atan2(dy, dx) * 180 / .pi
                                    if angle < 0 { angle += 360 }
                                    let radius = (MenuArcMetrics.segmentSize - MenuArcMetrics.lineWidth) / 2
                                    let distance: CGFloat
                                    if angle > QuotaArc.start && angle < 360 + QuotaArc.end(percent: 100) {
                                        let a = QuotaArc.point(size: MenuArcMetrics.segmentSize, lineWidth: MenuArcMetrics.lineWidth, angle: QuotaArc.start)
                                        let b = QuotaArc.point(size: MenuArcMetrics.segmentSize, lineWidth: MenuArcMetrics.lineWidth, angle: QuotaArc.end(percent: 100))
                                        distance = min(hypot(point.x - a.x, point.y - a.y),
                                                       hypot(point.x - b.x, point.y - b.y))
                                    } else { distance = abs(hypot(dx, dy) - radius) }
                                    minimumGap = min(minimumGap, distance - MenuArcMetrics.lineWidth / 2)
                                }
                            }
                        }
                        #expect(count > Int(10 * factor * factor))
                        #expect(minimumGap >= MenuArcMetrics.logoClearance - 0.01, "\(provider) pct=\(percentage) size=\(pointSize) scale=\(scale): \(minimumGap)")
                    }
                }
            }
        }
    }

    @MainActor @Test func grokUsesPublicTemplateSVGAtMenuScales() throws {
        let source = SharedResources.url("grok.svg", directory: "logos/subscriptions")
        #expect(try String(contentsOf: source, encoding: .utf8).contains("<title>Grok</title>"))
        #expect(SubscriptionGlyph.image(.grok).isTemplate)
        for side in [11, 14, 18, 24] {
            let image = SubscriptionGlyph.pixelImage(.grok, side: side)
            #expect(image.isTemplate)
            let bitmap = try #require(image.representations.first as? NSBitmapImageRep)
            var opaque = 0, transparent = 0
            for y in 0..<side {
                for x in 0..<side {
                    if bitmap.colorAt(x: x, y: y)!.alphaComponent == 1 { opaque += 1 }
                    else { transparent += 1 }
                }
            }
            #expect(opaque > side)
            #expect(transparent > side)
        }
    }

    @MainActor @Test func subscriptionPresentationUsesOnlyExistingSubscriptionsInTheRequestedOrder() {
        let store = AIUsageStore(applyDisplayFilters: false, fetcher: { _ in throw AIUsageError.signedOut })
        store.snapshots = Array(UsageSnapshotFixture.snapshots.reversed()) + [
            AIUsageSnapshot(provider: .openaiAPI, isConnected: true, status: "fixture", source: "fixture")
        ]
        #expect(store.subscriptionDisplaySnapshots.map(\.provider) == [.codex, .claude, .grok, .openaiAPI])
        store.snapshots.removeAll { $0.provider == .claude }
        #expect(store.subscriptionDisplaySnapshots.map(\.provider) == [.codex, .grok, .openaiAPI])
        #expect(store.snapshots.contains { $0.provider == .openaiAPI })
    }

    @MainActor @Test func oneXLogosReduceIntermediateAlphaWithoutLosingTheirInk() throws {
        for provider in [AIUsageProvider.codex, .claude, .grok] {
            for percentage in [false, true] {
                let side = QuotaMenuImage.logoSize(showPercentage: percentage)
                let oldRect = CGRect(x: (MenuArcMetrics.segmentSize - side) / 2, y: (MenuArcMetrics.segmentSize - side) / 2 + (percentage ? 0.6 : 0),
                                     width: side, height: side)
                let old = NSImage(size: NSSize(width: MenuArcMetrics.segmentSize, height: MenuArcMetrics.segmentSize), flipped: true) { _ in
                    SubscriptionGlyph.image(provider).draw(in: oldRect, from: .zero,
                        operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                    return true
                }
                let new = NSImage(size: old.size, flipped: true) { _ in
                    guard let context = NSGraphicsContext.current?.cgContext else { return false }
                    QuotaMenuImage.drawLogo(provider: provider, showPercentage: percentage,
                                           foreground: .black, context: context)
                    return true
                }
                func metrics(_ image: NSImage) throws -> (intermediate: Int, ink: CGFloat) {
                    let bitmap = try Self.renderMenu(image, scale: 1)
                    var intermediate = 0
                    var ink: CGFloat = 0
                    for y in 0..<bitmap.pixelsHigh {
                        for x in 0..<bitmap.pixelsWide {
                            let alpha = try #require(bitmap.colorAt(x: x, y: y)).alphaComponent
                            if (0.2...0.8).contains(alpha) { intermediate += 1 }
                            ink += alpha
                        }
                    }
                    return (intermediate, ink)
                }
                let before = try metrics(old), after = try metrics(new)
                print("1x logo \(provider.rawValue) percentage=\(percentage): intermediate pixels \(before.intermediate) -> \(after.intermediate); ink \(before.ink) -> \(after.ink)")
                #expect(before.intermediate > 0)
                #expect(Double(after.intermediate) <= Double(before.intermediate) * 0.7)
                #expect(after.ink >= before.ink * 0.65)
                #expect(after.ink <= before.ink * 1.5)
            }
        }
    }

    @MainActor @Test func menuImageKeepsPointSizeAndAllThreeSegmentsAtBothScales() throws {
        for showPercentage in [false, true] {
            let image = QuotaMenuImage.image(snapshots: Self.menuSnapshots, showPercentage: showPercentage)
            for scale in [1, 2] {
                let bitmap = try Self.renderMenu(image, scale: scale)
                #expect(image.size == NSSize(width: Self.menuWidth, height: MenuArcMetrics.segmentSize))
                #expect(bitmap.size == image.size)
                #expect(bitmap.pixelsWide == Int(Self.menuWidth) * scale)
                #expect(bitmap.pixelsHigh == Int(MenuArcMetrics.segmentSize) * scale)
                // All three 22pt segments survive 1x and Retina drawing, with 7pt gaps.
                for segment in 0..<3 {
                    let origin = segment * Int(MenuArcMetrics.segmentSize + MenuArcMetrics.segmentGap) * scale
                    let middle = Int(MenuArcMetrics.segmentSize / 2) * scale
                    #expect(try #require(bitmap.colorAt(x: origin + scale, y: middle)).alphaComponent > 0)
                    #expect(try #require(bitmap.colorAt(x: origin + Int(MenuArcMetrics.segmentSize - 1) * scale, y: middle)).alphaComponent > 0)
                    #expect(try #require(bitmap.colorAt(x: origin + Int(MenuArcMetrics.segmentSize * 2 / 9) * scale, y: Int(MenuArcMetrics.segmentSize * 5 / 6) * scale)).alphaComponent > 0)
                    if !showPercentage {
                        #expect(try #require(bitmap.colorAt(x: origin + middle, y: 0)).alphaComponent > 0)
                    }
                    if segment < 2 {
                        #expect(try #require(bitmap.colorAt(x: origin + Int(MenuArcMetrics.segmentSize + MenuArcMetrics.segmentGap / 2) * scale, y: middle)).alphaComponent == 0)
                    }
                }
            }
        }
    }

    @MainActor @Test func percentageDigitsUseSemiboldRoundedMonospacedFontInMenuAndPanel() throws {
        let descriptor = NSFont.systemFont(ofSize: MenuArcMetrics.digitFontSize, weight: MenuArcMetrics.digitWeight)
            .fontDescriptor.withDesign(.rounded)!
        let expected = try #require(NSFont(descriptor: descriptor, size: MenuArcMetrics.digitFontSize))
        for scale in [CGFloat(1), CGFloat(2), MenuArcMetrics.panelSize / MenuArcMetrics.segmentSize, 2 * MenuArcMetrics.panelSize / MenuArcMetrics.segmentSize] {
            var advances: [Double] = []
            for digit in 0...9 {
                let layout = QuotaMenuImage.numberLayout(percent: digit, scale: scale)
                let run = try #require((CTLineGetGlyphRuns(layout.line) as? [CTRun])?.first)
                let attributes = CTRunGetAttributes(run) as NSDictionary
                let font = try #require(attributes[kCTFontAttributeName] as? NSFont)
                #expect(font.fontName == expected.fontName)
                advances.append(CTLineGetTypographicBounds(layout.line, nil, nil, nil))
            }
            #expect(try #require(advances.max()) - #require(advances.min()) < 0.0001)
        }
    }

    @MainActor @Test func percentageCutoutRemovesOnlyTheTopArc() throws {
        for scale in [CGFloat(1), CGFloat(2), MenuArcMetrics.panelSize / MenuArcMetrics.segmentSize, 2 * MenuArcMetrics.panelSize / MenuArcMetrics.segmentSize] {
            for number in 0...100 {
                let layout = QuotaMenuImage.numberLayout(percent: number, scale: scale)
                let rect = layout.cutout
                #expect(abs(rect.width - (layout.inkBounds.width + 2 * MenuArcMetrics.digitCutoutPadding)) < 0.0001)
                #expect(rect.contains(layout.inkBounds))
                #expect(rect.height == MenuArcMetrics.digitFontSize)
                #expect(rect.midX == MenuArcMetrics.segmentSize / 2)
                #expect(abs(rect.midY - layout.inkBounds.midY) < 0.0001)
            }
        }
        for scale in [1, 2] {
            let with = try Self.renderMenu(QuotaMenuImage.image(snapshots: Self.menuSnapshots, showPercentage: true), scale: scale)
            let without = try Self.renderMenu(QuotaMenuImage.image(snapshots: Self.menuSnapshots, showPercentage: false), scale: scale)
            for (segment, number) in [95, 35, 10].enumerated() {
                let cutout = QuotaMenuImage.numberLayout(percent: number, scale: CGFloat(scale)).cutout
                var removedArcPixels = 0
                for y in 0..<4 * scale {
                    for x in 0..<Int(MenuArcMetrics.segmentSize) * scale where cutout.contains(
                        CGPoint(x: (CGFloat(x) + 0.5) / CGFloat(scale), y: (CGFloat(y) + 0.5) / CGFloat(scale))) {
                        let before = try #require(without.colorAt(x: segment * Int(MenuArcMetrics.segmentSize + MenuArcMetrics.segmentGap) * scale + x, y: y)).alphaComponent
                        let after = try #require(with.colorAt(x: segment * Int(MenuArcMetrics.segmentSize + MenuArcMetrics.segmentGap) * scale + x, y: y)).alphaComponent
                        // The thinner stroke and smaller digits can share an antialiased
                        // pixel at 1x; check reduced arc coverage rather than exact zero.
                        if before - after > 0.1 { removedArcPixels += 1 }
                    }
                }
                #expect(removedArcPixels > 0, "number=\(number) scale=\(scale)")
                // Both sides outside the digit cutout still carry the arc.
                for side in [0..<Int(MenuArcMetrics.segmentSize / 6), Int(MenuArcMetrics.segmentSize * 5 / 6)..<Int(MenuArcMetrics.segmentSize)] {
                    let coverage = try side.flatMap { x in
                        try (0..<scale).map { offset in
                            try #require(with.colorAt(x: segment * Int(MenuArcMetrics.segmentSize + MenuArcMetrics.segmentGap) * scale + x * scale + offset, y: Int(MenuArcMetrics.segmentSize / 2) * scale)).alphaComponent
                        }
                    }
                    #expect(try #require(coverage.max()) > 0.25)
                }
            }
        }
    }

    @MainActor @Test func percentageDigitsKeepAllInkInsideTheTopEdgeAtBothScales() throws {
        for scale in [1, 2] {
            let menu = try Self.renderMenu(QuotaMenuImage.image(snapshots: Self.menuSnapshots, showPercentage: true), scale: scale)
            for number in [0, 1, 8, 10, 35, 95, 100] {
                let layout = QuotaMenuImage.numberLayout(percent: number, scale: CGFloat(scale))
                #expect(layout.inkBounds.minY >= MenuArcMetrics.digitTopClearance)
                #expect(layout.inkBounds.maxY < MenuArcMetrics.segmentSize)
                #expect(layout.inkBounds.minY < MenuArcMetrics.digitCenterY && layout.inkBounds.maxY > MenuArcMetrics.digitCenterY)
                #expect(layout.baseline * CGFloat(scale) == (layout.baseline * CGFloat(scale)).rounded())
                // Draw beyond the menu's top boundary so clipped antialiasing cannot hide.
                let padding: CGFloat = 4
                let referenceImage = NSImage(size: NSSize(width: MenuArcMetrics.segmentSize, height: MenuArcMetrics.segmentSize + 8), flipped: true) { _ in
                    guard let context = NSGraphicsContext.current?.cgContext else { return false }
                    context.translateBy(x: 0, y: padding)
                    QuotaMenuImage.drawNumber(layout, context: context)
                    return true
                }
                let reference = try Self.renderMenu(referenceImage, scale: scale)
                var totalInk = 0
                for y in 0..<reference.pixelsHigh {
                    for x in 0..<Int(MenuArcMetrics.segmentSize) * scale {
                        let alpha = try #require(reference.colorAt(x: x, y: y)).alphaComponent
                        if y < Int(padding) * scale { #expect(alpha == 0) }
                        if y >= Int(padding + MenuArcMetrics.segmentSize) * scale { #expect(alpha == 0) }
                        if alpha > 0 { totalInk += 1 }
                        // Every reference digit pixel survives in the actual menu image.
                        if let segment = [95, 35, 10].firstIndex(of: number),
                           alpha > 0 {
                            let actual = try #require(menu.colorAt(x: segment * Int(MenuArcMetrics.segmentSize + MenuArcMetrics.segmentGap) * scale + x, y: y - Int(padding) * scale))
                            #expect(actual.alphaComponent >= alpha - 0.01)
                        }
                    }
                }
                #expect(totalInk >= 10)
            }
        }
    }

    @MainActor @Test func menuImageResolvesColorsAndGlyphsAtEachDrawingAppearance() throws {
        // Reuse one image, as the status button does when its appearance changes.
        let image = QuotaMenuImage.image(snapshots: Self.menuSnapshots, showPercentage: false)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let bitmap = try Self.renderMenu(image, scale: 2, appearance: appearance)
            let colors = try (0..<3).map { segment in
                try #require(bitmap.colorAt(x: segment * Int(MenuArcMetrics.segmentSize + MenuArcMetrics.segmentGap) * 2 + Int(MenuArcMetrics.segmentSize * 5 / 3), y: Int(MenuArcMetrics.segmentSize * 14 / 9))?.usingColorSpace(.deviceRGB))
            }
            #expect(colors[0].greenComponent > colors[0].redComponent)
            #expect(colors[0].greenComponent > colors[0].blueComponent)
            #expect(colors[1].redComponent > colors[1].greenComponent)
            #expect(colors[1].greenComponent > colors[1].blueComponent)
            #expect(colors[2].redComponent > colors[2].greenComponent * 1.5)
            #expect(colors[2].redComponent > colors[2].blueComponent * 1.5)
            let track = try #require(bitmap.colorAt(x: Int(MenuArcMetrics.segmentSize + MenuArcMetrics.segmentGap) * 2 + 2, y: Int(MenuArcMetrics.segmentSize))?.usingColorSpace(.deviceRGB))
            #expect(abs(track.alphaComponent - MenuArcMetrics.trackOpacity) < 0.02)
            #expect(appearance == .darkAqua ? track.redComponent > 0.95 : track.redComponent < 0.05)
            // A glyph-only mask excludes colored arcs inside the SVG's rectangular bounds.
            let maskImage = NSImage(size: NSSize(width: MenuArcMetrics.segmentSize, height: MenuArcMetrics.segmentSize), flipped: true) { _ in
                QuotaMenuImage.drawLogo(provider: .grok, showPercentage: false, foreground: .white,
                                       context: NSGraphicsContext.current!.cgContext)
                return true
            }
            let mask = try Self.renderMenu(maskImage, scale: 2, appearance: appearance)
            let origin = Int(MenuArcMetrics.segmentSize + MenuArcMetrics.segmentGap) * 4
            var opaqueGlyphPixels = 0
            for y in 0..<mask.pixelsHigh {
                for x in 0..<mask.pixelsWide where mask.colorAt(x: x, y: y)!.alphaComponent > 0.95 {
                    let logo = try #require(bitmap.colorAt(x: origin + x, y: y)?.usingColorSpace(.deviceRGB))
                    opaqueGlyphPixels += 1
                    #expect(logo.alphaComponent > 0.9)
                    #expect(appearance == .darkAqua ? logo.redComponent > 0.95 : logo.redComponent < 0.05)
                }
            }
            #expect(opaqueGlyphPixels > 10)
        }
    }

    @MainActor @Test func missingMenuQuotaKeepsTrackAndLogoWithoutDigitsOrFill() throws {
        for variant in 0..<3 {
            var snapshot = Self.menuSnapshots[0]
            if variant == 0 { snapshot.isConnected = false }
            if variant == 1 { snapshot.windows = [] }
            if variant == 2 { snapshot.error = "offline fixture" }
            let bitmap = try Self.renderMenu(QuotaMenuImage.image(snapshots: [snapshot], showPercentage: true), scale: 2)
            let top = try #require(bitmap.colorAt(x: Int(MenuArcMetrics.segmentSize), y: 1)?.usingColorSpace(.deviceRGB))
            #expect(abs(top.alphaComponent - MenuArcMetrics.trackOpacity) < 0.02)
            let start = try #require(bitmap.colorAt(x: Int(MenuArcMetrics.segmentSize * 5 / 3), y: Int(MenuArcMetrics.segmentSize * 14 / 9))?.usingColorSpace(.deviceRGB))
            #expect(abs(start.alphaComponent - MenuArcMetrics.trackOpacity) < 0.02)
            var logoPixels = 0
            for y in 12..<26 {
                for x in 10..<26 {
                    if try #require(bitmap.colorAt(x: x, y: y)).alphaComponent > 0.5 { logoPixels += 1 }
                }
            }
            #expect(logoPixels > 0)
        }
    }

    @MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["SG_PREVIEW_DIR"] != nil))
    func menuBarV9Previews() throws {
        let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["SG_PREVIEW_DIR"]), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for dark in [false, true] {
            for (mode, percentage, placement) in [
                ("nopct", false, AIUsageMenuBarPreference.PercentagePlacement.arcTop),
                ("pct", true, .arcTop), ("beside", true, .beside)
            ] {
                for scale in [1, 2] {
                    let image = QuotaMenuImage.image(snapshots: Self.menuSnapshots, showPercentage: percentage, placement: placement)
                    let bitmap = try Self.renderMenu(image, scale: scale, appearance: dark ? .darkAqua : .aqua,
                                                     margin: 8, background: dark ? 0x1C1C20 : 0xF6F6F8, canvasHeight: 22)
                    let filename = "v9-impl-\(dark ? "dark" : "light")-\(mode)-\(scale)x.png"
                    let png = try #require(bitmap.representation(using: .png, properties: [:]))
                    try png.write(to: directory.appendingPathComponent(filename))
                    #expect(bitmap.pixelsWide == Int(image.size.width + 16) * scale)
                    #expect(bitmap.pixelsHigh == 22 * scale)
                }
            }
        }
    }

    @MainActor @Test func percentagePlacementDefaultsAndSavedValuesPersist() throws {
        let name = "menu-placement-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(AIUsageMenuBarPreference.showsPercentage(defaults: defaults))
        #expect(AIUsageMenuBarPreference.percentagePlacement(defaults: defaults) == .arcTop)
        for placement in AIUsageMenuBarPreference.PercentagePlacement.allCases {
            defaults.set(placement.rawValue, forKey: AIUsageMenuBarPreference.placementKey)
            let reopened = try #require(UserDefaults(suiteName: name))
            #expect(AIUsageMenuBarPreference.percentagePlacement(defaults: reopened) == placement)
        }
        defaults.set("unknown", forKey: AIUsageMenuBarPreference.placementKey)
        #expect(AIUsageMenuBarPreference.percentagePlacement(defaults: defaults) == .arcTop)
    }

    @MainActor @Test func menuPercentagePreferenceChangesNotifyDrawingObservers() async throws {
        let name = "menu-redraw-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        var images: [NSImage] = []
        let observer = NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).sink { _ in
            Task { @MainActor in
                images.append(QuotaMenuImage.image(snapshots: Self.menuSnapshots,
                    showPercentage: AIUsageMenuBarPreference.showsPercentage(defaults: defaults),
                    placement: AIUsageMenuBarPreference.percentagePlacement(defaults: defaults)))
            }
        }
        defer { observer.cancel() }
        for (percentage, placement) in [(true, "beside"), (false, "beside"), (true, "arcTop")] {
            images.removeAll()
            defaults.set(percentage, forKey: AIUsageMenuBarPreference.percentageKey)
            defaults.set(placement, forKey: AIUsageMenuBarPreference.placementKey)
            for _ in 0..<50 where images.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
            let image = try #require(images.last)
            #expect(image.size.height == MenuArcMetrics.segmentSize)
            #expect(percentage && placement == "beside" ? image.size.width > Self.menuWidth : image.size.width == Self.menuWidth)
        }
    }

    @MainActor @Test func besidePercentageKeepsFullArcsAndSmallerLogosWithWiderPointLayout() throws {
        let beside = QuotaMenuImage.image(snapshots: Self.menuSnapshots, showPercentage: true, placement: .beside)
        #expect(beside.size.width > Self.menuWidth)
        #expect(beside.size.height == MenuArcMetrics.segmentSize)
        for scale in [1, 2] {
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                let bitmap = try Self.renderMenu(beside, scale: scale, appearance: appearance)
                let noDigits = try Self.renderMenu(QuotaMenuImage.image(snapshots: Self.menuSnapshots,
                    showPercentage: false), scale: scale, appearance: appearance)
                #expect(bitmap.pixelsHigh == Int(MenuArcMetrics.segmentSize) * scale)
                var origin = 0
                for (index, percent) in [95.0, 35, 10].enumerated() {
                    let width = Int(QuotaMenuImage.segmentWidth(percent: percent, showPercentage: true, placement: .beside))
                    // Arc ink outside the logo's bounds matches percentage-off rendering.
                    for y in 0..<Int(MenuArcMetrics.segmentSize) * scale {
                        for x in 0..<Int(MenuArcMetrics.segmentSize) * scale {
                            let actual = try #require(bitmap.colorAt(x: origin * scale + x, y: y))
                            let expected = try #require(noDigits.colorAt(x: index * Int(MenuArcMetrics.segmentSize + MenuArcMetrics.segmentGap) * scale + x, y: y))
                            let center = MenuArcMetrics.segmentSize / 2
                            let radius = hypot((CGFloat(x) + 0.5) / CGFloat(scale) - center,
                                               (CGFloat(y) + 0.5) / CGFloat(scale) - center)
                            if radius > center - MenuArcMetrics.lineWidth { #expect(actual == expected) }
                        }
                    }
                    #expect(try #require(bitmap.colorAt(x: (origin + Int(MenuArcMetrics.segmentSize / 2)) * scale, y: 0)).alphaComponent > 0)
                    var digitPixels = 0
                    var minY = Int(MenuArcMetrics.segmentSize) * scale, maxY = 0
                    for y in 0..<Int(MenuArcMetrics.segmentSize) * scale {
                        for x in Int(MenuArcMetrics.segmentSize) * scale..<width * scale {
                            let color = try #require(bitmap.colorAt(x: origin * scale + x, y: y)?.usingColorSpace(.deviceRGB))
                            if color.alphaComponent > 0.1 {
                                digitPixels += 1
                                // Center the solid ink; faint antialias fringes span partial pixels.
                                if color.alphaComponent > 0.5 { minY = min(minY, y); maxY = max(maxY, y) }
                                let foreground: CGFloat = appearance == .darkAqua ? 1 : 0
                                #expect(abs(color.redComponent - foreground) < 0.01)
                                #expect(abs(color.greenComponent - foreground) < 0.01)
                                #expect(abs(color.blueComponent - foreground) < 0.01)
                            }
                        }
                    }
                    #expect(digitPixels > 10 * scale)
                    #expect(abs(CGFloat(minY + maxY + 1) / 2 / CGFloat(scale) - MenuArcMetrics.segmentSize / 2) <= 0.5 / CGFloat(scale) + 0.0001)
                    if index < 2 {
                        for x in width * scale..<(width + Int(MenuArcMetrics.segmentGap)) * scale {
                            for y in 0..<Int(MenuArcMetrics.segmentSize) * scale {
                                #expect(try #require(bitmap.colorAt(x: origin * scale + x, y: y)).alphaComponent == 0)
                            }
                        }
                    }
                    origin += width + Int(MenuArcMetrics.segmentGap)
                }
            }
            let offBeside = try Self.renderMenu(QuotaMenuImage.image(snapshots: Self.menuSnapshots,
                showPercentage: false, placement: .beside), scale: scale)
            let offTop = try Self.renderMenu(QuotaMenuImage.image(snapshots: Self.menuSnapshots,
                showPercentage: false, placement: .arcTop), scale: scale)
            #expect(offBeside.size == offTop.size)
            #expect(Data(bytes: try #require(offBeside.bitmapData), count: offBeside.bytesPerRow * offBeside.pixelsHigh)
                == Data(bytes: try #require(offTop.bitmapData), count: offTop.bytesPerRow * offTop.pixelsHigh))
        }
        for percent in [0.0, 8, 15, 35, 100] {
            let width = QuotaMenuImage.segmentWidth(percent: percent, showPercentage: true, placement: .beside)
            let line = QuotaMenuImage.numberLayout(percent: Int(percent), placement: .beside).line
            let run = try #require((CTLineGetGlyphRuns(line) as? [CTRun])?.first)
            let font = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as! CTFont
            var glyphs = [CGGlyph](repeating: 0, count: CTRunGetGlyphCount(run))
            CTRunGetGlyphs(run, CFRange(location: 0, length: glyphs.count), &glyphs)
            let characters = Array("\(Int(percent))%".utf16)
            var percentGlyph: CGGlyph = 0
            let percentCharacter: UniChar = 37
            #expect(withUnsafePointer(to: percentCharacter) { CTFontGetGlyphsForCharacters(font, $0, &percentGlyph, 1) })
            #expect(CTLineGetStringRange(line).length == characters.count)
            #expect(glyphs.count == characters.count && glyphs.last == percentGlyph)
            #expect(width == ceil(MenuArcMetrics.segmentSize + MenuArcMetrics.besideGap + CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))))
        }
        #expect(QuotaMenuImage.segmentWidth(percent: nil, showPercentage: true, placement: .beside) == MenuArcMetrics.segmentSize)
    }

    @MainActor @Test func besideDigitsUseRoundedSemiboldMonospacedNumbers() throws {
        var advances: [Double] = []
        let descriptor = NSFont.systemFont(ofSize: MenuArcMetrics.besideDigitFontSize, weight: MenuArcMetrics.digitWeight).fontDescriptor.withDesign(.rounded)!
        let expectedFont = try #require(NSFont(descriptor: descriptor, size: MenuArcMetrics.besideDigitFontSize))
        for digit in 0...9 {
            let layout = QuotaMenuImage.numberLayout(percent: digit, placement: .beside)
            let run = try #require((CTLineGetGlyphRuns(layout.line) as? [CTRun])?.first)
            let attributes = CTRunGetAttributes(run) as NSDictionary
            let font = try #require(attributes[kCTFontAttributeName] as? NSFont)
            #expect(font.fontName == expectedFont.fontName)
            #expect(font.pointSize == MenuArcMetrics.besideDigitFontSize)
            #expect(layout.cutout.isEmpty)
            #expect(layout.inkBounds.minX >= MenuArcMetrics.segmentSize + MenuArcMetrics.besideGap)
            advances.append(CTLineGetTypographicBounds(layout.line, nil, nil, nil))
        }
        #expect(try #require(advances.max()) - #require(advances.min()) < 0.0001)
    }

    @MainActor @Test func besideDigitInkIsCenteredAndUnclippedAtBothScales() throws {
        for scale in [1, 2] {
            for percent in 0...100 {
                let layout = QuotaMenuImage.numberLayout(percent: percent, scale: CGFloat(scale), placement: .beside)
                #expect(abs(layout.inkBounds.midY - MenuArcMetrics.segmentSize / 2) < 0.0001)
                let width = QuotaMenuImage.segmentWidth(percent: Double(percent), showPercentage: true, placement: .beside)
                #expect(layout.inkBounds.minY > 0 && layout.inkBounds.maxY < MenuArcMetrics.segmentSize)
                #expect(layout.inkBounds.maxX <= width)
                let padding: CGFloat = 4
                let image = NSImage(size: NSSize(width: width + padding * 2, height: MenuArcMetrics.segmentSize + padding * 2), flipped: true) { _ in
                    let context = NSGraphicsContext.current!.cgContext
                    context.translateBy(x: padding, y: padding)
                    QuotaMenuImage.drawNumber(layout, context: context)
                    return true
                }
                let bitmap = try Self.renderMenu(image, scale: scale)
                var minY = bitmap.pixelsHigh, maxY = 0
                for y in 0..<bitmap.pixelsHigh {
                    for x in 0..<bitmap.pixelsWide {
                        let alpha = try #require(bitmap.colorAt(x: x, y: y)).alphaComponent
                        if alpha > 0 {
                            #expect(x >= Int(padding) * scale && x < Int(padding + width) * scale)
                            #expect(y >= Int(padding) * scale && y < Int(padding + MenuArcMetrics.segmentSize) * scale)
                        }
                        if alpha > 0.5 { minY = min(minY, y); maxY = max(maxY, y) }
                    }
                }
                #expect(minY <= maxY)
                let center = CGFloat(minY + maxY + 1) / (2 * CGFloat(scale)) - padding
                #expect(abs(center - MenuArcMetrics.segmentSize / 2) <= 0.5 / CGFloat(scale) + 0.0001, "percent=\(percent) scale=\(scale) center=\(center)")
            }
        }
    }

    @MainActor @Test func menuImageFitsCenteredInTwentyTwoPointStatusCell() throws {
        let image = QuotaMenuImage.image(snapshots: Self.menuSnapshots, showPercentage: true)
        let cell = NSButtonCell(imageCell: image)
        cell.imagePosition = .imageOnly
        cell.imageScaling = .scaleProportionallyDown
        cell.isBordered = false
        let bounds = CGRect(x: 0, y: 0, width: image.size.width, height: 22)
        let rect = cell.imageRect(forBounds: bounds)
        #expect(rect.size == image.size)
        #expect(abs(rect.midY - bounds.midY) < 0.5)
        #expect(bounds.contains(rect))
    }

    private static var menuWidth: CGFloat { 3 * MenuArcMetrics.segmentSize + 2 * MenuArcMetrics.segmentGap }

    @MainActor private static var menuSnapshots: [AIUsageSnapshot] {
        zip([AIUsageProvider.codex, .claude, .grok], [95.0, 35, 10]).map { provider, percent in
            AIUsageSnapshot(provider: provider, windows: [AIUsageWindow(id: "fixture", title: "fixture", remainingPercent: percent)],
                            isConnected: true, status: "fixture", source: "fixture")
        }
    }

    /// Bitmap dimensions use pixels; image layout and drawing remain in points.
    @MainActor private static func renderMenu(_ image: NSImage, scale: Int,
                                              appearance: NSAppearance.Name = .aqua, margin: CGFloat = 0,
                                              background: Int? = nil, canvasHeight: CGFloat? = nil) throws -> NSBitmapImageRep {
        let pointSize = NSSize(width: image.size.width + margin * 2, height: canvasHeight ?? image.size.height)
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: Int(pointSize.width) * scale, pixelsHigh: Int(pointSize.height) * scale,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = pointSize
        let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
        let appearance = try #require(NSAppearance(named: appearance))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        appearance.performAsCurrentDrawingAppearance {
            if let background {
                NSColor(deviceRed: CGFloat((background >> 16) & 255) / 255,
                        green: CGFloat((background >> 8) & 255) / 255,
                        blue: CGFloat(background & 255) / 255, alpha: 1).setFill()
                NSRect(origin: .zero, size: pointSize).fill()
            }
            image.draw(in: NSRect(x: margin, y: (pointSize.height - image.size.height) / 2,
                                 width: image.size.width, height: image.size.height))
        }
        return bitmap
    }
}
