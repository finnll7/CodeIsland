import Foundation
import UserNotifications

/// Tiered system notifications for the Panda plan balance: one shot per tier
/// when remaining credits drop to ≤40% / ≤20% / ≤10%.
///
/// - Sent tiers persist in UserDefaults (survive restarts).
/// - A refill (remaining back above 40% — i.e. a billing-window reset) clears
///   the sent flags so the next cycle re-alerts.
/// - One notification per check (the most severe newly-hit tier) — a bulk
///   burn-down while asleep never triple-buzzes.
/// - Authorization is requested once at app launch; a denied consent simply
///   mutes the alerts (the quota card still shows the numbers).
@MainActor
public enum QuotaAlertNotifier {
    /// (maxRemainingPercent, defaults flag key, tier emoji, alert title)
    private static let tiers: [(maxRemaining: Int, key: String, emoji: String, title: String)] = [
        (40, "quotaAlertSent40", "🟡", "套餐余额已不足 40%"),
        (20, "quotaAlertSent20", "🟠", "套餐余额已不足 20%"),
        (10, "quotaAlertSent10", "🔴", "套餐余额仅剩不足 10%"),
    ]

    /// Pure tier selection: the most severe tier whose threshold is crossed
    /// and whose flag isn't sent yet. Nil = nothing to notify.
    nonisolated static func alertTier(
        remainingPercent: Int,
        sentFlags: Set<String>
    ) -> (key: String, emoji: String, title: String)? {
        // Refill (new billing window): remaining back above 40% clears flags.
        guard remainingPercent <= 40 else { return nil }
        let candidates = tiers.reversed().filter { tier in
            remainingPercent <= tier.maxRemaining && !sentFlags.contains(tier.key)
        }
        // Most severe = the smallest maxRemaining among unsent candidates.
        guard let tier = candidates.min(by: { $0.maxRemaining < $1.maxRemaining }) else {
            return nil
        }
        return (tier.key, tier.emoji, tier.title)
    }

    /// Called after every successful quota fetch. Blocking flag I/O is tiny
    /// (UserDefaults); the network permission dialog is requested once.
    public nonisolated static func check(snapshot: PandaQuotaSnapshot, defaults: UserDefaults = .standard) {
        let remainingPercent = max(0, min(100, 100 - Int(snapshot.usagePercent.rounded())))
        let sentFlags = Set(tiers.map(\.key).filter { defaults.bool(forKey: $0) })

        guard let tier = alertTier(remainingPercent: remainingPercent, sentFlags: sentFlags) else { return }
        defaults.set(true, forKey: tier.key)

        deliver(
            emoji: tier.emoji,
            title: tier.title,
            body: "剩余 \(snapshot.creditsDisplay(snapshot.remainingCredits)) Credits"
                + (snapshot.windowEndLabel.isEmpty ? "" : "，\(snapshot.windowEndLabel) 重置")
        )
    }

    nonisolated private static func deliver(emoji: String, title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "\(emoji) \(title)"
            content.body = body
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: "panda-quota-\(UUID().uuidString)",
                content: content,
                trigger: nil
            )
            center.add(request)
        }
    }

    /// One-time authorization prompt at launch (idempotent — a granted or
    /// denied consent never re-prompts).
    public nonisolated static func requestAuthorization() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
}
