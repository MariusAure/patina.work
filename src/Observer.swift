import AppKit
import ApplicationServices

/// Observes app switches, focus changes, and AX element data.
/// Writes platform-neutral observations to SQLite. No AX types escape this file.
final class WorkflowObserver {
    private let db: PatinaDatabase
    private let sessionId: String
    private var isRunning = false
    private var observationCount = 0

    // CGEvent tap for click detection
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    // Dedup state — accessed only on stateQueue
    private var lastAppId: String?
    private var lastWindowTitle: String?
    private var lastDedupKey: DedupKey?
    private var lastClickDedupTime: Date = .distantPast

    // Clipboard monitoring state — accessed only on stateQueue
    private var lastClipboardChangeCount: Int = NSPasteboard.general.changeCount
    private var captureClipboard: Bool = false

    // Element value capture state — accessed only on stateQueue
    private var captureElementValues: Bool = false
    private var pendingElementValue: String?

    // Tracks when an excluded app was last frontmost (for clipboard safety)
    private var lastExcludedAppFrontmost: Bool = false

    // Settings refresh — counter incremented before modulo checks in polling loop
    private var settingsRefreshCounter: Int = 0

    // All state mutations happen on this queue to avoid data races
    private let stateQueue = DispatchQueue(label: "patina.observer.state")

    var onObservation: ((Int) -> Void)?

    /// Apps excluded from observation by default (password managers, sensitive apps)
    private let defaultExcludedApps: Set<String> = [
        "com.1password.1password",
        "com.agilebits.onepassword7",           // 1Password 7
        "com.bitwarden.desktop",
        "com.lastpass.LastPass",
        "com.dashlane.Dashlane",
        "com.apple.keychainaccess",
        "org.keepassxc.keepassxc",
        "com.enpass.Enpass",
    ]

    private struct DedupKey: Equatable {
        let appId: String
        let role: String?
        let title: String?
    }

    init(db: PatinaDatabase) {
        self.db = db
        let cal = Calendar(identifier: .gregorian)
        var utcCal = cal
        utcCal.timeZone = TimeZone(identifier: "UTC")!
        let comps = utcCal.dateComponents([.year, .month, .day], from: Date())
        self.sessionId = String(format: "%04d-%02d-%02d", comps.year!, comps.month!, comps.day!)
    }

    /// Reload capture_clipboard and capture_element_values from DB settings.
    func refreshCaptureSettings() {
        let clipboard = db.getSetting("capture_clipboard") == "1"
        let values = db.getSetting("capture_element_values") == "1"
        stateQueue.sync {
            captureClipboard = clipboard
            captureElementValues = values
        }
    }

    func start() {
        stateQueue.sync {
            guard !isRunning else { return }
            isRunning = true
            lastClipboardChangeCount = NSPasteboard.general.changeCount
        }
        refreshCaptureSettings()
        print("[Observer] Started. Session: \(sessionId)")

        if let app = NSWorkspace.shared.frontmostApplication {
            recordAppSwitch(app)
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(appDidActivate(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )

        startEventTap()
        startFocusPolling()
    }

    func stop() {
        stateQueue.sync {
            isRunning = false
        }
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            }
        }
        eventTap = nil
        runLoopSource = nil
        var finalCount = 0
        stateQueue.sync { finalCount = observationCount }
        print("[Observer] Stopped. Observations this session: \(finalCount)")
    }

    var count: Int {
        stateQueue.sync { observationCount }
    }

    @objc private func appDidActivate(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        var running = false
        stateQueue.sync { running = isRunning }
        guard running else { return }
        recordAppSwitch(app)
    }

    private func recordAppSwitch(_ app: NSRunningApplication) {
        let appId = app.bundleIdentifier ?? "unknown"
        let appName = app.localizedName ?? "Unknown"

        guard appId != Bundle.main.bundleIdentifier else { return }

        // Track excluded app state for clipboard safety
        if defaultExcludedApps.contains(appId) {
            stateQueue.sync { lastExcludedAppFrontmost = true }
            return
        }
        stateQueue.sync { lastExcludedAppFrontmost = false }

        var isDuplicate = false
        stateQueue.sync {
            isDuplicate = (appId == lastAppId)
            if !isDuplicate {
                lastAppId = appId
                lastDedupKey = nil  // Reset dedup on app switch
            }
        }
        guard !isDuplicate else { return }

        let windowTitle = axWindowTitle(for: app)
        stateQueue.sync { lastWindowTitle = windowTitle }

        write(ObservationRow(
            timestamp: ISO8601Formatter.now(),
            appId: appId,
            appName: appName,
            windowTitle: windowTitle,
            eventType: "app_switch",
            sessionId: sessionId
        ))
    }

    // MARK: - CGEvent tap for click detection

    private func startEventTap() {
        let eventMask = (1 << CGEventType.leftMouseDown.rawValue) |
                        (1 << CGEventType.rightMouseDown.rawValue)

        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { _, _, event, refcon -> Unmanaged<CGEvent>? in
                guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
                let observer = Unmanaged<WorkflowObserver>.fromOpaque(refcon).takeUnretainedValue()
                let location = event.location
                // Dispatch AX lookup off the callback thread to avoid tap timeout
                DispatchQueue.global(qos: .utility).async { [weak observer] in
                    observer?.handleClick(at: location)
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: userInfo
        ) else {
            print("[Observer] CGEvent tap creation failed — Input Monitoring permission may be needed")
            return
        }

        self.eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        print("[Observer] CGEvent tap active (leftMouseDown + rightMouseDown)")
    }

    private func handleClick(at point: CGPoint) {
        var running = false
        stateQueue.sync { running = isRunning }
        guard running else { return }

        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        let appId = app.bundleIdentifier ?? "unknown"
        let appName = app.localizedName ?? "Unknown"

        guard appId != Bundle.main.bundleIdentifier else { return }
        guard !defaultExcludedApps.contains(appId) else { return }

        let pid = app.processIdentifier
        let axApp = AXUIElementCreateApplication(pid)

        var elementRef: AXUIElement?
        let result = AXUIElementCopyElementAtPosition(axApp, Float(point.x), Float(point.y), &elementRef)

        guard result == .success, let element = elementRef else {
            writeCoverageLog(appId: appId, appName: appName, hasElementData: false)
            return
        }

        let role = axString(element, kAXRoleAttribute)
        let title = axString(element, kAXTitleAttribute) ?? axString(element, kAXDescriptionAttribute)

        // Skip password fields
        let subrole = axString(element, kAXSubroleAttribute)
        if subrole == "AXSecureTextField" { return }
        let roleDesc = axString(element, kAXRoleDescriptionAttribute)
        if let rd = roleDesc?.lowercased(), rd.contains("secure") || rd.contains("password") { return }
        if let t = title?.lowercased(), t.contains("password") || t.contains("passwor") || t.contains("passord") { return }

        let portableRole = mapRole(role)
        let hasUsefulClick = portableRole != nil || title != nil

        // Log coverage BEFORE dedup — measures AX reliability per app
        writeCoverageLog(appId: appId, appName: appName, hasElementData: hasUsefulClick)

        guard hasUsefulClick else { return }

        // Time-windowed dedup: same (appId, role, title) within 0.3s = skip (absorbs double-clicks)
        let key = DedupKey(appId: appId, role: portableRole, title: title)
        let now = Date()
        var isDuplicate = false
        stateQueue.sync {
            if key == lastDedupKey && now.timeIntervalSince(lastClickDedupTime) < 0.3 {
                isDuplicate = true
            }
            if !isDuplicate {
                lastDedupKey = key
                lastClickDedupTime = now
            }
        }
        guard !isDuplicate else { return }

        let windowTitle = axWindowTitle(for: app)

        write(ObservationRow(
            timestamp: ISO8601Formatter.now(),
            appId: appId,
            appName: appName,
            windowTitle: windowTitle,
            elementRole: portableRole,
            elementTitle: title,
            eventType: "click",
            sessionId: sessionId
        ))
    }

    // MARK: - Focus polling

    private func startFocusPolling() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            while true {
                guard let self = self else { return }
                var running = false
                self.stateQueue.sync { running = self.isRunning }
                guard running else { return }
                self.pollFocusedElement()
                self.pollClipboard()
                // Refresh capture settings every 60 seconds
                self.stateQueue.sync { self.settingsRefreshCounter += 1 }
                var counter = 0
                self.stateQueue.sync { counter = self.settingsRefreshCounter }
                if counter % 60 == 0 { self.refreshCaptureSettings() }
                if counter % 3600 == 0 { self.db.pruneCoverageLog() }
                Thread.sleep(forTimeInterval: 1.0)
            }
        }
    }

    private func pollFocusedElement() {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        let appId = app.bundleIdentifier ?? "unknown"
        let appName = app.localizedName ?? "Unknown"

        guard appId != Bundle.main.bundleIdentifier else { return }
        guard !defaultExcludedApps.contains(appId) else { return }

        let pid = app.processIdentifier
        let axApp = AXUIElementCreateApplication(pid)

        var focusedRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &focusedRef)

        // Coverage logging: record every poll attempt, regardless of dedup.
        // This measures "does AX work for this app" — the diagnostic question.
        if result != .success {
            writeCoverageLog(appId: appId, appName: appName, hasElementData: false)
            return
        }

        // CF type downcast always succeeds — force cast is safe here
        let element = focusedRef as! AXUIElement

        let role = axString(element, kAXRoleAttribute)
        let title = axString(element, kAXTitleAttribute) ?? axString(element, kAXDescriptionAttribute)

        // Skip password fields — defense in depth
        let subrole = axString(element, kAXSubroleAttribute)
        if subrole == "AXSecureTextField" { return }

        // Electron/web password heuristic: check role description and title
        let roleDesc = axString(element, kAXRoleDescriptionAttribute)
        if let rd = roleDesc?.lowercased(), rd.contains("secure") || rd.contains("password") { return }
        if let t = title?.lowercased(), t.contains("password") || t.contains("passwor") || t.contains("passord") { return }

        let portableRole = mapRole(role)

        // Element value capture: read AXValue for text-bearing roles
        var captureValues = false
        stateQueue.sync { captureValues = captureElementValues }
        let valueRoles: Set<String> = ["text_field", "combo_box", "web_content"]
        if captureValues, let pr = portableRole, valueRoles.contains(pr) {
            let rawValue = axString(element, kAXValueAttribute)
            if let raw = rawValue {
                let truncated = raw.count > 500 ? String(raw.prefix(500)) : raw
                stateQueue.sync { pendingElementValue = truncated }
            }
        }

        let hasUsefulElement = portableRole != nil || title != nil

        // Log coverage BEFORE dedup — measures AX API reliability, not unique elements
        writeCoverageLog(appId: appId, appName: appName, hasElementData: hasUsefulElement)

        guard hasUsefulElement else { return }

        // Dedup on (appId, role, title) — element value NOT in dedup key
        let key = DedupKey(appId: appId, role: portableRole, title: title)
        var isDuplicate = false
        var departureValue: String? = nil
        stateQueue.sync {
            isDuplicate = (key == lastDedupKey)
            if !isDuplicate {
                // Focus departing previous element — flush pending value
                departureValue = pendingElementValue
                pendingElementValue = nil
                lastDedupKey = key
            }
        }

        // Write departure value to the previous observation (if any)
        // Redact credential tokens but preserve the rest for workflow context
        if let depValue = departureValue, captureValues {
            let redacted = CredentialDetector.redactTokens(depValue)
            let sanitized = sanitizeForLog(redacted) ?? redacted
            db.updateLastElementValue(sessionId: sessionId, value: sanitized)
        }

        guard !isDuplicate else { return }

        let windowTitle = axWindowTitle(for: app)

        write(ObservationRow(
            timestamp: ISO8601Formatter.now(),
            appId: appId,
            appName: appName,
            windowTitle: windowTitle,
            elementRole: portableRole,
            elementTitle: title,
            eventType: "focus_change",
            sessionId: sessionId
        ))
    }

    // MARK: - Clipboard monitoring

    private func pollClipboard() {
        var shouldCapture = false
        stateQueue.sync { shouldCapture = captureClipboard }
        guard shouldCapture else { return }

        let pb = NSPasteboard.general
        let currentCount = pb.changeCount
        var lastCount = 0
        stateQueue.sync { lastCount = lastClipboardChangeCount }
        guard currentCount != lastCount else { return }
        stateQueue.sync { lastClipboardChangeCount = currentCount }

        // Check which app is frontmost RIGHT NOW (at the moment clipboard changed).
        // If an excluded app (password manager) is frontmost, skip entirely.
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        let appId = app.bundleIdentifier ?? "unknown"
        guard !defaultExcludedApps.contains(appId) else {
            print("[Observer] Clipboard change from excluded app — skipping")
            return
        }

        // Also skip if excluded app was the last frontmost app (covers the case where
        // the clipboard write is processed after the user already switched away)
        var wasExcluded = false
        stateQueue.sync { wasExcluded = lastExcludedAppFrontmost }
        guard !wasExcluded else {
            print("[Observer] Clipboard change shortly after excluded app — skipping")
            return
        }

        // Read string content only
        guard let content = pb.string(forType: .string), !content.isEmpty else { return }

        // Skip very large clipboard content (likely not a credential, but also not useful)
        guard content.count <= 2000 else { return }

        // Credential detection — token-scan for secrets in multi-line/mixed content
        guard CredentialDetector.isTextSafe(content) else {
            print("[Observer] Clipboard credential detected — skipping")
            return
        }

        // Sanitize and truncate for storage
        let sanitized = sanitizeForLog(content) ?? content
        let truncated = sanitized.count > 500 ? String(sanitized.prefix(500)) + "..." : sanitized

        let appName = app.localizedName ?? "Unknown"
        let windowTitle = axWindowTitle(for: app)

        write(ObservationRow(
            timestamp: ISO8601Formatter.now(),
            appId: appId,
            appName: appName,
            windowTitle: windowTitle,
            elementValue: truncated,
            eventType: "clipboard_change",
            sessionId: sessionId,
            source: "clipboard"
        ))
    }

    private func axWindowTitle(for app: NSRunningApplication) -> String? {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
              windowRef != nil else { return nil }
        let window = windowRef as! AXUIElement
        guard let title = axString(window, kAXTitleAttribute) else { return nil }
        // Redact any credential tokens embedded in window titles (e.g., terminal showing API keys)
        return CredentialDetector.redactTokens(title)
    }

    private func axString(_ element: AXUIElement, _ attribute: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success,
              let val = ref as? String, !val.isEmpty else { return nil }
        return val
    }

    private func mapRole(_ role: String?) -> String? {
        guard let role = role else { return nil }
        switch role {
        case "AXTextField", "AXTextArea": return "text_field"
        case "AXButton": return "button"
        case "AXStaticText": return "static_text"
        case "AXMenuItem": return "menu_item"
        case "AXCheckBox": return "checkbox"
        case "AXComboBox", "AXPopUpButton": return "combo_box"
        case "AXList": return "list"
        case "AXTable", "AXOutline": return "table"
        case "AXWebArea": return "web_content"
        case "AXGroup": return "group"
        case "AXLink": return "link"
        case "AXTab", "AXTabGroup": return "tab"
        case "AXRadioButton": return "radio"
        case "AXSheet", "AXDialog": return "dialog"
        // Noise — skip these entirely
        case "AXToolbar": return nil
        case "AXScrollArea": return nil
        case "AXImage": return nil
        case "AXMenuBar": return nil
        case "AXSplitGroup": return nil
        case "AXHelpTag": return nil
        default: return "unknown"
        }
    }

    private func write(_ obs: ObservationRow) {
        do {
            try db.insertObservation(obs)
            var currentCount = 0
            stateQueue.sync {
                observationCount += 1
                currentCount = observationCount
            }
            DispatchQueue.main.async { [weak self] in
                self?.onObservation?(currentCount)
            }
            if currentCount <= 5 || currentCount % 100 == 0 {
                let safeWindow = sanitizeForLog(obs.windowTitle) ?? "no title"
                let safeElement = sanitizeForLog(obs.elementTitle)
                let displayTitle = safeElement ?? safeWindow
                print("[Observer] #\(currentCount): \(obs.eventType) — \(obs.appName) — \(obs.elementRole ?? "no role") — \(displayTitle)")
            }
        } catch {
            print("[Observer] Write error: \(error)")
        }
    }

    private func writeCoverageLog(appId: String, appName: String, hasElementData: Bool) {
        do {
            try db.insertCoverageLog(appId: appId, appName: appName, hasElementData: hasElementData,
                                     timestamp: ISO8601Formatter.now(), sessionId: sessionId)
        } catch {
            // Coverage logging is best-effort — don't crash on failure
        }
    }
}
