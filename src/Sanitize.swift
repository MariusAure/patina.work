import Foundation

/// Strip file paths, URLs, emails, and sensitive info from text before logging or sending to LLM.
func sanitizeForLog(_ text: String?) -> String? {
    guard var t = text else { return nil }

    // Strip file paths (macOS style) — replace ALL matches, keep filename only
    while let range = t.range(of: #"(/Users/|/Volumes/|~/)[^\s]*"#, options: .regularExpression) {
        let path = String(t[range])
        let filename = (path as NSString).lastPathComponent
        t = t.replacingCharacters(in: range, with: filename)
    }

    // Strip URLs
    t = t.replacingOccurrences(of: #"https?://[^\s]*"#, with: "[url]", options: .regularExpression)

    // Strip email addresses
    t = t.replacingOccurrences(of: #"[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}"#, with: "[email]", options: .regularExpression)

    return t.isEmpty ? nil : t
}

/// Sanitize element_value / clipboard content for inclusion in LLM prompts.
/// Strips credentials and replaces raw values with semantic content-type labels.
/// The LLM sees "[invoice number]" not "INV-4521-ACME".
func sanitizeValueForPrompt(_ text: String?) -> String? {
    guard let t = text, !t.isEmpty else { return nil }

    // First: credential redaction (defense in depth — should already be clean)
    let redacted = CredentialDetector.redact(t)
    if redacted.hasPrefix("[redacted:") { return redacted }

    // Classify content type for the LLM
    return classifyContentType(redacted)
}

/// Classify text into a semantic label the LLM can reason about without seeing raw data.
private func classifyContentType(_ text: String) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

    // Already sanitized markers
    if trimmed == "[url]" || trimmed == "[email]" { return trimmed }

    // Numeric patterns
    let digitsOnly = trimmed.filter { $0.isNumber }
    let digitRatio = trimmed.isEmpty ? 0 : Double(digitsOnly.count) / Double(trimmed.count)

    // Phone number
    if trimmed.range(of: #"^[\+\(]?\d[\d\s\-\(\)]{7,15}$"#, options: .regularExpression) != nil {
        return "[phone number]"
    }

    // Currency amount
    if trimmed.range(of: #"^[$€£¥₹]?\s?\d[\d\s,]*\.?\d*$"#, options: .regularExpression) != nil && digitRatio > 0.4 {
        return "[currency amount]"
    }

    // Mostly digits with separators — likely an ID, invoice number, account number
    if digitRatio > 0.5 && trimmed.count < 30 {
        return "[numeric identifier]"
    }

    // URL was already stripped by sanitizeForLog, but check again
    if trimmed.hasPrefix("http") || trimmed.hasPrefix("www.") { return "[url]" }

    // Email
    if trimmed.contains("@") && trimmed.contains(".") { return "[email address]" }

    // Short single-line text (likely a field value: name, label, short input)
    if !trimmed.contains("\n") && trimmed.count < 80 {
        return "[text: \(trimmed.count) chars]"
    }

    // Multi-line or long text
    let lineCount = trimmed.components(separatedBy: "\n").count
    if trimmed.contains("{") || trimmed.contains("func ") || trimmed.contains("class ") {
        return "[code snippet: \(lineCount) lines]"
    }

    return "[text block: \(trimmed.count) chars]"
}
