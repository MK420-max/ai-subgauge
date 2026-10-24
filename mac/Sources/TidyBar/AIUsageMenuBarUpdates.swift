import AppKit
import Combine

/// One pending update per burst; unchanged pixels never reach the bitmap renderer.
@MainActor
final class AIUsageMenuBarUpdates {
    private var pending: Task<Void, Never>?
    private var lastRenderKey: AIUsageMenuBarRenderKey?

    func request(_ update: @escaping @MainActor () -> Void) {
        guard pending == nil else { return }
        pending = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 25_000_000) }
            catch { return }
            guard let self else { return }
            defer { self.pending = nil }
            update()
        }
    }

    func reset() {
        pending?.cancel()
        pending = nil
        lastRenderKey = nil
    }

    func image(for key: AIUsageMenuBarRenderKey, render: () -> NSImage) -> NSImage? {
        guard key != lastRenderKey else { return nil }
        // Publish before rendering/AppKit setters can synchronously notify observers.
        lastRenderKey = key
        return render()
    }

    static func appearanceChanges(of view: NSView) -> AnyPublisher<NSAppearance.Name, Never> {
        view.publisher(for: \.effectiveAppearance, options: [.initial, .new])
            .map(\.name).removeDuplicates().dropFirst().eraseToAnyPublisher()
    }
}
