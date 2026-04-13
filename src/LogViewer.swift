import AppKit

/// Activity log window — shows all recorded observations with search, filter, deletion.
/// The trust mechanism: workers see and control their data.
final class ActivityLogWindowController: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private let db: PatinaDatabase
    private var window: NSWindow?
    private var tableView: NSTableView!
    private var scrollView: NSScrollView!
    private var searchField: NSSearchField!
    private var dateSegment: NSSegmentedControl!
    private var statusLabel: NSTextField!

    private var rows: [ObservationRow] = []
    private var totalCount: Int = 0
    private var isLoadingMore = false
    private let pageSize = 500

    // Current filter state
    private var searchText: String?
    private var sinceDate: Date?
    private var searchDebounceItem: DispatchWorkItem?

    // Timestamp formatters
    private let todayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
    private let olderFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d HH:mm"
        return f
    }()
    private let isoParser: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private let columnIDs = [
        NSUserInterfaceItemIdentifier("Time"),
        NSUserInterfaceItemIdentifier("App"),
        NSUserInterfaceItemIdentifier("Event"),
        NSUserInterfaceItemIdentifier("Window"),
        NSUserInterfaceItemIdentifier("Role"),
        NSUserInterfaceItemIdentifier("Element"),
        NSUserInterfaceItemIdentifier("Value")
    ]

    init(db: PatinaDatabase) {
        self.db = db
        super.init()
    }

    var isVisible: Bool { window?.isVisible ?? false }

    func showWindow() {
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        w.title = "Patina — Activity Log"
        w.minSize = NSSize(width: 600, height: 400)
        w.center()
        w.delegate = self

        let contentView = NSView(frame: w.contentView!.bounds)
        contentView.autoresizingMask = [.width, .height]
        w.contentView = contentView

        // Top bar
        let topBar = NSView(frame: NSRect(x: 0, y: contentView.bounds.height - 40, width: contentView.bounds.width, height: 40))
        topBar.autoresizingMask = [.width, .minYMargin]

        searchField = NSSearchField(frame: NSRect(x: 8, y: 8, width: 300, height: 24))
        searchField.placeholderString = "Search apps, windows, elements..."
        searchField.autoresizingMask = [.maxXMargin]
        searchField.target = self
        searchField.action = #selector(searchChanged(_:))
        topBar.addSubview(searchField)

        dateSegment = NSSegmentedControl(labels: ["Today", "7 Days", "All"], trackingMode: .selectOne, target: self, action: #selector(dateFilterChanged(_:)))
        dateSegment.frame = NSRect(x: topBar.bounds.width - 220, y: 8, width: 210, height: 24)
        dateSegment.autoresizingMask = [.minXMargin]
        dateSegment.selectedSegment = 2  // "All" by default
        topBar.addSubview(dateSegment)

        contentView.addSubview(topBar)

        // Bottom bar
        let bottomBar = NSView(frame: NSRect(x: 0, y: 0, width: contentView.bounds.width, height: 36))
        bottomBar.autoresizingMask = [.width, .maxYMargin]

        statusLabel = NSTextField(labelWithString: "Loading...")
        statusLabel.frame = NSRect(x: 8, y: 8, width: 300, height: 20)
        statusLabel.autoresizingMask = [.maxXMargin]
        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        bottomBar.addSubview(statusLabel)

        let deleteAllBtn = NSButton(title: "Delete All", target: self, action: #selector(deleteAllTapped))
        deleteAllBtn.frame = NSRect(x: bottomBar.bounds.width - 90, y: 6, width: 82, height: 24)
        deleteAllBtn.autoresizingMask = [.minXMargin]
        deleteAllBtn.bezelStyle = .rounded
        deleteAllBtn.font = NSFont.systemFont(ofSize: 11)
        bottomBar.addSubview(deleteAllBtn)

        let deleteSelBtn = NSButton(title: "Delete Selected", target: self, action: #selector(deleteSelectedTapped))
        deleteSelBtn.frame = NSRect(x: bottomBar.bounds.width - 210, y: 6, width: 112, height: 24)
        deleteSelBtn.autoresizingMask = [.minXMargin]
        deleteSelBtn.bezelStyle = .rounded
        deleteSelBtn.font = NSFont.systemFont(ofSize: 11)
        bottomBar.addSubview(deleteSelBtn)

        contentView.addSubview(bottomBar)

        // Table view
        tableView = NSTableView()
        tableView.style = .plain
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.rowHeight = 20
        tableView.intercellSpacing = NSSize(width: 6, height: 2)

        let columns: [(String, CGFloat, CGFloat)] = [
            ("Time", 130, 90),
            ("App", 110, 70),
            ("Event", 90, 70),
            ("Window", 170, 80),
            ("Role", 70, 50),
            ("Element", 150, 80),
            ("Value", 150, 80)
        ]

        for (i, (title, width, minWidth)) in columns.enumerated() {
            let col = NSTableColumn(identifier: columnIDs[i])
            col.title = title
            col.width = width
            col.minWidth = minWidth
            if i == columns.count - 1 {
                col.resizingMask = [.autoresizingMask, .userResizingMask]
            } else {
                col.resizingMask = .userResizingMask
            }
            tableView.addTableColumn(col)
        }

        tableView.dataSource = self
        tableView.delegate = self

        scrollView = NSScrollView(frame: NSRect(x: 0, y: 36, width: contentView.bounds.width, height: contentView.bounds.height - 76))
        scrollView.autoresizingMask = [.width, .height]
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false

        contentView.addSubview(scrollView)

        // Observe scroll for lazy loading
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrollViewDidScroll(_:)),
            name: NSScrollView.didLiveScrollNotification,
            object: scrollView
        )

        self.window = w

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)

        loadData(reset: true)
    }

    // MARK: - Data loading

    private func loadData(reset: Bool) {
        let search = searchText
        let since = sinceDate
        let offset = reset ? 0 : rows.count
        let limit = pageSize

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let newRows = self.db.queryObservations(search: search, since: since, limit: limit, offset: offset)
            let total = self.db.queryObservationCount(search: search, since: since)

            DispatchQueue.main.async {
                if reset {
                    self.rows = newRows
                } else {
                    self.rows.append(contentsOf: newRows)
                }
                self.totalCount = total
                self.isLoadingMore = false
                self.tableView.reloadData()
                self.updateStatus()
            }
        }
    }

    private func updateStatus() {
        statusLabel.stringValue = "Showing \(rows.count) of \(totalCount) observations"
    }

    // MARK: - Search

    @objc private func searchChanged(_ sender: NSSearchField) {
        searchDebounceItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            let text = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            self.searchText = text.isEmpty ? nil : text
            self.loadData(reset: true)
        }
        searchDebounceItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
    }

    // MARK: - Date filter

    @objc private func dateFilterChanged(_ sender: NSSegmentedControl) {
        let cal = Calendar.current
        switch sender.selectedSegment {
        case 0: // Today
            sinceDate = cal.startOfDay(for: Date())
        case 1: // 7 Days
            sinceDate = cal.date(byAdding: .day, value: -7, to: cal.startOfDay(for: Date()))
        default: // All
            sinceDate = nil
        }
        loadData(reset: true)
    }

    // MARK: - Lazy loading on scroll

    @objc private func scrollViewDidScroll(_ notification: Notification) {
        guard !isLoadingMore, rows.count < totalCount else { return }
        let clipView = scrollView.contentView
        let visibleEnd = clipView.bounds.origin.y + clipView.bounds.height
        let contentHeight = tableView.frame.height
        if visibleEnd > contentHeight - 100 {
            isLoadingMore = true
            loadData(reset: false)
        }
    }

    // MARK: - Deletion

    @objc private func deleteSelectedTapped() {
        let selected = tableView.selectedRowIndexes
        guard !selected.isEmpty else { return }

        let ids = selected.compactMap { rows[$0].id }
        guard !ids.isEmpty else { return }

        let alert = NSAlert()
        alert.messageText = "Delete \(ids.count) observations?"
        alert.informativeText = "This cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        db.deleteObservations(ids: ids)
        loadData(reset: true)
        NotificationCenter.default.post(name: Notification.Name("patinaObservationsChanged"), object: nil)
    }

    @objc private func deleteAllTapped() {
        let alert = NSAlert()
        alert.messageText = "Delete all observations?"
        alert.informativeText = "This will permanently delete all observations. This cannot be undone."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Delete All")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        db.deleteAllObservations()
        rows = []
        totalCount = 0
        tableView.reloadData()
        updateStatus()
        NotificationCenter.default.post(name: Notification.Name("patinaObservationsChanged"), object: nil)
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let colID = tableColumn?.identifier, row < rows.count else { return nil }
        let obs = rows[row]

        let cellID = NSUserInterfaceItemIdentifier("Cell_\(colID.rawValue)")
        let cell: NSTextField
        if let existing = tableView.makeView(withIdentifier: cellID, owner: self) as? NSTextField {
            cell = existing
        } else {
            cell = NSTextField(labelWithString: "")
            cell.identifier = cellID
            cell.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
            cell.lineBreakMode = .byTruncatingTail
            cell.cell?.truncatesLastVisibleLine = true
        }

        switch colID {
        case columnIDs[0]: // Time
            cell.stringValue = formatTimestamp(obs.timestamp)
        case columnIDs[1]: // App
            cell.stringValue = obs.appName
        case columnIDs[2]: // Event
            cell.stringValue = obs.eventType
        case columnIDs[3]: // Window
            cell.stringValue = sanitizeForLog(obs.windowTitle) ?? ""
        case columnIDs[4]: // Role
            cell.stringValue = obs.elementRole ?? ""
        case columnIDs[5]: // Element
            cell.stringValue = sanitizeForLog(obs.elementTitle) ?? ""
        case columnIDs[6]: // Value
            cell.stringValue = sanitizeForLog(obs.elementValue) ?? ""
        default:
            break
        }

        return cell
    }

    // MARK: - Timestamp formatting

    private func formatTimestamp(_ iso: String) -> String {
        guard let date = isoParser.date(from: iso) else { return iso }
        if Calendar.current.isDateInToday(date) {
            return todayFormatter.string(from: date)
        }
        return olderFormatter.string(from: date)
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self, name: NSScrollView.didLiveScrollNotification, object: scrollView)
        // Nil out window so isVisible returns false before the demotion check
        window = nil
        // Let MenuBarController decide based on all window state
        NotificationCenter.default.post(name: Notification.Name("patinaWindowClosed"), object: nil)
    }
}
