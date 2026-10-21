import AppKit
import Testing
@testable import TidyBar

extension TidyBarTests {
@Suite
final class AppearanceTests {
    @Test
    func testNotchedDisplayGapIsCenteredAndMatchesNotch() {
        let widths = AppearanceGeometry.splitWidths(width: 1512, notchWidth: 176)
        #expect(widths.left == 668)
        #expect(widths.gap == 176)
        #expect(widths.right == 668)
        #expect(widths.left + widths.gap + widths.right == 1512)
    }

    @Test
    func testAsymmetricSafeAreasKeepGapAtActualNotch() {
        let widths = AppearanceGeometry.splitWidths(width: 1800, notchWidth: 160, notchCenter: 920)
        #expect(widths.left == 840)
        #expect(widths.gap == 160)
        #expect(widths.right == 800)
        #expect(widths.left + widths.gap / 2 == 920)
    }

    @Test
    func testUnnotchedAndNarrowPreviewsNeverProduceNegativeWidths() {
        let desktop = AppearanceGeometry.splitWidths(width: 1920, notchWidth: 0)
        #expect(desktop.left == 952)
        #expect(desktop.gap == 16)
        #expect(desktop.right == 952)
        for width in [CGFloat(0), 8, 100] {
            let value = AppearanceGeometry.splitWidths(width: width, notchWidth: 176)
            #expect(value.left >= 0)
            #expect(value.right >= 0)
            #expect(value.left + value.gap + value.right == width)
        }
    }

    @Test
    func testSystemMenuHidingSuppressesDecorationAndRestoresDefault() {
        #expect(AppearanceGeometry.shouldHideDecoration(presentationOptions: [], autoHidePreference: true))
        #expect(AppearanceGeometry.shouldHideDecoration(presentationOptions: [.autoHideMenuBar], autoHidePreference: false))
        #expect(AppearanceGeometry.shouldHideDecoration(presentationOptions: [.hideMenuBar], autoHidePreference: false))
        #expect(!(AppearanceGeometry.shouldHideDecoration(presentationOptions: [], autoHidePreference: false)))
    }

    @Test
    func testLegacyNilOptionsKeepUniformCornersAndOriginalHeight() {
        let style = BarStyle()
        let metrics = AppearanceGeometry.metrics(menuHeight: 33, style: style)
        #expect(metrics.topRadius == 10)
        #expect(metrics.bottomRadius == 10)
        #expect(metrics.extensionHeight == 0)
        #expect(metrics.panelHeight == 33)
        #expect(AppearanceGeometry.borderColor(style: style, dark: true) == style.borderColor)
    }

    @Test
    func testIndependentCornersAndExtensionReserveShadowSpace() {
        var style = BarStyle()
        style.cornerRadius = 12
        style.roundTop = false
        style.roundBottom = true
        var metrics = AppearanceGeometry.metrics(menuHeight: 33, style: style)
        #expect(metrics.topRadius == 0)
        #expect(metrics.bottomRadius == 12)
        style.roundBottom = false
        metrics = AppearanceGeometry.metrics(menuHeight: 33, style: style)
        #expect(metrics.bottomRadius == 0)
        style.roundUnderMenuBar = true
        style.shadow = true
        metrics = AppearanceGeometry.metrics(menuHeight: 33, style: style)
        #expect(metrics.menuHeight == 33)
        #expect(metrics.extensionHeight == 12)
        #expect(metrics.topRadius == 0)
        #expect(metrics.bottomRadius == 12)
        #expect(metrics.shapeHeight == 45)
        #expect(metrics.shadowPadding == 12)
        #expect(metrics.panelHeight == 57)
        #expect(metrics.panelHeight - metrics.shapeHeight > 3 * 3 + 1)
    }

    @Test
    func testMultiStopGradientPreservesLocationsAndDarkOverride() {
        var style = BarStyle()
        style.gradient = true
        let legacy = AppearanceGeometry.gradientColors(style: style, dark: false)
        #expect(legacy.map { $0.color } == [style.color, style.endColor])
        #expect(legacy.map { $0.location } == [0, 1])
        style.gradientStops = [GradientColorStop(color: "#112233", location: 0), GradientColorStop(color: "#445566", location: 0.5), GradientColorStop(color: "#778899", location: 0.5)]
        let light = AppearanceGeometry.gradientColors(style: style, dark: false)
        #expect(light.map { $0.color } == ["#112233", "#445566", "#778899"])
        #expect(light.map { $0.location } == [0, 0.5, 0.5])
        style.useDarkStyle = true
        style.darkColor = "#010203"
        #expect(AppearanceGeometry.gradientColors(style: style, dark: true).map { $0.color } == ["#010203", "#445566", "#778899"])
        style.gradient = false
        #expect(AppearanceGeometry.gradientColors(style: style, dark: true).map { $0.color } == ["#010203", "#010203"])
    }

    @Test
    func testIndependentDarkBorderHasExplicitLegacyFallback() {
        var style = BarStyle()
        style.borderColor = "#111111"
        style.darkBorderColor = "#EEEEEE"
        #expect(AppearanceGeometry.borderColor(style: style, dark: true) == "#111111")
        style.linkBorderColors = false
        #expect(AppearanceGeometry.borderColor(style: style, dark: true) == "#EEEEEE")
        #expect(AppearanceGeometry.borderColor(style: style, dark: false) == "#111111")
        style.darkBorderColor = nil
        #expect(AppearanceGeometry.borderColor(style: style, dark: true) == "#111111")
    }


    @Test
    func testSearchBackgroundFillsContainerEvenWhenMenuExtensionIsEnabled() {
        var style = BarStyle()
        style.roundUnderMenuBar = true
        style.shadow = true
        style.cornerRadius = 20
        let background = AppearanceGeometry.surfaceMetrics(containerHeight: 420, menuHeight: nil, style: style)
        #expect(background.menuHeight == 420)
        #expect(background.shapeHeight == 420)
        #expect(background.panelHeight == 420)
        #expect(background.extensionHeight == 0)
        #expect(background.shadowPadding == 0)
        let menu = AppearanceGeometry.surfaceMetrics(containerHeight: 65, menuHeight: 33, style: style)
        #expect(menu.shapeHeight == 53)
        #expect(menu.panelHeight == 65)
    }

    @Test
    func testAppKitPanelAnchorsAtScreenTopWithShadowBelowShape() {
        var style = BarStyle()
        style.roundUnderMenuBar = true
        style.cornerRadius = 14
        style.shadow = true
        let metrics = AppearanceGeometry.metrics(menuHeight: 33, style: style)
        for screen in [CGRect(x: 0, y: 0, width: 1512, height: 982), CGRect(x: -1920, y: -1080, width: 1920, height: 1080)] {
            let panel = AppearanceGeometry.panelFrame(screenFrame: screen, menuHeight: 33, style: style)
            #expect(panel.maxY == screen.maxY)
            #expect(panel.minX == screen.minX)
            #expect(panel.width == screen.width)
            #expect(panel.maxY - metrics.shapeHeight - panel.minY == metrics.shadowPadding)
            #expect(panel.maxY - metrics.menuHeight == screen.maxY - 33)
        }
    }

}
}
