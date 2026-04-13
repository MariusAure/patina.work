import AppKit

/// Redirect all stdout/stderr to a log file so we can debug menu bar apps.
func setupFileLogging() {
    let logPath = NSString("~/Library/Application Support/Patina/patina.log").expandingTildeInPath

    // Rotate if log exceeds 5 MB
    let fm = FileManager.default
    if fm.fileExists(atPath: logPath),
       let attrs = try? fm.attributesOfItem(atPath: logPath),
       let size = attrs[.size] as? UInt64,
       size > 5 * 1024 * 1024 {
        let rotatedPath = logPath + ".1"
        try? fm.removeItem(atPath: rotatedPath)
        try? fm.moveItem(atPath: logPath, toPath: rotatedPath)
    }

    freopen(logPath, "a", stdout)
    freopen(logPath, "a", stderr)
    setbuf(stdout, nil)  // Unbuffered
    setbuf(stderr, nil)
}

class PatinaAppDelegate: NSObject, NSApplicationDelegate {
    var menuBar: MenuBarController?
    var notifier: PatternNotifier?
    var lockFd: Int32 = -1  // Single-instance flock — kept open for process lifetime

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let db = try PatinaDatabase()
            db.pruneCoverageLog()
            let count = try db.observationCount()
            print("[Patina] DB ready. Existing observations: \(count)")

            // First-run onboarding (includes AX permission pre-framing)
            if !Onboarding.isComplete(db: db) {
                let granted = Onboarding.run(db: db)
                if !granted {
                    print("[Patina] AX not yet granted. Will observe once permission is enabled.")
                }
            } else {
                // Not first run — check AX trust and remind if missing
                let trusted = AXIsProcessTrustedWithOptions(
                    [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): false] as CFDictionary
                )
                if !trusted {
                    print("[Patina] Accessibility permission not granted.")
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate(ignoringOtherApps: true)

                    let alert = NSAlert()
                    alert.messageText = "Patina needs Accessibility access"
                    alert.informativeText = "Patina cannot observe your workflow without Accessibility access.\n\nGrant access in System Settings > Privacy & Security > Accessibility."
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "Open System Settings")
                    alert.addButton(withTitle: "Continue anyway")
                    alert.addButton(withTitle: "Quit")

                    let result = alert.runModal()
                    if result == .alertFirstButtonReturn {
                        // Open System Settings to Accessibility pane
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                            NSWorkspace.shared.open(url)
                        }
                    } else if result == .alertThirdButtonReturn {
                        NSApp.terminate(nil)
                        return
                    }

                    NSApp.setActivationPolicy(.accessory)
                }
            }

            // Set up notification system
            let patternNotifier = PatternNotifier(db: db)
            self.notifier = patternNotifier

            let license = LicenseManager(db: db)
            let observer = WorkflowObserver(db: db)
            let analyzer = WorkflowAnalyzer(db: db)
            analyzer.licenseManager = license
            analyzer.notifier = patternNotifier
            if analyzer.canAnalyze {
                analyzer.startPeriodicAnalysis(intervalMinutes: 30)
            }
            let menu = MenuBarController(observer: observer, analyzer: analyzer, licenseManager: license)
            menu.setup()
            menu.startObserving()
            menuBar = menu

            // Schedule a first-session summary notification after 4 hours of observation
            scheduleFirstSessionSummary(db: db, notifier: patternNotifier)

            print("[Patina] Running. Menu bar icon active.")
        } catch {
            print("[Patina] Fatal: \(error)")
            NSApplication.shared.terminate(nil)
        }
    }

    /// After 4 hours, send a summary notification if this is the first day.
    /// Designer spec: "After 4 hours of observation, before any API call for pattern detection,
    /// show the user their raw observations."
    private func scheduleFirstSessionSummary(db: PatinaDatabase, notifier: PatternNotifier) {
        let alreadySent = db.getSetting("first_summary_sent") == "1"
        guard !alreadySent else { return }

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 4 * 60 * 60) {
            let stats = (try? db.observationCount()) ?? 0
            guard stats >= 20 else { return } // Don't notify if barely any data
            let apps = db.distinctAppNames().count
            notifier.notifySummary(observationCount: stats, appCount: apps)
            db.setSetting("first_summary_sent", "1")
        }
    }
}

/// Ensure only one Patina instance runs at a time using flock().
/// Returns the file descriptor (must be kept open for the lifetime of the process).
func acquireInstanceLock() -> Int32? {
    let support = NSString("~/Library/Application Support/Patina").expandingTildeInPath
    try? FileManager.default.createDirectory(atPath: support, withIntermediateDirectories: true)
    let lockPath = support + "/patina.lock"
    let fd = open(lockPath, O_CREAT | O_RDWR, 0o644)
    guard fd >= 0 else {
        fputs("[Patina] Could not create lock file\n", stderr)
        return nil
    }
    if flock(fd, LOCK_EX | LOCK_NB) != 0 {
        fputs("[Patina] Another instance is already running. Exiting.\n", stderr)
        close(fd)
        return nil
    }
    // Write PID for diagnostics
    ftruncate(fd, 0)
    let pidStr = "\(getpid())\n"
    pidStr.withCString { ptr in _ = write(fd, ptr, strlen(ptr)) }
    return fd  // Keep open — closing releases the lock
}

setupFileLogging()

guard let lockFd = acquireInstanceLock() else {
    exit(1)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = PatinaAppDelegate()
delegate.lockFd = lockFd  // Prevent ARC from closing it
app.delegate = delegate
app.run()
