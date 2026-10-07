import AppKit
import Foundation
import os.log

private let thingsLog = Logger(subsystem: "com.codeisland", category: "things3")

/// Things3 to-dos and plans for the header card, read via the official
/// AppleScript dictionary (no Full Disk Access, no network). Replaces the
/// EventKit calendar column when enabled.
///
/// Consent model (same posture as CalendarMonitor): NO automatic request —
/// the card shows a grant button until the user explicitly clicks it; the
/// first read then triggers the macOS Automation prompt for Things3.
///
/// Refresh model: one osascript run per 60s tick. Each run queries only the
/// localized「今天/Today」and「计划/Upcoming」pseudo-lists, so the query stays
/// cheap even with years of logbook history. List names follow the app's UI
/// language, so the script resolves them from `name of lists` at runtime.
@MainActor
@Observable
final class Things3Monitor {
    struct Item: Equatable {
        let title: String
        /// Localized due-date text straight from AppleScript (display only).
        let dueText: String
        let tags: String
    }

    enum Status: Equatable {
        /// Waiting for the user's explicit first read (grant button shown).
        case needsGrant
        /// The user declined the Automation prompt — point at System Settings.
        case denied
        /// Anything else (script failure, Things3 not running …).
        case failed(String)
        /// Data read successfully (even when the lists are empty).
        case live
    }

    private(set) var todayItems: [Item] = []
    private(set) var upcomingItems: [Item] = []
    private(set) var status: Status = .needsGrant

    var isEnabled: Bool {
        // Same initialization-order caveat as CalendarMonitor: fall back to
        // the built-in default instead of relying on registerDefaults timing.
        UserDefaults.standard.object(forKey: SettingsKey.showThings3) as? Bool
            ?? SettingsDefaults.showThings3
    }

    var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.culturedcode.ThingsMac") != nil
    }

    /// UI visibility: enabled + installed + data (or the grant prompt).
    var isLive: Bool {
        isEnabled && isInstalled && status == .live
    }

    /// The Things3 column replaces the calendar column as soon as the app is
    /// installed and enabled — the grant state renders inside that column, so
    /// the swap is visible before the first read.
    var needsGrant: Bool {
        isEnabled && isInstalled && status == .needsGrant
    }

    /// Grant/retry button visibility: before the first consent, or while
    /// Things3 is not running (clicking relaunches and re-reads).
    var showsGrantButton: Bool {
        guard isEnabled, isInstalled else { return false }
        if status == .needsGrant { return true }
        if case .failed(let message) = status { return message == "not running" }
        return false
    }

    /// True when the Things3 column should take over the calendar column.
    var takesOverCalendar: Bool {
        isEnabled && isInstalled
    }

    private var refreshTimer: Timer?
    private var activated = false
    private var scanning = false

    /// Persisted consent memory: once the user clicked the grant button (and
    /// macOS recorded the Automation permission for this bundle), later app
    /// launches resume polling WITHOUT another button click — the TCC grant
    /// itself is permanent, so the in-panel step is one-time.
    private var hasGrantedOnce: Bool {
        UserDefaults.standard.bool(forKey: SettingsKey.things3Granted)
    }

    init() {
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.syncActivation() }
        }
        // Returning user: consent was given in a previous run — resume
        // polling right away. Things3 staying closed is fine: the scan marks
        // "not running" and the next tick picks it up once launched.
        if hasGrantedOnce {
            startPolling()
            activated = true
            refresh()
        }
    }

    // No deinit: lives as long as AppState (process lifetime).

    // MARK: - Activation

    private func startPolling() {
        guard refreshTimer == nil else { return }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    /// Explicit user-initiated grant (header card button). `launchIfNeeded`
    /// is only true for the button click — a user who clicks means it, while
    /// background ticks must never force-launch Things3.
    func activate(launchIfNeeded: Bool = false) {
        UserDefaults.standard.set(true, forKey: SettingsKey.things3Granted)
        activated = true
        startPolling()
        if launchIfNeeded, !isRunning,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.culturedcode.ThingsMac") {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
        refresh()
    }

    private var isRunning: Bool {
        // A plain `application "Things3" is running` check does NOT launch it.
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == "com.culturedcode.ThingsMac"
        }
    }

    private func syncActivation() {
        // Toggle off → stop polling and clear, back to the calendar column.
        if !isEnabled {
            refreshTimer?.invalidate()
            refreshTimer = nil
            activated = false
            status = .needsGrant
            todayItems = []
            upcomingItems = []
        } else if activated {
            startPolling()
        } else if hasGrantedOnce {
            // Re-enabled after being off, with consent from an earlier run.
            activated = true
            startPolling()
            refresh()
        }
    }

    // MARK: - Queries

    func refresh() {
        guard isEnabled, isInstalled, !scanning else { return }
        guard status != .denied else { return } // denied → user must re-enable in System Settings
        scanning = true
        let script = Self.script
        Task.detached(priority: .utility) { [weak self] in
            let result = Self.runScript(script)
            guard let self else { return }
            await self.applyScriptResult(result)
        }
    }

    /// Applies a finished scan back on the main actor.
    private func applyScriptResult(_ result: Result<String, ScriptError>) {
        scanning = false
        switch result {
        case .success(let output):
            if output.trimmingCharacters(in: .whitespacesAndNewlines) == "NOT_RUNNING" {
                // Things3 closed after consent — show the not-running state;
                // the next tick recovers automatically once it launches.
                status = .failed("not running")
            } else {
                let parsed = Self.parse(output)
                todayItems = parsed.today
                upcomingItems = parsed.upcoming
                status = .live
            }
        case .failure(let error):
            thingsLog.notice("things3 read failed: \(error.message, privacy: .public)")
            if error.isDenied {
                refreshTimer?.invalidate()
                refreshTimer = nil
                status = .denied
            } else {
                status = .failed(error.message)
            }
        }
    }

    // MARK: - AppleScript

    struct ScriptError: Error {
        let message: String
        let isDenied: Bool
    }

    /// One osascript run resolving the localized list names and reading both
    /// lists. Output is line-based with \x1f field separators (see parse).
    /// Plans are capped at 25 entries — the card shows a count anyway.
    static let script = """
    set SEP to character id 31
    set LF to linefeed
    if not (application "Things3" is running) then
        return "NOT_RUNNING"
    end if
    tell application "Things3"
        set allNames to name of lists
        set todayName to ""
        set planName to ""
        repeat with n in allNames
            set nStr to n as string
            if nStr is "Today" or nStr is "今天" then set todayName to nStr
            if nStr is "Upcoming" or nStr is "计划" then set planName to nStr
        end repeat
        set out to ""
        if todayName is not "" then
            set out to out & "TODAY" & LF
            set todayList to to dos of list todayName
            repeat with t in todayList
                set dueTxt to ""
                try
                    if due date of t is not missing value then set dueTxt to (due date of t as string)
                end try
                set tagTxt to ""
                try
                    set tagTxt to (name of tags of t as string)
                end try
                set out to out & "T" & (name of t) & SEP & dueTxt & SEP & tagTxt & LF
            end repeat
        end if
        if planName is not "" then
            set out to out & "PLAN" & LF
            set planList to to dos of list planName
            set counter to 0
            repeat with t in planList
                set counter to counter + 1
                if counter > 25 then exit repeat
                set dueTxt to ""
                try
                    if due date of t is not missing value then set dueTxt to (due date of t as string)
                end try
                set tagTxt to ""
                try
                    set tagTxt to (name of tags of t as string)
                end try
                set out to out & "U" & (name of t) & SEP & dueTxt & SEP & tagTxt & LF
            end repeat
        end if
        return out
    end tell
    """

    /// Runs the script via osascript (stdin), capturing stdout/stderr.
    /// Non-blocking for the main thread — called from a detached task.
    nonisolated static func runScript(_ script: String) -> Result<String, ScriptError> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-"] // read the script from stdin
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            return .failure(ScriptError(message: "cannot launch osascript", isDenied: false))
        }
        stdin.fileHandleForWriting.write(Data(script.utf8))
        stdin.fileHandleForWriting.closeFile()
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: outData, encoding: .utf8) ?? ""
        if process.terminationStatus != 0 {
            let message = String(data: errData, encoding: .utf8) ?? "unknown error"
            // errAEEventNotPermitted (-1743): the Automation prompt was denied.
            let denied = message.contains("-1743") || message.contains("not authorized")
            return .failure(ScriptError(message: message, isDenied: denied))
        }
        return .success(output)
    }

    // MARK: - Parsing (pure, testable)

    /// Parses the line-based script output. Field separator is \x1f; sections
    /// start at bare "TODAY"/"PLAN" lines; items are lines prefixed T/U.
    /// Empty titles (Things headings / placeholder rows) are skipped.
    nonisolated static func parse(_ output: String) -> (today: [Item], upcoming: [Item]) {
        var today: [Item] = []
        var upcoming: [Item] = []
        var section = 0 // 0 = none, 1 = today, 2 = plan
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            if line == "TODAY" { section = 1; continue }
            if line == "PLAN" { section = 2; continue }
            guard line.hasPrefix("T") || line.hasPrefix("U") else { continue }
            let body = line.dropFirst()
            let fields = body.split(separator: "\u{1F}", omittingEmptySubsequences: false)
            guard let rawTitle = fields.first else { continue }
            let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }
            let dueText = fields.count > 1 ? String(fields[1]) : ""
            let tags = fields.count > 2 ? String(fields[2]) : ""
            let item = Item(title: title, dueText: dueText, tags: tags)
            if line.hasPrefix("T") && section == 1 { today.append(item) }
            else if line.hasPrefix("U") && section == 2 { upcoming.append(item) }
        }
        return (today, upcoming)
    }
}
