import AppKit
import CodeIslandCore
import Foundation
import UserNotifications

/// Watches for Panda Desktop launches and keeps the launcher patch healthy.
///
/// - On CodeIsland launch and on every Panda launch, verifies the patch is
///   still applied; a Panda update rewrites the bundle and silently removes
///   it, so we re-apply automatically and only notify when that fails.
/// - A few seconds after a Panda launch, checks the live process actually
///   carries the DevTools port (catches "patched but launched via the raw
///   .bin" and "patch flipped but Panda not restarted yet" states).
@MainActor
final class PandaPatchGuard {
    static let pandaAppBundlePath = "/Applications/Panda 桌面版.app"
    static let pandaBundleID = "com.pandacode.desktop"

    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        verifyPatch()
        let ws = NSWorkspace.shared.notificationCenter
        observers.append(ws.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let isPanda = app.bundleIdentifier == Self.pandaBundleID
                || (app.bundleURL?.path.hasPrefix(Self.pandaAppBundlePath) ?? false)
            if isPanda {
                self?.pandaLaunched()
            }
        })
    }

    deinit {
        for o in observers { NSWorkspace.shared.notificationCenter.removeObserver(o) }
    }

    private var patchEnabled: Bool {
        defaults.bool(forKey: SettingsKey.pandaLauncherPatch)
    }

    /// Panda finished launching — verify, then (after a settle delay) check
    /// the live process for the port.
    func pandaLaunched() {
        guard patchEnabled else { return }
        verifyPatch()
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard let self, self.patchEnabled, PandaLauncherPatch.isApplied else { return }
            if PandaProcessScanner.findRunningDebugPort() == nil {
                self.notify(
                    titleKey: "panda_patch_title",
                    bodyKey: "panda_patch_not_effective"
                )
            }
        }
    }

    /// Patch presence check + automatic re-apply. Silent on success when the
    /// patch was already in place; notifies on re-apply (so the user knows a
    /// Panda restart is needed) and on failure.
    func verifyPatch() {
        guard patchEnabled else { return }
        guard PandaLauncherPatch.isAvailable else { return }
        guard !PandaLauncherPatch.isApplied else { return }
        let ok = PandaLauncherPatch.apply()
        notify(
            titleKey: "panda_patch_title",
            bodyKey: ok ? "panda_patch_reapplied" : "panda_patch_reapply_failed"
        )
    }

    private func notify(titleKey: String, bodyKey: String) {
        let center = UNUserNotificationCenter.current()
        let l10n = L10n.shared
        let content = UNMutableNotificationContent()
        content.title = l10n[titleKey]
        content.body = l10n[bodyKey]
        content.sound = nil
        let request = UNNotificationRequest(
            identifier: "panda-patch-\(UUID().uuidString)", content: content, trigger: nil)
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            center.add(request)
        }
    }
}

/// Shows banners even while CodeIsland is frontmost (default suppresses them).
final class PandaPatchNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = PandaPatchNotificationDelegate()
    func userNotificationCenter(
        _: UNUserNotificationCenter,
        willPresent _: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
