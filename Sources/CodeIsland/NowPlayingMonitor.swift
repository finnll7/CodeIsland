import AppKit
import Foundation

/// Now-Playing probe backed by the MediaRemote private framework, loaded with
/// dlopen at runtime (no link-time dependency, degrades silently when Apple
/// renames/withdraws symbols). Ported from SuperIsland's NowPlayingManager,
/// trimmed to the system-media path: register for MediaRemote notifications,
/// fetch track info, advance elapsed time locally while playing, and send
/// playback commands. SuperIsland's AppleScript/Chrome-tab/adapter branches
/// are deliberately not carried over.
///
/// Lifecycle: the monitor runs process-wide and gates itself on the
/// `showNowPlaying` setting — disabled clears the track state and stops
/// observing; enabling re-arms. The footer reads `isLive` to show itself.
@MainActor
@Observable
final class NowPlayingMonitor {
    private(set) var title = ""
    private(set) var artist = ""
    private(set) var album = ""
    private(set) var artwork: NSImage?
    private(set) var duration: TimeInterval = 0
    private(set) var elapsedTime: TimeInterval = 0
    private(set) var playbackRate: Double = 0
    private(set) var isPlaying = false
    /// Human-facing source label; MediaRemote itself doesn't name the player.
    private(set) var sourceName = ""
    /// True once MediaRemote delivered at least one track — drives UI visibility.
    private(set) var hasTrack = false

    var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: SettingsKey.showNowPlaying)
    }

    /// UI visibility: the setting is on AND MediaRemote actually gave us a track.
    var isLive: Bool {
        isEnabled && hasTrack
    }

    private var registerFunc: (@convention(c) (DispatchQueue) -> Void)?
    private var getInfoFunc: (@convention(c) (DispatchQueue, @escaping ([String: Any]) -> Void) -> Void)?
    private var sendCommandFunc: (@convention(c) (UInt32, UnsafeMutableRawPointer?) -> Bool)?
    private var setElapsedTimeFunc: (@convention(c) (Double) -> Void)?

    private var progressTimer: Timer?
    private var lastTickDate: Date?
    private var notificationTokens: [NSObjectProtocol] = []
    private var defaultsToken: NSObjectProtocol?
    private var activated = false

    init() {
        loadMediaRemote()
        defaultsToken = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.syncActivation() }
        }
        syncActivation()
    }

    // No deinit: the monitor lives as long as AppState (process lifetime), and
    // a deinit could not touch the MainActor-isolated timer/observers anyway.

    // MARK: - Activation

    private func syncActivation() {
        if isEnabled, !activated {
            activate()
        } else if !isEnabled, activated {
            deactivate()
        }
    }

    private func activate() {
        // Without MediaRemote there is nothing to observe — stay dormant so the
        // footer never shows, and retry nothing (symbols don't come back).
        guard registerFunc != nil, getInfoFunc != nil else { return }
        activated = true
        registerFunc?(DispatchQueue.main)
        let center = NotificationCenter.default
        for name in [
            "kMRMediaRemoteNowPlayingInfoDidChangeNotification",
            "kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
            "kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
        ] {
            notificationTokens.append(center.addObserver(
                forName: NSNotification.Name(name), object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.fetchNowPlayingInfo() }
            })
        }
        fetchNowPlayingInfo()
    }

    private func deactivate() {
        activated = false
        for token in notificationTokens { NotificationCenter.default.removeObserver(token) }
        notificationTokens.removeAll()
        stopProgressTimer()
        clearTrack()
    }

    private func clearTrack() {
        title = ""
        artist = ""
        album = ""
        artwork = nil
        duration = 0
        elapsedTime = 0
        playbackRate = 0
        isPlaying = false
        sourceName = ""
        hasTrack = false
    }

    // MARK: - MediaRemote loading

    private func loadMediaRemote() {
        let handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW)
        guard let handle else { return }
        if let sym = dlsym(handle, "MRMediaRemoteRegisterForNowPlayingNotifications") {
            registerFunc = unsafeBitCast(sym, to: (@convention(c) (DispatchQueue) -> Void).self)
        }
        if let sym = dlsym(handle, "MRMediaRemoteGetNowPlayingInfo") {
            getInfoFunc = unsafeBitCast(
                sym,
                to: (@convention(c) (DispatchQueue, @escaping ([String: Any]) -> Void) -> Void).self
            )
        }
        if let sym = dlsym(handle, "MRMediaRemoteSendCommand") {
            sendCommandFunc = unsafeBitCast(sym, to: (@convention(c) (UInt32, UnsafeMutableRawPointer?) -> Bool).self)
        }
        if let sym = dlsym(handle, "MRMediaRemoteSetElapsedTime") {
            setElapsedTimeFunc = unsafeBitCast(sym, to: (@convention(c) (Double) -> Void).self)
        }
    }

    // MARK: - Track info

    func fetchNowPlayingInfo() {
        getInfoFunc?(DispatchQueue.main) { [weak self] info in
            Task { @MainActor in self?.applyNowPlayingInfo(info) }
        }
    }

    private func applyNowPlayingInfo(_ info: [String: Any]) {
        let newTitle = info["kMRMediaRemoteNowPlayingInfoTitle"] as? String ?? ""
        guard !newTitle.isEmpty else { return }
        let rate = info["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? Double ?? 0
        title = newTitle
        artist = info["kMRMediaRemoteNowPlayingInfoArtist"] as? String ?? ""
        album = info["kMRMediaRemoteNowPlayingInfoAlbum"] as? String ?? ""
        duration = info["kMRMediaRemoteNowPlayingInfoDuration"] as? TimeInterval ?? 0
        elapsedTime = info["kMRMediaRemoteNowPlayingInfoElapsedTime"] as? TimeInterval ?? 0
        playbackRate = rate
        isPlaying = rate > 0
        sourceName = "MediaRemote"
        hasTrack = true
        if let data = info["kMRMediaRemoteNowPlayingInfoArtworkData"] as? Data {
            artwork = NSImage(data: data)
        }
        syncProgressTimer()
    }

    // MARK: - Local progress ticking

    /// MediaRemote only pushes on track/state changes; elapsed time is advanced
    /// locally once per second while playing, re-synced on every notification.
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

    // MARK: - Playback controls

    func togglePlayPause() {
        sendCommand(playbackRate > 0 || isPlaying ? 1 : 0) // kMRPause / kMRPlay
        isPlaying.toggle()
        syncProgressTimer()
    }

    func nextTrack() {
        sendCommand(4) // kMRNextTrack
    }

    func previousTrack() {
        sendCommand(5) // kMRPreviousTrack
    }

    func seek(to time: TimeInterval) {
        let clamped = max(0, min(time, duration))
        elapsedTime = clamped
        syncProgressTimer()
        setElapsedTimeFunc?(clamped)
    }

    private func sendCommand(_ command: UInt32) {
        _ = sendCommandFunc?(command, nil)
    }
}
