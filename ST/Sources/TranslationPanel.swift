import Cocoa
import SwiftUI

public class TranslationPanel: NSPanel {
    public static let shared = TranslationPanel()

    private let viewModel = TranslationViewModel()
    private var hostingView: NSHostingView<TranslationView>?
    private var showTimestamp: Date = .distantPast

    public var isPinned: Bool {
        return viewModel.isPinned
    }

    private init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 220),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false
        )

        // Set to popUpMenu level so it floats above Books, Obsidian, and all other apps
        self.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.popUpMenuWindow)))
        self.isFloatingPanel = true
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false
        self.isMovableByWindowBackground = true
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        viewModel.onClose = { [weak self] in
            self?.dismissAnimated(force: true)
        }

        let view = TranslationView(viewModel: viewModel)
        let hosting = NSHostingView(rootView: view)
        hosting.autoresizingMask = [.width, .height]
        hosting.frame = NSRect(x: 0, y: 0, width: 380, height: 220)
        self.contentView = hosting
        self.hostingView = hosting
    }

    public func show(at point: NSPoint, selectionRect: NSRect, text: String) {
        showTimestamp = Date()
        viewModel.isPinned = false // Reset pinned state for new selection
        viewModel.startTranslation(source: text)

        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main else {
            return
        }

        let visible = screen.visibleFrame
        let panelWidth: CGFloat = 380
        let panelHeight: CGFloat = 220

        var originX = point.x - (panelWidth / 2.0)
        // Position directly above the top edge of the selection
        let topOfSelection = max(selectionRect.maxY, point.y)
        var originY = topOfSelection + 12.0

        // Clamp horizontal bounds to keep window fully on screen
        if originX < visible.minX + 10.0 {
            originX = visible.minX + 10.0
        } else if originX + panelWidth > visible.maxX - 10.0 {
            originX = visible.maxX - panelWidth - 10.0
        }

        // If popping above would exceed top of screen, flip below selection
        if originY + panelHeight > visible.maxY - 10.0 {
            let bottomOfSelection = min(selectionRect.minY, point.y)
            originY = bottomOfSelection - panelHeight - 12.0
        }

        // Clamp vertical lower bound
        if originY < visible.minY + 10.0 {
            originY = visible.minY + 10.0
        }

        self.setFrame(NSRect(x: originX, y: originY, width: panelWidth, height: panelHeight), display: true)
        self.alphaValue = 0.0
        self.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            self.animator().alphaValue = 1.0
        }
    }

    /// Displays the panel in the center of the active screen (used for manual tests)
    public func showCenter(text: String) {
        showTimestamp = Date()
        viewModel.isPinned = false // Reset pinned state so outside click dismisses it
        viewModel.startTranslation(source: text)

        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let panelWidth: CGFloat = 380
        let panelHeight: CGFloat = 220

        let originX = visible.midX - (panelWidth / 2.0)
        let originY = visible.midY - (panelHeight / 2.0)

        self.setFrame(NSRect(x: originX, y: originY, width: panelWidth, height: panelHeight), display: true)
        self.alphaValue = 0.0
        self.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            self.animator().alphaValue = 1.0
        }
    }

    public func dismissAnimated(force: Bool = false) {
        guard self.isVisible else { return }
        if isPinned && !force {
            STLog("dismissAnimated: panel is pinned, ignoring non-forced dismiss")
            return
        }

        STLog("dismissAnimated: dismissing translation panel")
        OllamaService.shared.cancelCurrentTranslation()

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.08
            self.animator().alphaValue = 0.0
        }, completionHandler: {
            self.orderOut(nil)
        })
    }
}
