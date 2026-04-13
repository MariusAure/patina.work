import Foundation

// Inline test runner for CredentialDetector
// Build: swiftc -O -o test_cred src/CredentialDetector.swift test_credential_detector.swift
// Run:   ./test_cred

var passed = 0
var failed = 0

func assert(_ condition: Bool, _ message: String, file: String = #file, line: Int = #line) {
    if condition {
        passed += 1
    } else {
        failed += 1
        print("FAIL [\(line)]: \(message)")
    }
}

func isCredential(_ text: String) -> Bool {
    if case .credential = CredentialDetector.classify(text) { return true }
    return false
}

// === API KEY PREFIXES ===

// OpenAI
assert(isCredential("sk-proj-abc123def456ghi789jkl012mno345pqr678stu901vwx234"), "OpenAI key sk-proj-")
assert(isCredential("sk-abcdefghij1234567890abcd"), "OpenAI key sk-")

// Anthropic
assert(isCredential("sk-ant-api03-abcdefghijklmnopqrstuvwxyz1234567890"), "Anthropic key sk-ant-")

// GitHub
assert(isCredential("ghp_ABCDEFGHIJKLMNOPabcdefghijklmnop12"), "GitHub PAT ghp_")
assert(isCredential("github_pat_22ABCDEFGHIJKLMNOPQRSTUVWXYZ_abcdefghijklmnopqrstuvwxyz1234567890ABCDEFG"), "GitHub fine-grained PAT")

// Slack (concatenated to avoid GitHub push protection false positives on test vectors)
assert(isCredential("xoxb-" + "000000000000-0000000000000-FAKEFAKEFAKEFAKEFAKEFAKE"), "Slack bot token")
assert(isCredential("xoxp-" + "000000000000-000000000000-000000000000-fakefakefakefakefakefake"), "Slack user token")
assert(isCredential("xapp-" + "0-FAKEFAKEFAK-0000000000000-fakefakefakefakefakefakefakefakefake"), "Slack app token")

// AWS
assert(isCredential("AKIAIOSFODNN7EXAMPLE1234"), "AWS access key")

// Google
assert(isCredential("AIzaSyDaGmWKa4JsXZ-HjGw7ISLn_3namBGewQe"), "Google API key")

// Groq
assert(isCredential("gsk_abcdefghijklmnopqrstuvwxyz1234567890ABCDEF"), "Groq key")

// Stripe
assert(isCredential("whsec_abcdefghijklmnopqrstuvwxyz1234567890"), "Stripe webhook secret")
assert(isCredential("rk_live_" + "FAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKE0000"), "Stripe restricted key")

// npm
assert(isCredential("npm_abcdefghijklmnopqrstuvwxyz1234"), "npm token")

// === FALSE NEGATIVES TO AVOID ===

// Short strings that match prefixes should NOT trigger (invoice numbers, etc.)
assert(!isCredential("SK-4521"), "Short SK- is not API key")
assert(!isCredential("sk-123"), "Short sk- is not API key")
assert(!isCredential("npm_v1"), "Short npm_ is not token")

// === JWT ===

// Valid JWT structure
let jwt = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyfQ.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c"
assert(isCredential(jwt), "JWT token")

// Not a JWT (three dots but not base64 JSON)
assert(!isCredential("hello.world.foo"), "Not a JWT")

// === BEARER TOKEN ===
assert(isCredential("Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.abc.def"), "Bearer token")
assert(!isCredential("Bearer short"), "Short Bearer not a token")

// === CREDIT CARDS (Luhn) ===
assert(isCredential("4111 1111 1111 1111"), "Visa test card")
assert(isCredential("5500-0000-0000-0004"), "Mastercard test card")
assert(isCredential("4111111111111111"), "Visa no spaces")
assert(!isCredential("1234567890123456"), "Random 16 digits fail Luhn")
// Note: "123-45-6789" matches SSN format, so isCredential returns true (correctly)
assert(isCredential("123-45-6789"), "SSN format matches even though not enough digits for CC")

// === SSN ===
assert(isCredential("123-45-6789"), "SSN format")
assert(!isCredential("123456789"), "Bare 9 digits not SSN")
assert(!isCredential("12-345-6789"), "Wrong SSN format")

// === CONNECTION STRINGS ===
assert(isCredential("postgresql://admin:s3cr3t_pass@db.example.com:5432/mydb"), "PostgreSQL connection string")
assert(isCredential("mongodb://user:password@cluster0.abc.mongodb.net/test"), "MongoDB connection string")
assert(isCredential("redis://default:mypassword@redis.example.com:6379"), "Redis connection string")
assert(!isCredential("https://example.com/page"), "Normal HTTPS URL")

// === PEM KEYS ===
assert(isCredential("-----BEGIN RSA PRIVATE KEY-----\nMIIEpAIBAAKCAQEA..."), "PEM private key")
assert(isCredential("-----BEGIN PRIVATE KEY-----\nMIIEvgIBADANBgk..."), "PEM generic private key")

// === HIGH ENTROPY ===
assert(isCredential("aB3cD4eF5gH6iJ7kL8mN9oP0qR1sT2u"), "Random 32-char alphanumeric")
assert(!isCredential("Hello world this is normal text"), "Normal English text")
assert(!isCredential("The quick brown fox jumps over the lazy dog"), "Normal sentence")
assert(!isCredential("Invoice INV-4521-ACME"), "Invoice number")

// === CLEAN CONTENT (should NOT trigger) ===
assert(!isCredential(""), "Empty string")
assert(!isCredential("Hello"), "Single word")
assert(!isCredential("Meeting notes from Monday"), "Normal text")
assert(!isCredential("john@example.com"), "Email address")
assert(!isCredential("https://google.com"), "URL")
assert(!isCredential("/Users/alice/Documents/report.pdf"), "File path")
assert(!isCredential("12345"), "Short number")
assert(!isCredential("INV-2024-00142"), "Invoice number")
assert(!isCredential("Order #12345-ABC"), "Order number")

// === REDACTION ===
let redacted = CredentialDetector.redact("sk-proj-abc123def456ghi789jkl012mno345pqr678stu901vwx234")
assert(redacted == "[redacted:api_key]", "Redact returns [redacted:api_key], got: \(redacted)")

let clean = CredentialDetector.redact("Hello world")
assert(clean == "Hello world", "Clean text passes through redact unchanged")

// === isSafe ===
assert(CredentialDetector.isSafe("Normal text"), "isSafe returns true for normal text")
assert(!CredentialDetector.isSafe("ghp_ABCDEFGHIJKLMNOPabcdefghijklmnop12"), "isSafe returns false for GitHub token")

// === RESULTS ===
print("\n=== Results: \(passed) passed, \(failed) failed ===")
if failed > 0 {
    print("SOME TESTS FAILED")
    exit(1)
} else {
    print("ALL TESTS PASSED")
}
