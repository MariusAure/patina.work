import Foundation

/// Analyzes workflow observations using Together AI (Llama-3.3-70B-Instruct-Turbo).
/// Sends: app_name, element_role, element_title, event_type, timestamp, dwell_seconds.
/// Element values and clipboard content are sent as semantic labels only (e.g. "[numeric identifier]"),
/// never as raw values. Sanitizes window_title (strips file paths and URLs).
final class WorkflowAnalyzer {
    let db: PatinaDatabase
    var notifier: PatternNotifier?
    var licenseManager: LicenseManager?
    private var apiKey: String?
    private let model = "meta-llama/Llama-3.3-70B-Instruct-Turbo"
    private let directEndpoint = "https://api.together.xyz/v1/chat/completions"
    private let proxyEndpoint = "https://patina.work/api/analyze"
    private let batchSize = 200
    private let maxRetries = 2
    // Together AI pricing for Llama-3.3-70B-Instruct-Turbo (as of 2026-04)
    private let inputCostPerM: Double = 0.88
    private let outputCostPerM: Double = 0.88
    private var analysisTimer: Timer?
    private var isAnalyzing = false
    private let analysisLock = NSLock()
    private var lastManualRun: Date?
    private let manualCooldown: TimeInterval = 60  // 60s between manual triggers
    private let dailyBatchLimit = 60

    init(db: PatinaDatabase) {
        self.db = db
        // BYO key: env var takes precedence, then DB setting
        if let envKey = ProcessInfo.processInfo.environment["TOGETHER_API_KEY"] {
            self.apiKey = envKey
        } else if let dbKey = db.getSetting("together_api_key") {
            self.apiKey = dbKey
        }
        if self.apiKey == nil {
            print("[Analyzer] No TOGETHER_API_KEY — will use license proxy or observation-only mode")
        } else {
            print("[Analyzer] Together AI configured (model: \(model))")
        }
    }

    /// Can run analysis via either license (proxy) or BYO key (direct)
    var canAnalyze: Bool {
        return (licenseManager?.isLicensed ?? false) || apiKey != nil
    }

    var hasApiKey: Bool { apiKey != nil }

    /// Check if manual analysis is allowed (60s cooldown)
    var manualRunAllowed: Bool {
        guard let last = lastManualRun else { return true }
        return Date().timeIntervalSince(last) >= manualCooldown
    }

    /// Call this from the menu bar when user triggers manual analysis
    func recordManualRun() {
        lastManualRun = Date()
    }

    func updateApiKey(_ key: String) {
        self.apiKey = key
        db.setSetting("together_api_key", key)
        print("[Analyzer] API key updated and saved to DB")
    }

    /// Start periodic analysis (every 30 minutes)
    func startPeriodicAnalysis(intervalMinutes: Int = 30) {
        guard canAnalyze else { return }
        let interval = TimeInterval(intervalMinutes * 60)
        DispatchQueue.main.async { [weak self] in
            self?.analysisTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                self?.runAnalysis()
            }
        }
        // Run once after 60s to catch any backlog
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 60) { [weak self] in
            self?.runAnalysis()
        }
        print("[Analyzer] Periodic analysis started (every \(intervalMinutes)m)")
    }

    func stopPeriodicAnalysis() {
        analysisTimer?.invalidate()
        analysisTimer = nil
    }

    /// Run a single analysis batch. Calls completion on finish (on arbitrary queue).
    func runAnalysis(completion: (() -> Void)? = nil) {
        analysisLock.lock()
        guard !isAnalyzing else {
            analysisLock.unlock()
            print("[Analyzer] Analysis already in progress — skipping")
            completion?()
            return
        }
        isAnalyzing = true
        analysisLock.unlock()

        let finish = { [weak self] in
            self?.analysisLock.lock()
            self?.isAnalyzing = false
            self?.analysisLock.unlock()
            completion?()
        }

        // Gate: need license or BYO key
        guard canAnalyze else {
            print("[Analyzer] No license and no API key — skipping analysis")
            finish()
            return
        }

        // Daily batch limit
        let today = ISO8601Formatter.dayString()
        let countKey = "analysis_count_\(today)"
        let todayCount = Int(db.getSetting(countKey) ?? "0") ?? 0
        guard todayCount < dailyBatchLimit else {
            print("[Analyzer] Daily batch limit reached (\(dailyBatchLimit))")
            finish()
            return
        }

        do {
            let observations = try db.unanalyzedObservations(limit: batchSize)
            guard observations.count >= 5 else {
                print("[Analyzer] Only \(observations.count) unanalyzed observations — skipping (need >= 5)")
                finish()
                return
            }

            let lastObsId = observations.last?.id ?? 0
            let batchId = try db.insertBatch(observationCount: observations.count, lastObservationId: lastObsId)
            print("[Analyzer] Batch #\(batchId): analyzing \(observations.count) observations (up to obs #\(lastObsId))")

            // Increment daily counter
            db.setSetting(countKey, String(todayCount + 1))

            let prompt = buildPrompt(observations)
            sendToLLM(prompt: prompt, batchId: batchId, observations: observations, onComplete: finish)
        } catch {
            print("[Analyzer] Error starting analysis: \(error)")
            finish()
        }
    }

    // MARK: - Prompt construction

    private func buildPrompt(_ observations: [ObservationRow]) -> String {
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        // Parse timestamps for dwell time computation
        let parsedDates: [Date?] = observations.map { isoFormatter.date(from: $0.timestamp) }

        // Compute dwell time (seconds until next app_switch event)
        var dwellSeconds: [Int?] = Array(repeating: nil, count: observations.count)
        for i in 0..<observations.count {
            guard let currentDate = parsedDates[i] else { continue }
            for j in (i + 1)..<observations.count {
                if observations[j].eventType == "app_switch", let nextDate = parsedDates[j] {
                    dwellSeconds[i] = max(0, Int(nextDate.timeIntervalSince(currentDate)))
                    break
                }
            }
        }

        // Build summary block
        let firstTimestamp = observations.first?.timestamp ?? "?"
        let lastTimestamp = observations.last?.timestamp ?? "?"
        var windowMinutes = 0
        if let first = parsedDates.first ?? nil, let last = parsedDates.last ?? nil {
            windowMinutes = max(1, Int(last.timeIntervalSince(first) / 60))
        }

        var appTime: [String: Int] = [:]
        for i in 0..<observations.count {
            if let dwell = dwellSeconds[i] {
                appTime[observations[i].appName, default: 0] += dwell
            }
        }
        let sortedApps = appTime.sorted { $0.value > $1.value }
        let appsLine = sortedApps.map { "\($0.key) (\($0.value / 60)m)" }.joined(separator: ", ")

        let totalSwitches = observations.filter { $0.eventType == "app_switch" }.count
        let totalFocusChanges = observations.filter { $0.eventType == "focus_change" }.count

        let summary = """
        Summary:
        - Time window: \(firstTimestamp) to \(lastTimestamp) (\(windowMinutes) minutes)
        - Apps used (by time): \(appsLine)
        - Total app switches: \(totalSwitches)
        - Focus changes: \(totalFocusChanges)
        """

        // Build observation lines with dwell time and data summary
        var lines: [String] = []
        for (i, obs) in observations.enumerated() {
            let sanitizedWindow = sanitizeForLog(obs.windowTitle)
            let sanitizedElement = sanitizeForLog(obs.elementTitle).map { CredentialDetector.redactTokens($0) }
            let dwellStr = dwellSeconds[i].map { String($0) } ?? "-"
            // Data summary: semantic label for clipboard content or field values
            let dataSummary: String
            if obs.eventType == "clipboard_change", let val = obs.elementValue {
                dataSummary = sanitizeValueForPrompt(val) ?? "-"
            } else if let val = obs.elementValue {
                dataSummary = sanitizeValueForPrompt(val) ?? "-"
            } else {
                dataSummary = "-"
            }
            let parts = [
                obs.timestamp,
                obs.eventType,
                obs.appName,
                dwellStr,
                sanitizedWindow ?? "-",
                obs.elementRole ?? "-",
                sanitizedElement ?? "-",
                dataSummary
            ]
            lines.append(parts.joined(separator: " | "))
        }

        let observationBlock = lines.joined(separator: "\n")

        return """
        You are a workflow pattern detector analyzing a knowledge worker's desktop activity.

        Each line: timestamp | event_type | app_name | duration_seconds | window_title | element_role | element_title | data_summary

        \(summary)

        Observations:
        \(observationBlock)

        Detect patterns that are ACTIONABLE — things the user could automate, streamline, or change.

        GOOD patterns (report these):
        - "User copies data from App A to App B manually every time" → automation candidate
        - "User checks email every 3 minutes, interrupting deep work" → behavior insight
        - "User repeats a multi-step sequence across 3 apps" → workflow automation candidate
        - "User spends 15 minutes navigating settings repeatedly" → setup/config issue
        - "clipboard_change events show data flowing from App A → App B" → data flow pattern
        - "Same data type entered in multiple apps" → redundant data entry

        BAD patterns (do NOT report these):
        - "User switches between App A and App B" — obvious, not actionable
        - "User uses Chrome" — not a pattern
        - "User opens System Settings" — single action, not a workflow

        Rules:
        - Only report patterns with evidence. Do not invent.
        - Each pattern needs at least 2 steps.
        - Include a specific, actionable recommendation.
        - observation_indices: at most 5 representative indices (0-based).
        - If no actionable patterns exist, return an empty array: []
        - Return ONLY the JSON array. No markdown, no explanation.

        JSON format:
        {
          "name": "short descriptive name",
          "description": "what the user is doing, with timing",
          "recommendation": "what they could do differently",
          "steps": ["step 1", "step 2"],
          "observation_indices": [0, 3, 7],
          "confidence": 0.0-1.0
        }
        """
    }

    // MARK: - Together AI request

    private func sendToLLM(prompt: String, batchId: Int64, observations: [ObservationRow], attempt: Int = 0, onComplete: @escaping () -> Void) {
        // Determine endpoint: license proxy or direct BYO
        let useProxy = licenseManager?.isLicensed ?? false
        let endpoint = useProxy ? proxyEndpoint : directEndpoint

        guard let url = URL(string: endpoint) else {
            onComplete()
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        if useProxy {
            request.setValue(licenseManager?.licenseKey, forHTTPHeaderField: "X-License-Key")
        } else if let apiKey = apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        } else {
            onComplete()
            return
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60

        var body: [String: Any] = [
            "messages": [
                ["role": "user", "content": prompt]
            ],
            "temperature": 0.3,
            "max_tokens": 4000,
            "response_format": ["type": "json_object"]
        ]
        // Direct calls include model; proxy adds it server-side
        if !useProxy {
            body["model"] = model
        }

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            print("[Analyzer] JSON serialization error: \(error)")
            onComplete()
            return
        }

        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else {
                onComplete()
                return
            }
            let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? 0

            if let error = error {
                if attempt < self.maxRetries {
                    let delay = pow(2.0, Double(attempt)) * 2.0
                    print("[Analyzer] Network error (attempt \(attempt + 1)/\(self.maxRetries + 1)), retrying in \(delay)s: \(error.localizedDescription)")
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) { [weak self] in
                        self?.sendToLLM(prompt: prompt, batchId: batchId, observations: observations, attempt: attempt + 1, onComplete: onComplete)
                    }
                    return
                }
                print("[Analyzer] Request error after \(attempt + 1) attempts: \(error.localizedDescription)")
                try? self.db.updateBatch(id: batchId, status: "error", receivedAt: ISO8601Formatter.now(),
                                         promptTokens: nil, completionTokens: nil, costUSD: nil,
                                         responseJSON: error.localizedDescription)
                onComplete()
                return
            }

            // Retry on transient HTTP errors (429 rate limit, 503 service unavailable)
            if httpStatus == 429 || httpStatus == 503 {
                if attempt < self.maxRetries {
                    var delay = pow(2.0, Double(attempt)) * 2.0
                    if let retryAfter = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After"),
                       let retrySeconds = Double(retryAfter) {
                        delay = max(delay, retrySeconds)
                    }
                    print("[Analyzer] HTTP \(httpStatus) (attempt \(attempt + 1)/\(self.maxRetries + 1)), retrying in \(delay)s")
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) { [weak self] in
                        self?.sendToLLM(prompt: prompt, batchId: batchId, observations: observations, attempt: attempt + 1, onComplete: onComplete)
                    }
                    return
                }
                print("[Analyzer] HTTP \(httpStatus) after \(attempt + 1) attempts — giving up")
                try? self.db.updateBatch(id: batchId, status: "error", receivedAt: ISO8601Formatter.now(),
                                         promptTokens: nil, completionTokens: nil, costUSD: nil,
                                         responseJSON: "HTTP \(httpStatus) after \(self.maxRetries + 1) attempts")
                onComplete()
                return
            }

            guard let data = data else {
                print("[Analyzer] No response data")
                try? self.db.updateBatch(id: batchId, status: "error", receivedAt: ISO8601Formatter.now(),
                                         promptTokens: nil, completionTokens: nil, costUSD: nil,
                                         responseJSON: "No response data")
                onComplete()
                return
            }

            self.handleResponse(data: data, batchId: batchId, observations: observations)
            onComplete()
        }
        task.resume()
    }

    private func handleResponse(data: Data, batchId: Int64, observations: [ObservationRow]) {
        do {
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                print("[Analyzer] Unexpected response format")
                return
            }

            // Check for API error
            if let error = json["error"] as? [String: Any], let message = error["message"] as? String {
                print("[Analyzer] API error: \(message)")
                try db.updateBatch(id: batchId, status: "error", receivedAt: ISO8601Formatter.now(),
                                   promptTokens: nil, completionTokens: nil, costUSD: nil,
                                   responseJSON: message)
                return
            }

            // Extract usage
            let usage = json["usage"] as? [String: Any]
            let promptTokens = usage?["prompt_tokens"] as? Int
            let completionTokens = usage?["completion_tokens"] as? Int

            // Extract content
            guard let choices = json["choices"] as? [[String: Any]],
                  let first = choices.first,
                  let message = first["message"] as? [String: Any],
                  let content = message["content"] as? String else {
                print("[Analyzer] No content in response")
                try db.updateBatch(id: batchId, status: "error", receivedAt: ISO8601Formatter.now(),
                                   promptTokens: promptTokens, completionTokens: completionTokens,
                                   costUSD: nil, responseJSON: String(data: data, encoding: .utf8))
                return
            }

            // Parse patterns from LLM response
            let patterns = parsePatterns(content, observations: observations)

            // Store patterns
            for p in patterns {
                try db.insertPattern(
                    name: p.name,
                    description: p.description,
                    recommendation: p.recommendation,
                    observationIds: p.observationIds,
                    confidence: p.confidence
                )
            }

            let costUSD: Double?
            if let pt = promptTokens, let ct = completionTokens {
                costUSD = (Double(pt) * inputCostPerM + Double(ct) * outputCostPerM) / 1_000_000
            } else {
                costUSD = nil
            }

            try db.updateBatch(id: batchId, status: "completed", receivedAt: ISO8601Formatter.now(),
                               promptTokens: promptTokens, completionTokens: completionTokens,
                               costUSD: costUSD, responseJSON: content)

            print("[Analyzer] Batch #\(batchId) complete: \(patterns.count) patterns detected, cost: $\(String(format: "%.6f", costUSD ?? 0))")

            // Notify user of new patterns
            for p in patterns {
                let name = p.name ?? "Unnamed pattern"
                notifier?.notifyPattern(name: name, occurrences: 1)
            }

            // Update menu bar pattern count
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: Notification.Name("patinaPatternsChanged"), object: nil)
            }

        } catch {
            print("[Analyzer] Response handling error: \(error)")
            try? db.updateBatch(id: batchId, status: "error", receivedAt: ISO8601Formatter.now(),
                                promptTokens: nil, completionTokens: nil, costUSD: nil,
                                responseJSON: error.localizedDescription)
        }
    }

    // MARK: - Pattern parsing

    private struct DetectedPattern {
        let name: String?
        let description: String
        let recommendation: String?
        let observationIds: [Int]
        let confidence: Double?
    }

    private func parsePatterns(_ content: String, observations: [ObservationRow]) -> [DetectedPattern] {
        // Strip markdown fences if present
        var cleaned = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("```") {
            if let firstNewline = cleaned.firstIndex(of: "\n") {
                cleaned = String(cleaned[cleaned.index(after: firstNewline)...])
            }
            if cleaned.hasSuffix("```") {
                cleaned = String(cleaned.dropLast(3))
            }
            cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let data = cleaned.data(using: .utf8) else { return [] }

        var patternsArray: [[String: Any]]?

        // Try raw array first
        if let parsed = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            patternsArray = parsed
        } else if let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            // Try common wrapper keys
            for key in ["patterns", "results", "workflows"] {
                if let arr = parsed[key] as? [[String: Any]] {
                    patternsArray = arr
                    break
                }
            }
        }

        guard let patterns = patternsArray else {
            print("[Analyzer] Could not parse patterns from response")
            return []
        }

        return patterns.compactMap { p in
            guard let desc = p["description"] as? String else { return nil }
            let name = p["name"] as? String
            let recommendation = p["recommendation"] as? String
            let confidence = p["confidence"] as? Double
            let indices = p["observation_indices"] as? [Int] ?? []

            // Map indices to actual observation IDs
            let obsIds = indices.compactMap { idx -> Int? in
                guard idx >= 0, idx < observations.count else { return nil }
                return observations[idx].id
            }

            return DetectedPattern(name: name, description: desc, recommendation: recommendation, observationIds: obsIds, confidence: confidence)
        }
    }

    // MARK: - Stats

    func todayStats() -> DayStats {
        do {
            let observations = try db.todayObservations()
            let appSwitches = observations.filter { $0.eventType == "app_switch" }.count
            let focusChanges = observations.filter { $0.eventType == "focus_change" }.count
            let uniqueApps = Set(observations.map { $0.appName }).count
            let withElementData = observations.filter { $0.elementRole != nil || $0.elementTitle != nil }.count
            let coverage = observations.isEmpty ? 0.0 : Double(withElementData) / Double(observations.count) * 100.0

            return DayStats(
                totalObservations: observations.count,
                appSwitches: appSwitches,
                focusChanges: focusChanges,
                uniqueApps: uniqueApps,
                elementCoverage: coverage
            )
        } catch {
            print("[Analyzer] Error: \(error)")
            return DayStats(totalObservations: 0, appSwitches: 0, focusChanges: 0, uniqueApps: 0, elementCoverage: 0)
        }
    }
}

struct DayStats {
    let totalObservations: Int
    let appSwitches: Int
    let focusChanges: Int
    let uniqueApps: Int
    let elementCoverage: Double
}
