import AppKit
import Foundation
import os.log

private let npLog = Logger(subsystem: "com.codeisland", category: "nowplaying")

/// Now-Playing data driven by the MediaRemote framework **through a child
/// process** (`swift NowPlayingProbe.swift`, interpreted — see that file).
///
/// Why a child process: mediaremoted on this OS only serves Now Playing data
/// to Apple-signed callers. Our self-signed app (and every compiled probe
/// variant) gets "Operation not permitted", while interpreted Swift runs
/// inside swift-frontend — an Apple-signed toolchain binary — and receives
/// full track data (verified live). The probe speaks JSON Lines on stdout and
/// takes playback commands on stdin.
///
/// Design notes:
/// - The probe needs ~3-5s of swift-driver compile time on first start; the
///   card appears once data arrives.
/// - If the probe dies it is restarted (bounded retries) — losing it must
///   never wedge the app.
/// - Elapsed time is app-local advanced between probe updates for smooth UI.
@MainActor
@Observable
final class NowPlayingMonitor {
    private(set) var title = ""
    private(set) var artist = ""
    private(set) var album = ""
    private(set) var artwork: NSImage?
    /// The playing app's own icon — cover fallback for players (QQ Music &
    /// friends) that provide no artwork through MediaRemote.
    private(set) var appIcon: NSImage?
    private(set) var duration: TimeInterval = 0
    private(set) var elapsedTime: TimeInterval = 0
    private(set) var playbackRate: Double = 0
    private(set) var isPlaying = false
    /// Human-facing source label; the probe does not identify the player.
    private(set) var sourceName = "MediaRemote"
    /// True once the probe delivered at least one track — drives UI visibility.
    private(set) var hasTrack = false

    var isEnabled: Bool {
        // Do NOT use bool(forKey:) alone: registerDefaults runs lazily inside
        // SettingsManager.shared and may execute AFTER this monitor's init —
        // an unregistered key reads false and register() fires no change
        // notification, leaving the monitor dormant forever. Fall back to the
        // built-in default so initialization order is irrelevant.
        UserDefaults.standard.object(forKey: SettingsKey.showNowPlaying) as? Bool
            ?? SettingsDefaults.showNowPlaying
    }

    /// UI visibility: the setting is on AND the probe delivered a track.
    var isLive: Bool {
        isEnabled && hasTrack
    }

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var lineBuffer = Data()
    private var activated = false
    private var restartCount = 0
    private var restartTask: Task<Void, Never>?
    private var progressTimer: Timer?
    private var lastTickDate: Date?
    private var defaultsToken: NSObjectProtocol?

    /// Bounded restarts so a fundamentally broken probe cannot spin forever.
    private let maxRestarts = 5

    init() {
        defaultsToken = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.syncActivation() }
        }
        syncActivation()
    }

    // No deinit: the monitor lives as long as AppState (process lifetime), and
    // a deinit could not touch the MainActor-isolated process/timer state.

    // MARK: - Activation

    private func syncActivation() {
        if isEnabled, !activated {
            activate()
        } else if !isEnabled, activated {
            deactivate()
        }
    }

    private func activate() {
        guard let swiftURL = Self.swiftExecutableURL(),
              let probeURL = Self.probeScriptURL() else {
            npLog.error("activate: swift toolchain or probe script missing, staying dormant")
            return
        }
        activated = true

        let proc = Process()
        proc.executableURL = swiftURL
        proc.arguments = [probeURL.path]
        let stdoutPipe = Pipe()
        let stdinPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardInput = stdinPipe
        proc.standardError = FileHandle.nullDevice

        proc.terminationHandler = { [weak self] _ in
            Task { @MainActor in self?.probeDidExit() }
        }

        do {
            try proc.run()
        } catch {
            npLog.error("probe launch failed: \(error.localizedDescription, privacy: .public)")
            activated = false
            scheduleRestart()
            return
        }

        process = proc
        stdinHandle = stdinPipe.fileHandleForWriting
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor in self?.consumeProbeData(data) }
        }
    }

    private func probeDidExit() {
        process = nil
        stdinHandle = nil
        stdoutBufferReset()
        stopProgressTimer()
        guard activated else { return }
        scheduleRestart()
    }

    /// Restart with bounded retries; the counter resets once a probe has
    /// delivered data (a healthy long-lived run).
    private func scheduleRestart() {
        guard restartCount < maxRestarts else {
            npLog.error("probe restart limit reached (\(self.restartCount)); now-playing stays off this launch")
            return
        }
        restartCount += 1
        let delay = TimeInterval(2 + restartCount) // backoff: 3s, 4s, …
        restartTask?.cancel()
        restartTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, self?.activated == true else { return }
            self?.activate()
        }
    }

    private func deactivate() {
        activated = false
        restartTask?.cancel()
        restartTask = nil
        if let process, process.isRunning {
            // SIGTERM the swift driver; the interpret session dies with it.
            process.terminate()
        }
        process = nil
        stdinHandle = nil
        stdoutBufferReset()
        stopProgressTimer()
        clearTrack()
    }

    private func clearTrack() {
        stopProgressTimer()
        title = ""
        artist = ""
        album = ""
        artwork = nil
        appIcon = nil
        duration = 0
        elapsedTime = 0
        playbackRate = 0
        isPlaying = false
        hasTrack = false
    }

    // MARK: - Probe output

    private var stdoutBuffer = Data()

    private func stdoutBufferReset() {
        stdoutBuffer = Data()
    }

    private func consumeProbeData(_ data: Data) {
        stdoutBuffer.append(data)
        // Split on newlines; keep the trailing partial line in the buffer.
        while let newline = stdoutBuffer.firstIndex(of: 0x0A) {
            let lineData = stdoutBuffer[..<newline]
            stdoutBuffer = Data(stdoutBuffer[stdoutBuffer.index(after: newline)...])
            guard !lineData.isEmpty,
                  let line = String(data: Data(lineData), encoding: .utf8)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
                  !line.isEmpty,
                  let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
                continue
            }
            // Player quit / queue emptied — the probe reports it explicitly so
            // the card disappears instead of showing a stale forever-playing
            // track.
            if (json["cleared"] as? Bool) == true {
                stopProgressTimer()
                clearTrack()
                continue
            }
            // The playing app's pid arrives as its own line (outside the
            // track-dedup gate so player switches always propagate).
            if let pid = json["playerPID"] as? Int32 {
                updateAppIcon(for: pid)
                continue
            }
            applyProbeUpdate(json)
        }
    }

    /// Cover fallback: the playing player's own app icon (NSRunningApplication
    /// serves the icns representation; cached per pid — icons never change).
    private var appIconCache: [pid_t: NSImage] = [:]

    private func updateAppIcon(for pid: pid_t) {
        guard appIconCache[pid] == nil else {
            appIcon = appIconCache[pid]
            return
        }
        let icon = NSRunningApplication(processIdentifier: pid)?.icon
        appIconCache[pid] = icon
        appIcon = icon
    }

    private func applyProbeUpdate(_ json: [String: Any]) {
        let newTitle = json["title"] as? String ?? ""
        guard !newTitle.isEmpty else { return }
        restartCount = 0 // a healthy delivery resets the restart budget
        title = newTitle
        artist = json["artist"] as? String ?? ""
        album = json["album"] as? String ?? ""
        duration = json["duration"] as? TimeInterval ?? 0
        elapsedTime = json["elapsedTime"] as? TimeInterval ?? 0
        playbackRate = json["playbackRate"] as? Double ?? 0
        // The probe reports the per-app system playing bit — QQ Music & co.
        // freeze their MediaRemote info on pause (playbackRate stays 1), so
        // rate>0 alone would never register a pause.
        if let playing = json["playing"] as? Bool {
            isPlaying = playing
        } else {
            isPlaying = playbackRate > 0
        }
        hasTrack = true
        syncProgressTimer()
    }

    // MARK: - Local progress ticking

    /// The probe updates elapsed time on MediaRemote events and its 1s poll;
    /// between updates the UI advances time locally for a smooth progress bar.
    private func syncProgressTimer() {
        stopProgressTimer()
        guard isPlaying, duration > 0 else { return }
        lastTickDate = Date()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.advanceProgress() }
        }
        RunLoop.main.add(timer, forMode: .common)
        progressTimer = timer
    }

    private func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
        lastTickDate = nil
    }

    private func advanceProgress() {
        guard isPlaying, duration > 0 else {
            syncProgressTimer()
            return
        }
        let now = Date()
        let delta = lastTickDate.map { now.timeIntervalSince($0) } ?? 1
        lastTickDate = now
        elapsedTime += min(max(delta, 0.5), 5) * max(playbackRate, 1)
        if elapsedTime >= duration {
            elapsedTime = duration
            syncProgressTimer()
        }
    }

    // MARK: - Playback controls (stdin commands to the probe)

    func togglePlayPause() {
        sendCommand("toggle")
        isPlaying.toggle()
        syncProgressTimer()
    }

    func nextTrack() {
        sendCommand("next")
    }

    func previousTrack() {
        sendCommand("prev")
    }

    private func sendCommand(_ command: String) {
        guard let stdinHandle else { return }
        stdinHandle.write(Data((command + "\n").utf8))
    }

    /// The probe only has artwork-free metadata today; MediaRemote's in-process
    /// GetNowPlayingInfo is refused on this OS, so there is no second source.
    /// (kept for future adapter extension)

    // MARK: - Paths

    private static func swiftExecutableURL() -> URL? {
        let url = URL(fileURLWithPath: "/usr/bin/swift")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    private static func probeScriptURL() -> URL? {
        // SPM .copy("Resources") keeps the Resources/ prefix inside the
        // CodeIsland_CodeIsland bundle.
        if let url = Bundle.appModule.url(
            forResource: "NowPlayingProbe", withExtension: "swift", subdirectory: "Resources"
        ) {
            return url
        }
        // Dev fallback: the bundle accessor may already land us inside Resources/.
        return Bundle.appModule.url(forResource: "NowPlayingProbe", withExtension: "swift")
    }
}

