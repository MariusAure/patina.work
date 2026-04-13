import Foundation
import UserNotifications

/// Delivers macOS notifications for detected patterns.
/// Rate-limited to maxPerDay (default 2). Tracks daily count in settings DB.
final class PatternNotifier: NSObject, UNUserNotificationCenterDelegate {
    private let db: PatinaDatabase
    private let maxPerDay: Int
    private var center: UNUserNotificationCenter?
    private let launchTime = Date()

    /// Minutes after launch before pattern notifications are sent.
    static let quietPeriodMinutes: Int = 240

    init(db: PatinaDatabase, maxPerDay: Int = 2) {
        self.db = db
        self.maxPerDay = maxPerDay
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

        guard !dailyLimitReached() else {
            print("[Notifier] Daily limit (\(maxPerDay)) reached — skipping")
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
        guard !dailyLimitReached() else { return }

        let content = UNMutableNotificationContent()
        content.title = "Patina"
        content.body = "You have \(observationCount) observations across \(appCount) apps so far. Your first pattern report arrives after analysis."
        content.sound = .default

        deliverIfAuthorized(content: content, identifier: "patina-summary-\(UUID().uuidString)")
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
                    self?.incrementDailyCount()
                }
            }
        }
    }

    // MARK: - Rate limiting

    private func todayKey() -> String {
        let cal = Calendar(identifier: .gregorian)
        var utc = cal
        utc.timeZone = TimeZone(identifier: "UTC")!
        let comps = utc.dateComponents([.year, .month, .day], from: Date())
        return String(format: "notif_count_%04d-%02d-%02d", comps.year!, comps.month!, comps.day!)
    }

    private func dailyLimitReached() -> Bool {
        let count = Int(db.getSetting(todayKey()) ?? "0") ?? 0
        return count >= maxPerDay
    }

    private func incrementDailyCount() {
        let key = todayKey()
        let count = (Int(db.getSetting(key) ?? "0") ?? 0) + 1
        db.setSetting(key, String(count))
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Show notifications even when app is in foreground (menu bar app is always "foreground").
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
