import Foundation

/// Detects credentials, secrets, and sensitive tokens in text.
/// Pure functions, no state. Used by Observer (clipboard + element values) and Sanitize (LLM prompt).
enum CredentialDetector {

    enum Classification: CustomStringConvertible {
        case clean
        case credential(kind: String)

        var description: String {
            switch self {
            case .clean: return "clean"
            case .credential(let kind): return "credential(\(kind))"
            }
        }
    }

    /// Known API key / token prefixes. Minimum 20 chars after prefix to avoid false positives
    /// on short strings like "SK-4521" (invoice numbers).
    private static let prefixes: [(prefix: String, kind: String, minLength: Int)] = [
        // OpenAI / Anthropic / AI providers
        ("sk-ant-", "api_key", 20),
        ("sk-proj-", "api_key", 20),
        ("sk-", "api_key", 20),
        ("pk-", "api_key", 20),
        ("sk_live_", "api_key", 20),
        ("sk_test_", "api_key", 20),
        ("pk_live_", "api_key", 20),
        ("pk_test_", "api_key", 20),
        // Together AI
        ("tgp_v1_", "together_key", 20),
        ("tgp_", "together_key", 20),
        // Fireworks AI
        ("fw_", "fireworks_key", 20),
        // Replicate
        ("r8_", "replicate_key", 20),
        // Cohere
        ("co_", "cohere_key", 30),  // Higher min to avoid false positives
        // Mistral
        ("mist_", "mistral_key", 20),
        // GitHub
        ("ghp_", "github_token", 20),
        ("gho_", "github_token", 20),
        ("ghs_", "github_token", 20),
        ("ghu_", "github_token", 20),
        ("github_pat_", "github_token", 20),
        // GitLab
        ("glpat-", "gitlab_token", 20),
        // Slack
        ("xoxb-", "slack_token", 20),
        ("xoxp-", "slack_token", 20),
        ("xoxs-", "slack_token", 20),
        ("xapp-", "slack_token", 20),
        // AWS
        ("AKIA", "aws_key", 20),
        ("ASIA", "aws_key", 20),
        // Google
        ("AIza", "google_key", 20),
        // SendGrid
        ("SG.", "sendgrid_key", 20),
        // Stripe
        ("whsec_", "stripe_webhook", 20),
        ("rk_live_", "stripe_key", 20),
        ("rk_test_", "stripe_key", 20),
        // npm
        ("npm_", "npm_token", 20),
        // Groq
        ("gsk_", "groq_key", 20),
        // Vercel
        ("vercel_", "vercel_token", 20),
        // Supabase
        ("sbp_", "supabase_key", 20),
        // Twilio
        ("SK", "twilio_key", 32),  // Twilio keys start with SK + 32 hex chars
        // Turso
        ("eyJhIjo", "turso_token", 20),  // Turso tokens are JWTs starting with this base64
        // Cloudflare
        ("cf_", "cloudflare_key", 30),
        // HuggingFace
        ("hf_", "huggingface_key", 20),
    ]

    /// Unicode format characters (Cf) that are invisible but defeat prefix matching.
    private static let invisibleChars = CharacterSet(charactersIn: "\u{200B}\u{200C}\u{200D}\u{FEFF}\u{00AD}\u{2060}\u{2061}\u{2062}\u{2063}\u{2064}")

    static func classify(_ text: String) -> Classification {
        // Strip whitespace AND invisible unicode format characters (zero-width spaces, BOM, etc.)
        let trimmed = String(text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) && !invisibleChars.contains($0) })
        guard !trimmed.isEmpty else { return .clean }

        // 1. API key prefix matching
        for (prefix, kind, minLength) in prefixes {
            if trimmed.hasPrefix(prefix) && trimmed.count >= minLength {
                return .credential(kind: kind)
            }
        }

        // 2. JWT format: three base64url segments separated by dots
        if isJWT(trimmed) { return .credential(kind: "jwt") }

        // 3. Bearer token
        if trimmed.hasPrefix("Bearer ") && trimmed.count > 27 {
            return .credential(kind: "bearer_token")
        }

        // 4. Credit card number (Luhn check)
        if isCreditCard(trimmed) { return .credential(kind: "credit_card") }

        // 5. SSN pattern (strict: NNN-NN-NNNN)
        if trimmed.range(of: #"^\d{3}-\d{2}-\d{4}$"#, options: .regularExpression) != nil {
            return .credential(kind: "ssn")
        }

        // 6. URL-embedded credentials (connection strings)
        if hasURLCredentials(trimmed) { return .credential(kind: "connection_string") }

        // 7. PEM private key
        if trimmed.contains("-----BEGIN") && (trimmed.contains("PRIVATE KEY") || trimmed.contains("RSA")) {
            return .credential(kind: "private_key")
        }

        // 8. High-entropy single-token strings (catches unknown secret formats)
        // Use whitespace-trimmed original — not the invisible-char-stripped version.
        // Real secrets don't contain spaces; stripping them would make normal sentences look like tokens.
        let trimmedForEntropy = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if isHighEntropySingleToken(trimmedForEntropy) { return .credential(kind: "high_entropy") }

        return .clean
    }

    /// Replace detected credentials with [redacted:kind] markers.
    static func redact(_ text: String) -> String {
        let classification = classify(text)
        switch classification {
        case .clean: return text
        case .credential(let kind): return "[redacted:\(kind)]"
        }
    }

    static func isSafe(_ text: String) -> Bool {
        if case .clean = classify(text) { return true }
        return false
    }

    /// Token-scanning version of isSafe(). Splits on delimiters and checks each token.
    /// Use for multi-line or mixed content (clipboard, element values) where a credential
    /// may be embedded within a larger string.
    static func isTextSafe(_ text: String) -> Bool {
        redactTokens(text) == text
    }

    /// Scan text for credential tokens embedded within a longer string.
    /// Returns the text with any detected credential tokens replaced with [redacted:kind].
    /// Splits on spaces, tabs, =, ;, quotes, commas to catch patterns like KEY=sk-proj-...
    static func redactTokens(_ text: String) -> String {
        // Pre-scan: redact URL-embedded credentials before splitting (: would break them)
        var prescan = text
        let urlCredPattern = #"[a-z][a-z0-9+\-.]*://[^\s]+"#
        if let regex = try? NSRegularExpression(pattern: urlCredPattern, options: .caseInsensitive) {
            let range = NSRange(prescan.startIndex..., in: prescan)
            for match in regex.matches(in: prescan, range: range).reversed() {
                if let r = Range(match.range, in: prescan) {
                    let url = String(prescan[r])
                    if hasURLCredentials(url) {
                        prescan.replaceSubrange(r, with: "[redacted:connection_string]")
                    }
                }
            }
        }

        // Split on common delimiters while preserving them for reassembly
        var tokens: [(String, Bool)] = []  // (token, isDelimiter)
        var current = ""
        let delimiters: Set<Character> = [" ", "\t", "\n", "\r", "=", ";", ",", ":", "\"", "'"]
        for ch in prescan {
            if delimiters.contains(ch) {
                if !current.isEmpty {
                    tokens.append((current, false))
                    current = ""
                }
                tokens.append((String(ch), true))
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { tokens.append((current, false)) }

        var changed = prescan != text
        let processed = tokens.map { (token, isDelimiter) -> String in
            guard !isDelimiter else { return token }
            let classification = classify(token)
            switch classification {
            case .clean: return token
            case .credential(let kind):
                changed = true
                return "[redacted:\(kind)]"
            }
        }
        return changed ? processed.joined() : text
    }

    // MARK: - Detection helpers

    private static func isJWT(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return false }
        // First segment should be base64url decodable to JSON with "alg" key
        guard let decoded = base64URLDecode(String(parts[0])),
              let json = try? JSONSerialization.jsonObject(with: decoded) as? [String: Any],
              json["alg"] != nil else { return false }
        return true
    }

    private static func base64URLDecode(_ str: String) -> Data? {
        var base64 = str.replacingOccurrences(of: "-", with: "+")
                        .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 { base64 += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: base64)
    }

    private static let cardSeparators: Set<Character> = [" ", "-", ".", "/", "\u{2009}", "\u{00B7}"]

    private static func isCreditCard(_ text: String) -> Bool {
        let digits = text.filter { $0.isNumber }
        guard digits.count >= 13, digits.count <= 19 else { return false }
        // Only check strings that are primarily digits (allow spaces, dashes, dots, slashes)
        let nonDigitNonSep = text.filter { !$0.isNumber && !cardSeparators.contains($0) }
        guard nonDigitNonSep.isEmpty else { return false }
        return luhnCheck(digits)
    }

    private static func luhnCheck(_ digits: String) -> Bool {
        let nums = digits.compactMap { Int(String($0)) }
        guard nums.count >= 13 else { return false }
        var sum = 0
        for (i, n) in nums.reversed().enumerated() {
            if i % 2 == 1 {
                let doubled = n * 2
                sum += doubled > 9 ? doubled - 9 : doubled
            } else {
                sum += n
            }
        }
        return sum % 10 == 0
    }

    private static func hasURLCredentials(_ text: String) -> Bool {
        // Detect any scheme://user:pass@host — protocol-agnostic per RFC 3986
        return text.range(of: #"[a-z][a-z0-9+\-.]*://[^:]+:[^@]+@"#, options: .regularExpression) != nil
    }

    private static func isHighEntropySingleToken(_ text: String) -> Bool {
        // Only single-word strings (no spaces) longer than 20 chars
        guard text.count > 20, !text.contains(" "), !text.contains("\n") else { return false }
        // Must be predominantly alphanumeric + common secret chars
        let secretChars = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "+/=_-"))
        let nonSecretCount = text.unicodeScalars.filter { !secretChars.contains($0) }.count
        guard Double(nonSecretCount) / Double(text.count) < 0.1 else { return false }
        // Shannon entropy
        let entropy = shannonEntropy(text)
        return entropy > 4.2  // English prose ~3.5-4.0, secrets typically >4.5
    }

    private static func shannonEntropy(_ text: String) -> Double {
        var freq: [Character: Int] = [:]
        for ch in text { freq[ch, default: 0] += 1 }
        let len = Double(text.count)
        var entropy = 0.0
        for count in freq.values {
            let p = Double(count) / len
            entropy -= p * log2(p)
        }
        return entropy
    }
}
