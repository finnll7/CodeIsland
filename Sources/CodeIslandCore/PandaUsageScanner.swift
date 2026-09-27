import Foundation

/// Token-usage aggregation over the local Panda Code turn metrics
/// (~/.panda/projects/*/sessions/*.jsonl) — local-first, no provider API calls.
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
public enum PandaUsageScanner {
    /// Sparkline resolution: one bucket per hour, oldest first. Same shape as
    /// the Claude scanner so the footer UI can render either.
    public static let sparklineHours = ClaudeUsageScanner.sparklineHours

    public typealias Snapshot = ClaudeUsageScanner.Snapshot

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
        }
        var files: [String: FileEntry] = [:]
        public init() {}
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
        let fiveHoursAgo = now.addingTimeInterval(-5 * 3600)
        let midnight = Calendar.current.startOfDay(for: now)
        let sparklineStart = now.addingTimeInterval(-Double(sparklineHours) * 3600)
        let cutoff = min(fiveHoursAgo, midnight, sparklineStart)

        var last5h = ClaudeUsageTotals()
        var today = ClaudeUsageTotals()
        var hourly = [Int](repeating: 0, count: sparklineHours)
        var activeFiles = Set<String>()

        let fm = FileManager.default
        let projectsDir = pandaHome + "/projects"
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

                for (_, turn) in entry.turns where turn.timestamp <= now {
                    if turn.timestamp >= fiveHoursAgo { last5h.add(turn.usage) }
                    if turn.timestamp >= midnight { today.add(turn.usage) }
                    let hoursAgo = Int(now.timeIntervalSince(turn.timestamp) / 3600)
                    if hoursAgo >= 0 && hoursAgo < sparklineHours {
                        hourly[sparklineHours - 1 - hoursAgo] += turn.usage.outputTokens
                    }
                }
            }
        }
        // Files that fell out of the mtime window carry no in-window turns.
        cache.files = cache.files.filter { activeFiles.contains($0.key) }
        return Snapshot(last5h: last5h, today: today, hourlyOutputTokens: hourly, scannedAt: now)
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
            }
        }
    }

    /// Parse one turnMetrics snapshot line into per-turn
    /// (turnId, startedAt, usage) tuples. Returns [] for non-metrics lines.
    /// Field mapping: promptTokens→input, completionTokens→output,
    /// cachedTokens→cache read, cacheWriteTokens→cache creation.
    static func parseTurnMetrics(_ line: String) -> [(turnId: String, timestamp: Date, usage: ClaudeUsageTotals)] {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["type"] as? String == "session_meta",
              obj["field"] as? String == "turnMetrics",
              let value = obj["value"] as? [[String: Any]]
        else { return [] }

        var result: [(String, Date, ClaudeUsageTotals)] = []
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
            result.append((turnId, Date(timeIntervalSince1970: startedAtMs / 1000), usage))
        }
        return result
    }
}
