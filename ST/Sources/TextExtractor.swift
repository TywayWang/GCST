import Cocoa
import ApplicationServices

public class TextExtractor {
    public static let shared = TextExtractor()

    private init() {}

    /// Checks if the text contains Latin letters and is suitable for translation
    public static func isTranslatableText(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return false }

        var latinCount = 0
        var cjkCount = 0

        for scalar in trimmed.unicodeScalars {
            if CharacterSet.letters.contains(scalar) && scalar.isASCII {
                latinCount += 1
            } else if (0x4E00...0x9FFF).contains(scalar.value) {
                cjkCount += 1
            }
        }

        return latinCount > 0 && latinCount >= (cjkCount / 2)
    }

    /// Cleans up any quotation marks or book citations (e.g. from Apple Books)
    public static func cleanExtractedText(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // Apple Books appends citations: "Excerpt From: ..."
        if let range = text.range(of: "\nExcerpt From:", options: .caseInsensitive) {
            text = String(text[..<range.lowerBound])
        } else if let range = text.range(of: "\r\nExcerpt From:", options: .caseInsensitive) {
            text = String(text[..<range.lowerBound])
        } else if let range = text.range(of: "\n—— 摘自") {
            text = String(text[..<range.lowerBound])
        }

        // Strip leading and trailing quotes: “ ” " '
        let quoteChars = CharacterSet(charactersIn: "“”\"'«»「」『』")
        text = text.trimmingCharacters(in: quoteChars).trimmingCharacters(in: .whitespacesAndNewlines)
        return text
    }

    /// Attempts to extract selected text using Accessibility API, menu bar copy, and simulated shortcut
    public func extractSelectedText(completion: @escaping (String?) -> Void) {
        STLog("extractSelectedText: starting extraction")

        let frontApp = NSWorkspace.shared.frontmostApplication
        let pid = frontApp?.processIdentifier ?? 0
        let bundleId = frontApp?.bundleIdentifier ?? ""
        STLog("extractSelectedText: target frontmost app = '\(frontApp?.localizedName ?? "unknown")', bundleId = '\(bundleId)', pid = \(pid)")

        // Strategy 1: Direct Accessibility SelectedText
        if let axText = getSelectedTextViaAccessibility(pid: pid),
           Self.isTranslatableText(axText) {
            let clean = Self.cleanExtractedText(axText)
            STLog("extractSelectedText: Strategy 1 (AX) succeeded: '\(clean.prefix(40))'")
            completion(clean)
            return
        }

        // If the frontmost app is Finder, file selection marquee/clicking must NEVER trigger Copy fallback!
        // In Finder, copying without a focused editable text field copies file system items, not text.
        if bundleId == "com.apple.finder" {
            STLog("extractSelectedText: Frontmost app is Finder and no editable text is selected via AX. Skipping Copy fallback to avoid capturing selected files.")
            completion(nil)
            return
        }

        STLog("extractSelectedText: Strategy 1 (AX) yielded no text. Triggering menu & copy fallbacks...")

        // Strategy 2: Menu Bar Copy Action + Keystroke simulation
        getSelectedTextViaCopy(pid: pid) { copiedText in
            if let copiedText = copiedText {
                let clean = Self.cleanExtractedText(copiedText)
                if Self.isTranslatableText(clean) {
                    STLog("extractSelectedText: Strategy 2 (Copy) succeeded: '\(clean.prefix(40))'")
                    completion(clean)
                    return
                }
            }

            STLog("extractSelectedText: All strategies failed to retrieve translatable text")
            completion(nil)
        }
    }

    // MARK: - Accessibility Extraction

    private func getSelectedTextViaAccessibility(pid: pid_t) -> String? {
        // First try system-wide focused element
        let systemWide = AXUIElementCreateSystemWide()
        var focusedUI: AnyObject?
        if AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedUI) == .success,
           let ui = focusedUI {
            var selectedTextValue: AnyObject?
            if AXUIElementCopyAttributeValue(ui as! AXUIElement, kAXSelectedTextAttribute as CFString, &selectedTextValue) == .success,
               let text = selectedTextValue as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return text
            }
        }

        // Next try target application element directly
        if pid > 0 {
            let appElement = AXUIElementCreateApplication(pid)
            var appFocusedUI: AnyObject?
            if AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &appFocusedUI) == .success,
               let ui = appFocusedUI {
                var selectedTextValue: AnyObject?
                if AXUIElementCopyAttributeValue(ui as! AXUIElement, kAXSelectedTextAttribute as CFString, &selectedTextValue) == .success,
                   let text = selectedTextValue as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return text
                }
            }
        }

        return nil
    }

    // MARK: - Menu Bar Copy + Shortcut Simulation

    private func getSelectedTextViaCopy(pid: pid_t, completion: @escaping (String?) -> Void) {
        let pb = NSPasteboard.general
        let initialChangeCount = pb.changeCount
        STLog("getSelectedTextViaCopy: initial pasteboard changeCount = \(initialChangeCount)")

        // Backup current pasteboard items
        var backupItems: [[(NSPasteboard.PasteboardType, Data)]] = []
        if let currentItems = pb.pasteboardItems {
            for item in currentItems {
                var itemData: [(NSPasteboard.PasteboardType, Data)] = []
                for type in item.types {
                    if let data = item.data(forType: type) {
                        itemData.append((type, data))
                    }
                }
                if !itemData.isEmpty {
                    backupItems.append(itemData)
                }
            }
        }

        func restoreClipboard() {
            if !backupItems.isEmpty {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    pb.clearContents()
                    for itemData in backupItems {
                        let item = NSPasteboardItem()
                        for (type, data) in itemData {
                            item.setData(data, forType: type)
                        }
                        pb.writeObjects([item])
                    }
                }
            }
        }

        // Trigger Copy Mechanism A: Native Menu Bar 'Copy' Action via AX
        let menuSuccess = triggerMenuCopy(pid: pid)
        STLog("triggerMenuCopy result: \(menuSuccess)")

        // Trigger Copy Mechanism B: Hardware modifier sequence directly to PID
        if pid > 0 {
            let src = CGEventSource(stateID: .combinedSessionState)
            let cmdKey: CGKeyCode = 0x37
            let cKey: CGKeyCode = 0x08

            let dCmd = CGEvent(keyboardEventSource: src, virtualKey: cmdKey, keyDown: true)
            dCmd?.flags = .maskCommand
            let dC = CGEvent(keyboardEventSource: src, virtualKey: cKey, keyDown: true)
            dC?.flags = .maskCommand
            let uC = CGEvent(keyboardEventSource: src, virtualKey: cKey, keyDown: false)
            uC?.flags = .maskCommand
            let uCmd = CGEvent(keyboardEventSource: src, virtualKey: cmdKey, keyDown: false)

            dCmd?.postToPid(pid)
            dC?.postToPid(pid)
            uC?.postToPid(pid)
            uCmd?.postToPid(pid)

            // Also post to session tap
            dCmd?.post(tap: .cgSessionEventTap)
            dC?.post(tap: .cgSessionEventTap)
            uC?.post(tap: .cgSessionEventTap)
            uCmd?.post(tap: .cgSessionEventTap)
        }

        // Poll pasteboard for changes (up to 450ms in 25ms steps)
        var elapsedMs = 0
        let stepMs = 25
        let maxMs = 450

        func checkPasteboard() {
            if pb.changeCount != initialChangeCount {
                // Reject file/folder/URL drops or Finder node references
                let types = pb.types ?? []
                let hasFilePayload = types.contains(NSPasteboard.PasteboardType("public.file-url")) ||
                                     types.contains(NSPasteboard.PasteboardType("NSFilenamesPboardType")) ||
                                     types.contains(NSPasteboard.PasteboardType("com.apple.finder.noderef"))
                if hasFilePayload {
                    STLog("getSelectedTextViaCopy: Detected file payload (public.file-url / filenames) instead of pure text; discarding.")
                    restoreClipboard()
                    completion(nil)
                    return
                }

                let copiedString = pb.string(forType: .string)
                STLog("getSelectedTextViaCopy: Detected new pasteboard content after \(elapsedMs)ms")
                restoreClipboard()

                if let text = copiedString, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    completion(text)
                } else {
                    completion(nil)
                }
                return
            }

            elapsedMs += stepMs
            if elapsedMs >= maxMs {
                STLog("getSelectedTextViaCopy: Timed out after \(maxMs)ms with no pasteboard change")
                restoreClipboard()
                completion(nil)
                return
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + Double(stepMs) / 1000.0) {
                checkPasteboard()
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + Double(stepMs) / 1000.0) {
            checkPasteboard()
        }
    }

    /// Invokes Edit -> Copy via Accessibility API directly on the target process
    private func triggerMenuCopy(pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        let appElement = AXUIElementCreateApplication(pid)

        var menuBar: AnyObject?
        guard AXUIElementCopyAttributeValue(appElement, kAXMenuBarAttribute as CFString, &menuBar) == .success,
              let mb = menuBar as! AXUIElement? else {
            return false
        }

        var children: AnyObject?
        guard AXUIElementCopyAttributeValue(mb, kAXChildrenAttribute as CFString, &children) == .success,
              let items = children as? [AXUIElement] else {
            return false
        }

        for item in items {
            var title: AnyObject?
            AXUIElementCopyAttributeValue(item, kAXTitleAttribute as CFString, &title)
            let t = title as? String ?? ""
            if t == "Edit" || t == "编辑" {
                var subMenu: AnyObject?
                if AXUIElementCopyAttributeValue(item, kAXChildrenAttribute as CFString, &subMenu) == .success,
                   let subMenus = subMenu as? [AXUIElement], let editMenu = subMenus.first {
                    var editItems: AnyObject?
                    if AXUIElementCopyAttributeValue(editMenu, kAXChildrenAttribute as CFString, &editItems) == .success,
                       let menuItems = editItems as? [AXUIElement] {
                        for m in menuItems {
                            var miTitle: AnyObject?
                            AXUIElementCopyAttributeValue(m, kAXTitleAttribute as CFString, &miTitle)
                            let str = miTitle as? String ?? ""
                            if str.hasPrefix("Copy") || str.hasPrefix("拷贝") || str.hasPrefix("复制") {
                                let res = AXUIElementPerformAction(m, kAXPressAction as CFString)
                                return res == .success
                            }
                        }
                    }
                }
            }
        }

        return false
    }
}
