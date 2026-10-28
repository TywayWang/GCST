import Cocoa
import SwiftUI

public class TranslationPanel: NSPanel {
    public static let shared = TranslationPanel()

    private let viewModel = TranslationViewModel()
    private var hostingView: NSHostingView<TranslationView>?
    private var showTimestamp: Date = .distantPast
    private var cursorTrackingTimer: Timer?
    private var initialTriggerPoint: NSPoint = .zero
    private var hasCursorEnteredPanel: Bool = false
    private let dismissPadding: CGFloat = 18.0
    private let triggerDismissDistance: CGFloat = 85.0

    public var isPinned: Bool {
        return viewModel.isPinned
    }

    public func updatePausedState(_ isPaused: Bool) {
        if viewModel.isPaused != isPaused {
            viewModel.isPaused = isPaused
        }
    }

    private init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 415, height: 185),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false
        )

        // Set to popUpMenu level so it floats above all other apps
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

        viewModel.onTogglePause = { isPaused in
            AppDelegate.shared?.setHoverEnabled(!isPaused)
        }

        let view = TranslationView(viewModel: viewModel)
        let hosting = NSHostingView(rootView: view)
        hosting.autoresizingMask = [.width, .height]
        hosting.frame = NSRect(x: 0, y: 0, width: 415, height: 185)
        self.contentView = hosting
        self.hostingView = hosting
    }

    public func show(at point: NSPoint, selectionRect: NSRect, text: String) {
        showTimestamp = Date()
        initialTriggerPoint = point
        hasCursorEnteredPanel = false
        viewModel.isPinned = false
        if let appDel = AppDelegate.shared {
            viewModel.isPaused = !appDel.isHoverEnabled
        }
        viewModel.startTranslation(source: text)

        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main else {
            return
        }

        let visible = screen.visibleFrame
        let panelWidth: CGFloat = 415
        let panelHeight: CGFloat = 185

        var originX = point.x - (panelWidth / 2.0)
        let topOfSelection = max(selectionRect.maxY, point.y)
        var originY = topOfSelection + 12.0

        if originX < visible.minX + 10.0 {
            originX = visible.minX + 10.0
        } else if originX + panelWidth > visible.maxX - 10.0 {
            originX = visible.maxX - panelWidth - 10.0
        }

        if originY + panelHeight > visible.maxY - 10.0 {
            let bottomOfSelection = min(selectionRect.minY, point.y)
            originY = bottomOfSelection - panelHeight - 12.0
        }

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
        startCursorTracking()
    }

    public func showCenter(text: String) {
        showTimestamp = Date()
        initialTriggerPoint = NSEvent.mouseLocation
        hasCursorEnteredPanel = false
        viewModel.isPinned = false
        if let appDel = AppDelegate.shared {
            viewModel.isPaused = !appDel.isHoverEnabled
        }
        viewModel.startTranslation(source: text)

        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let panelWidth: CGFloat = 415
        let panelHeight: CGFloat = 185

        let originX = visible.midX - (panelWidth / 2.0)
        let originY = visible.midY - (panelHeight / 2.0)

        self.setFrame(NSRect(x: originX, y: originY, width: panelWidth, height: panelHeight), display: true)
        self.alphaValue = 0.0
        self.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            self.animator().alphaValue = 1.0
        }
        startCursorTracking()
    }

    public func dismissAnimated(force: Bool = false) {
        guard self.isVisible else {
            stopCursorTracking()
            return
        }
        if isPinned && !force {
            return
        }

        stopCursorTracking()
        STLog("dismissAnimated: dismissing translation panel")
        OllamaService.shared.cancelCurrentTranslation()

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.08
            self.animator().alphaValue = 0.0
        }, completionHandler: {
            self.orderOut(nil)
        })
    }

    public override func orderOut(_ sender: Any?) {
        stopCursorTracking()
        super.orderOut(sender)
    }

    private func startCursorTracking() {
        stopCursorTracking()
        let timer = Timer(timeInterval: 0.06, repeats: true) { [weak self] _ in
            self?.checkCursorTracking()
        }
        cursorTrackingTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopCursorTracking() {
        cursorTrackingTimer?.invalidate()
        cursorTrackingTimer = nil
        hasCursorEnteredPanel = false
    }

    private func checkCursorTracking() {
        guard self.isVisible else {
            stopCursorTracking()
            return
        }
        if isPinned {
            return
        }
        // Grace period during entry animation
        if Date().timeIntervalSince(showTimestamp) < 0.25 {
            return
        }

        let mouseLoc = NSEvent.mouseLocation
        let expandedFrame = self.frame.insetBy(dx: -dismissPadding, dy: -dismissPadding)

        if expandedFrame.contains(mouseLoc) {
            hasCursorEnteredPanel = true
        } else {
            if hasCursorEnteredPanel {
                STLog("checkCursorTracking: Cursor moved outside translation panel -> auto-dismissing")
                dismissAnimated()
            } else {
                let dist = hypot(mouseLoc.x - initialTriggerPoint.x, mouseLoc.y - initialTriggerPoint.y)
                if dist > triggerDismissDistance {
                    STLog("checkCursorTracking: Cursor moved away from selection point (\(Int(dist))px > \(Int(triggerDismissDistance))px) -> auto-dismissing")
                    dismissAnimated()
                }
            }
        }
    }
}
