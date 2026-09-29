import AppKit
import EventKit
import Foundation
import os.log

private let calLog = Logger(subsystem: "com.codeisland", category: "calendar")


/// TEMPORARY file-based diagnostics (unified log proved unreliable to query).
private func calDebug(_ message: String) {
    let line = "[\(Date().formatted(date: .omitted, time: .standard))] \(message)\n"
    let path = "/tmp/codeisland-calendar.log"
    if let handle = FileHandle(forWritingAtPath: path) {
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(line.utf8))
    } else {
        try? Data(line.utf8).write(to: URL(fileURLWithPath: path))
    }
}

/// Today's calendar events, driven by EventKit. Shows the event currently in
/// progress (with a progress rail) or the next one today, plus a remaining
/// count — as a header card under the Now Playing card.
///
/// Refresh model: a full EventKit query every 5 minutes and on
/// `.EKEventStoreChanged`, plus a 30s local tick that only re-derives the
/// displayed card from the cached events (countdown text / event transitions)
/// — EventKit queries stay cheap.
@MainActor
@Observable
final class CalendarMonitor {
    private(set) var authorizationStatus: EKAuthorizationStatus = .notDetermined

    var isEnabled: Bool {
        // Same initialization-order caveat as NowPlayingMonitor: fall back to
        // the built-in default instead of relying on registerDefaults timing.
        UserDefaults.standard.object(forKey: SettingsKey.showCalendar) as? Bool
            ?? SettingsDefaults.showCalendar
    }

    /// UI visibility: enabled + authorized + at least one remaining event today.
    var isLive: Bool {
        isEnabled && isAuthorized && displayEvent != nil
    }

    /// True while the user still has to grant (or re-grant) Calendar access —
    /// the card shows a grant button instead of events. There is deliberately
    /// NO automatic request and NO status polling: EventKit's own preference
    /// writes broadcast defaults didChange and a failed request stays
    /// .notDetermined, so any automatic retry storms. One request per click.
    var needsGrant: Bool {
        isEnabled && !isAuthorized
    }

    struct DisplayEvent {
        let title: String
        let start: Date
        let end: Date
        let isInProgress: Bool
    }

    /// The event currently in progress, or the next one starting today.
    private(set) var displayEvent: DisplayEvent?
    /// Events still ahead today (started-or-starting after `now`).
    private(set) var todayRemainingCount = 0

    private let store = EKEventStore()
    private var cachedEvents: [EKEvent] = []
    private var tickTimer: Timer?
    private var refreshTimer: Timer?
    private var storeChangeToken: NSObjectProtocol?
    private var defaultsToken: NSObjectProtocol?
    private var activated = false
    private var requestInFlight = false
    private var lastRequestAt = Date.distantPast
    private var lastSyncAt = Date.distantPast
    /// 60s poll so a grant made in System Settings is picked up without an
    /// app restart (authorization changes have no notification).

    private var isAuthorized: Bool {
        switch authorizationStatus {
        case .fullAccess, .authorized: return true
        default: return false
        }
    }

    init() {
        authorizationStatus = EKEventStore.authorizationStatus(for: .event)
        defaultsToken = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.syncActivation() }
        }
        syncActivation()
    }

    // No deinit: lives as long as AppState (process lifetime).

    // MARK: - Activation

    private func syncActivation() {
        // defaults didChange fires many times per second while an access
        // request is in flight (EventKit writes its own preferences, and each
        // write broadcasts here) — throttle the check.
        let now = Date()
        guard now.timeIntervalSince(lastSyncAt) >= 1 else { return }
        lastSyncAt = now
        if isEnabled, !activated {
            activate()
        } else if !isEnabled, activated {
            deactivate()
        }
    }

    private func activate() {
        activated = true
        switch authorizationStatus {
        case .fullAccess, .authorized:
            startObserving()
            refreshEvents()
        case .notDetermined, .denied, .restricted, .writeOnly:
            // No automatic request and no status polling: EventKit's own
            // preference writes broadcast defaults didChange while a request
            // is in flight, and a declined request stays .notDetermined — an
            // automatic retry is an infinite hot loop (seen live: hundreds of
            // requests/second). The grant is explicit: the header card shows
            // a button (needsGrant) that calls requestAccess().
            calLog.notice("calendar access \(self.authorizationStatus.rawValue) — waiting for explicit grant")
        @unknown default:
            break
        }
    }

    /// Explicit user-initiated grant (header card button / settings button).
    func requestAccess() {
        guard !requestInFlight else { return }
        requestInFlight = true
        calLog.notice("requesting full access to events")
        calDebug("requesting full access")
        Task { [weak self] in
            guard let self else { return }
            let granted = (try? await self.store.requestFullAccessToEvents()) ?? false
            await MainActor.run {
                self.requestInFlight = false
                self.authorizationStatus = EKEventStore.authorizationStatus(for: .event)
                calLog.notice("calendar access granted=\(granted)")
                calDebug("access granted=\(granted) status=\(self.authorizationStatus.rawValue)")
                if granted, self.activated {
                    self.startObserving()
                    self.refreshEvents()
                }
            }
        }
    }

    private func deactivate() {
        stopTimers()
        storeChangeToken.map { NotificationCenter.default.removeObserver($0) }
        storeChangeToken = nil
        cachedEvents = []
        displayEvent = nil
        todayRemainingCount = 0
    }


    private func startObserving() {
        let center = NotificationCenter.default
        if storeChangeToken == nil {
            storeChangeToken = center.addObserver(
                forName: .EKEventStoreChanged, object: store, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.refreshEvents() }
            }
        }
        startTimers()
    }

    private func startTimers() {
        guard tickTimer == nil else { return }
        // 30s tick: re-derive the displayed card from cached events only.
        tickTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.rederiveDisplay() }
        }
        // 5min tick: full EventKit re-query.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshEvents() }
        }
    }

    private func stopTimers() {
        tickTimer?.invalidate()
        tickTimer = nil
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    // MARK: - Queries

    func refreshEvents() {
        guard isAuthorized else { return }
        let now = Date()
        let endOfTomorrow = Calendar.current.startOfDay(for: now)
            .addingTimeInterval(2 * 24 * 3600)
        let predicate = store.predicateForEvents(withStart: now, end: endOfTomorrow, calendars: nil)
        cachedEvents = store.events(matching: predicate)
            .filter { !$0.isAllDay }
            .sorted { $0.startDate < $1.startDate }
        rederiveDisplay()
    }

    /// Re-derives `displayEvent`/`todayRemainingCount` from the cached events
    /// against the current clock — cheap, runs on every tick.
    private func rederiveDisplay() {
        guard isAuthorized else { return }
        let now = Date()
        let upcoming = cachedEvents.filter { $0.endDate > now }
        todayRemainingCount = upcoming.count

        if let running = upcoming.first(where: { $0.startDate <= now }) {
            displayEvent = DisplayEvent(
                title: running.title ?? "",
                start: running.startDate,
                end: running.endDate,
                isInProgress: true
            )
        } else if let next = upcoming.first {
            displayEvent = DisplayEvent(
                title: next.title ?? "",
                start: next.startDate,
                end: next.endDate,
                isInProgress: false
            )
        } else {
            displayEvent = nil
        }
    }
}

// MARK: - Display formatting (pure, testable)

extension CalendarMonitor {
    /// Minute-level countdown line for the card's subtitle. `localize` looks
    /// up an L10n key; "%d" placeholders are substituted here.
    static func countdownText(
        event: DisplayEvent,
        now: Date,
        localize: (String) -> String
    ) -> String {
        func l10nMin(_ key: String, _ minutes: Int) -> String {
            localize(key).replacingOccurrences(of: "%d", with: "\(minutes)")
        }
        if event.isInProgress {
            let remaining = max(0, Int(event.end.timeIntervalSince(now) / 60))
            if remaining < 1 {
                return l10nMin("calendar_ending_now", 0)
            }
            return l10nMin("calendar_remaining_min", remaining)
        }
        let minutes = max(0, Int(event.start.timeIntervalSince(now) / 60))
        if minutes < 1 {
            return l10nMin("calendar_starting_now", 0)
        }
        return l10nMin("calendar_starts_in_min", minutes)
    }

    /// Progress of an in-progress event, 0…1 (nil when not running).
    static func progressFraction(event: DisplayEvent, now: Date) -> Double? {
        guard event.isInProgress else { return nil }
        let total = event.end.timeIntervalSince(event.start)
        guard total > 0 else { return nil }
        let elapsed = now.timeIntervalSince(event.start)
        return min(max(elapsed / total, 0), 1)
    }
}
