import AppKit

/// First-run onboarding flow.
/// Shows welcome explanation, "How it works" detail, and permission pre-framing.
/// Uses NSAlert for simplicity.
enum Onboarding {

    /// Returns true if onboarding was already completed.
    static func isComplete(db: PatinaDatabase) -> Bool {
        db.getSetting("onboarding_complete") == "1"
    }

    /// Run the full onboarding flow. Blocks until user completes it.
    /// Returns true if user granted permission (or it was already granted).
    static func run(db: PatinaDatabase) -> Bool {
        // Temporarily become a regular app so windows appear
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // Step 1: Welcome
        let welcome = NSAlert()
        welcome.messageText = "Patina"
        welcome.informativeText = """
        Patina watches which apps you use and what you click on.
        It finds patterns you repeat and writes them down.

        Observations are stored locally. To detect patterns, Patina
        sends app names, window titles, and field labels to Together AI
        (a cloud LLM). No screenshots, no field values, no accounts.

        Without a license key or API key, nothing leaves your Mac.
        """
        welcome.alertStyle = .informational
        welcome.addButton(withTitle: "Start observing")
        welcome.addButton(withTitle: "How it works")
        welcome.addButton(withTitle: "Quit")

        var welcomeResult = welcome.runModal()

        while welcomeResult == .alertSecondButtonReturn {
            showHowItWorks()
            welcomeResult = welcome.runModal()
        }

        if welcomeResult == .alertThirdButtonReturn {
            NSApp.terminate(nil)
            return false
        }

        // Step 2: Permission pre-framing
        let preframe = NSAlert()
        preframe.messageText = "Accessibility Access"
        preframe.informativeText = """
        macOS will ask you to grant Accessibility access.

        This is how Patina reads field names and window titles.
        Without it, Patina cannot observe your workflow.

        You can revoke this in System Settings > Privacy > Accessibility at any time.
        """
        preframe.alertStyle = .informational
        preframe.addButton(withTitle: "Continue")
        preframe.addButton(withTitle: "Quit")

        let preframeResult = preframe.runModal()
        if preframeResult == .alertSecondButtonReturn {
            NSApp.terminate(nil)
            return false
        }

        // Step 3: Trigger the actual macOS Accessibility prompt
        let trusted = AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        )

        // Mark onboarding complete regardless of trust result —
        // we don't want to re-show onboarding every launch while user is granting permission
        db.setSetting("onboarding_complete", "1")

        // Back to accessory (menu bar only)
        NSApp.setActivationPolicy(.accessory)

        if !trusted {
            print("[Onboarding] Accessibility not yet granted. User needs to toggle in System Settings.")
            print("[Onboarding] App will start observing once permission is granted (on next launch).")
        }

        return trusted
    }

    private static func showHowItWorks() {
        let detail = NSAlert()
        detail.messageText = "How Patina works"
        detail.informativeText = """
        What Patina records:
        • Which app is active (e.g. "Safari", "Slack", "Excel")
        • The title of the window (e.g. "Invoice #4521 - SAP")
        • The name of the field you click (e.g. "Invoice Number")

        What Patina does NOT record:
        • Screenshots
        • Passwords (password fields are always skipped)
        • Audio, camera, or file contents

        Optional (off by default, enable in menu bar → Data Capture):
        • Clipboard content (what you copy/paste between apps)
        • Field values (what's entered in input fields)
        Passwords and credentials are automatically detected and never stored.

        Observations are stored locally in a SQLite database.

        To detect patterns, Patina sends to Together AI: app names,
        field labels, window titles (paths and URLs stripped), event
        types, timestamps. Field values are replaced with labels like
        "[numeric identifier]" — never sent raw.

        Without a license or API key, nothing is sent. Inspect or
        delete the data from the menu bar.
        """
        detail.alertStyle = .informational
        detail.addButton(withTitle: "OK")
        detail.runModal()
    }
}
