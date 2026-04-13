import Foundation

/// Pure transform: turns detected patterns into shareable markdown.
/// Includes attribution footer.
///
/// Defense in depth: pattern fields originate from an LLM that receives
/// sanitized inputs, but window-title sanitization (sanitizeForLog) does
/// not run credential detection. We re-run CredentialDetector here as a
/// final guard before content reaches the user's clipboard.
enum PatternExporter {
    static func markdown(
        _ patterns: [PatternRow],
        observationCount: Int,
        date: Date = Date()
    ) -> String {
        let dateString: String = {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            f.locale = Locale(identifier: "en_US_POSIX")
            return f.string(from: date)
        }()

        var lines: [String] = []
        lines.append("# Patina Patterns — \(dateString)")
        lines.append("")
        lines.append("Observed over \(observationCount) events on macOS. \(patterns.count) pattern\(patterns.count == 1 ? "" : "s") detected. Confidence is the model's self-reported certainty, not ground truth.")
        lines.append("")

        for p in patterns {
            let safeName = sanitizeForExport(p.name ?? "Unnamed pattern", isHeading: true)
            let safeDesc = sanitizeForExport(p.description, isHeading: false)
            let confLabel: String
            if let c = p.confidence {
                confLabel = "[\(Int((c * 100).rounded()))%] "
            } else {
                confLabel = ""
            }
            lines.append("## \(confLabel)\(safeName)")
            lines.append(safeDesc)
            if let rec = p.recommendation, !rec.isEmpty {
                let safeRec = sanitizeForExport(rec, isHeading: false)
                lines.append("")
                lines.append("**Suggestion:** \(safeRec)")
            }
            lines.append("")
        }

        lines.append("---")
        lines.append("*Observed by [Patina](https://patina.work?ref=export) — a macOS app that watches how you work.*")

        return lines.joined(separator: "\n")
    }

    /// Sanitize a string for inclusion in markdown export.
    /// - Runs credential redaction (defense-in-depth — LLM should never have seen credentials,
    ///   but window-title sanitization is incomplete upstream).
    /// - Headings: collapse all whitespace to single spaces (newlines break `## name` syntax).
    /// - Body: escape leading `#` and `---` on any line (would create unintended structure).
    private static func sanitizeForExport(_ text: String, isHeading: Bool) -> String {
        // Defense in depth: redact any credential tokens that slipped through
        let redacted = CredentialDetector.redactTokens(text)

        if isHeading {
            // Collapse all whitespace (including newlines) to single spaces
            let collapsed = redacted
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            return collapsed
        } else {
            // Escape leading markdown structure on each line
            let escaped = redacted
                .components(separatedBy: "\n")
                .map { line -> String in
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("#") { return "\\" + line }
                    if trimmed == "---" || trimmed == "***" { return "\\" + line }
                    return line
                }
                .joined(separator: "\n")
            return escaped
        }
    }
}
