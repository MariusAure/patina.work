import Foundation

/// Manages license key for paid analysis features.
/// License key format: pat_ followed by 32 hex characters.
/// BYO Together AI key (via env var TOGETHER_API_KEY) bypasses license requirement.
final class LicenseManager {
    private let db: PatinaDatabase
    private static let keyPattern = "^pat_[0-9a-f]{32}$"

    init(db: PatinaDatabase) {
        self.db = db
        if isLicensed {
            print("[License] Valid license key found")
        } else {
            print("[License] No license key — analysis requires license or BYO API key")
        }
    }

    var isLicensed: Bool {
        guard let key = db.getSetting("license_key") else { return false }
        return key.range(of: LicenseManager.keyPattern, options: .regularExpression) != nil
    }

    var licenseKey: String? {
        guard isLicensed else { return nil }
        return db.getSetting("license_key")
    }

    func setLicenseKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        db.setSetting("license_key", trimmed)
        if trimmed.range(of: LicenseManager.keyPattern, options: .regularExpression) != nil {
            print("[License] License key saved")
        } else {
            print("[License] Invalid license key format (expected pat_ + 32 hex chars)")
        }
    }
}
