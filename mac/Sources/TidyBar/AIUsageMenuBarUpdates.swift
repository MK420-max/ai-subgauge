import AppKit
import Combine

/// Compare the inputs used by the bitmap, including colors that can change under the same name.
struct AIUsageMenuBarAppearance: Equatable {
    let dark: Bool
    let quotaColors: [NSColor]
}

extension AIUsageMenuBarAppearance {
    @MainActor init(_ appearance: NSAppearance) {
        dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        var colors: [NSColor] = []
        appearance.performAsCurrentDrawingAppearance {
            colors = [NSColor.systemGreen, .systemOrange, .systemRed].map {
                $0.usingColorSpace(.deviceRGB) ?? $0
            }
        }
        quotaColors = colors
    }
}

/// One pending update per burst; unchanged pixels never reach the bitmap renderer.
@MainActor
final class AIUsageMenuBarUpdates {
    private var pending: Task<Void, Never>?
    private var dirty = false
    private var lastRenderKey: AIUsageMenuBarRenderKey?

    func request(_ update: @escaping @MainActor () -> Void) {
        dirty = true
        guard pending == nil else { return }
        pending = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 25_000_000) }
            catch { return }
            guard !Task.isCancelled, let self else { return }
            self.dirty = false
            update()
            // reset() may have cancelled this task and installed a new pending batch.
            guard !Task.isCancelled else { return }
            self.pending = nil
            if self.dirty { self.request(update) }
        }
    }

    func reset() {
        pending?.cancel()
        pending = nil
        dirty = false
        lastRenderKey = nil
    }

    func image(for key: AIUsageMenuBarRenderKey, render: () -> NSImage) -> NSImage? {
        guard key != lastRenderKey else { return nil }
        // Publish before rendering/AppKit setters can synchronously notify observers.
        lastRenderKey = key
        return render()
    }

    static func appearanceChanges(of view: NSView) -> AnyPublisher<AIUsageMenuBarAppearance, Never> {
        view.publisher(for: \.effectiveAppearance, options: [.initial, .new])
            .receive(on: DispatchQueue.main)
            .map { AIUsageMenuBarAppearance($0) }.removeDuplicates().dropFirst().eraseToAnyPublisher()
    }
}
