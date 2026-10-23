import Cocoa
import ApplicationServices
import Network

public class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, SelectionMonitorDelegate {
    private var statusItem: NSStatusItem?
    private let selectionMonitor = SelectionMonitor()
    private var isEnabledMenuItem: NSMenuItem?
    private var accessibilityMenuItem: NSMenuItem?
    private var ollamaStatusMenuItem: NSMenuItem?
    private var commandListener: NWListener?

    public func applicationDidFinishLaunching(_ notification: Notification) {
        STLog("ST applicationDidFinishLaunching: started. PID: \(ProcessInfo.processInfo.processIdentifier)")

        // Check Accessibility permission and prompt if needed
        let trusted = checkAccessibility(prompt: true)
        STLog("Initial accessibility trust check: \(trusted)")

        // Set up Selection Monitor
        selectionMonitor.delegate = self
        selectionMonitor.start()

        // Set up Menu Bar Status Item (only if in standalone mode; otherwise GCST manages unified tray)
        let isStandalone = ProcessInfo.processInfo.arguments.contains("--standalone") ||
                           ProcessInfo.processInfo.environment["ST_STANDALONE"] == "1"
        if isStandalone {
            setupStatusBarItem()
        } else {
            STLog("Running in unified GCST suite mode: menu bar icon is handled by GCST")
        }

        // Start internal IPC command listener on port 11435 for GCST suite coordination
        startCommandListener()

        // Check Ollama status
        checkOllamaConnection()
    }

    public func applicationWillTerminate(_ notification: Notification) {
        STLog("ST applicationWillTerminate")
        commandListener?.cancel()
        commandListener = nil
        selectionMonitor.stop()
    }

    // MARK: - Internal IPC Command Listener

    private func startCommandListener() {
        do {
            let port = NWEndpoint.Port(rawValue: 11435)!
            let listener = try NWListener(using: .tcp, on: port)
            listener.newConnectionHandler = { [weak self] connection in
                self?.handleConnection(connection)
            }
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    STLog("ST Command listener is ready on 127.0.0.1:11435")
                case .failed(let err):
                    STLog("ST Command listener failed: \(err)")
                default:
                    break
                }
            }
            listener.start(queue: .main)
            self.commandListener = listener
        } catch {
            STLog("Failed to bind command listener on port 11435: \(error)")
        }
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 2048) { [weak self] data, _, _, _ in
            guard let self = self, let data = data, let req = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }

            var responseBody = "{\"ok\":true}"
            if req.contains("GET /toggle") {
                self.selectionMonitor.isEnabled.toggle()
                self.isEnabledMenuItem?.state = self.selectionMonitor.isEnabled ? .on : .off
                responseBody = "{\"enabled\":\(self.selectionMonitor.isEnabled)}"
                STLog("IPC command: toggle -> isEnabled: \(self.selectionMonitor.isEnabled)")
            } else if req.contains("GET /status") {
                let model = OllamaService.shared.modelName
                let enabled = self.selectionMonitor.isEnabled
                responseBody = "{\"running\":true,\"enabled\":\(enabled),\"model\":\"\(model)\"}"
            } else if req.contains("GET /test") {
                self.triggerTestPopup()
                responseBody = "{\"test\":true}"
                STLog("IPC command: trigger test popup")
            } else if req.contains("GET /quit") {
                STLog("IPC command: quit")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    NSApp.terminate(nil)
                }
                responseBody = "{\"quit\":true}"
            }

            let httpResponse = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nAccess-Control-Allow-Origin: *\r\nContent-Length: \(responseBody.utf8.count)\r\nConnection: close\r\n\r\n\(responseBody)"
            connection.send(content: httpResponse.data(using: .utf8), completion: .contentProcessed({ _ in
                connection.cancel()
            }))
        }
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
            selectionMonitor.start()
        } else {
            accessibilityMenuItem?.title = "⚠️ Grant Accessibility..."
            accessibilityMenuItem?.action = #selector(openAccessibilityPreferences)
        }

        checkOllamaConnection()
    }

    // MARK: - Status Bar Setup (Standalone Mode Only)

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

        // Manual test action
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

    @objc public func triggerTestPopup() {
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
