import AppKit

/// Menu bar status item.
final class MenuBarController: NSObject {
    private var statusItem: NSStatusItem?
    private let observer: WorkflowObserver
    private let analyzer: WorkflowAnalyzer
    private let licenseManager: LicenseManager
    private var isObserving = false

    private var countMenuItem: NSMenuItem?
    private var coverageMenuItem: NSMenuItem?
    private var appsSeenMenuItem: NSMenuItem?
    private var patternsCountMenuItem: NSMenuItem?
    private var licenseStatusMenuItem: NSMenuItem?
    private var toggleMenuItem: NSMenuItem?
    private var analyzeMenuItem: NSMenuItem?
    private var patternsMenuItem: NSMenuItem?
    private var clipboardToggle: NSMenuItem?
    private var valuesToggle: NSMenuItem?
    private var logViewer: ActivityLogWindowController?
    private var statsPanel: NSPanel?
    private var patternsPanel: NSPanel?
    private var licensePanel: NSPanel?
    private var licenseField: NSTextField?

    init(observer: WorkflowObserver, analyzer: WorkflowAnalyzer, licenseManager: LicenseManager) {
        self.observer = observer
        self.analyzer = analyzer
        self.licenseManager = licenseManager
        super.init()
    }

    func setup() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            let initialSymbol = analyzer.canAnalyze ? "circle.fill" : "circle"
            button.image = NSImage(systemSymbolName: initialSymbol, accessibilityDescription: "Patina")
            button.image?.size = NSSize(width: 14, height: 14)
            button.image?.isTemplate = true
        }

        let menu = NSMenu()

        let headerItem = NSMenuItem(title: "Patina", action: nil, keyEquivalent: "")
        headerItem.isEnabled = false
        menu.addItem(headerItem)

        menu.addItem(NSMenuItem.separator())

        countMenuItem = NSMenuItem(title: "Observations: 0", action: nil, keyEquivalent: "")
        countMenuItem?.isEnabled = false
        menu.addItem(countMenuItem!)

        coverageMenuItem = NSMenuItem(title: "Element coverage: --", action: nil, keyEquivalent: "")
        coverageMenuItem?.isEnabled = false
        menu.addItem(coverageMenuItem!)

        appsSeenMenuItem = NSMenuItem(title: "Apps seen: --", action: nil, keyEquivalent: "")
        appsSeenMenuItem?.isEnabled = false
        menu.addItem(appsSeenMenuItem!)

        patternsCountMenuItem = NSMenuItem(title: "Patterns detected: 0", action: nil, keyEquivalent: "")
        patternsCountMenuItem?.isEnabled = false
        menu.addItem(patternsCountMenuItem!)

        menu.addItem(NSMenuItem.separator())

        toggleMenuItem = NSMenuItem(title: "Pause", action: #selector(toggleObserving), keyEquivalent: "p")
        toggleMenuItem?.target = self
        menu.addItem(toggleMenuItem!)

        // Data Capture submenu (opt-in clipboard + field values)
        let captureSubmenu = NSMenu()
        clipboardToggle = NSMenuItem(title: "Capture Clipboard", action: #selector(toggleClipboard), keyEquivalent: "")
        clipboardToggle?.target = self
        clipboardToggle?.state = analyzer.db.getSetting("capture_clipboard") == "1" ? .on : .off
        captureSubmenu.addItem(clipboardToggle!)

        valuesToggle = NSMenuItem(title: "Capture Field Values", action: #selector(toggleFieldValues), keyEquivalent: "")
        valuesToggle?.target = self
        valuesToggle?.state = analyzer.db.getSetting("capture_element_values") == "1" ? .on : .off
        captureSubmenu.addItem(valuesToggle!)

        let captureItem = NSMenuItem(title: "Data Capture", action: nil, keyEquivalent: "")
        captureItem.submenu = captureSubmenu
        menu.addItem(captureItem)

        menu.addItem(NSMenuItem.separator())

        let statsItem = NSMenuItem(title: "Show Stats", action: #selector(showStats), keyEquivalent: "s")
        statsItem.target = self
        menu.addItem(statsItem)

        analyzeMenuItem = NSMenuItem(title: "Run Analysis Now", action: #selector(runAnalysisNow), keyEquivalent: "a")
        analyzeMenuItem?.target = self
        menu.addItem(analyzeMenuItem!)

        patternsMenuItem = NSMenuItem(title: "Show Patterns", action: #selector(showPatterns), keyEquivalent: "d")
        patternsMenuItem?.target = self
        menu.addItem(patternsMenuItem!)

        let logItem = NSMenuItem(title: "View Activity Log", action: #selector(showActivityLog), keyEquivalent: "l")
        logItem.target = self
        menu.addItem(logItem)

        menu.addItem(NSMenuItem.separator())

        licenseStatusMenuItem = NSMenuItem(title: licenseManager.isLicensed ? "Licensed" : "Unlicensed", action: nil, keyEquivalent: "")
        licenseStatusMenuItem?.isEnabled = false
        menu.addItem(licenseStatusMenuItem!)

        let licenseKeyItem = NSMenuItem(title: "Enter License Key...", action: #selector(enterLicenseKey), keyEquivalent: "k")
        licenseKeyItem.target = self
        menu.addItem(licenseKeyItem)

        let buyItem = NSMenuItem(title: "Buy License ($10)...", action: #selector(buyLicense), keyEquivalent: "")
        buyItem.target = self
        menu.addItem(buyItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit Patina", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem?.menu = menu

        NotificationCenter.default.addObserver(self, selector: #selector(observationsDidChange),
                                               name: Notification.Name("patinaObservationsChanged"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(patternsDidChange),
                                               name: Notification.Name("patinaPatternsChanged"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleWindowClosed),
                                               name: Notification.Name("patinaWindowClosed"), object: nil)
    }

    @objc private func observationsDidChange() {
        if let count = try? analyzer.db.observationCount() {
            updateCount(count)
        }
    }

    @objc private func patternsDidChange() {
        if let patterns = try? analyzer.db.allPatterns() {
            patternsCountMenuItem?.title = "Patterns detected: \(patterns.count)"
        }
    }

    /// Single authority for activation policy demotion. Called when any window closes.
    @objc private func handleWindowClosed() {
        if statsPanel == nil && patternsPanel == nil && licensePanel == nil && logViewer?.isVisible != true {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    func startObserving() {
        isObserving = true
        observer.onObservation = { [weak self] count in
            self?.updateCount(count)
        }
        observer.start()
        updateIcon(observing: true)
        toggleMenuItem?.title = "Pause"
    }

    @objc private func toggleObserving() {
        if isObserving {
            observer.stop()
            isObserving = false
            updateIcon(observing: false)
            toggleMenuItem?.title = "Resume"
        } else {
            observer.start()
            isObserving = true
            updateIcon(observing: true)
            toggleMenuItem?.title = "Pause"
        }
    }

    @objc private func toggleClipboard() {
        let current = analyzer.db.getSetting("capture_clipboard") == "1"
        let newVal = current ? "0" : "1"
        analyzer.db.setSetting("capture_clipboard", newVal)
        clipboardToggle?.state = newVal == "1" ? .on : .off
        observer.refreshCaptureSettings()
        updateIcon(observing: isObserving)
        print("[Menu] Clipboard capture: \(newVal == "1" ? "ON" : "OFF")")
    }

    @objc private func toggleFieldValues() {
        let current = analyzer.db.getSetting("capture_element_values") == "1"
        let newVal = current ? "0" : "1"
        analyzer.db.setSetting("capture_element_values", newVal)
        valuesToggle?.state = newVal == "1" ? .on : .off
        observer.refreshCaptureSettings()
        updateIcon(observing: isObserving)
        print("[Menu] Field value capture: \(newVal == "1" ? "ON" : "OFF")")
    }

    @objc private func showActivityLog() {
        if logViewer == nil {
            logViewer = ActivityLogWindowController(db: analyzer.db)
        }
        logViewer?.showWindow()
    }

    @objc private func enterLicenseKey() {
        // Reuse existing panel if open
        if let panel = licensePanel {
            licenseField?.stringValue = ""
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let panel = makeInfoPanel(title: "Enter License Key", width: 400, height: 160)
        licensePanel = panel
        guard let contentView = panel.contentView else { return }

        let label = NSTextField(wrappingLabelWithString: "Paste your Patina license key. Buy one at patina.work if you don't have one.")
        label.frame = NSRect(x: 16, y: 90, width: 368, height: 40)
        label.autoresizingMask = [.width, .maxYMargin]
        label.isSelectable = false
        contentView.addSubview(label)

        let field = NSTextField(frame: NSRect(x: 16, y: 56, width: 368, height: 24))
        field.placeholderString = "pat_..."
        field.autoresizingMask = [.width]
        contentView.addSubview(field)
        licenseField = field

        let cancelBtn = NSButton(title: "Cancel", target: self, action: #selector(licensePanelCancel))
        cancelBtn.frame = NSRect(x: contentView.bounds.width - 176, y: 12, width: 76, height: 28)
        cancelBtn.autoresizingMask = [.minXMargin, .maxYMargin]
        cancelBtn.bezelStyle = .rounded
        cancelBtn.keyEquivalent = "\u{1b}"
        contentView.addSubview(cancelBtn)

        let okBtn = NSButton(title: "OK", target: self, action: #selector(licensePanelOK))
        okBtn.frame = NSRect(x: contentView.bounds.width - 92, y: 12, width: 76, height: 28)
        okBtn.autoresizingMask = [.minXMargin, .maxYMargin]
        okBtn.bezelStyle = .rounded
        okBtn.keyEquivalent = "\r"
        contentView.addSubview(okBtn)

        panel.makeKeyAndOrderFront(nil)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeFirstResponder(field)
    }

    @objc private func licensePanelOK() {
        let value = licenseField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        licensePanel?.close()
        licensePanel = nil
        licenseField = nil
        guard !value.isEmpty else { return }
        licenseManager.setLicenseKey(value)
        licenseStatusMenuItem?.title = licenseManager.isLicensed ? "Licensed" : "Unlicensed (invalid key)"
        updateIcon(observing: isObserving)
        if licenseManager.isLicensed {
            analyzer.startPeriodicAnalysis(intervalMinutes: 30)
        }
    }

    @objc private func licensePanelCancel() {
        licensePanel?.close()
        licensePanel = nil
        licenseField = nil
    }

    @objc private func buyLicense() {
        if let url = URL(string: "https://patina.work/#subscribe") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func runAnalysisNow() {
        guard analyzer.canAnalyze else {
            analyzeMenuItem?.title = "Run Analysis Now (requires license)"
            return
        }
        guard analyzer.manualRunAllowed else {
            print("[Menu] Manual analysis on cooldown")
            return
        }
        print("[Menu] Manual analysis triggered")
        analyzer.recordManualRun()
        analyzeMenuItem?.title = "Analyzing..."
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.analyzer.runAnalysis {
                DispatchQueue.main.async {
                    self?.analyzeMenuItem?.title = "Run Analysis Now"
                }
            }
        }
    }

    @objc private func showPatterns() {
        // If panel exists, just bring it to front and refresh content
        if let panel = patternsPanel {
            refreshPatternsContent(panel)
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let panel = makeInfoPanel(title: "Patina — Patterns", width: 480, height: 400)
        patternsPanel = panel
        refreshPatternsContent(panel)
        panel.makeKeyAndOrderFront(nil)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func refreshPatternsContent(_ panel: NSPanel) {
        guard let contentView = panel.contentView else { return }
        // Remove old content (keep close button = last subview)
        for view in contentView.subviews { view.removeFromSuperview() }

        let patterns = (try? analyzer.db.allPatterns()) ?? []
        let text: String
        if patterns.isEmpty {
            text = "No patterns detected yet.\n\nRun analysis first (⌘A) or wait for the periodic batch."
        } else {
            text = patterns.map { p in
                let name = p.name ?? "Unnamed"
                let conf = p.confidence.map { String(format: "%.0f%%", $0 * 100) } ?? "?"
                var t = "[\(conf)] \(name)\n\(p.description)"
                if let rec = p.recommendation { t += "\n→ \(rec)" }
                return t
            }.joined(separator: "\n\n")
        }
        panel.title = "Patina — Patterns (\(patterns.count))"
        addScrollableText(text, to: contentView)
        addCopyMarkdownButton(to: contentView, enabled: !patterns.isEmpty)
        addCloseButton(to: contentView, panel: panel)
    }

    @objc private func copyPatternsAsMarkdown(_ sender: NSButton) {
        let patterns = (try? analyzer.db.allPatterns()) ?? []
        guard !patterns.isEmpty else { return }
        let stats = analyzer.todayStats()
        let md = PatternExporter.markdown(patterns, observationCount: stats.totalObservations)

        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(md, forType: .string)

        // Brief visual confirmation
        let originalTitle = sender.title
        sender.title = "Copied"
        sender.isEnabled = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak sender] in
            sender?.title = originalTitle
            sender?.isEnabled = true
        }
        print("[Menu] Copied \(patterns.count) patterns as markdown (\(md.count) chars)")
    }

    @objc private func showStats() {
        // If panel exists, just bring it to front and refresh content
        if let panel = statsPanel {
            refreshStatsContent(panel)
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let panel = makeInfoPanel(title: "Patina — Today", width: 420, height: 340)
        statsPanel = panel
        refreshStatsContent(panel)
        panel.makeKeyAndOrderFront(nil)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func refreshStatsContent(_ panel: NSPanel) {
        guard let contentView = panel.contentView else { return }
        for view in contentView.subviews { view.removeFromSuperview() }

        let stats = analyzer.todayStats()
        var msg = """
        Today's observations:  \(stats.totalObservations)
        App switches:          \(stats.appSwitches)
        Focus changes:         \(stats.focusChanges)
        Unique apps:           \(stats.uniqueApps)
        Element coverage:      \(String(format: "%.0f%%", stats.elementCoverage))
        """

        let cal = Calendar(identifier: .gregorian)
        var utc = cal
        utc.timeZone = TimeZone(identifier: "UTC")!
        let comps = utc.dateComponents([.year, .month, .day], from: Date())
        let sessionId = String(format: "%04d-%02d-%02d", comps.year!, comps.month!, comps.day!)
        if let coverage = try? analyzer.db.coverageStats(sessionId: sessionId), !coverage.isEmpty {
            msg += "\n\nPer-app coverage:"
            for app in coverage.prefix(10) {
                msg += "\n  \(app.appName): \(String(format: "%.0f%%", app.coveragePercent)) (\(app.pollsWithData)/\(app.totalPolls))"
            }
        }

        addScrollableText(msg, to: contentView)
        addCloseButton(to: contentView, panel: panel)
    }

    @objc private func quit() {
        observer.stop()
        NSApplication.shared.terminate(nil)
    }

    // MARK: - Non-modal info panels

    /// Install a minimal Edit menu so Cmd+C/V/X/A work in .accessory mode.
    private func installEditMenuIfNeeded() {
        guard NSApp.mainMenu == nil || NSApp.mainMenu?.item(withTitle: "Edit") == nil else { return }
        let mainMenu = NSApp.mainMenu ?? NSMenu()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu
    }

    /// Create a floating NSPanel for read-only info display.
    private func makeInfoPanel(title: String, width: CGFloat, height: CGFloat) -> NSPanel {
        installEditMenuIfNeeded()

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = title
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.center()
        panel.isReleasedWhenClosed = false

        // Clean up reference when user closes the panel
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: panel, queue: .main) { [weak self] note in
            guard let self = self, let closedPanel = note.object as? NSPanel else { return }
            if closedPanel === self.statsPanel { self.statsPanel = nil }
            if closedPanel === self.patternsPanel { self.patternsPanel = nil }
            if closedPanel === self.licensePanel { self.licensePanel = nil; self.licenseField = nil }
            // Defer demotion so it runs after the close completes
            DispatchQueue.main.async { [weak self] in
                self?.handleWindowClosed()
            }
        }
        return panel
    }

    /// Add a scrollable text view with monospaced font to a content view.
    private func addScrollableText(_ text: String, to contentView: NSView) {
        let scrollView = NSScrollView(frame: contentView.bounds.insetBy(dx: 12, dy: 44))
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder

        let textView = NSTextView(frame: scrollView.bounds)
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.autoresizingMask = [.width]
        textView.string = text

        scrollView.documentView = textView
        contentView.addSubview(scrollView)
    }

    /// Add a Close button in the bottom-right corner.
    private func addCloseButton(to contentView: NSView, panel: NSPanel) {
        let btn = NSButton(title: "Close", target: panel, action: #selector(NSPanel.performClose(_:)))
        btn.frame = NSRect(x: contentView.bounds.width - 88, y: 8, width: 76, height: 28)
        btn.autoresizingMask = [.minXMargin, .maxYMargin]
        btn.bezelStyle = .rounded
        btn.keyEquivalent = "\u{1b}" // Escape key closes
        contentView.addSubview(btn)
    }

    /// Add a "Copy as Markdown" button to the bottom-left of the patterns panel.
    /// Disabled when there are no patterns to export.
    private func addCopyMarkdownButton(to contentView: NSView, enabled: Bool) {
        let btn = NSButton(title: "Copy as Markdown", target: self, action: #selector(copyPatternsAsMarkdown(_:)))
        btn.frame = NSRect(x: 12, y: 8, width: 160, height: 28)
        btn.autoresizingMask = [.maxXMargin, .maxYMargin]
        btn.bezelStyle = .rounded
        btn.isEnabled = enabled
        contentView.addSubview(btn)
    }

    private func updateCount(_ count: Int) {
        countMenuItem?.title = "Observations: \(count)"
        if count % 10 == 0 {
            let stats = analyzer.todayStats()
            coverageMenuItem?.title = "Element coverage: \(String(format: "%.0f%%", stats.elementCoverage))"
            appsSeenMenuItem?.title = "Apps seen: \(stats.uniqueApps)"
        }
        // Update pattern count less frequently
        if count % 50 == 0 {
            if let patterns = try? analyzer.db.allPatterns() {
                patternsCountMenuItem?.title = "Patterns detected: \(patterns.count)"
            }
        }
    }

    private func updateIcon(observing: Bool) {
        let enhancedCapture = analyzer.db.getSetting("capture_clipboard") == "1"
                           || analyzer.db.getSetting("capture_element_values") == "1"
        let symbolName: String
        if !analyzer.canAnalyze {
            symbolName = "circle"
        } else if observing && enhancedCapture {
            symbolName = "circle.inset.filled"  // Double-circle: enhanced capture active
        } else {
            symbolName = observing ? "circle.fill" : "circle"
        }
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Patina")
            button.image?.size = NSSize(width: 14, height: 14)
            button.image?.isTemplate = true
        }
    }
}
