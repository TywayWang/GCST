import Cocoa
import ApplicationServices

public class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, SelectionMonitorDelegate {
    private var statusItem: NSStatusItem?
    private let selectionMonitor = SelectionMonitor()
    private var isEnabledMenuItem: NSMenuItem?
    private var accessibilityMenuItem: NSMenuItem?
    private var ollamaStatusMenuItem: NSMenuItem?

    public func applicationDidFinishLaunching(_ notification: Notification) {
        STLog("ST applicationDidFinishLaunching: started. PID: \(ProcessInfo.processInfo.processIdentifier)")

        // Check Accessibility permission and prompt if needed
        let trusted = checkAccessibility(prompt: true)
        STLog("Initial accessibility trust check: \(trusted)")

        // Set up Selection Monitor
        selectionMonitor.delegate = self
        selectionMonitor.start()

        // Set up Menu Bar Status Item
        setupStatusBarItem()

        // Check Ollama status
        checkOllamaConnection()
    }

    public func applicationWillTerminate(_ notification: Notification) {
        STLog("ST applicationWillTerminate")
        selectionMonitor.stop()
    }

    // MARK: - Accessibility Check

    @discardableResult
    private func checkAccessibility(prompt: Bool) -> Bool {
        if prompt {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            return AXIsProcessTrustedWithOptions(options)
        } else {
            return AXIsProcessTrusted()
        }
    }

    @objc private func openAccessibilityPreferences() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)

        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - NSMenuDelegate (Dynamically refresh status on click)

    public func menuWillOpen(_ menu: NSMenu) {
        let isTrusted = checkAccessibility(prompt: false)
        STLog("menuWillOpen: AXIsProcessTrusted = \(isTrusted)")

        if isTrusted {
            accessibilityMenuItem?.title = "Accessibility: Granted ✓"
            accessibilityMenuItem?.action = nil
            // Ensure monitor is active
            selectionMonitor.start()
        } else {
            accessibilityMenuItem?.title = "⚠️ Grant Accessibility..."
            accessibilityMenuItem?.action = #selector(openAccessibilityPreferences)
        }

        checkOllamaConnection()
    }

    // MARK: - Status Bar Setup

    private func setupStatusBarItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            button.title = "ST"
            button.font = NSFont.systemFont(ofSize: 13, weight: .bold)
            button.toolTip = "ST: English to Chinese Translator (Gemma 4)"
        }

        let menu = NSMenu()
        menu.delegate = self

        let titleItem = NSMenuItem(title: "ST Translator (Gemma 4)", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)

        menu.addItem(NSMenuItem.separator())

        let enabledItem = NSMenuItem(title: "Active (Hover Translation)", action: #selector(toggleEnabled), keyEquivalent: "")
        enabledItem.target = self
        enabledItem.state = .on
        self.isEnabledMenuItem = enabledItem
        menu.addItem(enabledItem)

        let isTrusted = checkAccessibility(prompt: false)
        let accessItem = NSMenuItem(
            title: isTrusted ? "Accessibility: Granted ✓" : "⚠️ Grant Accessibility...",
            action: isTrusted ? nil : #selector(openAccessibilityPreferences),
            keyEquivalent: ""
        )
        accessItem.target = self
        self.accessibilityMenuItem = accessItem
        menu.addItem(accessItem)

        let statusItem = NSMenuItem(title: "Ollama: Checking...", action: #selector(checkOllamaConnection), keyEquivalent: "")
        statusItem.target = self
        self.ollamaStatusMenuItem = statusItem
        menu.addItem(statusItem)

        menu.addItem(NSMenuItem.separator())

        // Hover delay submenu
        let delayMenu = NSMenu()
        for delay in [0.25, 0.35, 0.50, 0.70] {
            let item = NSMenuItem(title: "\(Int(delay * 1000)) ms", action: #selector(setHoverDelay(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = delay
            if abs(delay - selectionMonitor.hoverDelay) < 0.01 {
                item.state = .on
            }
            delayMenu.addItem(item)
        }
        let delayParent = NSMenuItem(title: "Hover Delay", action: nil, keyEquivalent: "")
        delayParent.submenu = delayMenu
        menu.addItem(delayParent)

        // Manual test action (centered and pinned so it's guaranteed to be seen)
        let testItem = NSMenuItem(title: "Test Popup Translation", action: #selector(triggerTestPopup), keyEquivalent: "t")
        testItem.target = self
        menu.addItem(testItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit ST", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        self.statusItem?.menu = menu
    }

    @objc private func toggleEnabled() {
        selectionMonitor.isEnabled.toggle()
        isEnabledMenuItem?.state = selectionMonitor.isEnabled ? .on : .off
        STLog("toggleEnabled: isEnabled is now \(selectionMonitor.isEnabled)")
    }

    @objc private func checkOllamaConnection() {
        ollamaStatusMenuItem?.title = "Ollama: Checking..."
        OllamaService.shared.checkHealth { [weak self] isOnline, models in
            if isOnline {
                let hasGemma = models.contains { $0.contains("gemma4:e4b") }
                if hasGemma {
                    self?.ollamaStatusMenuItem?.title = "Ollama: gemma4:e4b ✓ Online"
                } else {
                    self?.ollamaStatusMenuItem?.title = "Ollama: Online (gemma4 not found)"
                }
            } else {
                self?.ollamaStatusMenuItem?.title = "Ollama: ✗ Offline"
            }
        }
    }

    @objc private func setHoverDelay(_ sender: NSMenuItem) {
        if let delay = sender.representedObject as? TimeInterval {
            selectionMonitor.hoverDelay = delay
            STLog("setHoverDelay: set to \(delay)s")
            if let menu = sender.menu {
                for item in menu.items {
                    item.state = (item == sender) ? .on : .off
                }
            }
        }
    }

    @objc private func triggerTestPopup() {
        STLog("triggerTestPopup: User triggered manual test popup")
        let sample = "Quantum entanglement is a physical phenomenon that occurs when a group of particles are generated, interact, or share spatial proximity."
        TranslationPanel.shared.showCenter(text: sample)
    }

    @objc private func quitApp() {
        STLog("quitApp: User selected Quit ST")
        NSApplication.shared.terminate(nil)
    }

    // MARK: - SelectionMonitorDelegate

    public func didRequestTranslation(at screenPoint: NSPoint, selectionRect: NSRect) {
        STLog("didRequestTranslation received at \(screenPoint)")
        TextExtractor.shared.extractSelectedText { [weak self] selectedText in
            guard self != nil else { return }

            guard let text = selectedText, !text.isEmpty else {
                STLog("didRequestTranslation: extractSelectedText returned nil or empty string")
                return
            }

            STLog("didRequestTranslation: Showing translation panel for '\(text.prefix(40))' at \(screenPoint)")
            DispatchQueue.main.async {
                TranslationPanel.shared.show(at: screenPoint, selectionRect: selectionRect, text: text)
            }
        }
    }

    public func didDismissRequested() {
        DispatchQueue.main.async {
            TranslationPanel.shared.dismissAnimated()
        }
    }

    public func isPointInsideActivePanel(_ point: NSPoint) -> Bool {
        return TranslationPanel.shared.frame.contains(point)
    }

    public func isPanelPinned() -> Bool {
        return TranslationPanel.shared.isPinned
    }

    public func isPanelVisible() -> Bool {
        return TranslationPanel.shared.isVisible
    }
}
