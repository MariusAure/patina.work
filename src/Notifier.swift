import Foundation
import UserNotifications

/// Delivers macOS notifications for detected patterns.
/// Rate-limited to one per minIntervalMinutes (default 20). Tracks last send time in settings DB.
final class PatternNotifier: NSObject, UNUserNotificationCenterDelegate {
    private let db: PatinaDatabase
    private let minIntervalSeconds: TimeInterval
    private var center: UNUserNotificationCenter?
    private let launchTime = Date()

    /// Minutes after launch before pattern notifications are sent.
    /// Short settling period to avoid notifying during install/onboarding.
    static let quietPeriodMinutes: Int = 5

    init(db: PatinaDatabase, minIntervalMinutes: Int = 20) {
        self.db = db
        self.minIntervalSeconds = Double(minIntervalMinutes) * 60
        super.init()
        // UNUserNotificationCenter.current() crashes if binary is not inside a .app bundle
        // (bundleProxyForCurrentProcess is nil). Guard against this.
        if Bundle.main.bundleIdentifier != nil {
            let c = UNUserNotificationCenter.current()
            self.center = c
            c.delegate = self
            requestAuthorization()
        } else {
            print("[Notifier] No bundle ID — notifications disabled (raw binary, not .app bundle)")
            self.center = nil
        }
    }

    private func requestAuthorization() {
        center?.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error = error {
                print("[Notifier] Authorization error: \(error.localizedDescription)")
            } else {
                print("[Notifier] Notifications \(granted ? "authorized" : "denied")")
            }
        }
    }

    /// Send a notification for a detected pattern. Respects daily limit and quiet period.
    func notifyPattern(name: String, occurrences: Int) {
        let elapsed = Date().timeIntervalSince(launchTime) / 60.0
        guard elapsed >= Double(Self.quietPeriodMinutes) else {
            print("[Notifier] Quiet period active (\(Int(elapsed))m / \(Self.quietPeriodMinutes)m) — skipping")
            return
        }

        guard !cooldownActive() else {
            print("[Notifier] Cooldown active (\(Int(minIntervalSeconds/60))m interval) — skipping")
            return
        }

        let content = UNMutableNotificationContent()
        content.title = "Patina"

        // Designer spec: always start with "You". Name the pattern. State the count.
        if occurrences > 1 {
            content.body = "You did \"\(name)\" \(occurrences) times."
        } else {
            content.body = "You have a new pattern: \"\(name)\""
        }
        content.sound = .default

        deliverIfAuthorized(content: content, identifier: "patina-pattern-\(UUID().uuidString)")
    }

    /// Send a summary notification (e.g., end of first observation session).
    func notifySummary(observationCount: Int, appCount: Int) {
        guard !cooldownActive() else { return }

        let content = UNMutableNotificationContent()
        content.title = "Patina"
        content.body = "You have \(observationCount) observations across \(appCount) apps so far. Your first pattern report arrives after analysis."
        content.sound = .default

        deliverIfAuthorized(content: content, identifier: "patina-summary-\(UUID().uuidString)")
    }

    /// First-insight notification. Fires once, after the first analysis that finds patterns.
    func notifyFirstInsight(patternName: String, observationCount: Int, appCount: Int) {
        let alreadySent = db.getSetting("first_insight_sent") == "1"
        guard !alreadySent else { return }

        let content = UNMutableNotificationContent()
        content.title = "Patina"
        content.body = "Your first pattern: \"\(patternName)\". \(observationCount) observations across \(appCount) apps."
        content.sound = .default

        deliverIfAuthorized(content: content, identifier: "patina-first-insight")
        db.setSetting("first_insight_sent", "1")
    }

    /// Notify that the free trial analysis quota is used up.
    func notifyTrialExhausted(patternCount: Int) {
        guard !cooldownActive() else { return }

        let content = UNMutableNotificationContent()
        content.title = "Patina"
        if patternCount > 0 {
            content.body = "You have \(patternCount) patterns. Free trial analysis is complete — buy a license to continue."
        } else {
            content.body = "Free trial analysis is complete. Buy a license to unlock pattern detection."
        }
        content.sound = .default

        deliverIfAuthorized(content: content, identifier: "patina-trial-\(UUID().uuidString)")
    }

    // MARK: - Delivery with lazy auth check

    /// Check authorization at delivery time (not at init) to avoid the async race
    /// where the auth callback hasn't returned yet when the first notification fires.
    private func deliverIfAuthorized(content: UNMutableNotificationContent, identifier: String) {
        guard let center = center else { return }
        center.getNotificationSettings { [weak self] settings in
            guard let self = self else { return }
            guard settings.authorizationStatus == .authorized else {
                print("[Notifier] Not authorized (status: \(settings.authorizationStatus.rawValue)) — skipping")
                return
            }

            let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
            center.add(request) { [weak self] error in
                if let error = error {
                    print("[Notifier] Delivery error: \(error.localizedDescription)")
                } else {
                    print("[Notifier] Sent: \(content.body)")
                    self?.recordSendTime()
                }
            }
        }
    }

    // MARK: - Rate limiting

    private static let lastNotifKey = "last_notif_time"

    private func cooldownActive() -> Bool {
        guard let raw = db.getSetting(Self.lastNotifKey),
              let last = Double(raw) else { return false }
        return Date().timeIntervalSince1970 - last < minIntervalSeconds
    }

    private func recordSendTime() {
        db.setSetting(Self.lastNotifKey, String(Date().timeIntervalSince1970))
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Show notifications even when app is in foreground (menu bar app is always "foreground").
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
