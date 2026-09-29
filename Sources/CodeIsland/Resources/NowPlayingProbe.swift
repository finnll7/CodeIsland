// NowPlayingProbe — MediaRemote data agent for CodeIsland.
//
// Run INTERPRETED: `/usr/bin/swift NowPlayingProbe.swift`. The whole point is
// that interpreted top-level code executes inside swift-frontend, an
// Apple-signed toolchain binary — mediaremoted only serves Now Playing data
// to Apple-signed callers on this OS (self-signed GUI apps and compiled
// binaries get "Operation not permitted", verified 2026-09).
//
// Protocol:
//   stdout: one JSON object per line whenever the track/state changes
//   stdin:  "toggle" | "next" | "prev" — playback commands
// stderr: diagnostics

import Foundation

let kMRPlay: UInt32 = 0
let kMRPause: UInt32 = 1
let kMRNextTrack: UInt32 = 4
let kMRPreviousTrack: UInt32 = 5

typealias RegisterFunc = @convention(c) (DispatchQueue) -> Void
typealias GetInfoFunc = @convention(c) (DispatchQueue, @escaping ([String: Any]) -> Void) -> Void
typealias SendFunc = @convention(c) (UInt32, UnsafeMutableRawPointer?) -> Bool

guard let handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW),
      let r = dlsym(handle, "MRMediaRemoteRegisterForNowPlayingNotifications"),
      let g = dlsym(handle, "MRMediaRemoteGetNowPlayingInfo"),
      let sc = dlsym(handle, "MRMediaRemoteSendCommand") else {
    FileHandle.standardError.write(Data("MediaRemote load failed\n".utf8))
    exit(1)
}
let registerFunc = unsafeBitCast(r, to: RegisterFunc.self)
let getInfoFunc = unsafeBitCast(g, to: GetInfoFunc.self)
let sendFunc = unsafeBitCast(sc, to: SendFunc.self)

var lastLine = ""
var lastPlaybackRate: Double = 0
var hadTrack = false

func emit(_ info: [String: Any]) {
    let title = info["kMRMediaRemoteNowPlayingInfoTitle"] as? String ?? ""
    // Player quit / queue emptied: MediaRemote pushes an EMPTY info dict. The
    // app must be told explicitly or it keeps showing the last track forever.
    guard !title.isEmpty else {
        if hadTrack {
            hadTrack = false
            lastLine = ""
            fputs("{\"cleared\":true}\n", stdout)
            fflush(stdout)
        }
        return
    }
    hadTrack = true
    lastPlaybackRate = info["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? Double ?? 0
    let payload: [String: Any] = [
        "title": title,
        "artist": info["kMRMediaRemoteNowPlayingInfoArtist"] as? String ?? "",
        "album": info["kMRMediaRemoteNowPlayingInfoAlbum"] as? String ?? "",
        "duration": info["kMRMediaRemoteNowPlayingInfoDuration"] as? TimeInterval ?? 0,
        "elapsedTime": info["kMRMediaRemoteNowPlayingInfoElapsedTime"] as? TimeInterval ?? 0,
        "playbackRate": lastPlaybackRate,
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: payload),
          let line = String(data: data, encoding: .utf8), line != lastLine else { return }
    lastLine = line
    // stdout is a pipe when driven by the app — print's buffering would delay
    // lines, so write + explicit flush.
    fputs(line + "\n", stdout)
    fflush(stdout)
}

func fetch() {
    getInfoFunc(DispatchQueue.main) { emit($0) }
}

// Notification-driven updates.
registerFunc(DispatchQueue.main)
let center = NotificationCenter.default
for name in [
    "kMRMediaRemoteNowPlayingInfoDidChangeNotification",
    "kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
    "kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
] {
    center.addObserver(forName: NSNotification.Name(name), object: nil, queue: .main) { _ in
        fetch()
    }
}

// Commands from the app arrive on stdin.
DispatchQueue.global(qos: .utility).async {
    while let line = readLine()?.trimmingCharacters(in: .whitespaces) {
        switch line {
        case "toggle":
            _ = sendFunc(lastPlaybackRate > 0 ? kMRPause : kMRPlay, nil)
        case "next":
            _ = sendFunc(kMRNextTrack, nil)
        case "prev":
            _ = sendFunc(kMRPreviousTrack, nil)
        default:
            break
        }
    }
}

// 1s poll keeps elapsed time moving and papers over missed notifications.
let timer = Timer(timeInterval: 1, repeats: true) { _ in
    fetch()
}
RunLoop.main.add(timer, forMode: .common)
fetch()

while true {
    RunLoop.main.run(mode: .default, before: Date.distantFuture)
}
