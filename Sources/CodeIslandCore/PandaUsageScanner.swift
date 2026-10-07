import Foundation

/// Token-usage aggregation over the local Panda Code turn metrics
/// (~/.panda[/desktop]/projects/*/sessions/*.jsonl) — local-first, no provider
/// API calls.
///
/// Panda's transcript layout differs from Claude Code's in two ways that shape
/// this scanner:
///
/// 1. Transcripts live in a per-project `sessions/` subdirectory
///    (`projects/<project>/sessions/<uuid>.jsonl`), not directly under the
///    project dir like Claude's.
///
/// 2. Per-turn usage arrives as `session_meta` lines with `field: "turnMetrics"`
///    whose `value` array is a FULL SNAPSHOT of every turn in the session; the
///    whole line is re-emitted (array growing) as further turns run. The same
///    `turnId` therefore appears on many lines — unlike Claude's append-only
///    per-message rows — so totals MUST dedupe on `turnId`, keeping the value
///    from the LAST occurrence (in-flight turns report partial token counts
///    that only settle when the turn completes).
///
/// Aggregation window is one CALENDAR WEEK: Monday 00:00:00 local time through
/// Sunday 24:00. Every turn that started within the current week counts into a
/// single weekly total, and the per-day sparkline buckets by natural day
/// (index 0 = Monday … index 6 = Sunday).
public enum PandaUsageScanner {
    /// One sparkline bucket per natural day of the week, Monday first.
    public static let daysPerWeek = 7

    public struct Snapshot: Equatable, Sendable {
        /// All turns that started since Monday 00:00:00 local time.
        public let thisWeek: ClaudeUsageTotals
        /// Output tokens per natural day, index 0 = Monday … 6 = Sunday.
        /// Future days stay 0.
        public let dailyOutputTokens: [Int]
        /// Monday 00:00:00 local time of the week `scannedAt` falls in.
        public let weekStart: Date
        public let scannedAt: Date
        /// Context occupancy of the most recently started turn across all
        /// scanned transcripts — the prompt + cache footprint the model is
        /// currently carrying. In-flight turns re-emit their turnMetrics
        /// snapshot every round, so this tracks the live conversation.
        public let liveContext: LiveContext?

        public init(thisWeek: ClaudeUsageTotals, dailyOutputTokens: [Int], weekStart: Date, scannedAt: Date, liveContext: LiveContext? = nil) {
            self.thisWeek = thisWeek
            self.dailyOutputTokens = dailyOutputTokens
            self.weekStart = weekStart
            self.scannedAt = scannedAt
            self.liveContext = liveContext
        }
    }

    /// The context footprint of the newest turn in the newest transcript.
    public struct LiveContext: Equatable, Sendable {
        /// prompt + cache-read + cache-write tokens of that turn — the input
        /// size the next request in the same conversation would carry.
        public let contextTokens: Int
        public let modelName: String?
        /// When that turn started (not completed — an in-flight turn reports
        /// partial counts that grow as the conversation grows).
        public let updatedAt: Date

        public init(contextTokens: Int, modelName: String?, updatedAt: Date) {
            self.contextTokens = contextTokens
            self.modelName = modelName
            self.updatedAt = updatedAt
        }
    }

    /// Per-file incremental parse state. Transcripts are append-only (each
    /// turnMetrics line re-states the full snapshot, older lines never change),
    /// so each rescan reads only the bytes past `consumedBytes`. Value
    /// semantics: the caller owns a copy, hands it to the background scan, and
    /// stores the returned state.
    public struct FileCache: Sendable {
        struct FileEntry: Sendable {
            var consumedBytes: UInt64 = 0
            /// turnId → (turn start, usage). Last occurrence wins per turnId.
            var turns: [String: (timestamp: Date, usage: ClaudeUsageTotals)] = [:]
            /// The most recently STARTED turn in this file, in-flight turns
            /// included — its prompt+cache sum is the live context footprint.
            var latest: (timestamp: Date, contextTokens: Int, modelName: String?)?
        }
        var files: [String: FileEntry] = [:]
        public init() {}
    }

    /// Monday 00:00:00 local time of the week `date` falls in. Computed from
    /// the weekday index directly — NOT `Calendar.firstWeekday`, which follows
    /// the user's locale (Sunday in en_US) while the requirement here is a
    /// fixed Monday-start week.
    public static func weekStart(for date: Date, calendar: Calendar = .current) -> Date {
        let day = calendar.startOfDay(for: date)
        // weekday: 1 = Sunday … 7 = Saturday → days since Monday.
        let weekday = calendar.component(.weekday, from: day)
        let daysSinceMonday = (weekday + 5) % 7
        return calendar.date(byAdding: .day, value: -daysSinceMonday, to: day) ?? day
    }

    /// One-shot convenience (tests, callers without persistent state).
    public static func scan(
        pandaHome: String = NSHomeDirectory() + "/.panda",
        now: Date = Date()
    ) -> Snapshot {
        var cache = FileCache()
        return scan(pandaHome: pandaHome, now: now, cache: &cache)
    }

    public static func scan(
        pandaHome: String = NSHomeDirectory() + "/.panda",
        now: Date = Date(),
        cache: inout FileCache
    ) -> Snapshot {
        let monday = weekStart(for: now)
        let cutoff = monday

        var thisWeek = ClaudeUsageTotals()
        var daily = [Int](repeating: 0, count: daysPerWeek)
        var activeFiles = Set<String>()
        var liveContext: LiveContext?

        let fm = FileManager.default
        // Panda Desktop writes transcripts under ~/.panda/desktop/projects/...,
        // the CLI under ~/.panda/projects/... — scan both.
        let projectsRoots = [pandaHome + "/desktop/projects", pandaHome + "/projects"]
        for projectsDir in projectsRoots {
            for project in (try? fm.contentsOfDirectory(atPath: projectsDir)) ?? [] {
                let sessionsDir = projectsDir + "/" + project + "/sessions"
                for file in (try? fm.contentsOfDirectory(atPath: sessionsDir)) ?? [] {
                    guard file.hasSuffix(".jsonl") else { continue }
                    let path = sessionsDir + "/" + file
                    // mtime gate: untouched-since-cutoff transcripts can't contain
                    // in-window turns, so the scan stays cheap on big histories.
                    guard let attrs = try? fm.attributesOfItem(atPath: path),
                          let mtime = attrs[.modificationDate] as? Date,
                          mtime >= cutoff else { continue }
                    activeFiles.insert(path)
                    let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0

                    var entry = cache.files[path] ?? FileCache.FileEntry()
                    if size < entry.consumedBytes {
                        // Truncated or replaced — start over.
                        entry = FileCache.FileEntry()
                    }
                    if size > entry.consumedBytes {
                        consumeNewLines(path: path, into: &entry)
                    }
                    cache.files[path] = entry

                    for (_, turn) in entry.turns where turn.timestamp > monday && turn.timestamp <= now {
                        thisWeek.add(turn.usage)
                        let dayIndex = calendarDayOffset(from: monday, to: turn.timestamp)
                        if dayIndex >= 0 && dayIndex < daysPerWeek {
                            daily[dayIndex] += turn.usage.outputTokens
                        }
                    }
                    // Live context ignores the week boundary — a conversation
                    // started last week still carries its context today. The
                    // newest started turn wins across files.
                    if let latest = entry.latest,
                       liveContext.map({ latest.timestamp > $0.updatedAt }) ?? true {
                        liveContext = LiveContext(
                            contextTokens: latest.contextTokens,
                            modelName: latest.modelName,
                            updatedAt: latest.timestamp)
                    }
                }
            }
        }
        // Files that fell out of the mtime window carry no in-window turns.
        cache.files = cache.files.filter { activeFiles.contains($0.key) }
        return Snapshot(thisWeek: thisWeek, dailyOutputTokens: daily, weekStart: monday, scannedAt: now, liveContext: liveContext)
    }

    /// Whole-day offset between two dates in the same week (0 = Monday).
    /// Uses startOfDay arithmetic so DST shifts cannot off-by-one a bucket.
    private static func calendarDayOffset(from weekStart: Date, to date: Date, calendar: Calendar = .current) -> Int {
        let from = calendar.startOfDay(for: weekStart)
        let to = calendar.startOfDay(for: date)
        return calendar.dateComponents([.day], from: from, to: to).day ?? 0
    }

    /// Read bytes past `entry.consumedBytes` and parse the COMPLETE lines only —
    /// a partial trailing line (writer mid-append) is left for the next scan.
    /// Lines are processed in order so a later turnMetrics snapshot (carrying
    /// settled token counts for in-flight turns) overwrites earlier partials.
    private static func consumeNewLines(path: String, into entry: inout FileCache.FileEntry) {
        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { handle.closeFile() }
        handle.seek(toFileOffset: entry.consumedBytes)
        let data = handle.readDataToEndOfFile()
        guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else { return }
        let consumable = data[data.startIndex...lastNewline]
        entry.consumedBytes += UInt64(consumable.count)
        guard let text = String(data: consumable, encoding: .utf8) else { return }

        for line in text.split(separator: "\n") {
            // Cheap pre-filter before full JSON decoding: only turnMetrics
            // snapshot lines carry usage.
            let lineString = String(line)
            guard lineString.contains("turnMetrics") else { continue }
            let parsed = parseTurnMetrics(lineString)
            for turn in parsed {
                entry.turns[turn.turnId] = (turn.timestamp, turn.usage)
                // Track the newest started turn for the live-context readout.
                // Later lines carry grown (settled or in-flight) counts.
                if entry.latest == nil || turn.timestamp > entry.latest!.timestamp {
                    entry.latest = (
                        turn.timestamp,
                        turn.usage.inputTokens + turn.usage.cacheReadTokens + turn.usage.cacheCreationTokens,
                        turn.modelName
                    )
                }
            }
        }
    }

    /// Parse one turnMetrics snapshot line into per-turn
    /// (turnId, startedAt, usage, modelName) tuples. Returns [] for
    /// non-metrics lines.
    /// Field mapping: promptTokens→input, completionTokens→output,
    /// cachedTokens→cache read, cacheWriteTokens→cache creation.
    static func parseTurnMetrics(_ line: String) -> [(turnId: String, timestamp: Date, usage: ClaudeUsageTotals, modelName: String?)] {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["type"] as? String == "session_meta",
              obj["field"] as? String == "turnMetrics",
              let value = obj["value"] as? [[String: Any]]
        else { return [] }

        var result: [(String, Date, ClaudeUsageTotals, String?)] = []
        result.reserveCapacity(value.count)
        for turn in value {
            guard let turnId = turn["turnId"] as? String, !turnId.isEmpty,
                  let startedAtMs = (turn["startedAt"] as? NSNumber)?.doubleValue else { continue }
            var usage = ClaudeUsageTotals()
            usage.inputTokens = turn["promptTokens"] as? Int ?? 0
            usage.outputTokens = turn["completionTokens"] as? Int ?? 0
            usage.cacheReadTokens = turn["cachedTokens"] as? Int ?? 0
            usage.cacheCreationTokens = turn["cacheWriteTokens"] as? Int ?? 0
            usage.messageCount = 1
            let modelName = turn["modelName"] as? String
                ?? ((turn["modelId"] as? String).map { $0.isEmpty ? nil : $0 } ?? nil)
            result.append((turnId, Date(timeIntervalSince1970: startedAtMs / 1000), usage, modelName))
        }
        return result
    }
}
