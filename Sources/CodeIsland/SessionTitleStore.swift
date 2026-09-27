import Foundation
import CodeIslandCore

struct ResolvedSessionTitle: Sendable, Equatable {
    let title: String
    let source: SessionTitleSource
}

enum SessionTitleStore {
    static func supports(provider: String) -> Bool {
        switch provider {
        case "codex", "claude", "panda":
            return true
        default:
            return false
        }
    }

    static func title(for sessionId: String, provider: String, cwd: String? = nil) -> ResolvedSessionTitle? {
        switch provider {
        case "codex":
            guard let title = codexThreadName(sessionId: sessionId) else { return nil }
            return ResolvedSessionTitle(title: title, source: .codexThreadName)
        case "claude":
            return claudeTitle(sessionId: sessionId, cwd: cwd)
        case "panda":
            return pandaTitle(sessionId: sessionId)
        default:
            return nil
        }
    }

    /// Panda Code transcripts carry a session's title in two places:
    ///   - the head `type: "session"` line holds the default title written at
    ///     creation ("对话 9/15/2026, 2:35:10 PM");
    ///   - every later change — the auto title derived from the first user
    ///     message, and each manual rename — appends a
    ///     `{"type":"session_meta","field":"title","value":…}` line deeper in
    ///     the file. The LAST such line in file order wins.
    /// Renames can land anywhere in a multi-megabyte transcript, and the
    /// refresh runs on every hook event, so scanning is incremental: a
    /// per-path cache remembers how far the transcript has been read and the
    /// newest title found, and each refresh only parses the bytes appended
    /// since the previous look. Layouts:
    ///   - Panda Desktop: ~/.panda/desktop/projects/<encoded>/sessions/<id>.jsonl
    ///   - Panda CLI:     ~/.panda/projects/<encoded>/sessions/<id>.jsonl
    static func pandaTitle(
        sessionId: String,
        pandaHome: String = NSHomeDirectory() + "/.panda"
    ) -> ResolvedSessionTitle? {
        let roots = [
            pandaHome + "/desktop/projects",
            pandaHome + "/projects",
        ]
        let fm = FileManager.default
        for root in roots {
            for project in (try? fm.contentsOfDirectory(atPath: root)) ?? [] {
                let path = root + "/" + project + "/sessions/" + sessionId + ".jsonl"
                guard let title = pandaTitle(atPath: path) else { continue }
                return ResolvedSessionTitle(title: title, source: .pandaSessionTitle)
            }
        }
        return nil
    }

    /// How far a transcript has been scanned plus the newest title found.
    /// `atLineBoundary` records whether `scannedEnd` sits just past a newline
    /// (or at 0) — a scan resuming mid-line must drop its leading partial.
    /// Main-thread only — AppState refreshes titles from its event loop.
    private struct PandaTitleScan {
        var scannedEnd: UInt64
        var atLineBoundary: Bool
        var title: String?
    }

    private static var pandaTitleScans: [String: PandaTitleScan] = [:]
    private static let pandaHeadBytes: UInt64 = 65_536
    private static let pandaChunkBytes: UInt64 = 1_048_576

    static func resetPandaTitleCache() {
        pandaTitleScans.removeAll()
    }

    private static func pandaTitle(atPath path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            pandaTitleScans[path] = nil
            return nil
        }
        defer { handle.closeFile() }
        let size = handle.seekToEndOfFile()
        guard size > 0 else {
            pandaTitleScans[path] = nil
            return nil
        }

        // Default title: the `type: "session"` creation line at the head.
        let head = pandaReadChunk(handle, from: 0, to: min(size, pandaHeadBytes), fileSize: size, startsAtBoundary: true)
        let defaultTitle = pandaDefaultTitle(in: head.text)

        // session_meta titles: scan forward from wherever the previous look
        // stopped. A shrunk file (rewind/rewrite) restarts from scratch.
        let previous = pandaTitleScans[path]
        var scanFrom: UInt64 = 0
        var atBoundary = true
        if let previous, previous.scannedEnd <= size, previous.scannedEnd > 0 {
            scanFrom = previous.scannedEnd
            atBoundary = previous.atLineBoundary
        }
        var newest = scanFrom == 0 ? nil : previous?.title
        var cursor = scanFrom
        while cursor < size {
            let chunk = pandaReadChunk(
                handle,
                from: cursor,
                to: min(size, cursor + pandaChunkBytes),
                fileSize: size,
                startsAtBoundary: atBoundary
            )
            if let found = latestPandaMetaTitle(in: chunk.text) {
                newest = found
            }
            if chunk.end <= cursor { break }
            cursor = chunk.end
            atBoundary = chunk.endsAtBoundary
        }
        if pandaTitleScans.count > 64 {
            pandaTitleScans.removeAll()
        }
        pandaTitleScans[path] = PandaTitleScan(scannedEnd: cursor, atLineBoundary: atBoundary, title: newest)
        return newest ?? defaultTitle
    }

    /// Reads `[from, to)` and returns only its COMPLETE lines, the offset the
    /// next read should start from, and whether that offset sits just past a
    /// newline — so a `"field":"title"` marker never straddles two reads, and
    /// a scan resuming mid-line drops its leading partial instead of a whole
    /// line. The chunk that reaches the file's end keeps a trailing line
    /// without its newline (it is the file's last).
    private static func pandaReadChunk(
        _ handle: FileHandle,
        from: UInt64,
        to: UInt64,
        fileSize: UInt64,
        startsAtBoundary: Bool
    ) -> (text: String, end: UInt64, endsAtBoundary: Bool) {
        guard to > from else { return ("", from, startsAtBoundary) }
        handle.seek(toFileOffset: from)
        let requested = Int(to - from)
        let data = handle.readData(ofLength: requested)
        guard !data.isEmpty else { return ("", to, startsAtBoundary) }
        // The final chunk (or a short read after the file shrank): its
        // trailing line is the file's last — keep it even without a newline.
        let atFileEnd = to >= fileSize || UInt64(data.count) < UInt64(requested)

        let base = data.startIndex
        var keepStart = base
        if !startsAtBoundary {
            guard let firstNewline = data.firstIndex(of: 0x0A) else {
                // No newline: the whole chunk is the interior of a giant line.
                return ("", to, false)
            }
            keepStart = data.index(after: firstNewline)
        }
        let keepEnd: Data.Index
        if atFileEnd {
            keepEnd = data.endIndex
        } else if let lastNewline = data.lastIndex(of: 0x0A) {
            // Drop the trailing partial — the next read re-includes it whole.
            keepEnd = data.index(after: lastNewline)
        } else {
            // Mid-file chunk with no newline: interior of a giant line.
            return ("", to, false)
        }

        let kept = data.subdata(in: keepStart..<keepEnd)
        let text = String(data: kept, encoding: .utf8) ?? ""
        let dataEnd = from + UInt64(data.count)
        let end = atFileEnd ? dataEnd : from + UInt64(keepEnd - base)
        return (text, end, atFileEnd ? data.last == 0x0A : true)
    }

    /// The newest `session_meta` title in file order (nil when none).
    /// Candidate lines are located by the compact-JSON marker
    /// `"field":"title"` that JSON.stringify always emits, then JSON-parsed —
    /// so ordinary lines cost one substring search, not a parse, and a marker
    /// appearing inside a chat message is rejected by the type check.
    private static func latestPandaMetaTitle(in text: String) -> String? {
        var latest: String?
        var searchStart = text.startIndex
        while let marker = text.range(of: "\"field\":\"title\"", range: searchStart..<text.endIndex) {
            let lineStart = text[..<marker.lowerBound].lastIndex(of: "\n")
                .map { text.index(after: $0) } ?? text.startIndex
            let lineEnd = text[marker.upperBound...].firstIndex(of: "\n") ?? text.endIndex
            if let value = pandaMetaTitleLine(String(text[lineStart..<lineEnd])) {
                latest = value
            }
            searchStart = lineEnd
        }
        return latest
    }

    private static func pandaMetaTitleLine(_ line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["type"] as? String == "session_meta",
              json["field"] as? String == "title"
        else { return nil }
        return trimmedTitle(json["value"])
    }

    private static func pandaDefaultTitle(in head: String) -> String? {
        var latest: String?
        for line in head.split(whereSeparator: \.isNewline) {
            guard let data = String(line).data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["type"] as? String == "session",
                  let title = trimmedTitle(json["title"])
            else { continue }
            latest = title
        }
        return latest
    }

    static func codexThreadName(sessionId: String) -> String? {
        // Each Codex root (CODEX_HOME / account) keeps its own thread index.
        for root in AppState.codexStateRoots() {
            let path = root + "/session_index.jsonl"
            guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            if let title = try? codexThreadName(sessionId: sessionId, indexContents: contents) {
                return title
            }
        }
        return nil
    }

    static func codexThreadName(sessionId: String, indexContents: String) throws -> String? {
        struct Entry: Decodable {
            let id: String
            let thread_name: String?
            let updated_at: String?
        }

        let decoder = JSONDecoder()
        let iso8601 = ISO8601DateFormatter()
        var latestMatch: (updatedAt: Date, title: String)?

        for line in indexContents.split(whereSeparator: \.isNewline) {
            guard let data = String(line).data(using: .utf8),
                  let entry = try? decoder.decode(Entry.self, from: data),
                  entry.id == sessionId,
                  let rawTitle = entry.thread_name?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !rawTitle.isEmpty
            else {
                continue
            }

            let updatedAt = entry.updated_at.flatMap(iso8601.date(from:)) ?? .distantPast
            if let latestMatch, latestMatch.updatedAt > updatedAt {
                continue
            }

            latestMatch = (updatedAt, rawTitle)
        }

        return latestMatch?.title
    }

    static func claudeTitle(sessionId: String, cwd: String?) -> ResolvedSessionTitle? {
        guard let cwd else { return nil }

        let projectDir = cwd.claudeProjectDirEncoded()
        // The transcript sits under whichever config dir (account) ran it.
        guard let path = ClaudeConfigPaths.transcriptPath(projectDir: projectDir, sessionId: sessionId),
              let handle = FileHandle(forReadingAtPath: path) else {
            return nil
        }
        defer { handle.closeFile() }

        let fileSize = handle.seekToEndOfFile()
        let readSize: UInt64 = min(fileSize, 65536)

        handle.seek(toFileOffset: 0)
        let headData = handle.readData(ofLength: Int(readSize))

        let tailData: Data
        if fileSize > readSize {
            handle.seek(toFileOffset: fileSize - readSize)
            tailData = handle.readDataToEndOfFile()
        } else {
            tailData = headData
        }

        guard let head = String(data: headData, encoding: .utf8),
              let tail = String(data: tailData, encoding: .utf8)
        else {
            return nil
        }

        let tailTitles = latestClaudeTitles(in: tail)
        let headTitles = latestClaudeTitles(in: head)

        if let customTitle = tailTitles.custom ?? headTitles.custom {
            return ResolvedSessionTitle(title: customTitle, source: .claudeCustomTitle)
        }
        if let aiTitle = tailTitles.ai ?? headTitles.ai {
            return ResolvedSessionTitle(title: aiTitle, source: .claudeAiTitle)
        }
        return nil
    }

    private static func latestClaudeTitles(in contents: String) -> (custom: String?, ai: String?) {
        var latestCustomTitle: String?
        var latestAiTitle: String?

        for line in contents.split(whereSeparator: \.isNewline) {
            guard let data = String(line).data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = json["type"] as? String
            else {
                continue
            }

            switch type {
            case "custom-title":
                if let title = trimmedTitle(json["customTitle"]) {
                    latestCustomTitle = title
                }
            case "ai-title":
                if let title = trimmedTitle(json["aiTitle"]) {
                    latestAiTitle = title
                }
            default:
                continue
            }
        }

        return (latestCustomTitle, latestAiTitle)
    }

    private static func trimmedTitle(_ value: Any?) -> String? {
        guard let raw = value as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
