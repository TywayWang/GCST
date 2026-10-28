import Cocoa
import CoreGraphics

public protocol SelectionMonitorDelegate: AnyObject {
    func didRequestTranslation(at screenPoint: NSPoint, selectionRect: NSRect)
    func didDismissRequested()
    func isPointInsideActivePanel(_ point: NSPoint) -> Bool
    func isPanelPinned() -> Bool
    func isPanelVisible() -> Bool
}

public class SelectionMonitor {
    public weak var delegate: SelectionMonitorDelegate?

    public var isEnabled: Bool = true
    public var hoverDelay: TimeInterval = 0.35 // 350ms hover delay
    public var maxHoverRadius: CGFloat = 65.0

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private var mouseDownLocation: NSPoint = .zero
    private var mouseDownTime: Date = .distantPast
    private var hoverTimer: Timer?
    private var autoDismissTimer: Timer?
    private var pendingSelectionPoint: NSPoint = .zero
    private var activeSelectionRect: NSRect = .zero

    private var lastMouseDownProcessed: Date = .distantPast
    private var lastMouseUpProcessed: Date = .distantPast

    public init() {}

    public func start() {
        stop()

        STLog("SelectionMonitor.start(): Initializing event monitors. Trusted: \(AXIsProcessTrusted())")

        // 1. Cocoa Global Monitor
        let eventMask: NSEvent.EventTypeMask = [
            .leftMouseDown,
            .leftMouseDragged,
            .leftMouseUp,
            .keyDown
        ]

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: eventMask) { [weak self] event in
            self?.handleNSEvent(event)
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: eventMask) { [weak self] event in
            self?.handleNSEvent(event)
            return event
        }

        // 2. Hardware-level CGEventTap for 100% capture across WebKit / Electron
        setupCGEventTap()
    }

    public func stop() {
        if let gm = globalMonitor {
            NSEvent.removeMonitor(gm)
            globalMonitor = nil
        }
        if let lm = localMonitor {
            NSEvent.removeMonitor(lm)
            localMonitor = nil
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let src = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
                runLoopSource = nil
            }
            eventTap = nil
        }
        hoverTimer?.invalidate()
        hoverTimer = nil
        autoDismissTimer?.invalidate()
        autoDismissTimer = nil
    }

    deinit {
        stop()
    }

    // MARK: - CGEventTap Setup

    private func setupCGEventTap() {
        let mask: CGEventMask = (1 << CGEventType.leftMouseDown.rawValue) |
                                (1 << CGEventType.leftMouseUp.rawValue) |
                                (1 << CGEventType.keyDown.rawValue)

        let observer = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<SelectionMonitor>.fromOpaque(refcon).takeUnretainedValue()

                let mouseLoc = NSEvent.mouseLocation

                if type == .leftMouseDown {
                    monitor.processMouseDown(at: mouseLoc)
                } else if type == .leftMouseUp {
                    let clickCount = event.getIntegerValueField(.mouseEventClickState)
                    monitor.processMouseUp(at: mouseLoc, clickCount: Int(clickCount))
                } else if type == .keyDown {
                    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
                    if keyCode == 53 { // Esc key
                        if monitor.delegate?.isPanelVisible() == true {
                            STLog("SelectionMonitor (CGEventTap): Esc key pressed, requesting dismiss")
                            DispatchQueue.main.async {
                                monitor.delegate?.didDismissRequested()
                            }
                        }
                    }
                }

                return Unmanaged.passUnretained(event)
            },
            userInfo: observer
        ) else {
            STLog("SelectionMonitor: CGEventTap creation returned nil (likely awaiting permission)")
            return
        }

        self.eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        STLog("SelectionMonitor: CGEventTap successfully installed and enabled")
    }

    // MARK: - Event Dispatchers

    private func handleNSEvent(_ event: NSEvent) {
        if event.type == .keyDown && event.keyCode == 53 { // Esc key
            if delegate?.isPanelVisible() == true {
                STLog("SelectionMonitor: Esc key pressed, requesting dismiss")
                delegate?.didDismissRequested()
            }
            return
        }

        switch event.type {
        case .leftMouseDown:
            processMouseDown(at: NSEvent.mouseLocation)
        case .leftMouseUp:
            processMouseUp(at: NSEvent.mouseLocation, clickCount: event.clickCount)
        default:
            break
        }
    }

    // MARK: - Unified State Machine

    private func processMouseDown(at point: NSPoint) {
        let now = Date()
        guard now.timeIntervalSince(lastMouseDownProcessed) > 0.04 else { return } // Deduplicate
        lastMouseDownProcessed = now

        let mouseLoc = NSEvent.mouseLocation
        mouseDownLocation = mouseLoc
        mouseDownTime = now
        cancelHoverTimer()

        STLog("processMouseDown at \(mouseLoc)")

        guard let delegate = delegate, delegate.isPanelVisible() else { return }

        // Check if click occurred inside active panel
        if delegate.isPointInsideActivePanel(mouseLoc) {
            STLog("processMouseDown: click inside active panel (\(mouseLoc)), retaining")
            return
        }

        // Clicked outside: dismiss panel if not pinned
        if !delegate.isPanelPinned() {
            STLog("processMouseDown: click outside ST UI at \(mouseLoc) -> requesting dismiss")
            delegate.didDismissRequested()
        } else {
            STLog("processMouseDown: click outside but panel is pinned -> retaining")
        }
    }

    private func processMouseUp(at point: NSPoint, clickCount: Int) {
        guard isEnabled else { return }
        let now = Date()
        guard now.timeIntervalSince(lastMouseUpProcessed) > 0.04 else { return } // Deduplicate
        lastMouseUpProcessed = now

        let dragDist = hypot(point.x - mouseDownLocation.x, point.y - mouseDownLocation.y)
        let isMultiClick = clickCount >= 2
        let wasDrag = dragDist > 6.0

        STLog("processMouseUp at \(point), dragDist=\(String(format: "%.1f", dragDist)), clickCount=\(clickCount), wasDrag=\(wasDrag)")

        if wasDrag || isMultiClick {
            let p1 = mouseDownLocation
            let p2 = point
            let minX = min(p1.x, p2.x) - 40.0
            let maxX = max(p1.x, p2.x) + 40.0
            let minY = min(p1.y, p2.y) - 35.0
            let maxY = max(p1.y, p2.y) + 35.0

            activeSelectionRect = NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            pendingSelectionPoint = point
            scheduleHoverTimer(at: point)
        }
    }

    // MARK: - Hover Detection

    private func scheduleHoverTimer(at point: NSPoint) {
        cancelHoverTimer()
        STLog("scheduleHoverTimer: waiting \(Int(hoverDelay * 1000))ms for hover at \(point)...")

        hoverTimer = Timer.scheduledTimer(withTimeInterval: hoverDelay, repeats: false) { [weak self] _ in
            guard let self = self, self.isEnabled else { return }

            let currentPoint = NSEvent.mouseLocation
            let dist = hypot(currentPoint.x - point.x, currentPoint.y - point.y)
            let isInsideSelection = self.activeSelectionRect.contains(currentPoint)

            STLog("hoverTimer fired: current=\(currentPoint), target=\(point), dist=\(String(format: "%.1f", dist)), insideSelection=\(isInsideSelection)")

            // If cursor is still inside selection box or within hover radius: Rule b is satisfied!
            if isInsideSelection || dist <= self.maxHoverRadius {
                STLog("HOVER CONDITION MET! Calling didRequestTranslation")
                self.delegate?.didRequestTranslation(at: currentPoint, selectionRect: self.activeSelectionRect)
            } else {
                STLog("Hover cancelled: cursor moved away (dist \(String(format: "%.1f", dist)) > \(self.maxHoverRadius))")
            }
        }
    }

    private func cancelHoverTimer() {
        if hoverTimer != nil {
            hoverTimer?.invalidate()
            hoverTimer = nil
        }
    }
}
